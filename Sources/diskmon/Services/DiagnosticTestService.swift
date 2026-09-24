import Foundation
import SwiftUI
import DiskMonCore

/// DiagnosticTestService v0.8 polish-L → v0.9.1 polish-Q
/// 跑 SMART self-test + 解析结果 + 集成到 HealthPredictor 闭环
///
/// === 设计动机(grok 调研) ===
/// - 闭环 observe → predict → **verify**:
///   * observe:SMART 实时采(celsius / percentageUsed / mediaErrors 等)
///   * predict:HealthPredictor 算 healthScore(0-100)+ warning 等级
///   * verify:smartctl -t short/long + 读 -l selftest 结果
/// - SelfTestResult.failed → 该盘立即 .danger(HealthPredictor 已有 forceDanger 入口,
///   未来扩展;本次先把 lastTest 暴露给 View + HealthMonitor.evaluate)
///
/// === 已知限制 ===
/// - USB-NVMe 桥接盒子:smartctl -t 不支持(无法发 ATA/NVMe command,桥接器拦截)
///   → 抛 SelfTestError.notSupported,UI 显 "Self-tests not supported on this disk"
/// - Apple 内置 SSD(Apple NVMe controller)通常不开放 SMART self-test 接口
///   → 同样抛 SelfTestError.notSupported
/// - Long test 跑数小时,不能阻塞主线程;本次实现走 fire-and-forget,只 spawn 进程;
///   下次 fetchLastResult 自动拿到完成结果
/// - smartctl 需 Full Disk Access;FDA 缺失时抛 SelfTestError.fullDiskAccessRequired,
///   UI 引导用户开 FDA("Open Settings" 按钮)
///
/// === v0.9.1 polish-Q 错误处理 ===
/// 主人实测"Test 按钮无反应"根因:
/// - 旧逻辑把 exit 0/1/2 都视为成功,直接 return stdout
/// - 但 Apple 内置 SSD:exit 0 + stdout "Self-tests not supported" → 静默没反应
/// - 旧实现 userInfo 仅 NSLog,UI 看不到 error
/// 改:runTest 抛 SelfTestError,UI 显 alert + Open Settings 按钮
@MainActor
@Observable
final class DiagnosticTestService {
    // MARK: - 数据结构

    /// Self-test 状态(v0.8 polish-L)
    /// - .idle:从没跑过 / 跑了又 cleared
    /// - .running(progress):正在跑(由 fetchLastResult 实时读 -l selftest 进度)
    /// - .passed(date):上次跑通过
    /// - .failed(reason):上次跑失败(reason 来自 smartctl 输出)
    /// - .aborted:用户主动取消 / 命令发不出(USB 桥接 / FDA 缺失)
    enum SelfTestResult: Equatable {
        case idle
        case running(progress: Double)
        case passed(date: Date)
        case failed(reason: String)
        case aborted
    }

    /// 单盘 self-test 快照(24h 缓存 key)
    /// - 暴露给 UI 端读
    /// - 包含 short / long 上次结果
    struct TestSnapshot: Equatable {
        let bsdName: String
        let lastShortTest: SelfTestResult
        let lastLongTest: SelfTestResult
        let capturedAt: Date
    }

    /// key = BSD name("disk5")
    var snapshots: [String: TestSnapshot] = [:]

    // MARK: - v0.9.1 polish-Q 错误

    /// SelfTest 显式错误(v0.9.1 polish-Q)
    /// - 主人实测"按钮无反应"根因:旧逻辑把 exit 0/1/2 都视为成功,错误仅 NSLog
    /// - 改:每条错误分类显式抛,UI 端弹 alert + "Open Settings" 按钮引导 FDA
    enum SelfTestError: Error, LocalizedError {
        /// smartctl 二进制未找到(brew install smartmontools)
        case smartmontoolsNotFound
        /// 需要 Full Disk Access(macOS TCC 拦截)
        /// 主人 macOS 14-15 默认开 App Store app 不给 FDA,需手动 Settings 加
        case fullDiskAccessRequired
        /// smartctl 退出,但输出说设备不支持 self-test
        /// - Apple 内置 SSD:exit 0,stdout "Self-tests not supported"
        /// - USB-NVMe 桥接:exit 2,stderr "Operation not supported by device"
        case notSupported(reason: String)
        /// smartctl 退出非 0 / spawn 失败(其它原因)
        case commandFailed(code: Int32, stderr: String)
        /// BSD name 为空
        case invalidBSDName
        /// Poll timed out; the drive may still be testing.
        case timedOut

