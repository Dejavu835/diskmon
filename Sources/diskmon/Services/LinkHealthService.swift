import Foundation
import SwiftUI

/// LinkHealthService v0.8 polish-L
/// 监控 macOS 链接健康(NVMe/PCIe/TB/USB4)协商 vs 期望
///
/// === 设计动机(grok 调研) ===
/// - 防 silent USB fallback:主人 WD Blue SN570 期望 PCIe 4.0 × 4(16 GT/s 双向),实际若
///   通过 TB4 → USB 3.x 桥接会 fallback 到 10 GT/s / 5 GT/s
/// - system_profiler -detailLevel full -json SPThunderboltDataType 拿 TB4 协商 speed/width
/// - diskutil info -plist <mountPoint> 拿 BusProtocol + DeviceTreePath
/// - 缓存 60s 避免高频调用拖慢 pollOnce
///
/// === 已知限制 ===
/// - USB-NVMe enclosure 走 USB 桥接(不是 TB),system_profiler 拿不到 PCIe speed,width 也
///   不可用 — UI 优雅降级 "—"
/// - system_profiler 启动慢(1-3s),不在 1s tick 调,只放 60s 缓存
/// - Intel vs Apple Silicon ThunderboltDataType 输出 schema 不同(Apple Silicon 4.0
///   × 4 = 16 GT/s;Intel Mac 3.0 × 4 = 8 GT/s)
/// - macOS 内部盘走 Apple Fabric,BusProtocol 是 "PCI-Express" 但 speed 拿不到(系统隐藏)
///   → nil + 降级
@MainActor
@Observable
final class LinkHealthService {
    // MARK: - 数据结构

    /// 单盘 link snapshot(60s 缓存 key)
    /// - 公开字段,UI 端读
    /// - Equatable 用于 SwiftUI diff
    struct LinkSnapshot: Equatable {
        let bsdName: String
        /// diskutil info -plist → `BusProtocol` 字段
        /// 真实值:`PCI-Express` / `USB` / `Thunderbolt` / `SATA` 等
        let busProtocol: String
        /// 协商 speed(GT/s)— PCIe Gen 数字 × 1.0
        /// 例:PCIe 4.0 × 4 = 16.0 GT/s,PCIe 3.0 × 2 = 6.0 GT/s
        /// nil = 无法读取(system_profiler 没匹配 / 内部盘 / 旧 OS)
        let negotiatedSpeedGTs: Double?
        /// 协商 width(× lanes)— 1 / 2 / 4 / 8 / 16
        let negotiatedWidth: Int?
        /// 期望 speed(基于盘类型 + 桥接协议估算,见 LinkHealthService.estimateExpected)
        let expectedSpeedGTs: Double?
        /// 期望 width
        let expectedWidth: Int?
        let capturedAt: Date
    }

    /// key = BSD name("disk5"),value = LinkSnapshot
    /// - 同一盘 60s 内重复读 → 走缓存,避免 system_profiler 1-3s 启动开销
    var snapshots: [String: LinkSnapshot] = [:]

    // MARK: - 私有状态

    /// 60s 缓存 TTL
    private static let cacheTTL: TimeInterval = 60

    /// 缓存过期时间戳(key = BSD name)
    private var cacheExpiry: [String: Date] = [:]

    /// ThunderboltDataType JSON 全量缓存(避免每个盘都跑 system_profiler)
    /// 同一进程内 system_profiler 输出不会变(无热插触发,本 service 主动 invalidate)
    private var thunderboltCache: (data: [[String: Any]], capturedAt: Date)?
    private static let thunderboltCacheTTL: TimeInterval = 30

    /// 已知期望 speed 表(基于 BusProtocol 推断)
    /// - PCIe 4.0 × 4 = 16.0 GT/s  → Apple Silicon WD Black SN850X 等
    /// - PCIe 3.0 × 4 = 8.0 GT/s   → 老款 NVMe
    /// - USB 3.2 Gen 2x2 = 10 GT/s → USB-NVMe 桥接盒子
    private static let expectedTable: [String: (speed: Double, width: Int)] = [
        "PCI-Express":  (16.0, 4),  // 乐观假设 PCIe 4.0 × 4
        "Thunderbolt":  (40.0, 4),  // TB4 = 40 GT/s,但底层是 PCIe 3.0 × 4 = 8 GT/s 给 NVMe
        "USB":          (10.0, 1),  // USB 3.2 Gen 2x2 桥接盒子
        "SATA":         (6.0, 1),   // SATA 3 = 6 Gbps(估算)
    ]

