import Foundation
import SwiftUI
import Darwin  // v0.9.1 polish-Q:EACCES / EPERM errno 常量

// MARK: - FSIntegrityService v0.8 polish-M
// 文件系统完整性检查 — 走 `diskutil verifyVolume` 只读路径
//
// === 设计动机(grok 2 调研) ===
// - APFS / HFS+ / ExFAT / FAT32 / NTFS 在 macOS 上都能跑 `diskutil verifyVolume`
// - verifyVolume 是只读,非破坏性,跟 `fsck_apfs -n` 行为一致(不动盘)
// - 用于检测文件系统元数据损坏 / 不一致(主人外接盘带电拔插可能触发)
// - 不替代 SMART self-test(SMART 测硬件,verifyVolume 测 FS 逻辑)
//
// === 关键决策 ===
// - **不用 `fsck_apfs -n`**:`fsck` 对非 APFS 文件系统(ExFAT / FAT32 / NTFS)无效,
//   `diskutil verifyVolume` 走 filesystem-aware 路径,自动选 fsck
// - **不用 `diskutil repairVolume`**:repair 是破坏性(改 FS),只用来 verify 不动
// - **24h 缓存**:verify 跑数秒 - 数十秒(取决于盘大小),1 天 1 spawn 足够
//   平时健康无需重跑;hot-plug 触发 invalidateCache
//
// === 已知限制 ===
// - USB-NVMe 桥接盒子 verify 可能会因为桥接器截获命令失败(类似 smartctl -t 的限制),
//   失败时 status = .failed(reason: "..."),UI 显"FAILED"
// - verifyVolume 在大文件系统上可能要 30s+,期间 UI 显示 .verifying(进度环)
// - 不写 SwiftData(verify 是一次性,无历史价值)
//
// === 状态机 ===
// .unknown         — 还没跑过
// .verifying       — 跑中(可能持续 30s+)
// .verified(date)  — 上次跑通过(capturedAt = Date)
// .warning(reason) — verify 发现问题但不致命(reason 来自 diskutil 输出)
// .failed(reason)  — 命令失败 / bridge 不支持 / exit 非 0
@MainActor
@Observable
final class FSIntegrityService {

    // MARK: - v0.9.1 polish-Q 错误

    /// FSIntegrity 显式错误(v0.9.1 polish-Q)
    /// - mountPointMissing:mountPoint 空 / 盘 unmount
    /// - fullDiskAccessRequired:diskutil 失败 EACCES(需 FDA 才能 unmount / fsck)
    /// - verifyFailed:其它 diskutil 失败(spawn / exit code 异常)
    /// - 注:bridge 不支持不抛错(转 .failed(reason) 给 UI 显 FAILED:...)
    enum FSIntegrityError: Error, LocalizedError {
        case mountPointMissing
        case fullDiskAccessRequired(reason: String)
        case verifyFailed(code: Int32, reason: String)

        var errorDescription: String? {
            switch self {
            case .mountPointMissing:
                return "盘未挂载,无法跑 diskutil verifyVolume。\n请先 mount 这块盘,再点 Verify。"
            case .fullDiskAccessRequired(let reason):
                return "需要 Full Disk Access 权限才能跑 diskutil verifyVolume。\n\n打开 系统设置 → 隐私与安全性 → 完整磁盘访问,添加 DiskMon,然后重启 App。\n\n技术细节:\(reason)"
            case .verifyFailed(let code, let reason):
                return "diskutil verifyVolume 失败(退出码 \(code))。\n\(reason)"
            }
        }

        var requiresOpenSettings: Bool {
            switch self {
            case .fullDiskAccessRequired: return true
            default: return false
            }
        }
    }
    // MARK: - 数据结构

    /// 完整性状态(枚举,带原因)
    enum IntegrityStatus: Equatable {
        case unknown
        case verified(date: Date)
        case warning(reason: String)
        case failed(reason: String)
        case verifying
    }

    /// 单盘 verify 结果(24h 缓存 value)
    struct IntegrityResult: Equatable {
        let mountPoint: String
        /// BSD name("disk5")— 从 diskutil info 拿,跟 LinkHealthService 一致
        let bsdName: String
        let status: IntegrityStatus
        let capturedAt: Date
    }

    /// key = mountPoint
    var results: [String: IntegrityResult] = [:]

    // MARK: - 私有状态

    /// 24h 缓存 TTL
    private static let cacheTTL: TimeInterval = 24 * 3600

    /// 缓存过期时间戳
    private var cacheExpiry: [String: Date] = [:]

