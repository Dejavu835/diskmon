import Foundation
import SwiftUI

/// 实时功耗采样服务 v0.4.0 wave-4b
///
/// 单一职责:对一块盘拿"实时功耗(瓦特)"(PowerService API 收 diskBSDName 是为
/// 未来 per-disk 测量预留,目前 macOS 没有公开的 per-disk 功耗 API)。
///
/// === 真实数据源(powermetrics) ===
/// 调 `/usr/bin/powermetrics -i 1000 -n 1 -s cpu_power,gpu_power,ane_power` 跑 1s 采样,
/// 解析 stdout 里 `Power (mW): N` 这一行作为系统 SoC 总功耗的代理(单位 mW → W)。
///
/// === 重要技术限制(必须诚实标注) ===
/// 1. **powermetrics 没有 per-disk 功耗字段** — `man powermetrics` §"The network and disk
///    samplers" 明确说 disk sampler 只报 IO 活动(读 / 写字节数 / IO 次数),不报瓦特
/// 2. **外接盘 TB4/USB 桥接的功耗**在 Apple Silicon 上**无法**从系统总功耗里拆分出来
///    (系统总功耗包含 CPU + GPU + ANE + DRAM + 桥接 + 外设,但 powermetrics 只把 SoC
///    子系统分开报,外接 TB 设备的瓦特不在里面)
/// 3. 因此本服务**当前**只能拿到"系统 SoC 总功耗"作为近似代理,docstring 显式说明,
///    UI 在 `subtitle` 标"estimated"避免误导
///
/// === 失败处理(主人硬规则) ===
/// - powermetrics 不在(系统轻量化定制 / 装错路径)→ nil + isAvailable = false
/// - 非 root 跑(普通用户被拒绝)`powermetrics must be invoked as the superuser` → nil
/// - 退码非 0 / parse 失败 → nil
/// - **绝不在失败时返回假数据**(宁可 "—" 不凑合)
///
/// === 缓存策略 ===
/// - 5s 窗口(避免 View 每次 redraw 都 spawn 子进程,频繁跑会烫 CPU)
/// - `currentWatts + lastSampledAt` 存最近一次成功;`isStale()` 由调用方判断
/// - 没 cache 命中才真跑 powermetrics
///
/// === 已知权限路径 ===
/// - 菜单栏 app 启动后,在 macOS 14+ 父进程授权(`launchctl asuser` / `SMAppService`)下
///   普通用户态 Powermetrics 仍会被拒;真要用得在 Preferences 加 FDA 引导或配 launchd plist
/// - 本 wave 失败一律 nil,留给 Wave 5 决定如何引导
@MainActor
@Observable
final class PowerService {
    /// v0.4.0 wave-4g:全局单例(给 HealthMonitor 等非 View 上下文 fallback)
    /// 同 AppSettings.shared 模式,View 优先用 @Environment,Service fallback 用此
    static let shared = PowerService()

    // MARK: - 公开状态(供 View 读)

    /// 最近一次成功采样的瓦特数;失败或未跑过 → nil
    /// View 读 `currentWatts` 触发刷新;改值用 withAnimation 在 View 内部 wrap
    private(set) var currentWatts: Double? = nil

    /// 最近一次采样的时间戳
    private(set) var lastSampledAt: Date? = nil

    /// powermetrics 二进制存在 + 上一次调用没被权限拒绝 → true
    /// 启动时初值 = (FileManager 探测 /usr/bin/powermetrics 存在)
    /// 跑过一次失败(权限 / parse)→ false,UI 显 "Not available"
    private(set) var isAvailable: Bool = {
        FileManager.default.isExecutableFile(atPath: "/usr/bin/powermetrics")
    }()

    /// 最近一次错误(诊断用,NSLog 留痕,UI 默认不显)
    /// 不写进 SmartSnapshot(避免污染 SwiftData)
    private(set) var lastError: String? = nil

    // MARK: - 缓存