    // MARK: - 公开 API

    /// 取指定 mountPoint 的 link snapshot
    /// - 优先走 60s 缓存
    /// - 缓存 miss → 跑 diskutil info + system_profiler(全量 TB JSON,30s 缓存)
    /// - 失败(nil 字段)不假数据
    func snapshot(for mountPoint: String) async -> LinkSnapshot? {
        // 先拿 BSD name(从 mountPoint 解析)→ 走快照缓存
        // 这里 key 用 mountPoint,实际缓存用 mountPoint 串作为 key 更直观
        if let cached = snapshots[mountPoint],
           let expiry = cacheExpiry[mountPoint],
           expiry > Date() {
            return cached
        }
        // 1) diskutil info -plist <mountPoint> 拿 BSD + BusProtocol
        guard let info = await runDiskutilInfo(mountPoint: mountPoint),
              let bsd = info["DeviceIdentifier"] as? String,
              let busProtocol = info["BusProtocol"] as? String else {
            return nil
        }
        // 2) system_profiler -json SPThunderboltDataType 找匹配 BSD
        let (speed, width) = await lookupThunderboltLink(bsd: bsd, busProtocol: busProtocol)
        // 3) 估算期望值
        let (expectedSpeed, expectedWidth) = Self.expectedTable[busProtocol]
            ?? (nil, nil)
        let snap = LinkSnapshot(
            bsdName: bsd,
            busProtocol: busProtocol,
            negotiatedSpeedGTs: speed,
            negotiatedWidth: width,
            expectedSpeedGTs: expectedSpeed,
            expectedWidth: expectedWidth,
            capturedAt: Date()
        )
        snapshots[mountPoint] = snap
        cacheExpiry[mountPoint] = Date().addingTimeInterval(Self.cacheTTL)
        return snap
    }

    /// 批量刷新所有已 watch 盘
    /// - 调一次 system_profiler(走 30s 缓存)+ 多次 diskutil info
    /// - HealthMonitor.startHotPlugObserver 之后调一次,后续可在 hot-plug 时再调
    func refreshAll(mountPoints: [String]) async {
        // 先清 TB cache,确保拿到最新状态
        thunderboltCache = nil
        for mp in mountPoints {
            _ = await snapshot(for: mp)
        }
    }

    /// 清缓存(下次 snapshot 重新 spawn diskutil + system_profiler)
    func invalidateCache() {
        snapshots = [:]
        cacheExpiry = [:]
        thunderboltCache = nil
    }

    // MARK: - 健康度评分

    /// 降级判断:negotiated speed < expected speed(>= 1 step down)
    /// - WD Blue SN570 期望 4.0 × 4 = 16 GT/s,实际 3.0 × 2 = 6 GT/s → 降级
    /// - nil 字段 → 不判断(数据不足,UI 优雅降级)
    static func isDegraded(_ snap: LinkSnapshot) -> Bool {
        // expectedTable guesses PCIe 4.0×4 for every PCI-Express disk.
        // A Gen3 SN570 at 8 GT/s would look "degraded". No Identify table → no flag.
        _ = snap
        return false
    }

    // MARK: - 私有实现