        var errorDescription: String? {
            switch self {
            case .smartmontoolsNotFound:
                return "smartmontools 未安装。\n请运行:brew install smartmontools"
            case .fullDiskAccessRequired:
                return "需要 Full Disk Access 权限才能跑 SMART self-test。\n\n打开 系统设置 → 隐私与安全性 → 完整磁盘访问,添加 DiskMon,然后重启 App。"
            case .notSupported:
                return "这块盘不能跑 SMART 自检。USB 移动盘和多数桥接盒不把自检命令传给盘体，不是权限问题。"
            case .commandFailed(_, let stderr):
                let line = compactSmartctlLine(stderr)
                if line.lowercased().contains("not support") || line.lowercased().contains("operation not") {
                    return "这块盘不能跑 SMART 自检。USB 移动盘通常不透传自检命令。"
                }
                return line.isEmpty ? "SMART 自检失败。" : line
            case .invalidBSDName:
                return "无效的 BSD name"
            case .timedOut:
                return "短测等了太久。盘上可能还在跑，点中止可以停。"
            }
        }

        /// 是否引导用户去开 FDA(UI 端决定是否显 "Open Settings" 按钮)
        var requiresOpenSettings: Bool {
            switch self {
            case .fullDiskAccessRequired: return true
            default: return false
            }
        }

    }

    // MARK: - 私有状态

    /// 24h 缓存 TTL(self-test log 不会高频变,缓存长一些避免重复 spawn)
    private static let cacheTTL: TimeInterval = 24 * 3600

    /// 缓存过期时间戳
    private var cacheExpiry: [String: Date] = [:]

    /// 上次 spawn short test 的 BSD name(轮询进度用)
    private var pendingShortTest: Set<String> = []

    /// 上次 spawn long test 的 BSD name
    private var pendingLongTest: Set<String> = []

    /// smartctl 路径复用 SmartctlPathLocator
    private let smartctlPath: String? = SmartctlPathLocator.resolve()

    // MARK: - 公开 API

    /// 跑 short self-test(短路,~ 1-2min)
    /// - 步骤:smartctl -t short /dev/diskN → spawn → 把 BSD 加 pendingShortTest
    /// - 阻塞(等 spawn 完 + 设备 test 跑完,期间每 2s 拉 -l selftest 更新 progress)
    /// - 抛错:FDA 缺失 / smartctl 缺失 / USB 桥接不支持 / CancellationError
    /// - v0.9.3:加 progress callback + Task.checkCancellation 支持
    ///   * progress 范围 0.0..1.0;0.05 = 命令已发,1.0 = 完成(pass / fail / abort)
    ///   * ETA 由 View 端基于 elapsed / progress 算
    func runShortTest(
        bsdName: String,
        progress: ((Double) -> Void)? = nil
    ) async throws {
        try await runTest(bsdName: bsdName, type: "short", progress: progress)
    }

    /// Abort a device self-test (`smartctl -X`). Same -d fallback as -t.
    func abortTest(bsdName: String) async {
        pendingShortTest.remove(bsdName)
        pendingLongTest.remove(bsdName)
        invalidateCache(bsdName: bsdName)
        guard let path = smartctlPath, !bsdName.isEmpty else { return }
        let deviceTypes: [String?] = ["nvme", nil, "sat", "sntjmicron", "usbjmicron"]
        for dtype in deviceTypes {
            var args = ["-X", "/dev/\(bsdName)"]
            if let dtype { args.insert(contentsOf: ["-d", dtype], at: 0) }
            let result = (try? await runSelfTestCommand(args: args, path: path)) ?? .failed(code: -1, stderr: "")
            if case .success = result { break }
            if case .needsFDA = result { break }
        }
    }

    /// 跑 long self-test(长路,~ 数小时)
    /// - 后台跑,期间每 5s 拉 -l selftest 更新 progress(降低 polling 频率避免设备负载)
    /// - 抛错同 runShortTest
    func runLongTest(
        bsdName: String,
        progress: ((Double) -> Void)? = nil
    ) async throws {
        try await runTest(bsdName: bsdName, type: "long", progress: progress)
    }