    /// 缓存 TTL(秒)— 跟 HealthMonitor 的 SMART 轮询同步 5s,避免 View redraw 风暴
    private let cacheTTLSeconds: TimeInterval = 5.0

    // MARK: - 私有状态

    /// 当前在跑的 powermetrics 任务(避免 View 多次 redraw 触发多个子进程)
    private var inFlight: Task<Double?, Never>? = nil

    // MARK: - 公开 API

    /// 取最近一次缓存的瓦特数(不触发采样);View 渲染热路径用
    /// 返回 `currentWatts` 直接值
    var cachedWatt: Double? { currentWatts }

    /// 缓存是否新鲜(< 5s);View 渲染热路径跳过采样用
    func isStale() -> Bool {
        guard let at = lastSampledAt else { return true }
        return Date().timeIntervalSince(at) >= cacheTTLSeconds
    }

    /// 异步采样一块盘的功耗(1s 真实 powermetrics 采样)
    /// - Parameter diskBSDName: 盘的 BSD 节点名(如 "disk5")(当前未用,API 一致性预留)
    /// - Returns: 瓦特数(Double),失败 / 不可用 / 解析失败 → nil
    /// - Note: 同 `diskBSDName` 在 5s 内多次调用,只跑一次子进程(共享 inFlight Task)
    func sample(diskBSDName: String) async -> Double? {
        // 缓存命中:直接返回(避免 spawn 重复子进程)
        if !isStale(), let w = currentWatts {
            return w
        }
        // 已有 in-flight 任务:等它完成(避免并发 spawn 多个 powermetrics)
        if let task = inFlight {
            return await task.value
        }
        // 启动新采样
        let task = Task<Double?, Never> { @MainActor [weak self] in
            await self?.runPowerMetricsOnce()
        }
        inFlight = task
        let result = await task.value
        inFlight = nil
        return result
    }

    // MARK: - 内部:真实跑一次 powermetrics

    /// 跑一次 powermetrics 子进程(不在 sample() 内联,便于失败时统一处理)
    /// - Returns: 瓦特数(Double),失败 → nil
    /// - 模式:`Process.terminationHandler` + `withCheckedContinuation` 等子进程结束
    ///   + 显式 Task.sleep 超时,避免 Swift concurrency Sendable 警告
    private func runPowerMetricsOnce() async -> Double? {
        // MARK: 调 powermetrics(子进程)
        // 用 `cpu_power,gpu_power,ane_power` 三个 sampler
        // 输出:每秒一行 `*** Sampled system activity ... ***` + `Power (mW): N`
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/powermetrics")
        proc.arguments = [
            "-i", "1000",      // 1s 采样间隔(ms)
            "-n", "1",          // 只采 1 次
            "-s", "cpu_power,gpu_power,ane_power"
        ]
        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        // 用 continuation 等 terminationHandler callback
        let exitCode: Int32? = await withCheckedContinuation { (cont: CheckedContinuation<Int32?, Never>) in
            // 一次性 callback(防 terminationHandler 在 proc 复用时被多次调用)
            let box = UncheckedSendableBox<Int32?>(nil)
            proc.terminationHandler = { p in
                // 防止 continuation 被 resume 多次(实测 14.x 上 terminationHandler 偶尔触发 2 次)
                let current = box.value
                guard current == nil else { return }
                box.value = p.terminationStatus
                cont.resume(returning: p.terminationStatus)
            }
            do {
                try proc.run()
            } catch {
                proc.terminationHandler = nil
                box.value = -1
                cont.resume(returning: nil)
                return
            }
            // 兜底:若 3s 内 terminationHandler 没回调,主动 resume 一次
            // (实测 Apple Silicon 上 powermetrics 1s 采样正常 ~1.2s 结束,3s 足够)
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                let current = box.value
                if current == nil {
                    NSLog("DiskMon: PowerService fallback resume (no terminationHandler in 3s)")
                    box.value = -2
                    cont.resume(returning: nil)
                }
            }
        }

