import Foundation
import DiskMonCore

/// 盘的基础信息
/// - volumeUUID: 持久化键(跨拔插稳定,ID 唯一)
/// - bsdName: 当前 BSD 节点(/dev/diskN,TB4 拔插会变,2 个 APFS 卷共享同一 backing disk)
/// v0.2.0: id 改用 volumeUUID(避免同 backing disk 的 2 卷 bsdName 重复)
/// v0.3.0: 加 usedBytes(diskutil info -plist → CapacityInUse 真实已用字节,无数据 = nil)
/// v0.4.0 wave-4c:usedBytes 由 HealthMonitor.refreshUsedBytesOnce 写回(每 5s discoverLoop tick
///   触发,内部 DiskDiscoveryService.usedBytes() 60s TTL 缓存 diskutil 调用)
/// v0.4.2:加 freeBytes / totalBytes(均为可选 UInt64,diskutil info -plist 真实读)
///   - freeBytes:`APFSContainerFree`(APFS 容器物理空闲字节;非 APFS fallback `Size - CapacityInUse`)
///   - totalBytes:`Size` / `TotalSize` / `IOKitSize`(三选一,均为磁盘卷声明大小)
///   - nil = 还没问过 diskutil / 盘没挂载 / 权限不够 / diskutil 失败
///   - UI 侧(CapacityModule)读到 nil → 优雅降级(数字 "—",不凑合假数据)
/// v0.8 polish-L:加 linkSnapshot / lastTest(LinkHealthService / DiagnosticTestService 写回)
///   - 都是 optional,未采集时 nil
///   - linkSnapshot 由 HealthMonitor.discoverOnce 末尾调 LinkHealthService.snapshot 写
///   - lastTest 由 HealthMonitor.pollOnce 末尾调 DiagnosticTestService.fetchLastResult 写
///   - Codable:linkSnapshot / lastTest 因为是嵌套结构体,在 CodingKeys 显式排除
/// v0.8 polish-M:加 benchmark / integrity(BenchmarkService / FSIntegrityService 写回)
///   - benchmark:用户点 Run Benchmark 后写,1h 缓存
///   - integrity:用户点 Verify 后写,24h 缓存
///   - 都不是 pollOnce 自动跑的(bench 写 1 GB 重 IO,verify 跑数十秒)— 等用户主动触发
///   - 一样从 CodingKeys 排除(运行时缓存,不持久化)
struct DiskInfo: Equatable, Identifiable, Codable {
    var id: String { volumeUUID }
    var bsdName: String       // "disk5"
    var volumeUUID: String    // 持久化键
    var mountPoint: String?   // "/Volumes/applelog"
    /// 卷名(diskutil VolumeName,例如 "Dahua" / "applelog")
    /// 显示优先用这个,不要只靠 mountPoint lastPathComponent
    var volumeName: String? = nil
    var isInternal: Bool
    var sizeBytes: Int64
    var modelName: String?
    /// 已用字节(diskutil info -plist → CapacityInUse 字段;人读显示为 "Volume Used Space")
    /// nil = 还没问过 diskutil(刚启动)或盘没挂载或权限不够或 diskutil 失败
    /// UI 侧(CapacityModule)读到 nil → "—" 圆圈 + 副标 "Not available",不凑合假数据
    var usedBytes: UInt64? = nil
    /// v0.4.2:空闲字节(diskutil info -plist → APFSContainerFree 字段;APFS 物理空闲)
    /// 非 APFS fallback:Size - CapacityInUse
    /// nil 含义同 usedBytes
    var freeBytes: UInt64? = nil
    /// v0.4.2:总字节(diskutil info -plist → Size / TotalSize / IOKitSize 字段,三选一)
    /// 跟 sizeBytes(来自 diskutil list -plist)通常一致,但 diskutil info 的 Size 更权威
    /// nil = 还没问过 diskutil
    var totalBytes: UInt64? = nil
    /// v0.8 polish-L:链接健康快照(TB4 / PCIe / USB 协商 vs 期望)
    /// nil = 还没跑过 LinkHealthService.snapshot(for:)
    /// Codable:从 CodingKeys 排除(运行时缓存,不持久化)
    var linkSnapshot: LinkHealthService.LinkSnapshot? = nil
    /// v0.8 polish-L:SMART self-test 上次结果
    /// nil = 还没跑过 DiagnosticTestService.fetchLastResult
    /// Codable:从 CodingKeys 排除(运行时缓存,不持久化)
    var lastTest: DiagnosticTestService.TestSnapshot? = nil
    /// v0.8 polish-M:benchmark 测速结果(写 + 读 MB/s)
    /// nil = 还没跑过 BenchmarkService.run(由用户点 Run Benchmark 触发)
    /// Codable:从 CodingKeys 排除(运行时缓存,不持久化)
    var benchmark: BenchmarkService.BenchmarkResult? = nil
    /// v0.8 polish-M:FS 完整性 verify 结果(diskutil verifyVolume)
    /// nil = 还没跑过 FSIntegrityService.verify(由用户点 Verify 触发)
    /// Codable:从 CodingKeys 排除(运行时缓存,不持久化)
    var integrity: FSIntegrityService.IntegrityResult? = nil
    /// diskutil info FilesystemName / FilesystemType。运行时字段，不持久化。
    var filesystemName: String? = nil
    /// diskutil info Writable。nil = 未问过 / 未挂载。
    var isVolumeWritable: Bool? = nil