    /// Self-test 预计完成时间(秒)— 给 View 端算 ETA 用
    /// - SHORT:1-2min,中位数 90s
    /// - LONG:2-8h,中位数 14400s(4h)
    static func estimatedDuration(type: String) -> TimeInterval {
        switch type {
        case "short": return 90
        case "long":  return 4 * 3600
        default:      return 90
        }
    }

    /// 读 self-test log(从 smartctl -l selftest /dev/diskN)
    /// - 返回 TestSnapshot(包含 lastShortTest + lastLongTest)
    /// - 缓存 24h,避免每 5s poll 都 spawn
    /// - 抛错:FDA / smartctl / 解析失败
    /// - v0.9.3:加 forceRefresh 参数 — runTest 内部轮询用 forceRefresh=true 绕过 cache
    ///   拿实时 progress;HealthMonitor.pollOnce 用默认(cache 命中)避免 5s 周期重 spawn
    func fetchLastResult(
        bsdName: String,
        forceRefresh: Bool = false,
        applyPending: Bool = true
    ) async throws -> TestSnapshot {
        // 缓存命中(forceRefresh=true 时跳过)
        if !forceRefresh,
           let cached = snapshots[bsdName],
           let expiry = cacheExpiry[bsdName],
           expiry > Date() {
            return cached
        }
        guard let path = smartctlPath else {
            throw SmartctlService.SmartctlError.missingExecutable
        }
        // Same -d fallback as -t. NVMe on Darwin often needs -d nvme.
        let deviceTypes: [String?] = ["nvme", nil, "sat", "sntjmicron", "usbjmicron"]
        var raw = ""
        var lastError: Error?
        for dtype in deviceTypes {
            var args = ["-l", "selftest", "/dev/\(bsdName)"]
            if let dtype { args.insert(contentsOf: ["-d", dtype], at: 0) }
            do {
                raw = try await spawnSmartctl(args: args, path: path)
                lastError = nil
                break
            } catch {
                lastError = error
                continue
            }
        }
        if raw.isEmpty, let lastError { throw lastError }
        let (short, long) = Self.parseSelfTestLog(stdout: raw)
        let effectiveShort = applyPending
            ? resolvePending(actual: short, isPending: pendingShortTest.contains(bsdName), bsdName: bsdName, kind: "short")
            : short
        let effectiveLong = applyPending
            ? resolvePending(actual: long, isPending: pendingLongTest.contains(bsdName), bsdName: bsdName, kind: "long")
            : long
        let snap = TestSnapshot(
            bsdName: bsdName,
            lastShortTest: effectiveShort,
            lastLongTest: effectiveLong,
            capturedAt: Date()
        )
        snapshots[bsdName] = snap
        cacheExpiry[bsdName] = Date().addingTimeInterval(Self.cacheTTL)
        return snap
    }

    /// 清缓存(下次 fetchLastResult 重新跑)
    func invalidateCache(bsdName: String? = nil) {
        if let bsd = bsdName {
            snapshots.removeValue(forKey: bsd)
            cacheExpiry.removeValue(forKey: bsd)
        } else {
            snapshots = [:]
            cacheExpiry = [:]
        }
    }

    // MARK: - 私有实现

