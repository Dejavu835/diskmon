import Foundation
import SwiftUI
import SwiftData
import DiskMonCore

/// 监控主调:单例真相源
/// View 通过 @Bindable 绑定,View 本身无状态
/// v0.2.0:
///   - 全部配置从 AppSettings 读(pollIntervalSeconds / warningTemp / criticalTemp)
///   - 监听 AppSettings.didChangeNotification 触发 restartPolling + evaluate
///   - 写 SwiftData 时冗余存 cumulativeEnergyKWh(给 DiskDetailView 24h 功耗折线用)
/// v0.4.0 wave-4g:集成 PowerService,每 poll 周期采一次实时功耗
///   写进 SmartSnapshot.powerConsumptionWatts(失败 nil,不假数据)
/// v0.4.4 fix-B:
///   - per-disk 功耗写入:每块 watched disk 独立 sample + 写自己的 SmartSnapshot
///     (以前用 disks.first 写到所有盘,多盘时其他盘 false data)
///   - toggleWatch 状态持久化:excludedUUIDs 存 UserDefaults JSON,
///     5s discover 不再把用户 off 的盘加回 watchedUUIDs
/// v0.5.0:集成 HealthPredictor,grok 调研 dwell-time hysteresis
///   - pollOnce 末尾对每块盘调 ingest(温度进 aboveSince/aboveLevel 字典)
///   - 同一次 pollOnce 末尾调 evaluateDwell(内部 60s 节流,实际只 1 min 扫一次)
///   - promote 后由 NotificationService.notifyIfChanged 通知(本次未动,留给 Wave 5B/5C)
@MainActor
@Observable
final class HealthMonitor {
    // MARK: - 真相源(供 View 读)

    /// 当前盘(选中盘的)的 SMART 数据
    var current: SmartData = SmartData()
    /// 当前温度(菜单栏数字用)
    var currentTemp: Double = 0
    /// 健康度等级
    var healthLevel: HealthLevel = .normal
    /// 监控盘列表(BSD Name 每次 5s 重探测会被替换)
    var watchedDisks: [DiskInfo] = []
    /// 发现的盘(含未勾选 watch 的)
    var discoveredDisks: [DiskInfo] = []
    /// Full Disk Access 缺失标记(让 UI 显错)
    var needsFullDiskAccess: Bool = false
    /// smartctl 缺失标记
    var smartctlMissing: Bool = false
    /// 错误信息
    var lastError: String?
    /// smartctl / diskutil 是否就绪
    var isReady: Bool = false

    /// 每块盘最近一次 SMART 数据(给 PopoverView 的"4 大指标"汇总 + StatStrip 用)
    /// key = volumeUUID;每次 pollOnce 更新
    var currentByUUID: [String: SmartData] = [:]
    /// 每块盘 SMART 失败原因(USB 桥接不支持 / parse 失败)。有值时 UI 显 "—" 而不是假 0
    var smartErrorByUUID: [String: String] = [:]

    struct IOSample: Equatable {
        var readBps: Double
        var writeBps: Double
    }
    struct IOHistoryPoint: Equatable {
        var at: Date
        var readBps: Double
        var writeBps: Double
    }
    /// 当前读写字节/秒
    var ioCurrentByUUID: [String: IOSample] = [:]
    /// 最近 1 小时读写（约 2s 一点）
    var ioHistoryByUUID: [String: [IOHistoryPoint]] = [:]
    /// Hour-resolution IO (max 7 days). Not a 2s ring.
    var ioHourBuckets: [String: [IOBucket]] = [:]
    private var ioMinuteBuf: [String: [IOBucket]] = [:]
    private var lastMinuteFold: Date = .distantPast
    /// 每次 IO 采样 +1，让 SwiftUI 一定刷新读数（字典替换有时观察不到）
    var ioGeneration: Int = 0
    /// Drop / unmount events this session + persisted 7d. Only disks seen live this session.
    var dropStore: DropWatchStore = HealthMonitor.loadDropStore()
    private struct SeenDisk: Equatable {
        var name: String
        var bsdName: String
        var bus: String?
        var isUSB: Bool
        var serial: String?
        var lastSeen: Date
    }
    private var lastSeenDisks: [String: SeenDisk] = [:]
    private var lastUserDiskAction: (uuid: String, op: String, at: Date)?
    /// Finder / system unmount (didUnmount) — not our Manage action, not a cable pull.
    private var lastWorkspaceUnmountAt: Date?
    private var lastSleepOrWakeAt: Date?
    private var lastDiscoverAt: Date?
    private var lastDiscoverGap: TimeInterval?
    private var sleepTokens: [NSObjectProtocol] = []
    private var userActionToken: NSObjectProtocol?

    /// Live disks for DropStory identity matching (Volume UUID may change on replug).
    var onlineDropIdentities: [DropIdentity] {
        watchedDisks.map {
            DropIdentity(uuid: $0.volumeUUID, name: $0.displayName, serial: $0.serialNumber)
        }
    }

    /// Card/widget state: open unexpected drop still gone > expected eject/unmount > flap > steady.
    func dropStory(for volumeUUID: String? = nil) -> DropNowState {
        let events: [DropEvent]
        if let volumeUUID {
            if let seen = lastSeenDisks[volumeUUID] {
                let id = DropIdentity(uuid: volumeUUID, name: seen.name, serial: seen.serial)
                events = dropStore.events.filter { $0.identity.matches(id) }
            } else {
                events = dropStore.events.filter { $0.uuid == volumeUUID }
            }
        } else {
            events = dropStore.events
        }
        let online = onlineDropIdentities
        let expected = expectedGoneEvent(in: events, online: online)
        return DropStory.now(events, online: online, expectedGone: expected)
    }

    /// Newest eject/unmount that is still expected (disk not back under any identity).
    private func expectedGoneEvent(in events: [DropEvent], online: [DropIdentity]) -> DropEvent? {
        let expected = events.reversed().first { $0.kind == .ejected || $0.kind == .unmounted }
        guard let ev = expected else { return nil }
        let stillGone = online.allSatisfy { !$0.matches(ev.identity) }
        return stillGone ? ev : nil
    }

    func ioMean(for uuid: String, window: IOWindow, now: Date = Date()) -> (read: Double?, write: Double?) {
        let live: [IOBucket] = (ioHistoryByUUID[uuid] ?? []).map {
            IOBucket(at: $0.at, readBps: $0.readBps, writeBps: $0.writeBps)
        }
        return IOMean.mix(
            hours: ioHourBuckets[uuid] ?? [],
            live: live,
            window: window,
            now: now
        )
    }

    /// Same point as the chart's right edge. Do not take max of the last two.
    func ioLiveSample(for uuid: String) -> IOSample? {
        if let last = ioHistoryByUUID[uuid]?.last {
            return IOSample(readBps: last.readBps, writeBps: last.writeBps)
        }
        return ioCurrentByUUID[uuid]
    }

    // MARK: - 配置快捷访问(从 AppSettings 读,v0.2.0 改)

    var pollIntervalSeconds: Double { settings.pollIntervalSeconds }
    var warningTempCelsius: Int { settings.warningTempCelsius }
    var criticalTempCelsius: Int { settings.criticalTempCelsius }

    // MARK: - 选中态 + SwiftData 容器公开

    /// 用户在 PopoverView 顶栏 DiskPickerView 点击选中的盘 UUID;nil = 自动选第一块
    var selectedDiskUUID: String? = nil
    /// SwiftData 容器 — 给 .modelContainer() 注入用
    let modelContainer: ModelContainer

    /// 选中盘(DiskPickerView + 顶栏标题用)
    var selectedDisk: DiskInfo? {
        let target = selectedDiskUUID ?? watchedDisks.first?.volumeUUID
        return target.flatMap { uuid in
            watchedDisks.first(where: { $0.volumeUUID == uuid })
        }
    }

    // MARK: - 内部状态

    /// AppSettings 注入(从 .environment 拿,fallback 单例)
    private let settings: AppSettings

    /// v0.4.0 wave-4g:PowerService 注入(从 .environment 拿,fallback 单例)
    /// 弱引用(避免与 DiskMonApp @State 强引用成环;通常 owner 在更外层)
    private weak var powerService: PowerService?

