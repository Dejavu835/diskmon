import Foundation
import IOKit
import DiskMonIOKitSMART

/// 多源抓取：任何 Apple IOKit 能看见的 SSD 传感器都收。
///
/// 优先级：
///   1) `diskutil info -plist` 整盘 `SMARTDeviceSpecificKeysMayVaryNotGuaranteed`
///      — PCIe / 雷电 NVMe（SN570 一类）不需要 smartctl、不需要 FDA
///   2) IOKit 父链 — 序列号 / 固件 / USB VID:PID / 链路速度（USB 桥也能拿到）
///   3) smartctl 由 HealthMonitor 再叠一层（Power States、Critical Warning）
///
/// USB 桥（RTL9210 / JMicron 等）Darwin 没有 SCSI passthrough：
///   SMARTStatus = Not Supported，键为空。这不是“再等 5 秒”，是永远没有。
actor DiskCaptureService {
    struct Capture: Equatable, Sendable {
        var busProtocol: String?
        var smartStatus: String?
        var solidState: Bool?
        var mediaName: String?
        var ioRegistryName: String?
        var serialNumber: String?
        var firmwareRevision: String?
        var vendorName: String?
        var productName: String?
        var nvmeRevision: String?
        var nvmeSMARTCapable: Bool?
        var usbVendorId: String?
        var usbProductId: String?
        var usbSpeedGbps: Double?
        /// IOPCIExpressLinkStatus raw（低 4 bit 速度，bit4-9 宽度）
        var pcieLinkStatus: Int?
        var usbLinuxType: String?
        var bridgeChipName: String?
        var sensorsHiddenByDarwin: Bool = false
        var smart: SmartData?
        var source: String = ""
        var unavailableKind: DiskInfo.SmartUnavailableKind = .pending
    }

    private struct CacheEntry {
        let capture: Capture
        let fetched: Date
    }

    private var cache: [String: CacheEntry] = [:]
    private let ttl: TimeInterval = 15

    func invalidate(bsdName: String) {
        cache.removeValue(forKey: Self.normalize(bsdName))
    }

    /// IOBlockStorageDriver 累计读写字节。给当前盘实时速度用。
    func ioBytes(bsdName: String) -> (read: UInt64, write: UInt64)? {
        let bag = IOKitDiskWalker.walk(bsdName: Self.normalize(bsdName))
        guard let stats = bag["Statistics"] as? [String: Any] else { return nil }
        let read = Self.statU64(stats, keys: [
            "Bytes (Read)", "Bytes Read", "Bytes read from block device", "bytes-read"
        ])
        let write = Self.statU64(stats, keys: [
            "Bytes (Write)", "Bytes Written", "Bytes written to block device", "bytes-written"
        ])
        guard let read, let write else { return nil }
        return (read, write)
    }

    private static func statU64(_ stats: [String: Any], keys: [String]) -> UInt64? {
        for k in keys {
            if let v = asU64(stats[k]) { return v }
        }
        return nil
    }

    func capture(bsdName: String) async -> Capture {
        let key = Self.normalize(bsdName)
        if let hit = cache[key], Date().timeIntervalSince(hit.fetched) < ttl {
            return hit.capture
        }
        var cap = Capture()
        if let native = Self.readNativeSMART(bsd: key) {
            cap.smart = native.smart
            cap.source = native.source
        }
        // Native SMART already has sensors — skip diskutil info spawn.
        // IOKit walk still fills serial / bus / USB IDs.
        if cap.smart?.hasSensorFields != true, let plist = Self.diskutilInfo(bsd: key) {
            Self.applyDiskutil(plist, into: &cap)
        }
        Self.applyIOKit(bsd: key, into: &cap)
        Self.applyUSBCatalog(into: &cap)
        Self._fillSmartIdentity(into: &cap)
        cap.unavailableKind = Self.classify(cap)
        if cap.smart?.hasSensorFields == true {
            cap.source = cap.source.isEmpty ? "IOKit" : cap.source
        }
        cache[key] = CacheEntry(capture: cap, fetched: Date())
        return cap
    }

    /// Stats / DriveDx 同款：IONVMeSMARTLib + ATA SMART plugin，不 spawn diskutil。
    private static func readNativeSMART(bsd: String) -> (smart: SmartData, source: String)? {
        var native = DiskMonNativeSMART()
        if DiskMonReadNVMeSMART(bsd, &native), let smart = smartFromNative(native) {
            return (smart, "NVMeSMARTLib")
        }
        native = DiskMonNativeSMART()
        if DiskMonReadATASMART(bsd, &native), let smart = smartFromNative(native) {
            return (smart, "ATASMARTLib")
        }
        return nil
    }

    private static func smartFromNative(_ n: DiskMonNativeSMART) -> SmartData? {
        var d = SmartData()
        if n.celsius != Int32.min { d.celsius = Int(n.celsius) }
        if n.percentUsed != Int32.min { d.percentageUsed = Int(n.percentUsed) }
        if n.availableSpare != Int32.min { d.availableSpare = Int(n.availableSpare) }
        if n.powerOnHours != Int32.min { d.powerOnHours = Int(n.powerOnHours) }
        if n.powerCycles != Int32.min { d.powerCycles = Int(n.powerCycles) }
        if n.unsafeShutdowns != Int32.min { d.unsafeShutdowns = Int(n.unsafeShutdowns) }
        if n.mediaErrors != Int32.min { d.mediaErrors = Int(n.mediaErrors) }
        if n.criticalWarning != Int32.min { d.criticalWarningRaw = Int(n.criticalWarning) }
        if n.dataUnitsReadTB >= 0 { d.dataUnitsReadTB = n.dataUnitsReadTB }
        if n.dataUnitsWrittenTB >= 0 { d.dataUnitsWrittenTB = n.dataUnitsWrittenTB }
        if n.healthPassed == 1 { d.healthPassed = true }
        else if n.healthPassed == 0 { d.healthPassed = false }
        return d.hasSensorFields ? d : nil
    }

    // MARK: - diskutil

    private static func diskutilInfo(bsd: String) -> [String: Any]? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
        proc.arguments = ["info", "-plist", bsd]
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = Pipe()
        do {
            try proc.run()
            let data = out.fileHandleForReading.readDataToEndOfFile()
            proc.waitUntilExit()
            guard proc.terminationStatus == 0 else { return nil }
            return try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        } catch {
            NSLog("DiskMon: diskutil info \(bsd) \(error)")
            return nil
        }
    }

    private static func applyDiskutil(_ plist: [String: Any], into cap: inout Capture) {
        cap.busProtocol = string(plist["BusProtocol"])
        cap.smartStatus = string(plist["SMARTStatus"])
        cap.solidState = bool(plist["SolidState"])
        cap.mediaName = string(plist["MediaName"])
        cap.ioRegistryName = string(plist["IORegistryEntryName"])
        if let keys = plist["SMARTDeviceSpecificKeysMayVaryNotGuaranteed"] as? [String: Any],
           !keys.isEmpty,
           let parsed = parseSMARTKeys(keys, mediaName: cap.mediaName, smartStatus: cap.smartStatus) {
            if let existing = cap.smart {
                cap.smart = existing.overlaying(parsed)
            } else {
                cap.smart = parsed
                cap.source = "diskutil"
            }
        }
    }

    /// Apple 把 NVMe Log 0x02 摊成这些键。TEMPERATURE 是开尔文（339 → 66°C）。
    /// 64-bit 计数拆成 NAME_0 / NAME_1。
    static func parseSMARTKeys(
        _ keys: [String: Any],
        mediaName: String?,
        smartStatus: String?
    ) -> SmartData? {
        var data = SmartData()
        if let name = mediaName, !name.isEmpty { data.modelNumber = name }
        if smartStatus == "Verified" { data.healthPassed = true }
        else if let s = smartStatus, s.localizedCaseInsensitiveContains("fail") {
            data.healthPassed = false
        }

        if let raw = intValue(keys["TEMPERATURE"]) ?? intValue(keys["Temperature"]) {
            data.celsius = kelvinOrCelsius(raw)
        }
        data.percentageUsed = intValue(keys["PERCENTAGE_USED"])
        data.availableSpare = intValue(keys["AVAILABLE_SPARE"])
        data.powerOnHours = intFrom64(keys, "POWER_ON_HOURS")
        data.powerCycles = intFrom64(keys, "POWER_CYCLES")
        data.unsafeShutdowns = intFrom64(keys, "UNSAFE_SHUTDOWNS")
        data.mediaErrors = intFrom64(keys, "MEDIA_ERRORS")
        if let units = u64(keys, "DATA_UNITS_READ") {
            data.dataUnitsReadTB = nvmeDataUnitsToTB(units)
        }
        if let units = u64(keys, "DATA_UNITS_WRITTEN") {
            data.dataUnitsWrittenTB = nvmeDataUnitsToTB(units)
        }
        data.warningCompTempTime = intFrom64(keys, "WARNING_TEMP_TIME")
            ?? intValue(keys["WARNING_COMPOSITE_TEMP_TIME"])
        data.criticalCompTempTime = intFrom64(keys, "CRITICAL_TEMP_TIME")
            ?? intValue(keys["CRITICAL_COMPOSITE_TEMP_TIME"])
        return data.hasSensorFields ? data : nil
    }

    // MARK: - IOKit 父链

    private static func applyIOKit(bsd: String, into cap: inout Capture) {
        let bag = IOKitDiskWalker.walk(bsdName: bsd)
        if cap.serialNumber == nil { cap.serialNumber = string(bag["Serial Number"]) }
        if cap.firmwareRevision == nil {
            cap.firmwareRevision = string(bag["Firmware Revision"])
                ?? string(bag["Product Revision Level"])
        }
        if cap.vendorName == nil {
            cap.vendorName = string(bag["Vendor Name"])
                ?? string(bag["USB Vendor Name"])
                ?? string(bag["Vendor Identification"])
        }
        if cap.productName == nil {
            cap.productName = string(bag["Model Number"])
                ?? string(bag["Product Name"])
                ?? string(bag["USB Product Name"])
                ?? string(bag["Product Identification"])
        }
        if cap.nvmeRevision == nil {
            cap.nvmeRevision = string(bag["NVMe Revision Supported"])
        }
        if cap.nvmeSMARTCapable == nil {
            cap.nvmeSMARTCapable = bool(bag["NVMe SMART Capable"])
        }
        if cap.busProtocol == nil {
            cap.busProtocol = string(bag["Physical Interconnect"])
        }
        if cap.solidState == nil {
            if let medium = string(bag["Medium Type"]),
               medium.localizedCaseInsensitiveContains("Solid") {
                cap.solidState = true
            }
        }
        if cap.usbVendorId == nil, let vid = intValue(bag["idVendor"]) {
            cap.usbVendorId = String(format: "%04x", vid)
        }
        if cap.usbProductId == nil, let pid = intValue(bag["idProduct"]) {
            cap.usbProductId = String(format: "%04x", pid)
        }
        if cap.usbSpeedGbps == nil, let speed = intValue(bag["Device Speed"]) {
            cap.usbSpeedGbps = usbSpeedGbps(speed)
        }
        if cap.pcieLinkStatus == nil, let st = intValue(bag["IOPCIExpressLinkStatus"]) {
            cap.pcieLinkStatus = st
        }
        if cap.serialNumber == nil {
            cap.serialNumber = string(bag["USB Serial Number"])
        }
    }

    private static func applyUSBCatalog(into cap: inout Capture) {
        let profile = USBBridgeCatalog.profile(vid: cap.usbVendorId, pid: cap.usbProductId)
            ?? USBBridgeCatalog.profile(matchingName: cap.productName ?? cap.mediaName)
        guard let profile else { return }
        cap.usbLinuxType = profile.linuxType
        cap.bridgeChipName = profile.name
        if cap.productName == nil { cap.productName = profile.name }
        if profile.hasSensors, cap.smart?.hasSensorFields != true {
            cap.sensorsHiddenByDarwin = true
        }
    }

    private static func _fillSmartIdentity(into cap: inout Capture) {
        if var smart = cap.smart {
            if smart.serialNumber.isEmpty, let s = cap.serialNumber { smart.serialNumber = s }
            if smart.firmwareVersion.isEmpty, let f = cap.firmwareRevision { smart.firmwareVersion = f }
            if smart.modelNumber.isEmpty, let m = cap.productName ?? cap.mediaName { smart.modelNumber = m }
            cap.smart = smart
        }
    }

    private static func classify(_ cap: Capture) -> DiskInfo.SmartUnavailableKind {
        if cap.smart?.hasSensorFields == true { return .none }
        let bus = (cap.busProtocol ?? "").uppercased()
        if bus.contains("USB") {
            if cap.nvmeSMARTCapable == true { return .pending }
            if cap.smartStatus == "Verified" { return .pending }
            return .usbBridge
        }
        if cap.smartStatus == "Not Supported" { return .notSupported }
        if cap.nvmeSMARTCapable == true { return .pending }
        return .pending
    }

    // MARK: - numbers

    /// NVMe 温度：>200 当开尔文。合理范围夹紧，异常值丢掉。
    static func kelvinOrCelsius(_ raw: Int) -> Int? {
        let c = raw > 200 ? raw - 273 : raw
        if c < -20 || c > 120 { return nil }
        return c
    }

    /// NVMe 数据单元 = 1000 × 512 字节。
    static func nvmeDataUnitsToTB(_ units: UInt64) -> Double {
        Double(units) * 512_000.0 / 1_000_000_000_000.0
    }

    static func usbSpeedGbps(_ code: Int) -> Double? {
        switch code {
        case 0: return 0.0015
        case 1: return 0.012
        case 2: return 0.48
        case 3: return 5
        case 4: return 10
        case 5: return 20
        default: return nil
        }
    }

    private static func normalize(_ bsd: String) -> String {
        bsd.hasPrefix("/dev/") ? String(bsd.dropFirst(5)) : bsd
    }

    private static func string(_ any: Any?) -> String? {
        guard let s = any as? String else { return nil }
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    private static func bool(_ any: Any?) -> Bool? {
        if let b = any as? Bool { return b }
        if let n = any as? NSNumber { return n.boolValue }
        return nil
    }

    static func intValue(_ any: Any?) -> Int? {
        if let n = any as? Int { return n }
        if let n = any as? Int64 { return Int(n) }
        if let n = any as? UInt64 { return Int(clamping: n) }
        if let n = any as? NSNumber { return n.intValue }
        if let s = any as? String, let n = Int(s) { return n }
        return nil
    }

    private static func asU64(_ any: Any?) -> UInt64? {
        if let n = any as? UInt64 { return n }
        if let n = any as? Int64 { return n >= 0 ? UInt64(n) : nil }
        if let n = any as? Int { return n >= 0 ? UInt64(n) : nil }
        if let n = any as? NSNumber { return n.uint64Value }
        if let s = any as? String, let n = UInt64(s) { return n }
        return nil
    }

    static func u64(_ dict: [String: Any], _ key: String) -> UInt64? {
        if let v = asU64(dict[key]) { return v }
        let lo = asU64(dict["\(key)_0"])
        let hi = asU64(dict["\(key)_1"])
        if lo == nil && hi == nil { return nil }
        return ((hi ?? 0) << 32) | (lo ?? 0)
    }

    static func intFrom64(_ dict: [String: Any], _ key: String) -> Int? {
        guard let v = u64(dict, key) else { return nil }
        return Int(clamping: v)
    }
}