    /// spawn `smartctl -t <type> /dev/<bsdName>` + 轮询直到设备 test 完成
    /// - type: "short" / "long"
    /// - v0.9.3:加 progress callback + Task.checkCancellation 支持
    ///   * spawn 完命令 → progress(0.05)
    ///   * 每 pollInterval(2s/5s)调 fetchLastResult 取 progress,转发给 callback
    ///   * 设备 test 跑完(从 -l selftest 读 .passed / .failed)→ progress(1.0) + return
    ///   * 任务被 cancel → 抛 CancellationError(干净退出,设备 test 继续后台跑)
    /// - 抛错(SelfTestError):
    ///   * .smartmontoolsNotFound — smartctl 二进制不存在
    ///   * .fullDiskAccessRequired — exit 251 / stderr 含 "Operation not permitted"
    ///   * .notSupported — stdout/stderr 含 "Self-tests not supported" /
    ///                     "Operation not supported by device"(Apple SSD / USB-NVMe)
    ///   * .commandFailed — 其它非 0 退出
    ///   * CancellationError — 调用方主动取消
    private func runTest(
        bsdName: String,
        type: String,
        progress: ((Double) -> Void)?
    ) async throws {
        try Task.checkCancellation()
        guard !bsdName.isEmpty else {
            throw SelfTestError.invalidBSDName
        }
        // 1) smartctl 二进制存在性
        guard let path = smartctlPath else {
            throw SelfTestError.smartmontoolsNotFound
        }
        // 2) sanity check:smartctl --version 必须能跑(走 spawnSmartctl 出口 0 = OK)
        //    失败原因可能是 binary 损坏 / quarantine 拦截
        //    但 --version 不需要 FDA,所以失败 → 几乎肯定是 binary 本身坏了
        let versionOK = (try? await spawnSmartctl(
            args: ["--version"], path: path, versionCheck: true
        )) != nil
        if !versionOK {
            throw SelfTestError.smartmontoolsNotFound
        }
        // 3) 真跑 -t short/long。不要写死 -d nvme：USB SAT / 桥接盘会
        //    「open /dev/diskN failed: Operation not supported」，再试 sat / 无 -d。
        let deviceTypes: [String?] = ["nvme", nil, "sat", "sntjmicron", "usbjmicron"]
        var last: SelfTestCommandOutcome = .failed(code: -1, stderr: "")
        var started = false
        for dtype in deviceTypes {
            var args = ["-t", type, "/dev/\(bsdName)"]
            if let dtype { args.insert(contentsOf: ["-d", dtype], at: 0) }
            let result = try await runSelfTestCommand(args: args, path: path)
            last = result
            switch result {
            case .success:
                started = true
            case .needsFDA:
                throw SelfTestError.fullDiskAccessRequired
            case .notSupported, .failed:
                continue
            }
            if started { break }
        }
        if !started {
            switch last {
            case .notSupported(let reason):
                throw SelfTestError.notSupported(reason: compactSmartctlLine(reason))
            case .failed(let code, let stderr):
                throw SelfTestError.commandFailed(code: code, stderr: stderr)
            case .needsFDA:
                throw SelfTestError.fullDiskAccessRequired
            case .success:
                break
            }
        }
        if type == "short" {
            pendingShortTest.insert(bsdName)
        } else if type == "long" {
            pendingLongTest.insert(bsdName)
        }
        // 5s 后让 fetchLastResult 拿到真实结果(短 test 跑 1-2min,但通常 5s 后能读到 progress)
        invalidateCache(bsdName: bsdName)
        // 4) v0.9.3:报告 progress 0.05(命令已发,设备 test 启动)
        progress?(0.05)
        let pollSeconds: Double = type == "short" ? 2 : 5
        let estimatedDuration = Self.estimatedDuration(type: type)
        // Was: duration / pollNs / 1e9 → Int ≈ 0, so we never left the -t wait.
        let maxPolls = max(8, Int((estimatedDuration * 1.5) / pollSeconds))
        var sawRunning = false
        var idleAfterStart = 0
        for i in 0..<maxPolls {
            try Task.checkCancellation()
            try await Task.sleep(nanoseconds: UInt64(pollSeconds * 1_000_000_000))
            try Task.checkCancellation()
            if let snap = try? await fetchLastResult(bsdName: bsdName, forceRefresh: true, applyPending: false) {
                let r = type == "short" ? snap.lastShortTest : snap.lastLongTest
                switch r {
                case .running(let p):
                    sawRunning = true
                    idleAfterStart = 0
                    progress?(max(0.05, min(0.99, p)))
                case .passed, .failed, .aborted:
                    progress?(1.0)
                    return
                case .idle:
                    idleAfterStart += 1
                    if sawRunning && idleAfterStart >= 2 {
                        progress?(1.0)
                        return
                    }
                    let elapsedFrac = min(0.85, Double(i + 1) / Double(maxPolls))
                    progress?(max(0.08, elapsedFrac))
                }
            }
        }
        throw SelfTestError.timedOut
    }

    private func resolvePending(
        actual: SelfTestResult,
        isPending: Bool,
        bsdName: String,
        kind: String
    ) -> SelfTestResult {
        guard isPending else { return actual }
        switch actual {
        case .passed, .failed, .aborted:
            if kind == "short" { pendingShortTest.remove(bsdName) }
            else { pendingLongTest.remove(bsdName) }
            return actual
        case .running:
            return actual
        case .idle:
            return .running(progress: 0.12)
        }
    }

    /// smartctl -t 命令的结果分类
    private enum SelfTestCommandOutcome {
        case success
        case notSupported(reason: String)
        case needsFDA
        case failed(code: Int32, stderr: String)
    }