    /// v0.9.8:IOKit / diskutil 身份。USB 桥没有 SMART 时仍能显示芯片、序列号、链路速度。
    var busProtocol: String? = nil
    var smartStatus: String? = nil
    var solidState: Bool? = nil
    var serialNumber: String? = nil
    var firmwareRevision: String? = nil
    var vendorName: String? = nil
    var productName: String? = nil
    var nvmeRevision: String? = nil
    var nvmeSMARTCapable: Bool? = nil
    var usbVendorId: String? = nil
    var usbProductId: String? = nil
    var usbSpeedGbps: Double? = nil
    /// IOPCIExpressLinkStatus，用来算 PCIe Gen × lanes
    var pcieLinkStatus: Int? = nil
    var usbLinuxType: String? = nil
    var bridgeChipName: String? = nil
    var sensorsHiddenByDarwin: Bool = false
    var smartCaptureSource: String? = nil
    var smartUnavailableKind: SmartUnavailableKind = .pending

    enum SmartUnavailableKind: String, Equatable, Sendable {
        case none
        case usbBridge
        case notSupported
        case pending
    }

    // v0.8 polish-L + v0.8 polish-M:显式 CodingKeys
    // 排除 linkSnapshot / lastTest / benchmark / integrity(运行时缓存,不持久化)
    // 内部自动合成的 decoder 会因这些嵌套结构体不是 Codable 而失败
    // → 显式列字段,只 decode 持久化字段,新字段从 CodingKeys 排除
    private enum CodingKeys: String, CodingKey {
        case bsdName, volumeUUID, mountPoint, volumeName, isInternal, sizeBytes, modelName
        case usedBytes, freeBytes, totalBytes
    }

    enum MediaKind: Equatable {
        case ssd, hdd, unknown
        var label: String {
            switch self {
            case .ssd: return "SSD"
            case .hdd: return "HDD"
            case .unknown: return ""
            }
        }
    }

    /// 固态 / 机械。只读已有 IOKit 字段，不再额外探测。
    var mediaKind: MediaKind {
        if solidState == true { return .ssd }
        if nvmeSMARTCapable == true { return .ssd }
        let blob = [busProtocol, modelName, productName]
            .compactMap { $0?.lowercased() }
            .joined(separator: " ")
        if blob.contains("nvme") || blob.contains("ssd") || blob.contains("solid") {
            return .ssd
        }
        if solidState == false { return .hdd }
        if blob.contains("hdd") || blob.contains("rotational") || blob.contains("hard disk") {
            return .hdd
        }
        return .unknown
    }