    /// v0.8 polish-L:LinkHealthService 注入(从 .environment 拿,fallback 临时实例)
    /// 弱引用:owner 在更外层(DiskMonApp @State),持强引用会成环
    private weak var linkHealthService: LinkHealthService?
    /// v0.8 polish-L:DiagnosticTestService 注入(从 .environment 拿,fallback 临时实例)
    private weak var diagnosticTestService: DiagnosticTestService?
    /// v0.8 polish-M:BenchmarkService 注入(从 .environment 拿,fallback 临时实例)
    /// 弱引用:owner 在更外层(DiskMonApp @State)
    private weak var benchmarkService: BenchmarkService?
    /// v0.8 polish-M:FSIntegrityService 注入(从 .environment 拿,fallback 临时实例)
    private weak var fsIntegrityService: FSIntegrityService?

    private let smartctl = SmartctlService()
    private let discovery = DiskDiscoveryService()
    private let capture = DiskCaptureService()
    private let notifications = NotificationService.shared

    private var modelContext: ModelContext?

    /// 轮询任务
    private var pollTask: Task<Void, Never>?
    private var discoveryTask: Task<Void, Never>?
    private var downsampleTask: Task<Void, Never>?
    private var ioTask: Task<Void, Never>?
    private var ioLastBytes: [String: (read: UInt64, write: UInt64, at: Date)] = [:]
    private var lastSmartctlAtByBSD: [String: Date] = [:]
    private var lastSMARTPersistAt: [String: Date] = [:]
    private static let smartctlMinInterval: TimeInterval = 30
    private static let smartPersistInterval: TimeInterval = 60

    /// 每个 diskUUID 持久化的"上次等级"(避免重复通知)
    private var lastLevelByUUID: [String: HealthLevel] = [:]

    /// 已选中的 watched UUID 集(从 watched-volumes.json 加载)
    private var watchedUUIDs: Set<String> = []

    /// v0.4.4 fix-B:用户 toggle-off 的盘 UUID 集(跨 polling 周期持久化)
    /// 5s discover 不再把 off 的盘加回;存 UserDefaults JSON array
    private var excludedUUIDs: Set<String> = []

    /// UserDefaults key(避免 magic string;写读都用同一常量)
    private static let excludedUUIDsKey = "diskmon.excludedUUIDs"

    /// 启动失败次数(退避重试用)
    private var startRetries: Int = 0