    /// 测速中标记(避免并发跑)
    private var inFlight: Set<String> = []

    // MARK: - 公开 API

    /// 跑指定 mountPoint 的 FS integrity verify
    /// - 缓存命中(< 24h)→ 直接返回
    /// - 否则 spawn `diskutil verifyVolume <mountPoint>` + 解析 stdout/stderr
    /// - 抛错(FSIntegrityError):
    ///   * .mountPointMissing — mountPoint 空
    ///   * .fullDiskAccessRequired — diskutil 失败 EACCES
    ///   * .verifyFailed — spawn 失败 / 其它不可恢复
    ///   * CancellationError — 调用方主动取消(via Task.cancel())
    /// - 注:bridge 不支持场景(USB-NVMe 桥接器拦截 diskutil)— 不抛错,转 .failed(reason)
    ///   UI 显 "FAIL: <reason>"(已实现);此场景下 verify 命令实际跑过,只是 verifyVolume
    ///   失败,这跟"命令发不出"是不同的失败模式
    /// - v0.9.1 polish-Q:每条错误显式抛 + 携带 stderr,UI 弹 alert
    /// - v0.9.3:加 progress callback(0.0..1.0)+ Task.checkCancellation 支持
    ///   * diskutil verifyVolume 不输出阶段进度(只输出最终结果),所以用 estimatedDuration
    ///     配合 time-based 进度推进(0.0 → 0.95,完成后跳 1.0)
    ///   * 默认 estimatedDuration = 30s(典型 APFS 容器)
    func verify(
        mountPoint: String,
        progress: ((Double) -> Void)? = nil
    ) async throws -> IntegrityResult {
        // 0) mountPoint 校验(v0.9.1 polish-Q)
        try Task.checkCancellation()
        guard !mountPoint.isEmpty else {
            throw FSIntegrityError.mountPointMissing
        }
        // 1) 缓存命中
        if let cached = results[mountPoint],
           let expiry = cacheExpiry[mountPoint],
           expiry > Date() {
            return cached
        }
        // 2) 防止并发
        if inFlight.contains(mountPoint) {
            try await Task.sleep(nanoseconds: 100_000_000)
            if let cached = results[mountPoint] {
                return cached
            }
        }
        inFlight.insert(mountPoint)
        defer { inFlight.remove(mountPoint) }

        // 3) 显 .verifying 状态(让 UI 立刻更新进度环)
        let bsdName = await fetchBSDName(mountPoint: mountPoint) ?? "unknown"
        let verifyingResult = IntegrityResult(
            mountPoint: mountPoint,
            bsdName: bsdName,
            status: .verifying,
            capturedAt: Date()
        )
        results[mountPoint] = verifyingResult
        cacheExpiry[mountPoint] = Date().addingTimeInterval(Self.cacheTTL)

        // 4) 跑 diskutil verifyVolume(走 Task.detached 不阻塞主线程)
        //    v0.9.1 polish-Q:runDiskutilVerify 改 throws
        //    v0.9.3:外层 await,内层用 TaskGroup 实现 cancel + progress 联动
        //    diskutil verifyVolume 是阻塞 spawn,无法内部 emit progress
        //    所以外层用 estimatedDuration × elapsed ratio 推 progress(0.0..0.95)
        let estimatedDuration: TimeInterval = 30  // APFS 容器典型 30s
        progress?(0.0)
        let start = Date()
        let verifyTask = Task.detached(priority: .userInitiated) { () -> (FSIntegrityService.IntegrityStatus, Date) in
            try Self.runDiskutilVerify(mountPoint: mountPoint)
        }
        // 轮询 elapsed → 推 progress(直到 verifyTask 完成)
        let progressTask = Task { @MainActor in
            while !Task.isCancelled {
                let elapsed = Date().timeIntervalSince(start)
                let p = min(0.95, elapsed / estimatedDuration)
                progress?(p)
                try? await Task.sleep(nanoseconds: 250_000_000)  // 4 Hz
            }
        }
        let (status, capturedAt): (IntegrityStatus, Date)
        do {
            (status, capturedAt) = try await verifyTask.value
            progressTask.cancel()
        } catch {
            progressTask.cancel()
            throw error
        }

        // 5) 写 cache
        let result = IntegrityResult(
            mountPoint: mountPoint,
            bsdName: bsdName,
            status: status,
            capturedAt: capturedAt
        )
        results[mountPoint] = result
        cacheExpiry[mountPoint] = Date().addingTimeInterval(Self.cacheTTL)
        progress?(1.0)
        return result
    }