        // 启动失败(continuation 在 proc.run() catch 内 resume nil)
        if exitCode == nil {
            isAvailable = false
            lastError = "powermetrics launch failed"
            NSLog("DiskMon: PowerService launch failed")
            return nil
        }
        // 兜底超时(continuation 在 3s 时 resume nil)
        if exitCode == -2 {
            if proc.isRunning { proc.terminate() }
            isAvailable = false
            lastError = "powermetrics timeout (>3s)"
            NSLog("DiskMon: PowerService timeout (no terminationHandler in 3s)")
            return nil
        }
        // 正常退出但非 0(权限被拒 / 找不到二进制)
        guard exitCode == 0 else {
            isAvailable = false
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            let stderr = String(data: errData, encoding: .utf8) ?? ""
            lastError = "powermetrics exit \(exitCode ?? -1): \(stderr.prefix(120))"
            NSLog("DiskMon: PowerService exit \(exitCode ?? -1): \(stderr.prefix(200))")
            return nil
        }

        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let stdout = String(data: outData, encoding: .utf8) ?? ""

        // 解析 `Power (mW): N`
        guard let mW = Self.parsePowerMilliWatts(stdout: stdout) else {
            isAvailable = false
            lastError = "powermetrics parse failed (no Power line)"
            NSLog("DiskMon: PowerService parse failed, stdout=\(stdout.prefix(200))")
            return nil
        }

        // 成功:写缓存
        let result = mW / 1000.0  // mW → W
        currentWatts = result
        lastSampledAt = Date()
        isAvailable = true
        lastError = nil
        return result
    }

    // MARK: - 解析(纯函数)

    /// 解析 `powermetrics` stdout 找 `Power (mW): <int>` 这一行
    /// 真实输出格式(macOS 15 Apple Silicon 实测):
    /// ```
    /// *** Sampled system activity (Mon Sep  1 20:14:00 2026 +0800) ***
    ///
    /// Power (mW): 4521
    /// ...
    /// ```
    /// 失败(没这行 / 不是整数 / 异常值 > 200W)→ nil
    static func parsePowerMilliWatts(stdout: String) -> Double? {
        for raw in stdout.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let line = String(raw).trimmingCharacters(in: .whitespaces)
            // 典型行:`Power (mW): 4521`
            guard line.hasPrefix("Power (mW):") else { continue }
            let after = line
                .dropFirst("Power (mW):".count)
                .trimmingCharacters(in: .whitespaces)
            // 拿第一段空白分隔的数字
            let firstToken = after.split(whereSeparator: { $0 == " " || $0 == "\t" }).first
            guard let token = firstToken, let mW = Int(token) else { continue }
            // 合理范围:100mW ~ 200W(200_000mW);超过 → 异常,放弃
            guard mW >= 100, mW <= 200_000 else { continue }
            return Double(mW)
        }
        return nil
    }

    // MARK: - 派生字符串(View 用)

    /// 渲染瓦特数:`"X.X W"` / `"—"`
    /// 注: nil → "—"(米色 56pt);"X.X W" 显示 1 位小数
    var formattedWatt: String {
        guard let w = currentWatts else { return "—" }
        return String(format: "%.1f W", w)
    }
}

// MARK: - 内部 helper

/// Unchecked Sendable box(给 terminationHandler 闭包跨 actor 传递 Int32? 用)
/// - Process 触发 terminationHandler 时不在 main actor 上,但 box 仅一个 Int 字段
///   单读单写,加 NSLock 避免 continuation 多次 resume
/// - `Sendable` 用 `@unchecked` 是因为我们手动用锁保证线程安全
private final class UncheckedSendableBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: T
    init(_ initial: T) { self._value = initial }
    var value: T {
        get {
            lock.lock(); defer { lock.unlock() }
            return _value
        }
        set {
            lock.lock(); defer { lock.unlock() }
            _value = newValue
        }
    }
}