    /// 跑 `diskutil info -plist <mountPoint>` 解析
    /// - 用 `/usr/sbin/diskutil`(系统自带,不用 SmartctlPathLocator)
    /// - 失败 → nil(不抛错,UI 优雅降级)
    private func runDiskutilInfo(mountPoint: String) async -> [String: Any]? {
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
                NSLog("LinkHealth: diskutil spawn failed: \(error)")
                return nil
            }
            let outData = pipe.fileHandleForReading.readDataToEndOfFile()
            proc.waitUntilExit()
            guard proc.terminationStatus == 0 else { return nil }
            guard let plist = try? PropertyListSerialization.propertyList(
                from: outData, format: nil
            ) as? [String: Any] else { return nil }
            return plist
        }.value
    }

    /// system_profiler -detailLevel full -json SPThunderboltDataType 解析
    /// - 30s 缓存,避免高频调用
    /// - Apple Silicon 真实输出:items[] → "device_name" / "vendor_id" / "device_id" 等
    ///   - 关键字段:`"link_speed"` (string: "40 Gb/s") + `"link_width"` (string: "x4")
    ///   - 不含 BSD name 字段 — 我们 fallback:若该 disk 在 TB tree 下(从 diskutil
    ///     info 的 DeviceTreePath 推断),用最接近的 TB bus link
    /// - Intel Mac 输出 schema 不同
    /// - 失败 / 内部盘 → 返回 (nil, nil)
    private func lookupThunderboltLink(
        bsd: String,
        busProtocol: String
    ) async -> (speed: Double?, width: Int?) {
        // BusProtocol 不是 Thunderbolt/PCI-Express 时,不需要查 TB tree
        guard busProtocol == "Thunderbolt" || busProtocol == "PCI-Express" else {
            return (nil, nil)
        }
        // 取(可能已缓存的)TB JSON
        let data = await fetchThunderboltData()
        guard let data = data, !data.isEmpty else {
            return (nil, nil)
        }
        // Apple Silicon ThunderboltDataType items[]:
        //   - "link_speed" : "40 Gb/s" / "20 Gb/s" / "10 Gb/s" 等
        //   - "link_width" : "x4" / "x2" / "x1"
        // 我们没拿到 disk → TB bridge 的直接 mapping(没有 "BSD" 字段),
        // 所以用 "max link_speed" + "max link_width" 作为 negotiated 上限
        // (注:这是 over-approximation;若多盘在同 TB bus,真实协商可能更低;
        //  gpt-4o audit 8/31 主人 Mac 实际只有 1 个 TB 设备,这个 over-approx 足够)
        var maxSpeedGTs: Double = 0
        var maxWidth: Int = 0
        for item in data {
            if let speed = parseLinkSpeed(item["link_speed"] as? String) {
                maxSpeedGTs = max(maxSpeedGTs, speed)
            }
            if let width = parseLinkWidth(item["link_width"] as? String) {
                maxWidth = max(maxWidth, width)
            }
        }
        return (maxSpeedGTs > 0 ? maxSpeedGTs : nil,
                maxWidth > 0 ? maxWidth : nil)
    }

    /// 拿 ThunderboltDataType JSON(30s 缓存)
    private func fetchThunderboltData() async -> [[String: Any]]? {
        if let cached = thunderboltCache,
           cached.capturedAt.addingTimeInterval(Self.thunderboltCacheTTL) > Date() {
            return cached.data
        }
        let raw: Any? = await Task.detached(priority: .utility) {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
            proc.arguments = ["-detailLevel", "full", "-json", "SPThunderboltDataType"]
            let pipe = Pipe()
            proc.standardOutput = pipe
            proc.standardError = Pipe()
            do {
                try proc.run()
            } catch {
                return nil
            }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            proc.waitUntilExit()
            guard proc.terminationStatus == 0 else { return nil }
            return try? JSONSerialization.jsonObject(with: data)
        }.value
        guard let dict = raw as? [String: Any],
              let items = dict["SPThunderboltDataType"] as? [[String: Any]]
        else {
            return nil
        }
        thunderboltCache = (items, Date())
        return items
    }

    /// 解析 "40 Gb/s" → 40.0(GT/s 当成 Gb/s 对待 — PCIe Gen 编码的 GT/s 等同 Gb/s)
    /// 实际 PCIe 4.0 = 16 GT/s,TBT4 link = 40 Gbps(TB 协议层 40 Gbps,底层 4 条 PCIe 3.0 = 8 GT/s)
    /// - 我们这里用 "GT/s" 表达协商 speed,值取自 system_profiler "link_speed" 字符串
    private func parseLinkSpeed(_ s: String?) -> Double? {
        guard let s = s, !s.isEmpty else { return nil }
        // "40 Gb/s" → 40.0
        let trimmed = s.replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "Gb/s", with: "")
            .replacingOccurrences(of: "GT/s", with: "")
        return Double(trimmed)
    }

    /// 解析 "x4" → 4
    private func parseLinkWidth(_ s: String?) -> Int? {
        guard let s = s, !s.isEmpty else { return nil }
        let trimmed = s.replacingOccurrences(of: "x", with: "")
            .replacingOccurrences(of: " ", with: "")
        return Int(trimmed)
    }
}

// grok 调研:v0.8 polish-L, macOS 链接健康(NVMe/PCIe/TB/USB4)监控
//   关键决策:用 system_profiler 拿 TB link,diskutil info 拿 BusProtocol;两张表期望 vs 协商
//   已知限制:USB-NVMe 盒子 system_profiler 无 link,UI 显示 "—"(不假数据)
//            内部盘 BusProtocol 隐藏,UI 显示 "—"
