import Foundation
import AppKit

// MARK: - NSWorkspace 通知 userInfo 键(字面量字符串)
// Apple 公开常量,Swift NSWorkspace API 未直接暴露
// 参考 AppKit 头:NSWorkspace.h
//  - NSWorkspaceVolumeURLKey              (NSURL *, volume root file URL)
//  - NSWorkspaceVolumeOldMountPointKey    (NSString *, unmount 时旧挂载点)
//  - NSWorkspaceVolumeNewMountPointKey    (NSString *, mount 时新挂载点)
private let NSWorkspaceVolumeURLKey = "NSWorkspaceVolumeURLKey"
private let NSWorkspaceVolumeOldMountPointKey = "NSWorkspaceVolumeOldMountPointKey"
private let NSWorkspaceVolumeNewMountPointKey = "NSWorkspaceVolumeNewMountPointKey"

/// diskutil 探测外接盘 + Volume UUID 持久化
/// SOP §3.3 plist 路径:
///   Root dict → "AllDisksAndPartitions" → [dict]
///     └─ "DeviceIdentifier": "disk5"
///     └─ "APFSVolumes" → [{DeviceIdentifier, MountPoint, VolumeName, VolumeUUID, ...}]
///     └─ "Partitions"  → [{DeviceIdentifier, MountPoint, VolumeName, VolumeUUID, ...}]
/// v0.4.2:
///   - 新增 `capacity(for:)` 一次性拿 used/free/total(原 usedBytes 改为内部走 capacity)
///   - 新增 hot-plug 监听(NSWorkspace.didMount/didUnmount → VolumeObserverBridge → HealthMonitor)
///   - 容量缓存 60s TTL,失败不入缓存
/// v0.6 polish-B:ExFAT/NTFS/FAT32 支持 + 300ms debounce + 1.5s retry
///   - parse 函数识别 `Content == "Microsoft Basic Data"` 的 partition(ExFAT/NTFS/FAT32),
///     字段实测(2026-09-02 主人 Mac /Volumes/ssd 512 diskutil list -plist):
///       - `Content` = "Microsoft Basic Data"(ExFAT/NTFS/FAT32 都是这个,filesystem 通过
///         `diskutil info -plist` 的 `FilesystemType` 字段区分:exfat / ntfs / ms-dos(fat32))
///       - `VolumeUUID` = ExFAT volume serial(MS GUID 格式),`DiskUUID` = GPT partition UUID
///       - `MountPoint` / `VolumeName` 都在 partition dict 里,不需要查 APFSContainer
///   - VolumeObserverBridge 加 300ms debounce + 1.5s retry:处理 didMount 早于 diskutil ready
///     的竞态,grok 调研 2026-09-02 确认
actor DiskDiscoveryService {
    private let persistenceURL: URL = {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!.appendingPathComponent("com.homecenter.diskmon", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: base, withIntermediateDirectories: true
        )
        return base.appendingPathComponent("watched-volumes.json")
    }()

    /// 跑 diskutil list -plist + 解析
    func listDisks() async throws -> [DiskInfo] {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
        proc.arguments = ["list", "-plist"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        try proc.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else {
            throw NSError(domain: "DiskDiscovery", code: Int(proc.terminationStatus))
        }
        let plist = try PropertyListSerialization.propertyList(
            from: data, format: nil
        ) as! [String: Any]
        let result = Self.parse(plist: plist)
        // DEBUG: 解析中间态
        let all = plist["AllDisksAndPartitions"] as? [[String: Any]] ?? []
        var debugLines: [String] = ["parse input: \(all.count) entries"]
        for e in all {
            let bsd = e["DeviceIdentifier"] as? String ?? "?"
            let content = e["Content"] as? String ?? "?"
            let isInt = (e["Internal"] as? Bool) ?? false
            let osInt = (e["OSInternal"] as? Bool) ?? false
            let parts = (e["Partitions"] as? [[String: Any]])?.count ?? 0
            let apfsV = (e["APFSVolumes"] as? [[String: Any]])?.count ?? 0
            debugLines.append("  \(bsd) content=\(content) Internal=\(isInt) OSInternal=\(osInt) Parts=\(parts) APFSV=\(apfsV)")
        }
        NSLog("DiskMon: " + debugLines.joined(separator: "\n"))
        NSLog("DiskMon: parse result count = \(result.count)")
        return result
    }

    /// 解析 diskutil -plist → [DiskInfo](只保留外接 USB/Thunderbolt)
    /// 策略:
    ///   1) 找 GUID 物理盘 entry(Content == "GUID_partition_scheme")
    ///   2) 对其 Partitions,按 Content 分发:
    ///      - "Apple_APFS":查 APFS_Container entry 拿 APFSVolumes
    ///      - "Microsoft Basic Data":ExFAT/NTFS/FAT32,直接用 partition dict 拿字段
    ///   3) 对每个 volume,BSD = backing 物理盘(disk4),VolumeUUID = volume 的 VolumeUUID
    /// v0.6 polish-B:ExFAT/NTFS/FAT32 支持
    ///   字段实测(2026-09-02 主人 Mac /Volumes/ssd 512 diskutil list -plist):
    ///     - partition dict Content = "Microsoft Basic Data"(ExFAT/NTFS/FAT32 都是)
    ///     - VolumeUUID + DiskUUID + MountPoint + VolumeName + Size 都在 partition dict 里
    ///     - 不需要 APFS_Container 二次查找,直接 makeExternalDiskInfo(volume: partition_dict)
    ///   `FilesystemName` / `FilesystemType`(exfat/ntfs/ms-dos)只有 `diskutil info -plist` 才有;
    ///   `diskutil list -plist` 不区分,统一标 "Microsoft Basic Data"。本函数只负责
    ///   "识别外接盘 + 拿稳定 UUID",具体 filesystem 名字留给 capacity() 内部 diskutil info
    static func parse(plist: [String: Any]) -> [DiskInfo] {
        guard let all = plist["AllDisksAndPartitions"] as? [[String: Any]] else {
            return []
        }
        // 建 APFS_Container 的 backing-store BSD → entry 索引
        // 关键:container entry 自己的 BSD(disk5 / disk6)跟 partition BSD(disk4s2 / disk4s3)不一样,
        // 必须用 APFSPhysicalStores 里的 backing store BSD 作 key,才能在 lookup 时匹配上
        var apfsContainerByBSD: [String: [String: Any]] = [:]
        for entry in all {
            guard (entry["Content"] as? String) == "Apple_APFS_Container" else { continue }
            guard let stores = entry["APFSPhysicalStores"] as? [[String: Any]] else { continue }
            for store in stores {
                if let storeBSD = store["DeviceIdentifier"] as? String {
                    apfsContainerByBSD[storeBSD] = entry
                }
            }
        }

        // 已挂载用户卷的常见 Content。GPT ExFAT = Microsoft Basic Data;
        // MBR ExFAT/NTFS 在 diskutil 里是 Windows_NTFS(实测 Dahua T70 PSSD)。
        // 另外:任何 MountPoint 以 /Volumes/ 开头的 partition 都收(兜底新格式)
        let userVolumeContents: Set<String> = [
            "Microsoft Basic Data",
            "Windows_NTFS",
            "Windows_FAT_32",
            "DOS_FAT_32",
            "DOS_FAT_16",
            "Apple_HFS",
            "Apple_HFSX",
            "Linux Filesystem",
            "Linux"
        ]
        let skipContents: Set<String> = [
            "EFI", "Apple_Boot", "Apple_APFS_ISC", "Apple_APFS_Recovery",
            "Linux Swap", "Apple_APFS"
        ]

        var out: [DiskInfo] = []
        for entry in all {
            guard let bsd = entry["DeviceIdentifier"] as? String else { continue }
            // 物理盘:GPT 或 MBR(FDisk)。Dahua T70 实测是 FDisk_partition_scheme
            let scheme = entry["Content"] as? String ?? ""
            guard scheme == "GUID_partition_scheme" || scheme == "FDisk_partition_scheme" else {
                continue
            }
            // 决定 internal
            let isInternal = (entry["Internal"] as? Bool) == true
                || (entry["OSInternal"] as? Bool) == true
            // 内置 SSD 跳过
            if isInternal { continue }
            // 拿 model + size
            let size = (entry["Size"] as? Int64) ?? (entry["IOKitSize"] as? Int64) ?? 0
            let model = entry["MediaName"] as? String
                ?? entry["IORegistryEntryName"] as? String
            // 找所有外接可见的 partition(APFS / ExFAT / NTFS / HFS 都拿)
            guard let parts = entry["Partitions"] as? [[String: Any]] else { continue }
            for p in parts {
                guard let partContent = p["Content"] as? String else { continue }
                let mount = p["MountPoint"] as? String
                let isUserMount = (mount?.hasPrefix("/Volumes/") == true)
                // APFS partition:必须查 APFS Container 拿 volumes
                if partContent == "Apple_APFS" {
                    guard let partBSD = p["DeviceIdentifier"] as? String else { continue }
                    guard let container = apfsContainerByBSD[partBSD] else { continue }
                    guard let apfsVolumes = container["APFSVolumes"] as? [[String: Any]]
                    else { continue }
                    for vol in apfsVolumes {
                        if let info = makeExternalDiskInfo(
                            volume: vol, backingBSD: bsd,
                            parentSize: size, parentModel: model
                        ) {
                            out.append(info)
                        }
                    }
                    continue
                }
                if skipContents.contains(partContent) { continue }
                // GPT ExFAT / MBR NTFS-labeled ExFAT / 其它已挂载用户卷
                if userVolumeContents.contains(partContent) || isUserMount {
                    if let info = makeExternalDiskInfo(
                        volume: p, backingBSD: bsd,
                        parentSize: size, parentModel: model
                    ) {
                        out.append(info)
                    }
                }
            }
        }
        return out
    }

    /// 从 APFS volume dict 或 ExFAT/NTFS/FAT32 partition dict + backing 物理盘 BSD → DiskInfo
    /// v0.6 polish-B:VolumeUUID 优先,DiskUUID fallback
    /// 字段实测:
    ///   - APFS volume dict:VolumeUUID 必有(APFS container 内部)
    ///   - ExFAT/NTFS/FAT32 partition dict:VolumeUUID(ExFAT volume serial, MS GUID 格式)
    ///     和 DiskUUID(GPT partition UUID)都在,VolumeUUID 优先
    ///   - 万一某 format 缺 VolumeUUID,fallback 到 DiskUUID,确保 hot-plug 不漏盘
    private static func makeExternalDiskInfo(
        volume dict: [String: Any],
        backingBSD: String,
        parentSize: Int64,
        parentModel: String?
    ) -> DiskInfo? {
        // VolumeUUID 是主键(跨拔插稳定);DiskUUID 是 fallback
        guard let uuid = (dict["VolumeUUID"] as? String)
                ?? (dict["DiskUUID"] as? String),
              !uuid.isEmpty
        else {
            return nil
        }
        let mount = dict["MountPoint"] as? String
        // 跳过未挂载的(system volumes on external during boot)
        guard let m = mount, !m.isEmpty else { return nil }
        // 只保留 /Volumes/ 下的用户可挂载卷,过滤 macOS 系统卷(/、/System/Volumes/...)
        // diskutil list -plist 的 GUID_partition_scheme entry 没有 Internal/BusProtocol
        // 字段(只有 OSInternal,且 disk0 内置 SSD 也是 false),靠 mount 前缀是最稳的信号
        guard m.hasPrefix("/Volumes/") else { return nil }
        if m == "/" || m.hasPrefix("/System/") { return nil }
        // macOS system volumes that surface under /Volumes (Recovery etc.)
        let volumeName = dict["VolumeName"] as? String
        let leaf = (m as NSString).lastPathComponent
        if Self.isSystemVolumeName(leaf) || Self.isSystemVolumeName(volumeName) {
            return nil
        }
        let size = (dict["Size"] as? Int64) ?? parentSize
        return DiskInfo(
            bsdName: backingBSD,
            volumeUUID: uuid,
            mountPoint: m,
            volumeName: (volumeName?.isEmpty == false) ? volumeName : nil,
            isInternal: false,
            sizeBytes: size,
            modelName: parentModel
        )
    }

    /// Never watch macOS built-in volumes (Recovery / Preboot / Update / …).
    static func isSystemVolumeName(_ name: String?) -> Bool {
        DiskInfo.isSystemVolumeName(name)
    }

    /// 从 APFS volume dict 或 partition dict 提取 DiskInfo
    private static func makeDiskInfo(
        apfsOrPartition dict: [String: Any],
        parentBSD: String,
        parentSize: Int64,
        parentModel: String?,
        parentInternal: Bool
    ) -> DiskInfo? {
        // 必须有 VolumeUUID 才算可监控(否则是 EFI/Recovery 那种小分区)
        guard let uuid = (dict["VolumeUUID"] as? String)
                ?? (dict["DiskUUID"] as? String),
              !uuid.isEmpty
        else { return nil }
        let mount = dict["MountPoint"] as? String
        let bsd = (dict["DeviceIdentifier"] as? String) ?? parentBSD
        // 空 mountPoint = 没挂载(EFI 等),跳过
        if let m = mount, m.isEmpty {
            return nil
        }
        let volumeName = dict["VolumeName"] as? String
        if let m = mount {
            let leaf = (m as NSString).lastPathComponent
            if isSystemVolumeName(leaf) || isSystemVolumeName(volumeName) {
                return nil
            }
        } else if isSystemVolumeName(volumeName) {
            return nil
        }
        let size = (dict["Size"] as? Int64) ?? parentSize
        // APFS volume 是 internal(系统盘) → 跳过
        let isInternal = parentInternal || (dict["OSInternal"] as? Bool) == true
        return DiskInfo(
            bsdName: bsd,
            volumeUUID: uuid,
            mountPoint: mount,
            volumeName: volumeName,
            isInternal: isInternal,
            sizeBytes: size,
            modelName: parentModel
        )
    }

    // MARK: - 容量三件套 v0.4.2(diskutil info -plist 真实读)

    /// 容量三元组(已用 / 空闲 / 总)
    /// - v0.4.2:一次 diskutil 调用拿全 3 个字段(原 usedBytes 单独跑,现在合并)
    /// - 60s TTL,失败不入缓存(下次重试,不背 stale)
    private struct CapacityInfo: Equatable {
        let used: UInt64
        let free: UInt64
        let total: UInt64
        let filesystem: String?
        let writable: Bool?
    }
    private var capacityCache: [String: (info: CapacityInfo, fetched: Date)] = [:]

    /// 已用字节缓存 v0.4.0 wave-4c(保留字段名,内部转 capacityCache)
    /// 60s TTL(避免每次 UI 渲染 / 每次 discoverLoop tick 都跑 diskutil)
    /// 容量数字变化慢(人手存文件,分钟级),60s 足够,既能减轻 diskutil 压力
    /// 也能保证 UI 不会"卡在某个过期值"
    /// 失败不入缓存(下次直接重试,不背 stale 状态)
    /// v0.4.2:已迁移到 capacityCache(单字段缓存合并)
    private var usedBytesCache: [String: (used: UInt64, fetched: Date)] = [:]
    private let usedBytesTTL: TimeInterval = 60.0

    /// 拿某个挂载点的已用字节(供容量饼图)— 向后兼容 v0.4.0 wave-4c 调用方
    /// 流程:跑 `/usr/sbin/diskutil info -plist <mountPoint>` → 解析 CapacityInUse
    /// **字段名校准**(v0.4.0 wave-4c 实测):`diskutil info` 人读输出 "Volume Used Space",
    /// 但 plist 模式 key 是 `CapacityInUse`(Apple 把人读字段名映射到这个内部 key)。
    /// 任务文本里的 "VolumeUsedSpace" 指的是人读名,plist 实际 key 必须是 `CapacityInUse`。
    /// 实测 /Volumes/applelog:`CapacityInUse = 116058832896` 字节 = 116.1 GB,跟人读完全一致。
    /// 返回 nil 的场景:
    ///   - mountPoint 路径已失效(盘拔了 / 卸载)
    ///   - diskutil exit != 0
    ///   - plist 解析失败
    ///   - CapacityInUse 字段缺失(非 APFS 旧格式)
    /// **不返回假数据**(主人硬规则:数据缺失就 N/A,不凑合)
    func usedBytes(for mountPoint: String) async -> UInt64? {
        if let cap = await capacity(for: mountPoint) {
            return cap.used
        }
        return nil
    }

    /// 拿空闲字节(APFS 物理空闲)— v0.4.2 新增
    /// 字段优先级:`APFSContainerFree` > `Size - CapacityInUse`
    /// APFS 多卷共享容器,`APFSContainerFree` 反映的是容器物理空闲(对单卷外接盘 = 该盘的可写空闲)
    /// 非 APFS 卷用算式 fallback(Size - CapacityInUse)
    func freeBytes(for mountPoint: String) async -> UInt64? {
        if let cap = await capacity(for: mountPoint) {
            return cap.free
        }
        return nil
    }

    /// 拿总字节(卷声明大小)— v0.4.2 新增
    /// 字段优先级:`Size` > `TotalSize` > `IOKitSize`(三者通常一致,任意一个拿到就用)
    func totalBytes(for mountPoint: String) async -> UInt64? {
        if let cap = await capacity(for: mountPoint) {
            return cap.total
        }
        return nil
    }

    /// 一次性拿 已用/空闲/总 — 一次 diskutil 调用出 3 个字段(避免 3 次进程开销)
    /// **plist 字段实测**(主人 Mac /Volumes/applelog 2026-09-02):
    ///   - `CapacityInUse` = 117917405184 字节(已用)— 字段必在
    ///   - `Size` = 499996688384 字节(卷大小)= `TotalSize` = `IOKitSize` — 字段必在
    ///   - `APFSContainerFree` = 381918441472 字节(APFS 容器物理空闲)— APFS 必有
    ///   - `FreeSpace` = 0(APFS 已知 quirk:卷级 free 字段不准确,不用)
    /// - `Size - CapacityInUse` ≈ `APFSContainerFree` ± APFS 元数据开销(本盘差 ~160MB)
    /// 60s TTL 缓存,失败不入缓存
    func volumeFacts(for mountPoint: String) async -> (used: UInt64, free: UInt64, total: UInt64, filesystem: String?, writable: Bool?)? {
        guard await capacity(for: mountPoint) != nil,
              let cached = capacityCache[mountPoint] else { return nil }
        let i = cached.info
        return (i.used, i.free, i.total, i.filesystem, i.writable)
    }

    func capacity(for mountPoint: String) async -> (used: UInt64, free: UInt64, total: UInt64)? {
        // 1) 缓存命中(< TTL)
        if let cached = capacityCache[mountPoint],
           Date().timeIntervalSince(cached.fetched) < usedBytesTTL {
            return (cached.info.used, cached.info.free, cached.info.total)
        }
        // 2) 跑 diskutil
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
        proc.arguments = ["info", "-plist", mountPoint]
        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe
        do {
            try proc.run()
            let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            proc.waitUntilExit()
            guard proc.terminationStatus == 0 else {
                let stderr = String(data: errData, encoding: .utf8) ?? ""
                NSLog("DiskMon: diskutil info -plist \(mountPoint) exit=\(proc.terminationStatus) stderr=\(stderr.prefix(120))")
                return nil
            }
            guard let plist = try? PropertyListSerialization.propertyList(
                from: outData, format: nil
            ) as? [String: Any] else {
                NSLog("DiskMon: diskutil info -plist \(mountPoint) plist parse failed")
                return nil
            }
            // 3) total:优先 Size,fallback TotalSize,fallback IOKitSize / VolumeSize
            let total: UInt64 = readUInt64(plist, key: "Size")
                ?? readUInt64(plist, key: "TotalSize")
                ?? readUInt64(plist, key: "IOKitSize")
                ?? readUInt64(plist, key: "VolumeSize")
                ?? 0
            // 4) used / free
            // APFS:CapacityInUse + APFSContainerFree
            // ExFAT/NTFS(Dahua 实测):没有 CapacityInUse,有 FreeSpace
            //   used = total - FreeSpace
            let used: UInt64
            let free: UInt64
            if let inUse = readUInt64(plist, key: "CapacityInUse") {
                used = inUse
                if let apfsFree = readUInt64(plist, key: "APFSContainerFree") {
                    free = apfsFree
                } else if let listedFree = readUInt64(plist, key: "FreeSpace"), listedFree > 0 {
                    free = listedFree
                } else if total >= inUse {
                    free = total - inUse
                } else {
                    free = 0
                }
            } else if let listedFree = readUInt64(plist, key: "FreeSpace") {
                free = listedFree
                used = total >= listedFree ? total - listedFree : 0
            } else {
                NSLog("DiskMon: diskutil info -plist \(mountPoint) missing CapacityInUse and FreeSpace")
                return nil
            }
            let fsName = (plist["FilesystemName"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let fsType = (plist["FilesystemType"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let filesystem: String?
            if let fsName, !fsName.isEmpty { filesystem = fsName }
            else if let fsType, !fsType.isEmpty { filesystem = fsType }
            else { filesystem = nil }
            let writable = (plist["Writable"] as? Bool) ?? (plist["WritableVolume"] as? Bool)
            // 6) 写缓存
            capacityCache[mountPoint] = (
                CapacityInfo(used: used, free: free, total: total, filesystem: filesystem, writable: writable),
                Date()
            )
            return (used, free, total)
        } catch {
            NSLog("DiskMon: diskutil info -plist \(mountPoint) error: \(error)")
            return nil
        }
    }

    /// 清理某 mountPoint 的容量缓存(给"盘拔了/卸载"场景;下次再问时强制重跑 diskutil)
    func invalidateCapacityCache(mountPoint: String) {
        capacityCache.removeValue(forKey: mountPoint)
        usedBytesCache.removeValue(forKey: mountPoint)
    }

    /// 全部清(给 debug / Wave 4 测试用)
    func clearUsedBytesCache() {
        capacityCache.removeAll()
        usedBytesCache.removeAll()
    }

    /// 跨平台读 UInt64(NSNumber / Int / Int64 / String 都接)
    private func readUInt64(_ dict: [String: Any], key: String) -> UInt64? {
        if let n = dict[key] as? UInt64 { return n }
        if let n = dict[key] as? Int64 { return n >= 0 ? UInt64(n) : nil }
        if let n = dict[key] as? Int { return n >= 0 ? UInt64(n) : nil }
        if let s = dict[key] as? String, let n = UInt64(s) { return n }
        if let n = dict[key] as? NSNumber { return n.uint64Value }
        return nil
    }

    // MARK: - Hot-plug 监听 v0.4.2

    /// 启动 hot-plug 监听(NSWorkspace mount/unmount 通知 → 回调)
    /// - 必须在主线程调(NSWorkspace API 限制)
    /// - 内部用 VolumeObserverBridge 持有 token,跟 actor 解耦
    ///   (actor 不能直接当 NotificationCenter target,通知闭包需要可捕获的引用)
    /// - 回调签名 `(@Sendable (String) -> Void)?`:`String` 是 mount point 路径
    ///   - mount: 优先 `volumeNewMountPointKey`,fallback `volumeURL.path`
    ///   - unmount: 优先 `volumeOldMountPointKey`,fallback `volumeURL.path`
    nonisolated func startHotPlugObserver(
        onMount: (@Sendable (String) -> Void)?,
        onUnmount: (@Sendable (String) -> Void)?
    ) {
        VolumeObserverBridge.shared.register(onMount: onMount, onUnmount: onUnmount)
    }

    /// 停止 hot-plug 监听(NSWorkspace 移除 observer)
    nonisolated func stopHotPlugObserver() {
        VolumeObserverBridge.shared.unregister()
    }

    // MARK: - 持久化

    /// 读取已保存的 Volume UUID 列表(用户勾选"监控"的盘)
    func loadWatched() -> [String] {
        guard let data = try? Data(contentsOf: persistenceURL),
              let list = try? JSONDecoder().decode([String].self, from: data)
        else { return [] }
        return list
    }

    /// 写回用户勾选的 Volume UUID 列表
    func saveWatched(_ uuids: [String]) {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(uuids) {
            try? data.write(to: persistenceURL)
        }
    }

    /// 加载完整 DiskInfo 列表(从 watched UUID 集 + 当前 diskutil 列表)
    /// BSD Name 会在每次 diskutil 重探测时被替换
    func resolveWatched(currentDisks: [DiskInfo], watchedUUIDs: [String]) -> [DiskInfo] {
        let uuidToDisk = Dictionary(uniqueKeysWithValues: currentDisks.map { ($0.volumeUUID, $0) })
        return watchedUUIDs.compactMap { uuidToDisk[$0] }
    }
}

// MARK: - VolumeObserverBridge(v0.4.2 + v0.6 polish-B)

/// 桥接类:持有 NSWorkspace notification 观察 token,转发到闭包
/// 解决 actor 不能直接当 NotificationCenter target 的问题
/// - 单例(actor 自身长生命周期,观察者跟它同寿命)
/// - `@unchecked Sendable` + NSLock 保护
/// - register/unregister 由 DiskDiscoveryService 非隔离方法代理
/// v0.6 polish-B:
///   - 加 300ms debounce:让 macOS 完成 mount 流程(diskutil list 同步跟上)再 discover
///   - 加 1.5s retry:处理 `didMount` 早于 diskutil ready 的边缘情况(grok 调研 2026-09-02 确认)
///   - 多次 mount/unmount 用 `Task.cancel` 取消上一次 debounce,避免并发 discoverOnce 风暴
final class VolumeObserverBridge: @unchecked Sendable {
    static let shared = VolumeObserverBridge()
    private let lock = NSLock()
    private var mountToken: NSObjectProtocol?
    private var unmountToken: NSObjectProtocol?
    private var mountHandler: ((String) -> Void)?
    private var unmountHandler: ((String) -> Void)?

    // v0.6 polish-B:300ms debounce + 1.5s retry 状态
    // 单个挂起的 debounce 任务(挂载/卸载共用一个槽位,后者取消前者)
    // 任务用 Task.detached 跑(脱离 .main 队列,不阻塞 NSWorkspace observer)
    private var pendingDebounceTask: Task<Void, Never>?
    /// 首次回调前等 300ms(让 macOS 完成 mount 流程、diskutil 跟上)
    private let debounceDelayNanos: UInt64 = 300_000_000
    /// 首次回调后等 1.5s 再回调一次(retry — 处理 diskutil 第一次没 ready 的边缘情况)
    private let retryDelayNanos: UInt64 = 1_500_000_000

    private init() {}

    /// 注册 mount/unmount 观察
    /// - 重复注册会自动清理旧 token
    /// - v0.6 polish-B:回调走 300ms debounce + 1.5s retry,handler 调用频率降为
    ///   "300ms 内合并 + 1.8s 后重试",避免 1 秒内连发 discoverOnce 把 CPU 跑满
    func register(
        onMount: ((String) -> Void)?,
        onUnmount: ((String) -> Void)?
    ) {
        lock.lock()
        defer { lock.unlock() }
        unregisterLocked()
        self.mountHandler = onMount
        self.unmountHandler = onUnmount
        let center = NSWorkspace.shared.notificationCenter
        self.mountToken = center.addObserver(
            forName: NSWorkspace.didMountNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let mp = Self.extractMountPoint(from: note, isMount: true) else { return }
            self?.scheduleDebounced(isMount: true, mountPoint: mp)
        }
        self.unmountToken = center.addObserver(
            forName: NSWorkspace.didUnmountNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let mp = Self.extractMountPoint(from: note, isMount: false) else { return }
            self?.scheduleDebounced(isMount: false, mountPoint: mp)
        }
    }

    /// v0.6 polish-B:300ms debounce + 1.5s retry 调度
    /// - 每次新 mount/unmount 取消上一次的 pendingDebounceTask(用 `Task.cancel`)
    /// - 300ms 后回调 handler 一次(挂载/卸载 path 各自)
    /// - 再 1.5s 后回调一次(retry,处理 diskutil 没 ready)
    /// - handler 是在 schedule 时刻锁内读出的快照(后续 unregister 不影响已挂起任务的 handler)
    ///   — handler 闭包本身通常用 `[weak self]` 捕获 HealthMonitor,deallocate 后回调 no-op
    private func scheduleDebounced(isMount: Bool, mountPoint: String) {
        lock.lock()
        let handler: ((String) -> Void)? = isMount ? mountHandler : unmountHandler
        pendingDebounceTask?.cancel()
        // grok 调研:v0.6 hot-plug polish, ExFAT/NTFS 支持 + 300ms debounce + 1.5s retry
        // 注:Task 闭包不访问 self(只读 handler/mountPoint 局部快照,锁内已 snapshot),
        //   所以不用 [weak self],编译器会警告 "variable 'self' was written to, but never read"
        let task = Task.detached(priority: .userInitiated) {
            // 1) 300ms debounce:让 macOS 完成 mount 流程、diskutil 同步跟上
            try? await Task.sleep(nanoseconds: 300_000_000)
            if Task.isCancelled { return }
            handler?(mountPoint)
            // 2) 1.5s retry:处理 diskutil 第一次没 ready 的边缘情况
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            if Task.isCancelled { return }
            handler?(mountPoint)
        }
        pendingDebounceTask = task
        lock.unlock()
        // 任务里 handler 闭包不直接访问 self.state(unlock 后没再读),所以锁释放后安全
    }

    /// 移除所有观察
    func unregister() {
        lock.lock()
        defer { lock.unlock() }
        unregisterLocked()
    }

    private func unregisterLocked() {
        // v0.6 polish-B:取消挂起的 debounce 任务(避免 unregister 后还在回调)
        pendingDebounceTask?.cancel()
        pendingDebounceTask = nil
        let center = NSWorkspace.shared.notificationCenter
        if let t = mountToken { center.removeObserver(t) }
        if let t = unmountToken { center.removeObserver(t) }
        mountToken = nil
        unmountToken = nil
        mountHandler = nil
        unmountHandler = nil
    }

    /// 提取 mount point 路径
    /// - mount 优先 `volumeNewMountPointKey`,fallback `volumeURL.path`
    /// - unmount 优先 `volumeOldMountPointKey`,fallback `volumeURL.path`
    /// 注意:NSWorkspace 这些 key 在 Swift NSWorkspace API 里没暴露(只在 ObjC 头),
    ///   必须用字面量字符串(Apple 公开常量值,长期稳定)
    private static func extractMountPoint(
        from note: Notification, isMount: Bool
    ) -> String? {
        let userInfo = note.userInfo ?? [:]
        if isMount {
            if let s = userInfo[NSWorkspaceVolumeNewMountPointKey] as? String, !s.isEmpty {
                return s
            }
        } else {
            if let s = userInfo[NSWorkspaceVolumeOldMountPointKey] as? String, !s.isEmpty {
                return s
            }
        }
        if let url = userInfo[NSWorkspaceVolumeURLKey] as? URL {
            return url.path
        }
        return nil
    }
}