    /// APFS / ExFAT / NTFS / FAT32；未知保留原串；缺数据 "—"。
    var filesystemLabel: String {
        guard let raw = filesystemName, !raw.isEmpty else { return "—" }
        let compact = raw.lowercased().replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: "_", with: "")
        if compact.contains("apfs") { return "APFS" }
        if compact.contains("exfat") { return "ExFAT" }
        if compact.contains("ntfs") { return "NTFS" }
        if compact.contains("fat32") || compact.contains("msdos") || compact.contains("msdosfat") {
            return "FAT32"
        }
        return raw
    }

    var isNTFSVolume: Bool { filesystemLabel == "NTFS" }

    var isMounted: Bool {
        guard let mp = mountPoint else { return false }
        return !mp.isEmpty
    }

    func ntfsAccess(extensionOn: Bool) -> NTFSAccess {
        NTFSAccess.state(
            isNTFS: isNTFSVolume,
            mounted: isMounted,
            extensionOn: extensionOn,
            volumeWritable: isVolumeWritable
        )
    }

    /// Sidebar chips from captured fields only. Never invents NAND/die.
    var identityChips: [String] {
        IdentityChips.chips(
            mediaKind: mediaKind.label,
            vendor: vendorName,
            product: productName ?? modelName,
            firmware: firmwareRevision,
            serial: serialNumber,
            filesystem: filesystemLabel == "—" ? nil : filesystemLabel,
            bridgeChip: bridgeChipName
        )
    }

    /// 已用占比 0...1；缺数据 nil。
    var usedRatio: Double? {
        let total = totalBytes.map { Int64($0) } ?? sizeBytes
        guard total > 0, let used = usedBytes else { return nil }
        return min(1, max(0, Double(used) / Double(total)))
    }

    /// 小字容量："236 GB / 2.00 TB · 12%"。缺已用只显示总量。
    var capacityFootnote: String {
        let total = totalBytes.map { Int64($0) } ?? sizeBytes
        let totalText = ByteFormatter.bytes(total)
        guard let used = usedBytes, total > 0 else { return totalText }
        let pct = Int((Double(used) / Double(total) * 100).rounded())
        return "\(ByteFormatter.bytes(Int64(used))) / \(totalText)  ·  \(pct)%"
    }

    /// UI 显示名:VolumeName → /Volumes/ 末段 → model → BSD
    var displayName: String {
        if let n = volumeName, !n.isEmpty { return n }
        if let mp = mountPoint, let last = mp.split(separator: "/").last, !last.isEmpty {
            return String(last)
        }
        if let m = modelName, !m.isEmpty { return m }
        return bsdName
    }

    /// 外接用户卷才允许进列表/操作。系统盘一律排除。
    var isExternalUserVolume: Bool {
        if isInternal { return false }
        if isDiskImage { return false }
        let bus = (busProtocol ?? "").uppercased()
        if bus.contains("APPLE FABRIC") { return false }
        guard let mp = mountPoint else { return false }
        if mp == "/" || mp.hasPrefix("/System/") { return false }
        if !mp.hasPrefix("/Volumes/") { return false }
        let leaf = (mp as NSString).lastPathComponent
        if DiskInfo.isSystemVolumeName(leaf) || DiskInfo.isSystemVolumeName(volumeName) {
            return false
        }
        return true
    }

    /// macOS 自带卷（挂在 /Volumes 下也不该监控）。
    static func isSystemVolumeName(_ name: String?) -> Bool {
        DiskMonCore.SystemVolumeNames.isSystemVolumeName(name)
    }

    var isUSB: Bool {
        (busProtocol ?? "").uppercased().contains("USB")
    }

    /// Mounted .dmg / installer images. Not hardware — never watch, never count as drop.
    var isDiskImage: Bool {
        let bus = (busProtocol ?? "").uppercased()
        if bus.contains("DISK IMAGE") || bus.contains("DISKIMAGE") { return true }
        if let m = modelName?.uppercased(), m.contains("DISK IMAGE") { return true }
        return false
    }

    /// USB 桥不透传 SMART：盘上即使有传感器，macOS 也读不到。
    var isUSBBridgeWithoutSMART: Bool {
        guard isUSB else { return false }
        if nvmeSMARTCapable == true { return false }
        if smartStatus == "Verified" { return false }
        if smartUnavailableKind == .usbBridge { return true }
        if smartStatus == "Not Supported" { return true }
        return nvmeSMARTCapable == false
    }

    /// 当前协商接口速度，给「当前盘」一行用。没有就退回总线名。
    var interfaceSpeedLabel: String {
        if isUSB, let gb = usbSpeedGbps, gb >= 1 {
            if gb >= 1 {
                return String(format: "USB %.0f Gb/s", gb)
            }
        }
        if let pcie = Self.pcieSpeedLabel(status: pcieLinkStatus) {
            return pcie
        }
        if let snap = linkSnapshot, let g = snap.negotiatedSpeedGTs, g > 0 {
            if let w = snap.negotiatedWidth, w > 0 {
                return String(format: "%@ %.0f Gb/s ×%d", snap.busProtocol, g, w)
            }
            return String(format: "%@ %.0f Gb/s", snap.busProtocol, g)
        }
        if let bus = busProtocol, !bus.isEmpty { return bus }
        return "—"
    }

    /// PCIe Link Status：bits 3:0 = speed (1=2.5, 2=5, 3=8, 4=16, 5=32 GT/s)，bits 9:4 = width。
    static func pcieSpeedLabel(status: Int?) -> String? {
        guard let status, status > 0 else { return nil }
        let code = status & 0xF
        let width = (status >> 4) & 0x3F
        let gen: String
        switch code {
        case 1: gen = "1.0"
        case 2: gen = "2.0"
        case 3: gen = "3.0"
        case 4: gen = "4.0"
        case 5: gen = "5.0"
        default: return nil
        }
        if width > 0 {
            return "PCIe \(gen) ×\(width)"
        }
        return "PCIe \(gen)"
    }

    var identityLine: String {
        var parts: [String] = []
        let speed = interfaceSpeedLabel
        if speed != "—" { parts.append(speed) }
        if isUSB {
            if speed == "—" { parts.append("USB") }
            let chip = [vendorName, productName ?? mediaChipFallback]
                .compactMap { $0 }
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            if !chip.isEmpty { parts.append(chip) }
            if let vid = usbVendorId, let pid = usbProductId {
                parts.append("\(vid):\(pid)")
            }
        } else {
            if speed == "—", let bus = busProtocol, !bus.isEmpty { parts.append(bus) }
            if let product = productName ?? modelName, !product.isEmpty {
                parts.append(product)
            }
            if let fw = firmwareRevision, !fw.isEmpty { parts.append("FW \(fw)") }
        }
        return parts.joined(separator: " · ")
    }

    private var mediaChipFallback: String? { modelName }

    func applying(_ cap: DiskCaptureService.Capture) -> DiskInfo {
        var d = self
        d.busProtocol = cap.busProtocol ?? d.busProtocol
        d.smartStatus = cap.smartStatus ?? d.smartStatus
        d.solidState = cap.solidState ?? d.solidState
        d.serialNumber = cap.serialNumber ?? d.serialNumber
        d.firmwareRevision = cap.firmwareRevision ?? d.firmwareRevision
        d.vendorName = cap.vendorName ?? d.vendorName
        d.productName = cap.productName ?? d.productName
        d.nvmeRevision = cap.nvmeRevision ?? d.nvmeRevision
        d.nvmeSMARTCapable = cap.nvmeSMARTCapable ?? d.nvmeSMARTCapable
        d.usbVendorId = cap.usbVendorId ?? d.usbVendorId
        d.usbProductId = cap.usbProductId ?? d.usbProductId
        d.usbSpeedGbps = cap.usbSpeedGbps ?? d.usbSpeedGbps
        d.pcieLinkStatus = cap.pcieLinkStatus ?? d.pcieLinkStatus
        d.usbLinuxType = cap.usbLinuxType ?? d.usbLinuxType
        d.bridgeChipName = cap.bridgeChipName ?? d.bridgeChipName
        d.sensorsHiddenByDarwin = cap.sensorsHiddenByDarwin || d.sensorsHiddenByDarwin
        d.smartCaptureSource = cap.source.isEmpty ? d.smartCaptureSource : cap.source
        d.smartUnavailableKind = cap.unavailableKind
        if (d.modelName == nil || d.modelName?.isEmpty == true),
           let name = cap.productName ?? cap.mediaName {
            d.modelName = name
        }
        return d
    }
}
