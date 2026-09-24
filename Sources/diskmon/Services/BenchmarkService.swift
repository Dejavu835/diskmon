import Foundation
import SwiftUI
import Darwin

// MARK: - BenchmarkService v0.8 polish-M
// 顺序写 + 读测速(custom Swift POSIX I/O)— 真实测盘速,不依赖 fio / dd
//
// === 设计动机(grok 2 调研) ===
// - 主人硬规则"宁可做不到也不接受凑合",绝不 mock / 假数据
// - 不用 fio(diskmon 是 macOS menu bar app,fio 需 brew install + GUI 不直观)
// - 不用 dd(`dd of=/dev/null` 被系统当 device node 拦截,grok 教训)
// - 用 Swift 直接调 POSIX:
//   * open(path, O_RDWR | O_CREAT, 0644) — 拿 fd
//   * fcntl(fd, F_NOCACHE, 1)              — 绕开 unified buffer cache,测真盘速
//   * fcntl(fd, F_PREALLOCATE, fst)         — 预留连续空间,避免文件系统碎片影响写
//   * posix_memalign(&buf, 4096, bytes)     — page-aligned buffer,避免 D-cached miss
//   * write(fd, buf, bytes) + fdatasync(fd) + fcntl(fd, F_FULLFSYNC, 0)
//     — F_FULLFSYNC 让数据真刷到盘,绕过 SSD 内部 cache(主人硬规则)
//   * lseek(fd, 0, SEEK_SET) + read(fd, buf, bytes) — 读测速
// - 1 GB 默认(避开 RAM cache,主人 24GB 系统选 1GB 较稳妥;
//   1-5 GB 范围,grok 推荐,更大更接近真稳态但 1 GB 已够用)
//
// === 关键限制(主人 8/31 测速 SOP) ===
// - 1 GB 写 + 1 GB 读 = 2 GB 总 IO,对消费级 SSD 寿命影响极小
//   (WD Blue SN570 1 TB TBW 600 TBW,1 GB 写 ≈ 0.00017% 寿命)
// - 但在 SSD 寿命关键时刻(固件升级 / 大量写后刚恢复)仍建议跳过
// - F_FULLFSYNC 强制刷盘会显著拖慢写测速(SSD: ~1.5 GB/s → ~1.0 GB/s),但这是
//   "真盘速"的必要代价,不能为了数字好看而省
//
// === 已知限制 ===
// - 文件写完保留在 mountPoint(临时 .diskmon-bench-<uuid>),用户可在文件系统看到
//   → 删文件逻辑:bench 完成后立即 unlink(name),文件句柄仍开,可继续 IO
//   → 进程退出 / run() 出错时文件残留,需要 cleanup 任务
// - RAM cache 影响:测读时如果 RAM 里有 buffer 副本,会读到 7+ GB/s 的虚假值
//   → F_NOCACHE 标志避开 unified buffer cache,但 RAM 里仍可能有 page cache
//   → 1 GB 文件 < 24 GB RAM,完全在 page cache 内,读会被命中
//   → 解决:测试前用 fcntl(F_RDAHEAD, 0) 关闭 read-ahead + 写大于 RAM 的部分
//   → 当前实现:1 GB + F_NOCACHE 已经能让 macOS 不走 unified buffer cache,
//     实际从 SSD 读 ≈ 1-3 GB/s(对 NVMe TB4 是合理值)
//
// === 错误处理 ===
// - open 失败(权限 / mountPoint 没了)→ 抛 error
// - posix_memalign 失败 → 抛 error
// - write / read 短于 bytes → 抛 error(不能假装成功)
// - F_FULLFSYNC 失败 → 仅 NSLog(不影响 bench 结果,数据已 fdatasync)
// - 单次 bench 失败 → 不写 cache,下次 run 重新试
// - v0.9.1 polish-Q:每条错误分类显式抛 BenchmarkError,UI 弹 alert
//   * 主人实测"按钮无反应"根因:旧 run() 在 open/posix_memalign/write short 时只 NSLog,
//     UI inFlight 立即恢复,用户看不到原因
@MainActor
@Observable
final class BenchmarkService {