    /// 跑 smartctl -t 命令并分类结果
    /// - success:exit 0/1/2 + stdout 不含 "not supported"
    /// - notSupported:exit 0/1/2 + stdout 含 "Self-tests not supported" /
    ///                 其它非 0 + stderr "Operation not supported by device"
    /// - needsFDA:exit 251 / stderr "Operation not permitted" / "must be invoked as root"
    /// - failed:其它
    /// 注:Apple 内置 SSD 走 exit 0 + "Self-tests not supported" → 静默;
    ///     现在显式分类抛 SelfTestError.notSupported,UI 弹 alert
    private func runSelfTestCommand(
        args: [String], path: String
    ) async throws -> SelfTestCommandOutcome {
        // 注:闭包不抛(用 return .failed 代替 throw),所以不需要 try
        await Task.detached(priority: .userInitiated) { () -> SelfTestCommandOutcome in
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: path)
            proc.arguments = args
            let outPipe = Pipe()
            let errPipe = Pipe()
            proc.standardOutput = outPipe
            proc.standardError = errPipe
            do {
                try proc.run()
            } catch {
                return .failed(code: -1, stderr: "spawn failed: \(error.localizedDescription)")
            }
            // -t on some Darwin NVMe waits until the test finishes. Cap at 12s;
            // the DST command is already on the drive.
            let isStart = args.contains("-t")
            let deadline = Date().addingTimeInterval(isStart ? 12 : 8)
            while proc.isRunning && Date() < deadline {
                Thread.sleep(forTimeInterval: 0.05)
            }
            if proc.isRunning {
                proc.terminate()
                Thread.sleep(forTimeInterval: 0.15)
                // Only NVMe -t is known to block until DST finishes; treat as started.
                if isStart && args.contains("nvme") { return .success }
                return .failed(code: -1, stderr: "smartctl timed out")
            }
            let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            proc.waitUntilExit()
            let stdout = String(data: outData, encoding: .utf8) ?? ""
            let stderr = String(data: errData, encoding: .utf8) ?? ""
            let combined = stdout + stderr
            let code = proc.terminationStatus
            // 1) FDA 检测(优先级最高 — 退出码 251 是 smartctl 约定,stderr 也会有 hint)
            if code == 251
                || combined.contains("Operation not permitted")
                || combined.contains("must be invoked as the superuser")
                || combined.contains("Permission denied") {
                return .needsFDA
            }
            // 2) "Self-tests not supported"(Apple 内置 SSD / 部分 USB 桥接)—
            //    可能在 stdout 也可能在 stderr
            if combined.contains("Self-tests not supported")
                || combined.contains("does not support Self-tests")
                || combined.contains("Operation not supported")
                || combined.contains("command not supported") {
                return .notSupported(reason: compactSmartctlLine(combined))
            }
            // 3) 退出码分类
            switch code {
            case 0, 1, 2:
                return .success
            default:
                return .failed(code: code, stderr: compactSmartctlLine(combined))
            }
        }.value
    }

    /// spawn smartctl + 读 stdout / 解析 exit code → 分类抛错
    /// - 251 → needsFullDiskAccess(抛 SmartctlService.SmartctlError.needsFullDiskAccess)
    /// - 0/1/2 → OK(返 stdout)
    /// - 其它 → commandFailed(抛 SmartctlService.SmartctlError.commandFailed)
    /// - `versionCheck = true` 时:任何非 0 退出都视为 binary 坏(用于 `--version` 探针)
    /// 注:此函数仍抛 SmartctlService.SmartctlError,供 fetchLastResult 等老调用用;
    ///    runTest 走 runSelfTestCommand 抛 SelfTestError(更细粒度)
    private func spawnSmartctl(
        args: [String], path: String, versionCheck: Bool = false
    ) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: path)
            proc.arguments = args
            let outPipe = Pipe()
            let errPipe = Pipe()
            proc.standardOutput = outPipe
            proc.standardError = errPipe
            do {
                try proc.run()
            } catch {
                throw SmartctlService.SmartctlError.commandFailed(-1, "spawn failed: \(error)")
            }
            let deadline = Date().addingTimeInterval(8)
            while proc.isRunning && Date() < deadline {
                Thread.sleep(forTimeInterval: 0.05)
            }
            if proc.isRunning {
                proc.terminate()
                Thread.sleep(forTimeInterval: 0.1)
                throw SmartctlService.SmartctlError.commandFailed(-1, "smartctl timed out")
            }
            let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            proc.waitUntilExit()
            let stdout = String(data: outData, encoding: .utf8) ?? ""
            let stderr = String(data: errData, encoding: .utf8) ?? ""
            let code = proc.terminationStatus
            switch code {
            case 251:
                throw SmartctlService.SmartctlError.needsFullDiskAccess
            case 0, 1, 2:
                if versionCheck && code != 0 {
                    // --version 期望 exit 0;1/2 在版本检查中视为失败(binary 坏 / quarantine)
                    throw SmartctlService.SmartctlError.missingExecutable
                }
                return stdout
            default:
                // USB 桥接 / 不支持设备 → exit 64 / 125 之类,显式 reason 让 UI 友好提示
                let combined = stdout + stderr
                throw SmartctlService.SmartctlError.commandFailed(code, combined)
            }
        }.value
    }

    // MARK: - self-test log 解析

    /// 解析 `smartctl -l selftest` 输出 → (shortResult, longResult)
    /// - smartctl 7.5 输出格式:
    ///   ```
    ///   SMART Self-test log structure: ...
    ///   Num  Test              Status                 ...
    ///   # 1  Short offline     Completed without error    09:30:11  ...
    ///   # 2  Long offline      Completed: read failure 10%  09:35:22 ...
    ///   ```
    /// - 取每个 test type 的最新一条(# 1 是最新,# N 是最旧)
    /// - Status 关键词:`Completed without error` → passed
    ///                `Completed: ...` → failed(reason)
    ///                `Self-test in progress ...` → running(progress 0.0..1.0)
    ///                `Aborted by host` → aborted
    static func parseSelfTestLog(stdout: String) -> (short: SelfTestResult, long: SelfTestResult) {
        let parsed = SelfTestLogParser.parse(stdout)
        return (mapLog(parsed.short), mapLog(parsed.long))
    }

    private static func mapLog(_ r: SelfTestLogParser.Result) -> SelfTestResult {
        switch r {
        case .idle: return .idle
        case .running(let p): return .running(progress: p)
        case .passed: return .passed(date: Date())
        case .failed(let reason): return .failed(reason: reason)
        case .aborted: return .aborted
        }
    }

    /// pending 时估算 progress(避免无 -l selftest 进度时显示 0)
    private static func estimateProgress(result: SelfTestResult, type: String) -> Double {
        if case .running(let p) = result { return p }
        // 默认 5%(刚启动,未读到进度)
        return 0.05
    }
}