    init(settings: AppSettings? = nil, powerService: PowerService? = nil,
         linkHealthService: LinkHealthService? = nil,
         diagnosticTestService: DiagnosticTestService? = nil,
         benchmarkService: BenchmarkService? = nil,
         fsIntegrityService: FSIntegrityService? = nil) {
        // AppSettings(从 .environment 拿,fallback 单例)
        self.settings = settings ?? AppSettings.shared
        // v0.4.0 wave-4g:PowerService(从参数拿,fallback 单例)
        // 弱引用:owner 通常在更外层(DiskMonApp @State),持强引用会成环
        self.powerService = powerService ?? PowerService.shared
        // v0.8 polish-L:LinkHealthService(从参数拿)— 默认 nil → discoverOnce 跳过 link snapshot
        // 弱引用:同 PowerService,owner 在更外层
        self.linkHealthService = linkHealthService
        // v0.8 polish-L:DiagnosticTestService(从参数拿)— 默认 nil → pollOnce 跳过 self-test fetch
        self.diagnosticTestService = diagnosticTestService
        // v0.8 polish-M:BenchmarkService(从参数拿)— 默认 nil → discoverOnce 跳过 benchmark 拉取
        self.benchmarkService = benchmarkService
        // v0.8 polish-M:FSIntegrityService(从参数拿)— 默认 nil → discoverOnce 跳过 integrity 拉取
        self.fsIntegrityService = fsIntegrityService
        // v0.4.4 fix-B:启动即读 excludedUUIDs(toggle-off 状态从上次会话恢复,
        // 避免 5s discover 第一次跑就把用户上次 off 的盘加回来)
        self.excludedUUIDs = Self.loadExcludedUUIDs()
        self.ioHourBuckets = Self.loadHourBuckets()
        self.dropStore = Self.loadDropStore()
        // SwiftData 容器 — 先建(必须 let,在 init 里同步建)
        do {
            self.modelContainer = try SwiftDataStack.makeContainer()
        } catch {
            let schema = Schema([SmartSnapshot.self, TemperatureSample.self])
            let cfg = ModelConfiguration(isStoredInMemoryOnly: true)
            self.modelContainer = try! ModelContainer(for: schema, configurations: cfg)
            NSLog("DiskMon: SwiftData persistent init failed, fallback in-memory: \(error)")
        }
        // 监听 AppSettings 变化 → poll interval / 阈值改了都重启
        // v0.2.0:直接 restartPolling,因为简单可靠,代价是一次 cancelled task
        NotificationCenter.default.addObserver(
            forName: AppSettings.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.restartPolling()
                for disk in self.watchedDisks {
                    if let data = self.currentByUUID[disk.volumeUUID] {
                        self.lastLevelByUUID[disk.volumeUUID] = self.evaluate(smart: data, uuid: disk.volumeUUID)
                    }
                }
                self.healthLevel = self.worstLevel
            }
        }
        // 启动监控(同步开始,内部 Task 异步跑轮询)
        start()
        // v0.4.2:注册 NSWorkspace hot-plug 监听(mount/unmount → 立即触发 discoverOnce + 缓存清理)
        // 必须在 start() 之后(discovery 字段已就位);stop() 时会反注册
        startHotPlugObserver()
        startSleepAndActionObservers()
    }

    // MARK: - Drop watch (no extra poll loop)

    private func startSleepAndActionObservers() {
        let center = NSWorkspace.shared.notificationCenter
        let sleepHandler: (Notification) -> Void = { [weak self] _ in
            Task { @MainActor in
                self?.lastSleepOrWakeAt = Date()
            }
        }
        sleepTokens.append(center.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main, using: sleepHandler
        ))
        sleepTokens.append(center.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main, using: sleepHandler
        ))
        userActionToken = NotificationCenter.default.addObserver(
            forName: .diskmonUserDiskAction,
            object: nil,
            queue: .main
        ) { [weak self] note in
            let uuid = note.userInfo?["uuid"] as? String ?? ""
            let op = note.userInfo?["op"] as? String ?? ""
            Task { @MainActor in
                self?.lastUserDiskAction = (uuid, op, Date())
            }
        }
    }

    private func stopSleepAndActionObservers() {
        let center = NSWorkspace.shared.notificationCenter
        for token in sleepTokens { center.removeObserver(token) }
        sleepTokens.removeAll()
        if let userActionToken {
            NotificationCenter.default.removeObserver(userActionToken)
            self.userActionToken = nil
        }
    }

    private func recordDropIfSeen(uuid: String, now: Date) {
        guard let seen = lastSeenDisks[uuid] else { return }
        // App wasn't sampling: quit, hung, or first discover after a long gap — not a drop.
        let maxGap = max(20, AppSettings.shared.pollIntervalSeconds * 4)
        if now.timeIntervalSince(seen.lastSeen) > maxGap { return }
        if let gap = lastDiscoverGap, gap > max(30, AppSettings.shared.pollIntervalSeconds * 6) {
            return
        }
        guard isReady else { return }
        let whole = DropClassifier.wholeDiskBSD(seen.bsdName)
        let nodeExists = FileManager.default.fileExists(atPath: "/dev/\(whole)")
        let action = lastUserDiskAction
        let recent = action.map { now.timeIntervalSince($0.at) <= DropClassifier.userActionWindow && $0.uuid == uuid } ?? false
        let op = recent ? action?.op : nil
        // Finder eject / system unmount: didUnmount without our Manage notify.
        let recentWorkspaceUnmount = (lastWorkspaceUnmountAt).map {
            now.timeIntervalSince($0) <= DropClassifier.userActionWindow
        } ?? false
        let prior = dropStore.lastDrop(uuid: uuid).map { now.timeIntervalSince($0.at) }
        let sleepAgo = lastSleepOrWakeAt.map { now.timeIntervalSince($0) }
        let ctx = DropContext(
            bsdNodeExists: nodeExists,
            recentUserEject: op == "eject",
            recentUserUnmount: op == "unmount" || op == "format",
            recentWorkspaceUnmount: recentWorkspaceUnmount && !recent,
            isDiskImage: seen.bus?.uppercased().contains("DISK IMAGE") == true
                || seen.name.uppercased().contains("INSTALLER"),
            secondsSinceSleepOrWake: sleepAgo,
            secondsSincePriorDrop: prior,
            isUSB: seen.isUSB
        )
        let (kind, hint) = DropClassifier.classify(ctx)
        lastSeenDisks.removeValue(forKey: uuid)
        // Installer images and eject/unmount are not hardware faults — do not persist.
        guard kind == .dropped else { return }
        var store = dropStore
        store.append(DropEvent(
            uuid: uuid,
            name: seen.name,
            bsdName: seen.bsdName,
            bus: seen.bus,
            serial: seen.serial,
            at: now,
            kind: kind,
            hint: hint
        ), now: now)
        dropStore = store
    }

    private func persistDropStore() {
        let json = dropStore.json()
        guard let url = Self.dropStoreURL() else { return }
        try? json.data(using: .utf8)?.write(to: url, options: .atomic)
    }

    private static func loadDropStore() -> DropWatchStore {
        guard let url = dropStoreURL(),
              let data = try? Data(contentsOf: url),
              let json = String(data: data, encoding: .utf8) else {
            return DropWatchStore()
        }
        var store = DropWatchStore.parse(json)
        // Drop historical installer / DMG events so they cannot show as “missing”.
        let cleaned = DropStory.hardwareEvents(store.events)
        if cleaned.count != store.events.count {
            store = DropWatchStore(cleaned)
            try? store.json().data(using: .utf8)?.write(to: url, options: .atomic)
        }
        return store
    }

    private static func dropStoreURL() -> URL? {
        // 可选：设置里的自定义日志文件夹；空则用默认 App Support
        let dir = DiskMonDataPaths.logDirectory(
            customPath: AppSettings.shared.logDirectoryPath
        )
        return dir.appendingPathComponent("drop-events.json")
    }

    // MARK: - v0.4.2 Hot-plug 监听

    /// 注册 NSWorkspace mount/unmount 观察者
    /// - mount 触发 `discoverOnce()`(1-2s 内更新,比 5s 轮询快)
    /// - unmount 触发 `invalidateCapacityCache` + `discoverOnce()`(立即从 watchedDisks 移除)
    private func startHotPlugObserver() {
        discovery.startHotPlugObserver(
            onMount: { [weak self] mountPoint in
                guard let self = self else { return }
                NSLog("DiskMon: hot-plug mount detected: \(mountPoint)")
                // 通知闭包在 .main queue 跑,主线程;但仍是 @Sendable 边界,用 Task 包
                Task { @MainActor in
                    await self.discoverOnce()
                }
            },
            onUnmount: { [weak self] mountPoint in
                guard let self = self else { return }
                NSLog("DiskMon: hot-plug unmount detected: \(mountPoint)")
                Task { @MainActor in
                    self.lastWorkspaceUnmountAt = Date()
                    await self.discovery.invalidateCapacityCache(mountPoint: mountPoint)
                    await self.discoverOnce()
                }
            }
        )
    }

    // MARK: - 公开 API

    /// 启动监控。smartctl 缺失不再停整个轮询：diskutil/IOKit 仍能抓 PCIe/雷电 NVMe 的温度和寿命。
    func start() {
        if SmartctlPathLocator.resolve() == nil {
            smartctlMissing = true
            lastError = String(
                localized: "error.smartctl.missing",
                defaultValue: "smartctl not installed. Please run: brew install smartmontools"
            )
        }
        Task { [weak self] in
            let uuids = await self?.discovery.loadWatched() ?? []
            await MainActor.run { [weak self] in
                self?.watchedUUIDs = Set(uuids)
            }
        }
        self.modelContext = ModelContext(modelContainer)
        isReady = true
        startRetries = 0
        startPollingTasks()
        NSLog("DiskMon: start() complete, container ready")
    }

    /// 停止
    func stop() {
        pollTask?.cancel(); pollTask = nil
        discoveryTask?.cancel(); discoveryTask = nil
        downsampleTask?.cancel(); downsampleTask = nil
        ioTask?.cancel(); ioTask = nil
        // v0.4.2:反注册 hot-plug 监听(VolumeObserverBridge 移除 token)
        discovery.stopHotPlugObserver()
        stopSleepAndActionObservers()
        isReady = false
    }

    func isMonitoring(_ uuid: String) -> Bool {
        watchedDisks.contains(where: { $0.volumeUUID == uuid })
    }

    /// 切换某块盘的"是否监控"
    /// v0.4.4 fix-B:改 `(disk:on:)` 显式签名,off 状态持久化到 UserDefaults,
    /// 5s discover 不再把 off 的盘加回 watchedUUIDs
    func toggleWatch(disk: DiskInfo, on: Bool) {
        // 系统盘禁止加入监控
        if on && !disk.isExternalUserVolume { return }
        let volumeUUID = disk.volumeUUID
        if on {
            watchedUUIDs.insert(volumeUUID)
            excludedUUIDs.remove(volumeUUID)
        } else {
            watchedUUIDs.remove(volumeUUID)
            excludedUUIDs.insert(volumeUUID)
        }
        let snapshot = Array(watchedUUIDs).sorted()
        Task { [weak self] in
            await self?.discovery.saveWatched(snapshot)
        }
        Self.saveExcludedUUIDs(excludedUUIDs)
        refreshWatchedFromDiscovered()
    }

    // MARK: - 任务调度

    private func startPollingTasks() {
        pollTask?.cancel()
        discoveryTask?.cancel()
        downsampleTask?.cancel()
        ioTask?.cancel()

        // 1) 主轮询(温度 / SMART / SwiftData 写)
        // v0.2.0:用 AppSettings.shared.pollIntervalSeconds(替换硬编码 1.0)
        let pollInterval = max(0.5, settings.pollIntervalSeconds)
        pollTask = Task { [weak self] in
            await self?.pollOnce()
            while !Task.isCancelled {
                let nanos = UInt64(pollInterval * 1_000_000_000)
                try? await Task.sleep(nanoseconds: nanos)
                if Task.isCancelled { break }
                await self?.pollOnce()
            }
        }

        // 2) diskutil 5s 重探测
        discoveryTask = Task { [weak self] in
            await self?.discoverLoop()
        }

        // 3) 60s 降采样 + 清理
        downsampleTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 60_000_000_000)
                if Task.isCancelled { break }
                await self?.downsampleOnce()
            }
        }

        ioTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.sampleIOOnce()
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                if Task.isCancelled { break }
            }
        }
    }

    /// 主动拉一次(给 AppSettings 改 pollInterval 时使用)
    func restartPolling() {
        startPollingTasks()
    }

    // MARK: - 轮询实现

    private func pollOnce() async {
        let disks = watchedDisks
        guard !disks.isEmpty else {
            return
        }
        var updatedSmartByUUID: [String: SmartData] = [:]
        var updatedErrors: [String: String] = [:]
        var capturesByBSD: [String: DiskCaptureService.Capture] = [:]
        var smartByWholeBSD: [String: SmartData] = [:]
        var errorByWholeBSD: [String: String] = [:]
        var sawFDA = false
        var ctlMissing = SmartctlPathLocator.resolve() == nil

        for disk in disks {
            let whole = DropClassifier.wholeDiskBSD(disk.bsdName)
            if let shared = smartByWholeBSD[whole] {
                updatedSmartByUUID[disk.volumeUUID] = shared
                if let cap = capturesByBSD[whole] { capturesByBSD[disk.bsdName] = cap }
                continue
            }
            if let sharedErr = errorByWholeBSD[whole] {
                updatedErrors[disk.volumeUUID] = sharedErr
                continue
            }

            let cap = await capture.capture(bsdName: whole)
            capturesByBSD[whole] = cap
            capturesByBSD[disk.bsdName] = cap
            var data = cap.smart

            let nativeOK = data?.hasSensorFields == true
            let smartctlFresh = lastSmartctlAtByBSD[whole].map {
                Date().timeIntervalSince($0) < Self.smartctlMinInterval
            } ?? false
            let shouldSmartctl = !ctlMissing && !(nativeOK && smartctlFresh)

            if shouldSmartctl {
                do {
                    let (ctl, _) = try await smartctl.read(device: whole)
                    data = ctl.overlaying(data)
                    lastSmartctlAtByBSD[whole] = Date()
                } catch SmartctlService.SmartctlError.needsFullDiskAccess {
                    sawFDA = true
                } catch SmartctlService.SmartctlError.missingExecutable {
                    ctlMissing = true
                } catch SmartctlService.SmartctlError.notSupported(let reason) {
                    if data?.hasSensorFields != true {
                        errorByWholeBSD[whole] = Self.captureError(
                            kind: cap.unavailableKind, capture: cap, fallback: reason
                        )
                    }
                } catch {
                    if data?.hasSensorFields != true {
                        errorByWholeBSD[whole] = Self.captureError(
                            kind: cap.unavailableKind, capture: cap,
                            fallback: error.localizedDescription
                        )
                    }
                }
            } else if !nativeOK {
                errorByWholeBSD[whole] = Self.captureError(
                    kind: cap.unavailableKind, capture: cap, fallback: nil
                )
            }

            if let data, data.hasSensorFields {
                smartByWholeBSD[whole] = data
                updatedSmartByUUID[disk.volumeUUID] = data
            } else if let err = errorByWholeBSD[whole] {
                updatedErrors[disk.volumeUUID] = err
            } else {
                let err = Self.captureError(kind: cap.unavailableKind, capture: cap, fallback: nil)
                errorByWholeBSD[whole] = err
                updatedErrors[disk.volumeUUID] = err
            }
        }
        if sawFDA {
            needsFullDiskAccess = true
            lastError = String(
                localized: "error.fullDiskAccess.short",
                defaultValue: "Full Disk Access required"
            )
            notifications.requestFullDiskAccess()
        } else {
            needsFullDiskAccess = false
        }
        smartctlMissing = ctlMissing
        stampIdentity(capturesByBSD, smartByUUID: updatedSmartByUUID)

        // 缓存:每块盘最近 SMART(给 PopoverView StatStrip + DiskDetailView 用)
        for (uuid, data) in updatedSmartByUUID {
            currentByUUID[uuid] = data
            smartErrorByUUID.removeValue(forKey: uuid)
        }
        for (uuid, reason) in updatedErrors {
            smartErrorByUUID[uuid] = reason
            currentByUUID.removeValue(forKey: uuid)
        }

        // 选中盘刷新 current；通知按每块 watched 盘各自的等级变化发
        let targetUUID = selectedDiskUUID ?? disks.first?.volumeUUID
        if let uuid = targetUUID,
           disks.contains(where: { $0.volumeUUID == uuid }) {
            if selectedDiskUUID == nil { selectedDiskUUID = uuid }
            if let data = updatedSmartByUUID[uuid] {
                current = data
                if let c = data.celsius { currentTemp = Double(c) }
            } else {
                current = SmartData()
            }
        }

        let predictNow = Date()
        for (uuid, data) in updatedSmartByUUID {
            HealthPredictor.shared.ingest(
                diskUUID: uuid,
                celsius: data.celsius,
                percentageUsed: data.percentageUsed,
                availableSpare: data.availableSpare,
                mediaErrors: data.mediaErrors ?? 0,
                criticalWarningRaw: data.criticalWarningRaw ?? 0,
                warningThreshold: settings.warningTempCelsius,
                criticalThreshold: settings.criticalTempCelsius,
                now: predictNow
            )
        }
        HealthPredictor.shared.evaluateDwell(now: predictNow)

        for (uuid, data) in updatedSmartByUUID {
            let level = evaluate(smart: data, uuid: uuid)
            let prev = lastLevelByUUID[uuid] ?? .normal
            lastLevelByUUID[uuid] = level
            if prev != level, let disk = disks.first(where: { $0.volumeUUID == uuid }) {
                notifications.notifyIfChanged(
                    level: level,
                    disk: disk,
                    smart: data,
                    diskUUID: uuid,
                    notifyRecover: AppSettings.shared.notifyOnRecover
                )
            }
        }
        healthLevel = worstLevel

        guard let context = modelContext else { return }
        let now = Date()
        for (uuid, data) in updatedSmartByUUID {
            if let c = data.celsius, SmartParse.isPlausibleCelsius(c) {
                context.insert(TemperatureSample(
                    diskUUID: uuid, celsius: Double(c), granularity: "raw"
                ))
            }
            let lastPersist = lastSMARTPersistAt[uuid] ?? .distantPast
            guard now.timeIntervalSince(lastPersist) >= Self.smartPersistInterval else { continue }
            guard let c = data.celsius, SmartParse.isPlausibleCelsius(c) else { continue }
            lastSMARTPersistAt[uuid] = now
            let snap = SmartSnapshot(
                diskUUID: uuid, timestamp: now,
                granularity: SmartSnapshot.granularityRaw,
                celsius: c,
                availableSpare: data.availableSpare ?? -1,
                percentageUsed: data.percentageUsed ?? 0,
                mediaErrors: data.mediaErrors ?? 0,
                unsafeShutdowns: data.unsafeShutdowns ?? 0,
                powerOnHours: data.powerOnHours ?? 0,
                powerCycles: data.powerCycles ?? 0,
                dataUnitsReadTB: data.dataUnitsReadTB ?? 0,
                dataUnitsWrittenTB: data.dataUnitsWrittenTB ?? 0,
                criticalWarningRaw: data.criticalWarningRaw ?? 0,
                warningCompTempTime: data.warningCompTempTime ?? 0,
                criticalCompTempTime: data.criticalCompTempTime ?? 0,
                healthPassed: data.healthPassed ?? false,
                cumulativeEnergyKWh: 0
            )
            context.insert(snap)
        }
        try? context.save()

        // v0.4.0 wave-4g:采一次实时功耗(走 PowerService 5s 缓存,1 个 poll 周期只跑 1 次子进程)
        // v0.4.4 fix-B:对每块 watched disk 各写一次自己的 SmartSnapshot(走 cache,只 spawn 1 次子进程)
        // — 不再把 disks.first 的值写到所有盘(以前多盘时其他盘显示 false data)
        // — powermetrics 不支持 per-disk,所以每盘写的都是系统 SoC 估值;UI 标 "system estimated" 避免误读
        // v0.7 polish-K:PowerService 跑出来的 watts 跟 smartctl 解析的 powerConsumptionWatts 二选一
        //   - smartctl 解析有值(Supported Power States 块成功) → 用 smartctl 值(更准确,per-disk 真实)
        //   - smartctl 解析 nil → 用 powermetrics 估算值(系统 SoC 代理,标 "system estimated")
        //   - 都没有 → nil
        if powerService != nil {
            for disk in disks {
                // 只记 NVMe Power States 额定瓦数。SoC 总功耗不是这块盘的。
                let watts = updatedSmartByUUID[disk.volumeUUID]?.powerConsumptionWatts
                recordPowerSample(watts: watts, disk: disk)
            }
        }

        // v0.5.0 + v0.6:健康预测 — dwell-time hysteresis + SMART 评分 + 温度 trend
        // 详细设计见 HealthPredictor.swift 类注释
        // 1) ingest:每块 watched disk
        //   - 维护 aboveSince/aboveLevel(温度 dwell)
        //   - 维护 recentPoints deque(温度 trend slope)
        //   - SMART 字段评分(立即,无 dwell):
        //     * criticalWarningRaw bit0/bit4 / mediaErrors > 0 / percentageUsed >= 95 → .danger
        //     * percentageUsed >= 90 / availableSpare < 10 → .critical
        //     * percentageUsed >= 70 / availableSpare < 25 → .warning
        //   - 温度 trend slope > 0.05 °C/s + temp >= warning → 升级到 .critical(独立 promote)
        //   - 温度回安全区间时立即 demote(不靠 evaluateDwell 节流,避免误报)
        // 2) evaluateDwell:内部 60s 节流,pollOnce 5s 调一次,实际只 1 min 扫一次
        //   elapsed >= criticalDwell (2 min) → .critical;warningDwell (5 min) → .warning
        //   v0.6 微调:不动 .danger(避免误降)
        //   v0.7 polish-K:sticky .danger demote 已在 ingest 步骤 6 处理(不动 evaluateDwell)
        // v0.7 polish-K:SmartData 字段 optional,HealthPredictor.ingest 签名仍 Int
        //   - 缺数据兜底用 0(保守"安全"侧,跟 SmartSnapshot 写入策略一致)
        //   - HealthPredictor 看到 0 会判定 "无 SMART 危险" + "温度 0°C 安全",正常 demote 路径
        // 不在这里调 NotificationService — 留给 Wave 5B/5C 单独 worker 接 notifyIfChanged
        // v0.8 polish-L:pollOnce 末尾调 DiagnosticTestService.fetchLastResult
        // - 拿到每块盘 self-test log → 写回 disk.lastTest
        // - 24h 缓存:DiagnosticTestService 内部 24h TTL,实际 1 天 1 spawn
        //   (v0.8 polish-L 选择长缓存,因为 self-test 跑 1-数小时,5s poll 读 -l selftest 浪费)
        // - 失败 → disk.lastTest 保持 nil(下次 poll 再试,FDA 缺失 / smartctl 缺失情况)
        // v0.9.1 polish-P1:testByUUID 拿到后,跟下面 benchmark/integrity 一起在
        //   **单次 MainActor.run** 里合并写回 watchedDisks
        //   - 改前:2 个 MainActor.run(test + bench/integrity),各 map 复制一次 + watchedDisks
        //     引用替换 2 次 → 9 widget 每次都全量 rebuild
        //   - 改后:1 个 MainActor.run,1 次 map 复制 + 1 次引用替换 → widget 只 rebuild 1 次
        //   - 同时减少 MainActor context switch 1 次(2 → 1)
        var testByUUID: [String: DiagnosticTestService.TestSnapshot] = [:]
        if let dt = self.diagnosticTestService {
            for disk in disks {
                do {
                    let snap = try await dt.fetchLastResult(bsdName: disk.bsdName)
                    testByUUID[disk.volumeUUID] = snap
                } catch {
                    // 单盘失败不影响其他盘
                    NSLog("DiskMon: pollOnce fetchLastResult failed for \(disk.bsdName): \(error)")
                }
            }
        }
        // v0.8 polish-M:pollOnce 末尾调 benchmark + fsIntegrity.refresh(for:)
        // - spec 硬规则:不每 5s 调 benchmark(写 1 GB 太重),fsIntegrity 同
        // - 实际上 refresh(for:) 是只读 cache,不做 IO,这里调它主要为了把
        //   用户刚跑的 benchmark / verify 结果立即写回 DiskInfo
        //   (用户点按钮 → service 写 cache → 下次 pollOnce 5s 内同步到 DiskInfo)
        // - service 自身的 1h / 24h cache TTL 防止 discoverOnce 触发不必要的 IO
        // v0.9.1 polish-P1:testByUUID + benchmark/integrity 合并成 1 次 MainActor.run
        //   写回 watchedDisks,watchedDisks 引用替换 1 次而非 2 次
        if self.diagnosticTestService != nil
            || self.benchmarkService != nil
            || self.fsIntegrityService != nil {
            await MainActor.run {
                // v0.9.1 polish-P1:单次 map 复制,所有字段(test/benchmark/integrity)同时更新
                // - 旧版分别 map 2 次 → 2N 次 struct copy;新版 1 次 → N 次 copy
                // - 2 块盘:N=2,改前 4 次 copy + 2 次引用替换;改后 2 次 copy + 1 次引用替换
                self.watchedDisks = self.watchedDisks.map { d in
                    var copy = d
                    if let t = testByUUID[d.volumeUUID] {
                        copy.lastTest = t
                    }
                    if let mp = d.mountPoint {
                        if let bm = self.benchmarkService {
                            copy.benchmark = bm.refresh(for: mp)
                        }
                        if let fs = self.fsIntegrityService {
                            copy.integrity = fs.refresh(for: mp)
                        }
                    }
                    return copy
                }
            }
        }
    }

    // MARK: - 功耗记录(v0.4.0 wave-4g,v0.4.4 fix-B per-disk 写入)

    /// 把当前功耗写到指定 disk 的"最新一条 raw SmartSnapshot"
    /// - 失败 nil → 字段保持 nil,UI 显 "—"(不凑合假数据)
    /// - 公开方法,PowerService.onChange 钩子或外部触发都能调
    /// - SwiftData fetchLimit = 1 减少 IO;只更新本周期最新一条
    /// - v0.4.4 fix-B:接受 `disk` 参数,每盘独立写入;多盘时不再共享同一功耗值
    ///   (注:powermetrics 不支持 per-disk,所以每盘写的都是同一系统 SoC 估值;
    ///    UI 侧在 subtitle 标 "system estimated" 避免误读)
    func recordPowerSample(watts: Double?, disk: DiskInfo) {
        guard let context = modelContext else { return }
        let rawGranularity = SmartSnapshot.granularityRaw
        let uuid = disk.volumeUUID
        var descriptor = FetchDescriptor<SmartSnapshot>(
            predicate: #Predicate<SmartSnapshot> { s in
                s.diskUUID == uuid
                && s.granularity == rawGranularity
            },
            sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
        )
        descriptor.fetchLimit = 1
        guard let latest = (try? context.fetch(descriptor))?.first else { return }
        // 幂等赋值:同值 SwiftData 不会触发更新
        latest.powerConsumptionWatts = watts
        try? context.save()
    }

    // MARK: - diskutil 5s 重探测

    private func discoverLoop() async {
        while !Task.isCancelled {
            await discoverOnce()
            await refreshCapacityOnce()
            // 周期重探测放宽到 10s；插拔仍由 NSWorkspace 立即触发 discoverOnce
            try? await Task.sleep(nanoseconds: 10_000_000_000)
        }
    }

    private var lastIdentityCaptures: [String: (cap: DiskCaptureService.Capture, at: Date)] = [:]
    private var lastListedBSDs: Set<String> = []

    private func discoverOnce() async {
        do {
            let listed = try await discovery.listDisks()
            let listedBSDs = Set(listed.map(\.bsdName))
            var capturesByBSD: [String: DiskCaptureService.Capture] = [:]
            let identityTTL: TimeInterval = 30
            for bsd in listedBSDs {
                // 身份字段（VID/SN/总线）变化慢：30s 内复用，避免每次 list 都跑 IOKit
                if let hit = lastIdentityCaptures[bsd],
                   Date().timeIntervalSince(hit.at) < identityTTL,
                   listedBSDs == lastListedBSDs {
                    capturesByBSD[bsd] = hit.cap
                } else {
                    let cap = await capture.capture(bsdName: bsd)
                    capturesByBSD[bsd] = cap
                    lastIdentityCaptures[bsd] = (cap, Date())
                }
            }
            lastListedBSDs = listedBSDs
            lastIdentityCaptures = lastIdentityCaptures.filter { listedBSDs.contains($0.key) }
            var disks = listed.map { disk in
                guard let cap = capturesByBSD[disk.bsdName] else { return disk }
                return disk.applying(cap)
            }
            // Drop images + built-in volumes (Recovery / Preboot / …) from watched set.
            disks.removeAll { d in
                if d.isDiskImage { return true }
                if d.isInternal { return true }
                if DiskDiscoveryService.isSystemVolumeName(d.volumeName) { return true }
                if let mp = d.mountPoint {
                    let leaf = (mp as NSString).lastPathComponent
                    if DiskDiscoveryService.isSystemVolumeName(leaf) { return true }
                }
                let bus = (d.busProtocol ?? "").uppercased()
                if bus.contains("APPLE FABRIC") { return true }
                return false
            }
            await MainActor.run { [weak self] in
                guard let self else { return }
                let nowDiscover = Date()
                self.lastDiscoverGap = self.lastDiscoverAt.map { nowDiscover.timeIntervalSince($0) }
                self.lastDiscoverAt = nowDiscover
                // v0.7 polish-K bug 4.1:stale UUID 清理
                //   - 上轮 watchedUUIDs 里有但本轮 discovery 没返回的盘 = 已拔掉
                //   - 调 HealthPredictor.shared.forget(diskUUID:) 清所有状态
                //     (aboveSince/aboveLevel/aboveCelsius/warnings/reasons/recentPoints)
                //   - 防止下次同 UUID 重新插回时,旧 dwell 状态污染新数据
                let currentDiskUUIDs = Set(disks.map { $0.volumeUUID })
                let staleUUIDs = self.watchedUUIDs.subtracting(currentDiskUUIDs)
                let now = Date()
                var dropMutated = false
                for disk in disks {
                    self.lastSeenDisks[disk.volumeUUID] = SeenDisk(
                        name: disk.displayName,
                        bsdName: disk.bsdName,
                        bus: disk.interfaceSpeedLabel == "—" ? disk.busProtocol : disk.interfaceSpeedLabel,
                        isUSB: disk.busProtocol?.uppercased().contains("USB") == true
                            || disk.usbVendorId != nil
                            || (disk.usbSpeedGbps ?? 0) > 0,
                        serial: disk.serialNumber,
                        lastSeen: now
                    )
                    // Replug may change Volume UUID — match by serial/name too.
                    let liveID = DropIdentity(
                        uuid: disk.volumeUUID,
                        name: disk.displayName,
                        serial: disk.serialNumber
                    )
                    if dropStore.events.contains(where: { $0.returnedAt == nil && $0.identity.matches(liveID) }) {
                        var store = self.dropStore
                        store.markReturned(matching: liveID, at: now)
                        self.dropStore = store
                        dropMutated = true
                    }
                }
                for stale in staleUUIDs {
                    let staleBSD = self.lastSeenDisks[stale]?.bsdName
                    self.recordDropIfSeen(uuid: stale, now: now)
                    dropMutated = true
                    if let staleBSD {
                        let whole = DropClassifier.wholeDiskBSD(staleBSD)
                        self.lastSmartctlAtByBSD.removeValue(forKey: whole)
                        Task { await self.smartctl.invalidateDevice(staleBSD) }
                    }
                    let uuid = HealthPredictor.uuid(from: stale)
                    HealthPredictor.shared.forget(diskUUID: uuid)
                    self.currentByUUID.removeValue(forKey: stale)
                    self.smartErrorByUUID.removeValue(forKey: stale)
                    self.ioCurrentByUUID.removeValue(forKey: stale)
                    self.ioHistoryByUUID.removeValue(forKey: stale)
                    self.ioLastBytes.removeValue(forKey: stale)
                    if self.selectedDiskUUID == stale { self.selectedDiskUUID = nil }
                    self.watchedUUIDs.remove(stale)
                    NSLog("DiskMon: discoverOnce forgot stale UUID \(stale)")
                }
                if dropMutated { self.persistDropStore() }
                if !staleUUIDs.isEmpty {
                    let snapshot = Array(self.watchedUUIDs).sorted()
                    Task { [weak self] in
                        await self?.discovery.saveWatched(snapshot)
                    }
                }
                self.discoveredDisks = disks
                self.refreshWatchedFromDiscovered()
                NSLog("DiskMon: discoverOnce got \(disks.count) external disks, \(staleUUIDs.count) stale cleaned")
            }
            // v0.8 polish-L:discoverOnce 末尾调 LinkHealthService.snapshot(for:)
            // - 拿到每块盘 link snapshot(TB 协商 speed/width)→ 写回 disk.linkSnapshot
            // - 5s 周期跑:但 LinkHealthService 内部 60s 缓存,实际只 60s spawn 一次 diskutil + system_profiler
            //   (注:这里 5s 调是 hot-plug 时让 linkSnapshot 立即刷新,平时走 60s 缓存)
            // v0.9.1 polish-P1:把 link 字段写回跟下面 benchmark/integrity 写回合并
            //   为 1 个 MainActor.run,watchedDisks / discoveredDisks 引用替换从 2 次 → 1 次
            //   (避免 9 widget 每次全量 rebuild)
            //   - read 1 (mps) + read 2 (linkSnaps) 仍需 2 次 MainActor.run(中间有 await
            //     lh.refreshAll 异步操作,不能跨 await 持有 actor 隔离状态)
            //   - 但 write 1 (link) + write 2 (bench/integrity) 合并为 1 次
            var linkSnaps: [String: LinkHealthService.LinkSnapshot] = [:]
            if let lh = self.linkHealthService {
                let mps = await MainActor.run { self.watchedDisks.compactMap { $0.mountPoint } }
                await lh.refreshAll(mountPoints: mps)
                // 把 link snapshot 拉出来(下面 1 次写回会用)
                linkSnaps = await MainActor.run { lh.snapshots }
            }
            // v0.8 polish-M:discoverOnce 末尾调 benchmark + fsIntegrity.refresh(for:)
            // - 轻操作:只读 cache(各自 1h / 24h TTL),不做 IO
            // - cache miss → nil → DiskInfo.benchmark / integrity 保持 nil(下次用户点按钮跑)
            // - cache hit → 把缓存结果写回 DiskInfo(供 UI 端 DiskDetailView 显)
            // - 不主动跑(避免 5s discover 周期重 IO),实际跑由用户点按钮触发
            // v0.9.1 polish-P1:跟 link 写回合并为 1 个 MainActor.run,所有
            //   linkSnapshot / benchmark / integrity 字段在单次 .map 闭包内同步更新
            if self.linkHealthService != nil
                || self.benchmarkService != nil
                || self.fsIntegrityService != nil {
                await MainActor.run {
                    // 单次 watchedDisks 替换 + 单次 discoveredDisks 替换
                    // 所有 3 个字段同时更新:linkSnapshot / benchmark / integrity
                    // (struct copy 仍 2N 次,但 MainActor.run 跨的次数从 2 → 1)
                    self.watchedDisks = self.watchedDisks.map { d in
                        var copy = d
                        if let mp = d.mountPoint, let snap = linkSnaps[mp] {
                            copy.linkSnapshot = snap
                        }
                        if let mp = d.mountPoint {
                            if let bm = self.benchmarkService {
                                copy.benchmark = bm.refresh(for: mp)
                            }
                            if let fs = self.fsIntegrityService {
                                copy.integrity = fs.refresh(for: mp)
                            }
                        }
                        return copy
                    }
                    self.discoveredDisks = self.discoveredDisks.map { d in
                        var copy = d
                        if let mp = d.mountPoint, let snap = linkSnaps[mp] {
                            copy.linkSnapshot = snap
                        }
                        if let mp = d.mountPoint {
                            if let bm = self.benchmarkService {
                                copy.benchmark = bm.refresh(for: mp)
                            }
                            if let fs = self.fsIntegrityService {
                                copy.integrity = fs.refresh(for: mp)
                            }
                        }
                        return copy
                    }
                }
            }
        } catch {
            NSLog("DiskMon: discoverOnce error: \(error)")
        }
    }

    /// v0.4.2:对所有 discovered 盘拿容量三件套(used / free / total),写回 DiskInfo
    /// 容量数据从 diskutil info -plist 真实读:
    ///   - used:`CapacityInUse`
    ///   - total:`Size` / `TotalSize` / `IOKitSize`(三选一)
    ///   - free:`APFSContainerFree`(APFS 物理空闲),非 APFS fallback `Size - CapacityInUse`
    /// 失败字段留 nil(不凑合假数据,UI 优雅降级)
    /// UI 侧(CapacityModule)读 disk.usedBytes / freeBytes / totalBytes,nil → "—" 圆圈 + "Not available"
    /// v0.4.0 wave-4c 旧 `refreshUsedBytesOnce` 升级为三件套;调用点同步更新
    private func refreshCapacityOnce() async {
        // 复制当前 discovered 盘快照(避免竞争)
        let snapshot = await MainActor.run { self.discoveredDisks }
        guard !snapshot.isEmpty else { return }
        // uuid -> (used, free, total)
        var byUUID: [String: (used: UInt64, free: UInt64, total: UInt64, filesystem: String?, writable: Bool?)] = [:]
        for disk in snapshot {
            guard let mp = disk.mountPoint else { continue }
            if let cap = await discovery.volumeFacts(for: mp) {
                byUUID[disk.volumeUUID] = cap
            }
        }
        if byUUID.isEmpty { return }
        await MainActor.run { [weak self] in
            guard let self else { return }
            // 写回 discovered + watched(三字段都更新)
            self.discoveredDisks = self.discoveredDisks.map { d in
                if let c = byUUID[d.volumeUUID] {
                    var copy = d
                    copy.usedBytes = c.used
                    copy.freeBytes = c.free
                    copy.totalBytes = c.total
                    copy.filesystemName = c.filesystem ?? copy.filesystemName
                    copy.isVolumeWritable = c.writable
                    return copy
                }
                return d
            }
            self.watchedDisks = self.watchedDisks.map { d in
                if let c = byUUID[d.volumeUUID] {
                    var copy = d
                    copy.usedBytes = c.used
                    copy.freeBytes = c.free
                    copy.totalBytes = c.total
                    copy.filesystemName = c.filesystem ?? copy.filesystemName
                    copy.isVolumeWritable = c.writable
                    return copy
                }
                return d
            }
        }
    }

    private func refreshWatchedFromDiscovered() {
        let dict = Dictionary(uniqueKeysWithValues: discoveredDisks.map { ($0.volumeUUID, $0) })
        // v0.4.2:始终自动加入新发现的外接盘(不只首次启动)
        // 主人反馈"插入新外接硬盘后,diskmon 不显示新盘"—
        // 旧逻辑只在 watchedUUIDs.isEmpty 时全量加入,新盘热插后不会被加进去
        // 现在:任何还没在 watchedUUIDs 的新盘都加(已 in 的不动,确保不重复)
        // DiskDiscoveryService.parse 已过滤 /Volumes/ 外接盘,所以不会把 macOS 系统卷卷进来
        // v0.4.4 fix-B:跳过 excludedUUIDs 里的盘(用户 toggle-off 后,5s discover 不会再把它们加回)
        var didAddNew = false
        for d in discoveredDisks {
            if !d.isExternalUserVolume { continue }
            if excludedUUIDs.contains(d.volumeUUID) { continue }
            if !watchedUUIDs.contains(d.volumeUUID) {
                watchedUUIDs.insert(d.volumeUUID)
                didAddNew = true
            }
        }
        if didAddNew {
            let snapshot = Array(watchedUUIDs).sorted()
            Task { [weak self] in
                await self?.discovery.saveWatched(snapshot)
            }
        }
        let next = watchedUUIDs.compactMap { dict[$0] }.filter(\.isExternalUserVolume)
        self.watchedDisks = next
    }

    /// 把 IOKit/diskutil 身份写回盘列表。USB 桥没有 SMART 时 UI 仍能显示芯片和链路。
    private func stampIdentity(
        _ byBSD: [String: DiskCaptureService.Capture],
        smartByUUID: [String: SmartData]
    ) {
        func stamp(_ disk: DiskInfo) -> DiskInfo {
            guard let cap = byBSD[disk.bsdName] else { return disk }
            var out = disk.applying(cap)
            if smartByUUID[disk.volumeUUID]?.hasSensorFields == true {
                out.smartUnavailableKind = .none
                let fromDiskutil = cap.smart?.hasSensorFields == true
                let fromCtl = smartByUUID[disk.volumeUUID]?.powerConsumptionWatts != nil
                    || (smartByUUID[disk.volumeUUID]?.firmwareVersion.isEmpty == false)
                if fromDiskutil && fromCtl {
                    out.smartCaptureSource = "diskutil+smartctl"
                } else if fromDiskutil {
                    out.smartCaptureSource = "diskutil"
                } else if fromCtl {
                    out.smartCaptureSource = "smartctl"
                }
            }
            return out
        }
        watchedDisks = watchedDisks.map(stamp)
        discoveredDisks = discoveredDisks.map(stamp)
    }

    private static func captureError(
        kind: DiskInfo.SmartUnavailableKind,
        capture: DiskCaptureService.Capture,
        fallback: String?
    ) -> String {
        switch kind {
        case .usbBridge:
            if let type = capture.usbLinuxType, let name = capture.bridgeChipName ?? capture.productName {
                return "\(name) has sensors; macOS USB does not pass SMART (Linux: smartctl -d \(type))"
            }
            let chip = [capture.vendorName, capture.productName]
                .compactMap { $0 }
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            if chip.isEmpty {
                return "USB bridge does not pass SMART"
            }
            return "USB bridge (\(chip)) does not pass SMART"
        case .notSupported:
            return "SMART not supported on \(capture.busProtocol ?? "this bus")"
        case .pending:
            return fallback ?? "Waiting for first sensor poll (~5s)"
        case .none:
            return fallback ?? ""
        }
    }

    private func sampleIOOnce() async {
        let disks = watchedDisks
        guard !disks.isEmpty else { return }
        let now = Date()
        let keepAfter = now.addingTimeInterval(-3600)
        var current: [String: IOSample] = ioCurrentByUUID
        var history = ioHistoryByUUID
        var last = ioLastBytes
        var anyMeaningfulChange = false
        var bytesByBSD: [String: (read: UInt64, write: UInt64)] = [:]
        for disk in disks {
            let whole = DropClassifier.wholeDiskBSD(disk.bsdName)
            let bytes: (read: UInt64, write: UInt64)
            if let hit = bytesByBSD[whole] {
                bytes = hit
            } else if let fetched = await capture.ioBytes(bsdName: whole) {
                bytesByBSD[whole] = fetched
                bytes = fetched
            } else {
                continue
            }
            if let prev = last[disk.volumeUUID] {
                let dt = now.timeIntervalSince(prev.at)
                if dt > 0.2 {
                    let readDelta = bytes.read >= prev.read ? bytes.read - prev.read : 0
                    let writeDelta = bytes.write >= prev.write ? bytes.write - prev.write : 0
                    let readBps = Double(readDelta) / dt
                    let writeBps = Double(writeDelta) / dt
                    let old = current[disk.volumeUUID]
                    // Idle disks: 0→0 不必逼 UI 重绘
                    if old == nil
                        || abs((old?.readBps ?? 0) - readBps) > 1
                        || abs((old?.writeBps ?? 0) - writeBps) > 1 {
                        anyMeaningfulChange = true
                    }
                    current[disk.volumeUUID] = IOSample(readBps: readBps, writeBps: writeBps)
                    var series = history[disk.volumeUUID] ?? []
                    series.append(IOHistoryPoint(at: now, readBps: readBps, writeBps: writeBps))
                    series.removeAll { $0.at < keepAfter }
                    history[disk.volumeUUID] = series
                }
            } else {
                anyMeaningfulChange = true
            }
            last[disk.volumeUUID] = (bytes.read, bytes.write, now)
        }
        ioLastBytes = last
        ioCurrentByUUID = current
        ioHistoryByUUID = history
        // 空闲时少 bump generation，降低模块树无效重绘（观感：数字仍会随真 IO 变）
        if anyMeaningfulChange {
            ioGeneration &+= 1
        }
    }

    // MARK: - 60s 降采样

    private func downsampleOnce() async {
        let now = Date()
        foldIOMinutes(now: now)
        guard let context = modelContext else { return }
        DownSampler.runScheduled(context: context, now: now, rawDays: settings.rawHistoryDays)
        // 缓存上限：超过时删最旧 raw 采样
        enforceCacheLimit(context: context, now: now)
    }

    /// SwiftData 体积超过 cacheLimitMB 时，优先删最旧 raw 行
    private func enforceCacheLimit(context: ModelContext, now: Date) {
        let limitMB = settings.cacheLimitMB
        guard limitMB > 0 else { return }
        let fm = FileManager.default
        let candidates = [
            SwiftDataStack.appSupportDir.appendingPathComponent("diskmon.store"),
            SwiftDataStack.appSupportDir.appendingPathComponent("diskmon.store-wal"),
            SwiftDataStack.appSupportDir.appendingPathComponent("diskmon.store-shm"),
            fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
                .appendingPathComponent("diskmon.store"),
            fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
                .appendingPathComponent("diskmon.store-wal"),
            fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
                .appendingPathComponent("diskmon.store-shm"),
        ]
        var size = Int64(0)
        for url in candidates {
            if let n = (try? fm.attributesOfItem(atPath: url.path)[.size] as? Int) ?? nil {
                size += Int64(n)
            }
        }
        let limit = Int64(limitMB) * 1024 * 1024
        guard size > limit else { return }
        // 从超过 1 天前的 raw 开始删，每轮最多删 2000 条，避免一次卡顿
        let cutoff = now.addingTimeInterval(-86400)
        let raw = SmartSnapshot.granularityRaw
        var descriptor = FetchDescriptor<SmartSnapshot>(
            predicate: #Predicate<SmartSnapshot> { s in
                s.granularity == raw && s.timestamp < cutoff
            },
            sortBy: [SortDescriptor(\.timestamp, order: .forward)]
        )
        descriptor.fetchLimit = 2000
        guard let rows = try? context.fetch(descriptor), !rows.isEmpty else { return }
        rows.forEach { context.delete($0) }
        try? context.save()
        NSLog("DiskMon: cache limit prune deleted \(rows.count) raw snapshots (store ~\(size) bytes)")
    }

    /// Collapse last 60s of 2s IO into a minute, then into hour buckets (≤168h).
    private func foldIOMinutes(now: Date) {
        if now.timeIntervalSince(lastMinuteFold) < 50 { return }
        lastMinuteFold = now
        let minuteStart = now.addingTimeInterval(-60)
        var hours = ioHourBuckets
        var minutes = ioMinuteBuf
        var changed = false
        for (uuid, series) in ioHistoryByUUID {
            let slice = series.filter { $0.at >= minuteStart }.map {
                IOBucket(at: $0.at, readBps: $0.readBps, writeBps: $0.writeBps)
            }
            guard let folded = IOMean.fold(samples: slice, now: now) else { continue }
            let rolled = IOMean.rollHour(minutes: minutes[uuid] ?? [], newMinute: folded, now: now)
            minutes[uuid] = rolled.minutes
            if let hour = rolled.hoursToAppend {
                var list = hours[uuid] ?? []
                list.append(hour)
                hours[uuid] = IOMean.cappedHours(list, now: now)
                changed = true
            }
        }
        ioMinuteBuf = minutes
        if changed {
            ioHourBuckets = hours
            persistHourBuckets()
        }
    }

    private func persistHourBuckets() {
        guard let data = try? JSONEncoder().encode(ioHourBuckets),
              let json = String(data: data, encoding: .utf8) else { return }
        settings.setIOHoursJSON(json)
    }

    private static func loadHourBuckets() -> [String: [IOBucket]] {
        let json = AppSettings.shared.ioHoursJSON
        guard let data = json.data(using: .utf8),
              let dict = try? JSONDecoder().decode([String: [IOBucket]].self, from: data) else {
            return [:]
        }
        return dict
    }

    // MARK: - 等级评估(SOP §3.6,叠加用户阈值)

    /// v0.2.0:阈值从 AppSettings 读,不再硬编码 70/80/85
    /// v0.2.0:阈值从 AppSettings 读,不再硬编码 70/80/85
    /// v0.7 polish-K:SmartData 字段全 optional,这里 0 兜底(保守"安全"侧)
    ///   - 缺数据时假定 0 度(冷)+ 0% 寿命(新) → 倾向 .normal
    ///   - 真有 SMART bit0/bit4 或 mediaErrors 时,即使其他字段 nil 也会触发 .danger
    /// v0.8 polish-L:self-test failed 立即 .danger
    ///   - SMART self-test 失败(read failure / uncorrectable error)是硬件级 fatal,
    ///     应比任何 SMART 字段告警更早触发
    ///   - 用 selectedDiskUUID 找对应 disk.lastTest(lastShortTest 或 lastLongTest 任一 .failed)
    ///   - nil disk.lastTest → 不知道,不影响
    /// v0.8 polish-M:FS integrity .failed / .warning → 立即 .danger
    ///   - diskutil verifyVolume 报 "Problems were found" → 文件系统不完整,数据可能丢失
    ///   - 优先级:跟 self-test failed 一样高(早于 SMART 字段)
    ///   - nil disk.integrity / .unknown / .verifying / .verified → 不影响
    ///   - .warning(reason) 也算 danger(verifyVolume 报"需要修复"是危险信号)
    func level(for uuid: String) -> HealthLevel {
        if let smart = currentByUUID[uuid] {
            return evaluate(smart: smart, uuid: uuid)
        }
        return lastLevelByUUID[uuid] ?? .normal
    }

    var worstLevel: HealthLevel {
        watchedDisks.map { level(for: $0.volumeUUID) }.max(by: { $0.rank < $1.rank }) ?? .normal
    }

    func evaluate(smart: SmartData, uuid: String? = nil) -> HealthLevel {
        let id = uuid ?? selectedDiskUUID
        let disk = id.flatMap { u in watchedDisks.first(where: { $0.volumeUUID == u }) }
        var selfFailed = false
        if let test = disk?.lastTest {
            if case .failed = test.lastShortTest { selfFailed = true }
            if case .failed = test.lastLongTest { selfFailed = true }
        }
        var fsFailed = false
        if let integrity = disk?.integrity {
            switch integrity.status {
            case .failed: fsFailed = true
            case .warning, .verifying, .verified, .unknown: break
            }
        }
        // Temperature is graded only via HealthPredictor dwell so the menu bar
        // and overview cannot disagree on the same snapshot.
        let policy = HealthPolicy.grade(
            celsius: nil,
            percentageUsed: smart.percentageUsed,
            mediaErrors: smart.mediaErrors,
            criticalWarningRaw: smart.criticalWarningRaw,
            availableSpare: smart.availableSpare,
            warningTemp: settings.warningTempCelsius,
            criticalTemp: settings.criticalTempCelsius,
            selfTestFailed: selfFailed,
            fsFailed: fsFailed
        )
        let pred = HealthPredictor.shared.warning(forDiskUUID: id ?? "")
        let predGrade: HealthGrade
        switch pred {
        case .none: predGrade = .normal
        case .warning: predGrade = .warning
        case .critical: predGrade = .critical
        case .danger: predGrade = .danger
        }
        let grade = HealthPolicy.rank(policy) >= HealthPolicy.rank(predGrade) ? policy : predGrade
        switch grade {
        case .normal: return .normal
        case .warning: return .warning
        case .critical: return .critical
        case .danger: return .danger
        }
    }

    // MARK: - excludedUUIDs 持久化(v0.4.4 fix-B)

    /// 从 UserDefaults 读 excludedUUIDs(JSON 数组字符串)
    /// 缺失 / 解析失败 → 返回空集(不抛错,降级到"无历史 off 状态")
    private static func loadExcludedUUIDs() -> Set<String> {
        guard let str = UserDefaults.standard.string(forKey: excludedUUIDsKey),
              let data = str.data(using: .utf8),
              let list = try? JSONDecoder().decode([String].self, from: data)
        else { return [] }
        return Set(list)
    }

    /// 写 excludedUUIDs 到 UserDefaults(JSON 数组字符串,排序保证稳定)
    /// 解析失败风险用 sorted 数组避免(虽然 Set 也是同语义,但 list 写入是稳定顺序便于 diff)
    private static func saveExcludedUUIDs(_ set: Set<String>) {
        let list = Array(set).sorted()
        guard let data = try? JSONEncoder().encode(list),
              let str = String(data: data, encoding: .utf8)
        else { return }
        UserDefaults.standard.set(str, forKey: excludedUUIDsKey)
    }
}