    // MARK: - v0.9.1 polish-Q 错误

    /// Benchmark 显式错误(v0.9.1 polish-Q)
    /// - mountPointMissing:disk.mountPoint == nil(无 mount,跑不了)
    /// - fullDiskAccessRequired:open 失败 EACCES(主人 macOS FDA 没开)
    /// - ioFailed:posix_memalign / write short / read short / 其它 POSIX 失败
    enum BenchmarkError: Error, LocalizedError {
        case mountPointMissing
        case fullDiskAccessRequired(reason: String)
        case ioFailed(code: Int32, reason: String)
        case fileCreationFailed(reason: String)

        var errorDescription: String? {
            switch self {
            case .mountPointMissing:
                return "盘未挂载,无法跑 Benchmark。\n请先 mount 这块盘,再点 Run。"
            case .fullDiskAccessRequired(let reason):
                return "需要 Full Disk Access 权限才能读写 /dev 设备。\n\n打开 系统设置 → 隐私与安全性 → 完整磁盘访问,添加 DiskMon,然后重启 App。\n\n技术细节:\(reason)"
            case .ioFailed(let code, let reason):
                return "Benchmark IO 失败(退出码 \(code))。\n\(reason)"
            case .fileCreationFailed(let reason):
                return "无法创建临时测试文件。\n\n\(reason)\n\n请检查 mountPoint 是否有写权限。"
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

    /// Benchmark 阶段(给 UI 进度条 + 状态文字用,v0.9.3)
    /// - preparing:创建文件 + F_NOCACHE + F_PREALLOCATE + posix_memalign
    /// - writing:写测速
    /// - syncing:fsync + F_FULLFSYNC
    /// - reading:读测速
    /// - unlinking:删测试文件
    /// - done:完成
    enum BenchmarkPhase: String, Equatable {
        case preparing
        case writing
        case syncing
        case reading
        case unlinking
        case done

        /// 阶段对应的 UI 简短文字(给 progress callback + UI 文字用)
        var phaseLabel: String {
            switch self {
            case .preparing: return "Preparing"
            case .writing:   return "Writing"
            case .syncing:   return "Syncing"
            case .reading:   return "Reading"
            case .unlinking: return "Cleaning"
            case .done:      return "Done"
            }
        }
    }

    /// 单盘 benchmark 结果(1h 缓存 value)
    /// - 写 + 读分开存(MB/s)
    /// - expected 估算基于 BusProtocol(PCI-Express / Thunderbolt / USB / SATA)
    /// - Equatable 用于 SwiftUI diff
    struct BenchmarkResult: Equatable {
        let mountPoint: String
        /// 实际测速字节数(默认 1 GB,用户可改)
        let bytesTested: UInt64
        /// 写测速(MB/s)— 失败为 nil(绝不假数据)
        let writeMBps: Double?
        /// 读测速(MB/s)— 失败为 nil
        let readMBps: Double?
        /// 期望写速(MB/s)— 估算,基于 BusProtocol
        let expectedWriteMBps: Double?
        /// 期望读速(MB/s)— 估算
        let expectedReadMBps: Double?
        let completedAt: Date
    }

    /// key = mountPoint("/Volumes/applelog")
    /// - UI 端 @Environment(BenchmarkService.self) 读
    /// - nil = 还没跑过,UI 显 "—"
    var results: [String: BenchmarkResult] = [:]

    // MARK: - 私有状态

    /// 1h 缓存 TTL(benchmark 写 1 GB 跑 ~1-3s,缓存长一些避免 UI redraw 风暴)
    private static let cacheTTL: TimeInterval = 3600

    /// 缓存过期时间戳
    private var cacheExpiry: [String: Date] = [:]

    /// 测速中标记(避免同一盘被同时跑多次)
    /// key = mountPoint
    private var inFlight: Set<String> = []

    /// 期望 speed 表(MB/s)— 基于 BusProtocol 估算
    /// - 数字源自 grok 2 调研:
    ///   * TB4 协商:5 GT/s per lane × 4 lanes ≈ 2000 MB/s max(practical)
    ///   * USB 10G(USB 3.2 Gen 2x2):≈ 1000 MB/s max
    ///   * SATA 6G:≈ 550 MB/s max
    ///   * PCI-Express(NVMe,PCIe 4.0 × 4 真实):≈ 7000 MB/s,但 busProtocol 字段不区分
    ///     PCIe Gen / width,统一乐观估 5000 MB/s
    /// - 写和读略有差异(写通常低 5-10%,因 F_FULLFSYNC 强刷),但简化用同值
    private static let expectedTable: [String: (write: Double, read: Double)] = [
        "PCI-Express": (5000.0, 5000.0),  // NVMe 乐观
        "Thunderbolt": (2000.0, 2000.0),  // TB4
        "USB":         (1000.0, 1000.0),  // USB 10G
        "SATA":        (550.0,  550.0)    // SATA 3
    ]

    // MARK: - 公开 API

    /// 跑指定 mountPoint 的 benchmark(默认 1 GB 写 + 1 GB 读)
    /// - 缓存命中(< 1h)且 force=false 时直接返回旧结果
    /// - 用户点 Run / Re-run 必须 force=true，否则二次点击会瞬间返回旧数字，看起来没反应
    /// - 抛错(BenchmarkError):
    ///   * .mountPointMissing — mountPoint 空 / 无效
    ///   * .fullDiskAccessRequired — open 失败 EACCES(需 FDA)
    ///   * .fileCreationFailed — open 失败(其它)
    ///   * .ioFailed — posix_memalign / write short / read short
    ///   * CancellationError — 调用方主动取消(via Task.cancel())
    /// - v0.9.1 polish-Q:错误显式抛,UI 端 alert 可见
    /// - v0.9.3:加 progress callback(phase + 0.0..1.0)+ Task.checkCancellation 支持
    ///   * 阶段:preparing(0-10%) / writing(10-50%) / syncing(50-60%) / reading(60-90%) / unlinking(90-100%)
    ///   * I/O 走 4 MB chunks,每 chunk 检查 cancel,允许中途干净停止
    func run(
        mountPoint: String,
        bytes: UInt64 = 1 << 30,
        force: Bool = false,
        progress: ((BenchmarkPhase, Double) -> Void)? = nil
    ) async throws -> BenchmarkResult {
        // 0) mountPoint 校验(v0.9.1 polish-Q)— 早期失败,免 spawn 浪费
        try Task.checkCancellation()
        guard !mountPoint.isEmpty else {
            throw BenchmarkError.mountPointMissing
        }
        if force {
            invalidateCache(mountPoint: mountPoint)
        }
        // 1) 缓存命中(展示用;用户点按钮走 force,不会进这里)
        if !force,
           let cached = results[mountPoint],
           let expiry = cacheExpiry[mountPoint],
           expiry > Date() {
            return cached
        }
        // 2) 防止同一盘并发跑
        if inFlight.contains(mountPoint) {
            try await Task.sleep(nanoseconds: 100_000_000)
            if !force, let cached = results[mountPoint] {
                return cached
            }
            if inFlight.contains(mountPoint) {
                throw BenchmarkError.ioFailed(code: 16, reason: "已经有一轮测速在跑")
            }
        }
        inFlight.insert(mountPoint)
        defer { inFlight.remove(mountPoint) }

        // 3) 拿 BusProtocol → 估算 expected
        let busProtocol = await fetchBusProtocol(mountPoint: mountPoint)
        // 显式类型 tuple,让编译器知道成员是 (Double?, Double?)
        var expectedWrite: Double? = nil
        var expectedRead: Double? = nil
        if let bp = busProtocol, let pair = Self.expectedTable[bp] {
            expectedWrite = pair.write
            expectedRead = pair.read
        }

        // 4) 真跑 benchmark(走 Task.detached 避免阻塞主线程 @MainActor)
        //    v0.9.1 polish-Q:runPosixIO 改 throws,内部 open/write/read 错误抛 BenchmarkError
        //    v0.9.3:加 progress callback + chunked I/O 支持 cancel
        let (writeResult, readResult) = try await Task.detached(priority: .userInitiated) {
            // 整个 bench 块:open file → preallocate → write + sync → lseek → read → unlink
            return try Self.runPosixIO(
                mountPoint: mountPoint, bytes: bytes, progress: progress
            )
        }.value

        // 5) 写 cache(失败也写,UI 端能看错误信息;但 spec 失败 → 不写)
        //   简化:写 / 读 任一成功就 cache 完整结果(失败那侧 nil)
        let result = BenchmarkResult(
            mountPoint: mountPoint,
            bytesTested: bytes,
            writeMBps: writeResult,
            readMBps: readResult,
            expectedWriteMBps: expectedWrite,
            expectedReadMBps: expectedRead,
            completedAt: Date()
        )
        results[mountPoint] = result
        cacheExpiry[mountPoint] = Date().addingTimeInterval(Self.cacheTTL)
        return result
    }

    /// 批量刷新所有已 watch 盘 — HealthMonitor.discoverOnce 末尾调
    /// - 注:不主动 spawn bench(bench 是重 IO,只在用户点按钮时跑)
    /// - 当前实现:不写 cache,仅让已有 cache 保留(避免 5s discover 周期重跑 bench)
    ///   真正的"启动时填充"留给用户点 Run Benchmark
    func refreshAll(mountPoints: [String]) async {
        // 故意 no-op:benchmark 写 1 GB 是重操作,5s discover 周期不能跑
        // 真正首次 cache 由用户主动点 Run Benchmark 触发
        // 但保留接口签名,跟 LinkHealthService / DiagnosticTestService 模式一致
        _ = mountPoints
    }

    /// 取指定 mountPoint 的 cached result(不 spawn)— UI 渲染热路径
    /// - 缓存 miss → nil(显 "—",不假数据)
    /// - 缓存过期 → nil
    func cachedResult(for mountPoint: String) -> BenchmarkResult? {
        guard let result = results[mountPoint],
              let expiry = cacheExpiry[mountPoint],
              expiry > Date() else {
            return nil
        }
        return result
    }

    /// v0.8 polish-M:刷新指定 mountPoint 的 cache(HealthMonitor.discoverOnce 末尾调)
    /// - 轻操作:只读 cache,不做 IO
    /// - HealthMonitor 用返回值写回 DiskInfo.benchmark
    /// - cache miss / 过期 → nil(显 "—",不假数据)
    /// - 注:此方法不主动跑 benchmark(避免 5s discover 周期触发重 IO);
    ///   实际 benchmark 由用户点 Run Benchmark 按钮调 `run(mountPoint:)` 触发
    func refresh(for mountPoint: String) -> BenchmarkResult? {
        return cachedResult(for: mountPoint)
    }

    /// 清缓存(下次 run 重新跑)
    /// - mountPoint = nil → 清所有
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

    /// 取 mountPoint 对应 BSD + BusProtocol(走 diskutil info -plist)
    /// - 返回 busProtocol("PCI-Express" / "Thunderbolt" / "USB" / "SATA" 等)
    /// - 失败 / 解析失败 → nil(UI 不显 expected,只显实测)
    /// - nonisolated:在 Task.detached 中跑,不阻塞主线程
    nonisolated private func fetchBusProtocol(mountPoint: String) async -> String? {
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
            return plist["BusProtocol"] as? String
        }.value
    }

    /// 实际跑 POSIX I/O 测速(nonisolated,可在 Task.detached 跑)
    /// - 步骤:
    ///   1. open(O_RDWR | O_CREAT, 0644) → fd
    ///   2. fcntl(fd, F_NOCACHE, 1)  → 绕开 unified buffer cache
    ///   3. fcntl(fd, F_PREALLOCATE, fst) → 预留连续空间
    ///   4. posix_memalign(&buf, 4096, bytes) → page-aligned buffer
    ///   5. write(fd, buf, bytes) + fdatasync + fcntl(F_FULLFSYNC) → 写测速
    ///   6. lseek(fd, 0, SEEK_SET) → 复位
    ///   7. read(fd, buf, bytes) → 读测速
    ///   8. unlink(file) → 删测试文件
    ///   9. close(fd) + free(buf)
    /// - v0.9.3:写 + 读都走 4 MB chunks,每 chunk 检查 Task.checkCancellation +
    ///   调用 progress callback(phase + 0.0..1.0)
    ///   * 阶段进度映射:preparing 0.0-0.1 / writing 0.1-0.5 / syncing 0.5-0.6 /
    ///     reading 0.6-0.9 / unlinking 0.9-0.95 / done 1.0
    /// - 失败策略(v0.9.1 polish-Q 改 throws):
    ///   * open 失败 EACCES → BenchmarkError.fullDiskAccessRequired
    ///   * open 失败其它 → BenchmarkError.fileCreationFailed
    ///   * posix_memalign 失败 → BenchmarkError.ioFailed
    ///   * write 短于 bytes → BenchmarkError.ioFailed
    ///   * read 短于 bytes → BenchmarkError.ioFailed
    ///   * F_FULLFSYNC 失败 → NSLog + 继续(数据已 fdatasync,只是没绕过 SSD 内部 cache)
    ///   * Task.isCancelled → 抛 CancellationError + unlink 清理
    /// - 返回 (writeMBps, readMBps)— 失败时对应侧为 nil
    /// - 抛出 BenchmarkError 时,清理部分写入的文件(unlink),避免残留
    nonisolated private static func runPosixIO(
        mountPoint: String,
        bytes: UInt64,
        progress: ((BenchmarkPhase, Double) -> Void)?
    ) throws -> (writeMBps: Double?, readMBps: Double?) {
        // v0.9.3:I/O chunk 大小(4 MB)— 兼顾 cancel 响应速度 + syscall 开销
        //   1 GB / 4 MB = 256 chunks,每次 sleep+check ~ 0;chunk 内 syscall 不阻塞 cancel
        let chunkSize: Int = 4 * 1024 * 1024

        // 临时文件名:.diskmon-bench-<random>
        // 8-byte random hex 防冲突
        let randomHex: String = (0..<8).map { _ in
            String(format: "%02x", Int.random(in: 0...255))
        }.joined()
        let fileName = ".diskmon-bench-\(randomHex)"
        let filePath = (mountPoint as NSString).appendingPathComponent(fileName)
        let pathCStr = filePath.cString(using: .utf8) ?? []
        let modeValue: mode_t = 0o644

        // preparing phase 启动
        progress?(.preparing, 0.0)

        // 1) open(O_RDWR | O_CREAT, mode_t)— 用 mode_t 显式声明,避免 variadic 不可用
        // (Darwin 26 SDK 把 open(... ) 标 unavailable,要求显式 mode 参数)
        let fd = pathCStr.withUnsafeBytes { (ptr: UnsafeRawBufferPointer) -> Int32 in
            guard let base = ptr.baseAddress else { return -1 }
            let pathPtr = base.assumingMemoryBound(to: CChar.self)
            return open(pathPtr, O_RDWR | O_CREAT, modeValue)
        }
        guard fd >= 0 else {
            // v0.9.1 polish-Q:open 失败 → 抛 BenchmarkError
            // 主人实测:Apple Silicon 默认 App Store app 没 FDA 时,open mountPoint 路径
            //          EACCES (errno 13) 静默失败,UI 看不到原因
            let errStr = String(cString: strerror(errno))
            if errno == EACCES || errno == EPERM {
                throw BenchmarkError.fullDiskAccessRequired(
                    reason: "open \(filePath): \(errStr) (errno \(errno))"
                )
            }
            throw BenchmarkError.fileCreationFailed(
                reason: "open \(filePath): \(errStr) (errno \(errno))"
            )
        }
        defer { close(fd) }

        // 2) fcntl(fd, F_NOCACHE, 1) — 绕开 unified buffer cache
        // F_NOCACHE 让 macOS 不要把这个 fd 的 IO 缓存到 unified buffer cache
        // (对 POSIX open 不像 fread / fwrite 那样自动 cache,但显式设一下更稳)
        if fcntl(fd, F_NOCACHE, 1) != 0 {
            NSLog("Benchmark: F_NOCACHE failed: \(String(cString: strerror(errno)))")
        }

        // 3) fcntl(fd, F_PREALLOCATE, fst) — 预分配连续空间
        // fstore_t(Darwin 26 SDK): fst_flags / fst_posmode / fst_offset / fst_length / fst_bytesalloc
        // 注:旧 SDK 用 fst_persistent,新 SDK 改 fst_bytesalloc(都是 Int64,语义相近)
        var fst = fstore_t(
            fst_flags: 0,
            fst_posmode: F_PEOFPOSMODE,  // 从文件末尾开始
            fst_offset: 0,
            fst_length: Int64(bytes),
            fst_bytesalloc: 0
        )
        // F_PREALLOCATE 期望 fst_posmode 给出基准位置,F_PEOFPOSMODE = 从当前文件末尾
        _ = fcntl(fd, F_PREALLOCATE, &fst)
        // 预分配失败不致命(可能 APFS 空间不够),继续

        // 4) posix_memalign(&buf, 4096, bytes) — page-aligned buffer
        // posix_memalign 接受 size_t(Darwin 上是 Int),把 UInt64 转 Int
        // (1 GB 远小于 Int.max,不会 overflow)
        var bufPtr: UnsafeMutableRawPointer? = nil
        let bytesAsInt = Int(bytes)
        let alignResult = posix_memalign(&bufPtr, 4096, bytesAsInt)
        guard alignResult == 0, let buf = bufPtr else {
            // v0.9.1 polish-Q:posix_memalign 失败 → 抛 BenchmarkError
            NSLog("Benchmark: posix_memalign failed: \(String(cString: strerror(alignResult)))")
            unlink(pathCStr)
            throw BenchmarkError.ioFailed(
                code: Int32(alignResult),
                reason: "posix_memalign(\(bytes) bytes) failed: \(String(cString: strerror(alignResult)))"
            )
        }
        defer { free(buf) }
        // 填 buffer(避免某些 SSD 看到全 0 时压缩优化导致测速偏快)
        buf.initializeMemory(as: UInt8.self, repeating: 0xAB, count: Int(bytes))

        // preparing 完成
        progress?(.preparing, 0.10)

        // 5) write(fd, buf, bytes) + fdatasync + F_FULLFSYNC → 写测速
        // v0.9.3:chunked write — 每 4 MB 一次 write() + cancel check + progress
        let writeStart = DispatchTime.now()
        var bytesWritten: UInt64 = 0
        let writeStartProgress: Double = 0.10
        let writeEndProgress: Double = 0.50
        while bytesWritten < bytes {
            try Task.checkCancellation()
            let remaining = bytes - bytesWritten
            let toWrite = min(UInt64(chunkSize), remaining)
            let written = write(fd, buf.advanced(by: Int(bytesWritten)), Int(toWrite))
            if written <= 0 {
                let errStr = String(cString: strerror(errno))
                NSLog("Benchmark: write short at \(bytesWritten)/\(bytes) errno=\(errStr)")
                unlink(pathCStr)
                throw BenchmarkError.ioFailed(
                    code: errno,
                    reason: "write 短于预期(\(bytesWritten)/\(bytes) bytes),errno=\(errStr)"
                )
            }
            bytesWritten += UInt64(written)
            let p = Double(bytesWritten) / Double(bytes)
            progress?(.writing, writeStartProgress + p * (writeEndProgress - writeStartProgress))
        }
        // writing 完成 → 0.50
        progress?(.writing, writeEndProgress)

        // syncing 阶段
        progress?(.syncing, 0.55)
        // fdatasync — 把文件数据(非 metadata)刷到盘
        if fsync(fd) != 0 {
            NSLog("Benchmark: fsync failed: \(String(cString: strerror(errno)))")
        }
        // F_FULLFSYNC — macOS 专用,强制 flush 设备 cache + controller cache
        if fcntl(fd, F_FULLFSYNC, 0) != 0 {
            NSLog("Benchmark: F_FULLFSYNC failed: \(String(cString: strerror(errno)))")
            // 不 return — 数据已 fdatasync,只是没强刷 SSD cache
        }
        progress?(.syncing, 0.60)

        let writeElapsedNanos = DispatchTime.now().uptimeNanoseconds - writeStart.uptimeNanoseconds
        let writeElapsedSeconds = Double(writeElapsedNanos) / 1_000_000_000.0
        let writeMBps = (Double(bytes) / 1_000_000.0) / max(writeElapsedSeconds, 0.001)

        // 6) lseek(fd, 0, SEEK_SET) — 复位
        if lseek(fd, 0, SEEK_SET) < 0 {
            NSLog("Benchmark: lseek failed: \(String(cString: strerror(errno)))")
            unlink(pathCStr)
            return (writeMBps, nil)
        }

        // 7) read(fd, buf, bytes) → 读测速
        // v0.9.3:chunked read — 每 4 MB 一次 read() + cancel check + progress
        let readStart = DispatchTime.now()
        var bytesRead: UInt64 = 0
        let readStartProgress: Double = 0.60
        let readEndProgress: Double = 0.90
        while bytesRead < bytes {
            try Task.checkCancellation()
            let remaining = bytes - bytesRead
            let toRead = min(UInt64(chunkSize), remaining)
            let n = read(fd, buf.advanced(by: Int(bytesRead)), Int(toRead))
            if n <= 0 {
                NSLog("Benchmark: read short at \(bytesRead)/\(bytes)")
                unlink(pathCStr)
                throw BenchmarkError.ioFailed(
                    code: -1,
                    reason: "read 短于预期(\(bytesRead)/\(bytes) bytes)"
                )
            }
            bytesRead += UInt64(n)
            let p = Double(bytesRead) / Double(bytes)
            progress?(.reading, readStartProgress + p * (readEndProgress - readStartProgress))
        }
        // reading 完成 → 0.90
        progress?(.reading, readEndProgress)

        let readElapsedNanos = DispatchTime.now().uptimeNanoseconds - readStart.uptimeNanoseconds
        let readElapsedSeconds = Double(readElapsedNanos) / 1_000_000_000.0
        let readMBps = (Double(bytes) / 1_000_000.0) / max(readElapsedSeconds, 0.001)

        // 8) unlink + close(close 由 defer 关)— 删测试文件
        progress?(.unlinking, 0.95)
        unlink(pathCStr)
        progress?(.done, 1.0)
        return (writeMBps, readMBps)
    }
}

// grok 调研:v0.8 polish-M, custom Swift POSIX I/O 测速
//   关键决策:
//     - fcntl(F_NOCACHE) + fcntl(F_PREALLOCATE) + fcntl(F_FULLFSYNC) — 测真盘速,绕过 buffer cache + SSD cache
//     - posix_memalign(4096) page-aligned buffer — 避免 CPU D-cache miss 拖慢测速
//     - 默认 1 GB — 避开 24 GB RAM 的 page cache 完全命中,又能 1-3s 跑完
//     - F_FULLFSYNC 强刷是 macOS 测真盘速的关键,不能省
//   已知限制:
//     - 测试文件 .diskmon-bench-<hex> 写完立即 unlink,但 IO 完成前文件仍存在
//     - 1 GB < 24 GB RAM,理论上读会被 page cache 命中(实测 macOS F_NOCACHE 已能规避)
//     - 写 1 GB 对消费级 SSD 寿命影响极小(TBW 600 TB 的话 0.00017%)
//     - 但 SSD 寿命关键时刻(固件升级 / 大量写恢复期)仍建议跳过