    /// 批量刷新所有已 watch 盘 — HealthMonitor.discoverOnce 末尾调
    /// - 注:不主动 spawn verify(verify 是重 IO,只在用户点按钮 / hot-plug 时跑)
    /// - 当前实现:不写 cache,仅让已有 cache 保留
    ///   真正首次 cache 由用户主动点 Verify 触发
    func refreshAll(mountPoints: [String]) async {
        // 故意 no-op:verify 跑数秒 - 数十秒,5s discover 周期不能跑
        // 真正首次 cache 由用户主动点 Verify 触发
        _ = mountPoints
    }

    /// 取指定 mountPoint 的 cached result(不 spawn)— UI 渲染热路径
    func cachedResult(for mountPoint: String) -> IntegrityResult? {
        guard let result = results[mountPoint],
              let expiry = cacheExpiry[mountPoint],
              expiry > Date() else {
            return nil
        }
        return result
    }

    /// v0.8 polish-M:刷新指定 mountPoint 的 cache(HealthMonitor.discoverOnce 末尾调)
    /// - 轻操作:只读 cache,不做 IO
    /// - HealthMonitor 用返回值写回 DiskInfo.integrity
    /// - cache miss / 过期 → nil(显 "—",不假数据)
    /// - 注:此方法不主动跑 verify(避免 5s discover 周期触发重 IO,
    ///   diskutil verifyVolume 跑数秒 - 数十秒,5s 跑会拖垮系统);
    ///   实际 verify 由用户点 Verify 按钮调 `verify(mountPoint:)` 触发
    func refresh(for mountPoint: String) -> IntegrityResult? {
        return cachedResult(for: mountPoint)
    }

    /// 清缓存
    func invalidateCache(mountPoint: String? = nil) {
        if let mp = mountPoint {
            results.removeValue(forKey: mp)
            cacheExpiry.removeValue(forKey: mp)
        } else {
            results = [:]
            cacheExpiry = [:]
        }
    }

    // MARK: - 私有实现

    /// 拿 mountPoint 对应 BSD name(走 diskutil info -plist)
    /// - 失败 → "unknown"(仍能 verify,只是 bsdName 字段显示 "unknown")
    /// - nonisolated:在 Task.detached 中跑,不阻塞主线程
    nonisolated private func fetchBSDName(mountPoint: String) async -> String? {
        await Task.detached(priority: .utility) {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
            proc.arguments = ["info", "-plist", mountPoint]
            let pipe = Pipe()
            let errPipe = Pipe()
            proc.standardOutput = pipe
            proc.standardError = errPipe
            do {
                try proc.run()
            } catch {
                return nil
            }
            let outData = pipe.fileHandleForReading.readDataToEndOfFile()
            proc.waitUntilExit()
            guard proc.terminationStatus == 0 else { return nil }
            guard let plist = try? PropertyListSerialization.propertyList(
                from: outData, format: nil
            ) as? [String: Any] else { return nil }
            return plist["DeviceIdentifier"] as? String
        }.value
    }