// MARK: - IOKit parent walk

enum IOKitDiskWalker {
    static func walk(bsdName: String) -> [String: Any] {
        var bag: [String: Any] = [:]
        guard let matching = IOBSDNameMatching(kIOMainPortDefault, 0, bsdName) else {
            return bag
        }
        var iterator: io_iterator_t = 0
        let kr = IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator)
        guard kr == KERN_SUCCESS else { return bag }
        defer { IOObjectRelease(iterator) }
        let first = IOIteratorNext(iterator)
        guard first != 0 else { return bag }
        var entry: io_registry_entry_t = first
        for _ in 0..<18 {
            if let props = copyProps(entry) {
                absorb(props, into: &bag)
            }
            var parent: io_registry_entry_t = 0
            let pr = IORegistryEntryGetParentEntry(entry, "IOService", &parent)
            IOObjectRelease(entry)
            if pr != KERN_SUCCESS || parent == 0 { return bag }
            entry = parent
        }
        IOObjectRelease(entry)
        return bag
    }

    private static func copyProps(_ entry: io_registry_entry_t) -> [String: Any]? {
        var unmanaged: Unmanaged<CFMutableDictionary>?
        let kr = IORegistryEntryCreateCFProperties(entry, &unmanaged, kCFAllocatorDefault, 0)
        guard kr == KERN_SUCCESS, let um = unmanaged else { return nil }
        return um.takeRetainedValue() as? [String: Any]
    }

    private static func absorb(_ props: [String: Any], into bag: inout [String: Any]) {
        flatten(props["Device Characteristics"], into: &bag)
        flatten(props["Protocol Characteristics"], into: &bag)
        let keys = [
            "Serial Number", "Firmware Revision", "Model Number",
            "NVMe Revision Supported", "NVMe SMART Capable",
            "Physical Interconnect", "Physical Interconnect Location",
            "USB Product Name", "USB Vendor Name", "USB Serial Number",
            "idVendor", "idProduct", "Device Speed", "USBSpeed", "bcdDevice",
            "IOPCIExpressLinkStatus", "IOPCIExpressLinkCapabilities",
            "Vendor Identification", "Product Identification",
            "Product Name", "Vendor Name", "Product Revision Level",
            "Medium Type"
        ]
        for k in keys {
            if bag[k] == nil, let v = props[k] { bag[k] = v }
        }
        if let stats = props["Statistics"] as? [String: Any], !stats.isEmpty {
            let byteKeys = [
                "Bytes (Read)", "Bytes Read", "Bytes read from block device", "bytes-read"
            ]
            let hasBytes = byteKeys.contains { stats[$0] != nil }
            if hasBytes {
                bag["Statistics"] = stats
            } else if bag["Statistics"] == nil {
                bag["Statistics"] = stats
            }
        }
    }

    private static func flatten(_ any: Any?, into bag: inout [String: Any]) {
        guard let dict = any as? [String: Any] else { return }
        for (k, v) in dict where bag[k] == nil {
            bag[k] = v
        }
    }
}