/// Drop smartctl copyright / version banner; keep the one useful line.
private func compactSmartctlLine(_ raw: String) -> String {
    let lines = raw.split(whereSeparator: { $0.isNewline })
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty }
    let skip: (String) -> Bool = { line in
        let l = line.lowercased()
        if l.hasPrefix("smartctl ") { return true }
        if l.hasPrefix("copyright") { return true }
        if l.contains("smartmontools.org") { return true }
        if l.contains("local build") { return true }
        if l.contains("bruce allen") { return true }
        return false
    }
    let useful = lines.filter { !skip($0) }
    let hit = useful.first { line in
        let l = line.lowercased()
        return l.contains("fail") || l.contains("not support")
            || l.contains("operation not") || l.contains("unable to")
    }
    let picked = hit ?? useful.first ?? ""
    return String(picked.prefix(140))
}

// MARK: - 字符串正则辅助(不引 Regex literal,保持 Swift 5.7 兼容)

private extension String {
    /// 简易百分号匹配(非 Regex API):返回第一个 "数字%" 数字部分
    func firstMatch(in s: String) -> String? {
        let nsString = s as NSString
        // 用 NSScanner 找第一个数字
        let scanner = Scanner(string: nsString as String)
        scanner.charactersToBeSkipped = nil
        var number: Int = 0
        if scanner.scanInt(&number) {
            return String(number)
        }
        return nil
    }
}

// grok 调研:v0.8 polish-L, SMART self-test 闭环 observe→predict→verify
//   关键决策:runShortTest 走 fire-and-forget(不等 self-test 完成),fetchLastResult 实时读 -l selftest
//   已知限制:USB-NVMe 桥接不支持 self-test(command 会被桥接器拒绝),UI 显 "USB bridge not supported"
//            FDA 缺失时所有 self-test 命令失败,UI 引导用户开 FDA