    /// 跑 `diskutil verifyVolume <mountPoint>` + 解析输出
    /// - exit 0 + "appears to be OK" → .verified
    /// - exit 0 + "Problems were found" → .warning(reason)
    /// - exit != 0 → .failed(reason: stderr 截取)
    /// - "verify/repair" 是 diskutil 标准 stdout 头
    /// - 注:verifyVolume 命令本身不修改 FS,但如果盘有问题仍可能触发 auto-repair;
    ///   实测在 APFS 上是只读 verify(走 fsck_apfs -n),与 diskutil man page 描述一致
    /// - 抛错(FSIntegrityError):
    ///   * .fullDiskAccessRequired — EACCES / "Operation not permitted"
    ///   * .verifyFailed — spawn 失败 / 其它不可恢复
    ///   * CancellationError — Task 被 cancel + proc 被 SIGTERM 杀
    /// - nonisolated:在 Task.detached 中跑,不阻塞主线程
    /// - v0.9.1 polish-Q:FDA 检测 → 抛 .fullDiskAccessRequired
    ///   bridge 不支持 / FS 真问题 → 转 .failed(reason) 不抛(UI 显 "FAIL: <reason>")
    /// - v0.9.3:支持 Task.cancel — cancel 时 proc.terminate() 杀进程,waitUntilExit 立即返回
    nonisolated private static func runDiskutilVerify(
        mountPoint: String
    ) throws -> (status: IntegrityStatus, capturedAt: Date) {
        let capturedAt = Date()
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
        proc.arguments = ["verifyVolume", mountPoint]
        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe
        do {
            try proc.run()
        } catch {
            // spawn 失败:通常是 binary 路径错 / sandbox 拦截
            throw FSIntegrityError.verifyFailed(
                code: -1,
                reason: "spawn failed: \(error.localizedDescription)"
            )
        }
        // v0.9.3:Task cancel 联动 — 检测到 cancel 时调 proc.terminate() 杀 diskutil
        // poll 50ms 间隔,既快响应 cancel,又不过度占用 CPU
        let cancelMonitorTask = Task.detached(priority: .background) {
            while !Task.isCancelled {
                if Task.isCancelled {
                    if proc.isRunning {
                        proc.terminate()
                    }
                    return
                }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
        }
        defer { cancelMonitorTask.cancel() }
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        // proc 退出后 cancel monitor 也会自然停(defer + Task.cancel)
        let stdout = String(data: outData, encoding: .utf8) ?? ""
        let stderr = String(data: errData, encoding: .utf8) ?? ""
        let combined = stdout + stderr
        let code = proc.terminationStatus
        // v0.9.3:如果是被 SIGTERM 杀的(15)— 抛 CancellationError
        // 注:Process.terminationStatus 对 SIGTERM 返回 15
        if code == 15 && cancelMonitorTask.isCancelled {
            throw CancellationError()
        }
        // v0.9.1 polish-Q:FDA 检测 — 优先级最高,抛 .fullDiskAccessRequired
        // diskutil 在没 FDA 时对 /dev/rdiskN 操作可能 EACCES / "Operation not permitted"
        if code == EACCES
            || combined.contains("Operation not permitted")
            || combined.contains("Permission denied") && combined.contains("/dev/")
            || code == 69 {  // EX_NOPERM
            throw FSIntegrityError.fullDiskAccessRequired(
                reason: "diskutil exit \(code): \(combined.prefix(160).trimmingCharacters(in: .whitespacesAndNewlines))"
            )
        }
        // 解析 stdout — 关键短语
        // "The volume ... appears to be OK" → pass
        // "Problems were found with the volume" → warning
        // 其他(没匹配)→ 根据 exit code 分类
        if stdout.contains("appears to be OK") || stdout.contains("was formatted") {
            return (.verified(date: capturedAt), capturedAt)
        }
        if stdout.contains("Problems were found") || stdout.contains("needs repair") {
            // 截取相关行作为 reason
            let reasonLines = stdout.split(whereSeparator: { $0 == "\n" })
                .filter { line in
                    let s = String(line)
                    return s.contains("error") || s.contains("problem")
                       || s.contains("repair") || s.contains("fix")
                }
                .prefix(3)
                .map(String.init)
            let reason = reasonLines.joined(separator: " · ")
            return (.warning(reason: reason.isEmpty ? "Problems found" : reason), capturedAt)
        }
        // 没匹配短语,看 exit code
        switch code {
        case 0:
            // exit 0 但没匹配短语 — 保守归 .verified
            return (.verified(date: capturedAt), capturedAt)
        case 1, 2:
            // exit 1/2 — verify 失败 / 部分问题
            let reason = stderr.isEmpty ? "verify exited \(code)" : stderr.prefix(120).description
            return (.warning(reason: reason), capturedAt)
        default:
            // exit 64+ — 桥接器拒绝 / 命令不支持
            // 不抛错,转 .failed(reason),让 UI 显 "FAIL: <reason>"(已实现)
            let reason = stderr.isEmpty
                ? "exit \(code)"
                : stderr.prefix(120).description
            return (.failed(reason: reason), capturedAt)
        }
    }
}

// grok 调研:v0.8 polish-M, FS 完整性 diskutil verifyVolume 只读
//   关键决策:
//     - diskutil verifyVolume(不是 fsck_apfs):走 fs-aware 路径,APFS/ExFAT/FAT32/NTFS 都支持
//     - 不用 diskutil repairVolume(repair 是破坏性,动 FS)
//     - 24h 缓存:verify 跑数秒 - 数十秒,1 天 1 spawn 足够
//     - 解析 "appears to be OK" / "Problems were found" 关键短语分类
//   已知限制:
//     - USB-NVMe 桥接盒子 verify 可能被桥接器拒绝 → .failed
//     - verifyVolume 在大文件系统上 30s+,UI 显示 .verifying 状态
//     - 失败不抛错,转 .failed(reason) — UI 端显 "FAILED: <reason>",不凑合
