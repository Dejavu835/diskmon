import Foundation
import SwiftUI
import Combine
import ServiceManagement
import DiskMonCore

/// 全局应用设置(单例 + 注入环境)
/// v0.2.0:从 PreferencesView 持久化脱节的 @State 改回真相源
/// 设计:
///   - @Observable + @MainActor(让 SwiftUI 自动追踪 + 线程安全)
///   - 字段后挂 UserDefaults(立即持久化,不依赖 SwiftUI 环境)
///   - 暴露 static .shared(给非 View 代码用)
///   - 提供 locale / unit 转换给 i18n 用
@MainActor
@Observable
final class AppSettings {
    /// 全局单例(View 优先用 @Environment,Service fallback 用此)
    static let shared = AppSettings()

    // MARK: - 监控配置

    /// 轮询间隔(秒)1-60
    var pollIntervalSeconds: Double = 5
    /// 警告温度阈值(摄氏度)50-95
    var warningTempCelsius: Int = 70
    /// 严重温度阈值(摄氏度)50-100
    var criticalTempCelsius: Int = 80

    // MARK: - Popover 模块化(v0.6.1 polish-H EditMode,模块顺序 + 隐藏 持久化)

    /// v0.6.1 polish-H + v0.8 polish-L + v0.8 polish-M:9 模块渲染顺序 CSV
    ///   - 默认 health,temperature,capacity,power,disklist,chartmini,link,test,bench,fs
    ///   - v0.8 polish-L:加 link / test 2 模块(LinkHealthModule + DiagnosticTestModule)
    ///   - v0.8 polish-M:加 bench / fs 2 模块(BenchmarkModule + FSIntegrityModule)
    ///   - key 跟 OverviewContent 渲染 switch 对应
    ///   - 已存在 key 不改(只改默认值)— 不引入新 UserDefaults key
    ///   - 注:旧装用户从 8 模块升 9 模块时,stored 仍是 8 字符串(从 UserDefaults 读),
    ///     新装用户用 9 模块默认值
    var moduleOrderRaw: String = "allio,health,temperature,capacity,power,disklist,manage,drop,chartmini,link,test,bench,fs"
    /// 隐藏模块 CSV(空 = 全显),逗号分隔
    var hiddenModulesRaw: String = ""
    /// Disk Manage 默认格式：APFS / ExFAT / FAT32 / NTFSKit
    var defaultFormatRaw: String = "ExFAT"
    /// Disk Manage 首次教程已看完
    var manageIntroDone: Bool = false
    /// After a successful format, mountDisk so the volume reappears in Finder.
    var autoMountAfterFormat: Bool = true
    /// Disk Detail sidebar IO mean window: h1 / h24 / d7
    var ioMeanWindowRaw: String = "h24"
    /// JSON map volumeUUID → "trouble"
    var diskMarksJSON: String = "{}"
    /// JSON map volumeUUID → [{at,readBps,writeBps}] hour buckets
    var ioHoursJSON: String = "{}"

    // MARK: - i18n / 单位

    /// 语言:"en" / "zh-Hans"
    /// 默认中文优先,跟主人审美
    var language: String = "zh-Hans"
    /// 温度单位:"celsius" / "fahrenheit"
    var temperatureUnit: String = "celsius"

    // MARK: - 系统集成

    /// 登录时启动
    var launchAtLogin: Bool = false
    /// 菜单栏脉动
    var showMenuBarPulse: Bool = true
    /// temperature / health / sparkline / ok
    var menuBarModeRaw: String = "temperature"
    /// When every disk is normal, show the quiet OK glyph.
    var autoOKWhenHealthy: Bool = false
    /// worst | selected
    var menuBarColorScopeRaw: String = "worst"
    /// Notify when a disk returns to normal.
    var notifyOnRecover: Bool = true

    // MARK: - 日志与缓存

    /// 自定义日志/讯息文件夹（空 = 默认 Application Support/com.homecenter.diskmon）
    var logDirectoryPath: String = ""
    /// SwiftData 历史缓存上限（MB）。0 = 不限制（仍走 DownSampler 固定保留期）
    var cacheLimitMB: Int = 512
    /// raw 采样保留天数（覆盖 DownSampler 默认；默认 7）
    var rawHistoryDays: Int = 7

    /// 解析后的日志目录
    var resolvedLogDirectory: URL {
        DiskMonDataPaths.logDirectory(customPath: logDirectoryPath)
    }

    // MARK: - 计算属性

    /// 当前 Locale(由 language 字段推导)
    /// v0.4.0 polish-F:默认 zh-Hans,新装用户直接进入中文
    var locale: Locale {
        switch language {
        case "zh-Hans": return Locale(identifier: "zh-Hans")
        case "en":      return Locale(identifier: "en")
        default:        return Locale(identifier: "zh-Hans")
        }
    }

    /// 摄氏度 → 当前单位数字
    /// - Returns: double 值(celsius 原样 / fahrenheit 转 °F)
    func displayTemperature(celsius: Double) -> Double {
        switch temperatureUnit {
        case "fahrenheit": return celsius * 9.0 / 5.0 + 32.0
        default: return celsius
        }
    }

    /// 单元后缀(℃ / ℉)
    var temperatureUnitSymbol: String {
        switch temperatureUnit {
        case "fahrenheit": return "℉"
        default: return "℃"
        }
    }

    /// 单元完整后缀
    var temperatureUnitLabel: String {
        switch temperatureUnit {
        case "fahrenheit": return "Fahrenheit (℉)"
        default: return "Celsius (℃)"
        }
    }

    /// v0.6.1 polish-H:按顺序返回 6 模块 key 数组
    /// - 从 CSV 切分;空字符串时 fallback 到默认顺序
    var moduleOrder: [String] {
        let parts = moduleOrderRaw.split(separator: ",").map(String.init)
        return parts.isEmpty
            ? ["allio", "health", "temperature", "capacity", "power", "disklist", "chartmini"]
            : parts
    }

    /// v0.6.1 polish-H:隐藏模块集合(用于 OverviewContent 过滤)
    /// - CSV 切分后 filter 空 token,避免 "", 边界 bug
    var hiddenModules: Set<String> {
        Set(hiddenModulesRaw.split(separator: ",").map(String.init).filter { !$0.isEmpty })
    }

    // MARK: - 持久化 keys

    private enum Keys {
        static let pollInterval  = "settings.pollIntervalSeconds"
        static let warning        = "settings.warningTempCelsius"
        static let critical       = "settings.criticalTempCelsius"
        static let language       = "settings.language"
        static let unit           = "settings.temperatureUnit"
        static let launchAtLogin  = "settings.launchAtLogin"
        static let menuBarPulse   = "settings.showMenuBarPulse"
        static let menuBarMode    = "menuBarMode"
        static let autoOK         = "settings.autoOKWhenHealthy"
        static let menuBarColor   = "settings.menuBarColorScope"
        static let notifyRecover  = "settings.notifyOnRecover"
        // v0.6.1 polish-H EditMode 持久化
        static let moduleOrder    = "popover.moduleOrderRaw"
        static let hiddenModules  = "popover.hiddenModulesRaw"
        static let defaultFormat  = "settings.manage.defaultFormat"
        static let manageIntro    = "diskmon.v4.manageIntroDone"
        static let autoMountAfterFormat = "settings.manage.autoMountAfterFormat"
        static let ioWindow       = "settings.disks.ioMeanWindow"
        static let diskMarks      = "settings.disks.marksJSON"
        static let ioHours        = "settings.disks.ioHoursJSON"
        static let logDir         = "settings.storage.logDirectoryPath"
        static let cacheLimitMB   = "settings.storage.cacheLimitMB"
        static let rawHistoryDays = "settings.storage.rawHistoryDays"
    }

    private init() {
        // 读持久化值,缺失时用默认值
        let defaults = UserDefaults.standard
        // 1) 轮询间隔(默认 5s)
        if defaults.object(forKey: Keys.pollInterval) != nil {
            self.pollIntervalSeconds = Self.clamp(
                defaults.double(forKey: Keys.pollInterval), low: 1, high: 60
            )
        }
        // 2) 警告温度
        if defaults.object(forKey: Keys.warning) != nil {
            self.warningTempCelsius = Self.clamp(
                defaults.integer(forKey: Keys.warning), low: 50, high: 95
            )
        }
        // 3) 严重温度
        if defaults.object(forKey: Keys.critical) != nil {
            self.criticalTempCelsius = Self.clamp(
                defaults.integer(forKey: Keys.critical), low: 50, high: 100
            )
        }
        // 4) 语言:有持久化值用持久化值;无值默认中文(主人审美优先)
        if let stored = defaults.string(forKey: Keys.language),
           ["en", "zh-Hans"].contains(stored) {
            self.language = stored
        } else {
            self.language = "zh-Hans"
        }
        // 注意:String(localized:) 走 .current bundle 选 lproj,跟 .environment(\.locale) 无关。
        // 主人系统本来就是中文 macOS,所以 zh-Hans.lproj 自动被 Bundle 选中;
        // 这里不再 setPreferredLocalizations(Bundle API 在 macOS 26 SDK 不可用,
        // 用 UserDefaults("AppleLanguages") 会污染全局,不安全)。
        // 5) 温度单位
        if let stored = defaults.string(forKey: Keys.unit),
           ["celsius", "fahrenheit"].contains(stored) {
            self.temperatureUnit = stored
        }
        // 6) 登录启动
        self.launchAtLogin = defaults.bool(forKey: Keys.launchAtLogin)
        // 7) 菜单栏脉动
        if defaults.object(forKey: Keys.menuBarPulse) != nil {
            self.showMenuBarPulse = defaults.bool(forKey: Keys.menuBarPulse)
        } else {
            self.showMenuBarPulse = true
            defaults.set(true, forKey: Keys.menuBarPulse)
        }
        if let stored = defaults.string(forKey: Keys.menuBarMode),
           ["temperature", "health", "sparkline", "ok"].contains(stored) {
            self.menuBarModeRaw = stored
        }
        self.autoOKWhenHealthy = defaults.bool(forKey: Keys.autoOK)
        if let stored = defaults.string(forKey: Keys.menuBarColor),
           ["worst", "selected"].contains(stored) {
            self.menuBarColorScopeRaw = stored
        } else {
            self.menuBarColorScopeRaw = "worst"
        }
        if defaults.object(forKey: Keys.notifyRecover) != nil {
            self.notifyOnRecover = defaults.bool(forKey: Keys.notifyRecover)
        } else {
            self.notifyOnRecover = true
        }
        // 8) v0.6.1 polish-H:Popover 模块顺序(CSV)— 有持久化用持久化,空时用默认
        if let stored = defaults.string(forKey: Keys.moduleOrder), !stored.isEmpty {
            var parts = stored.split(separator: ",").map(String.init)
            var changed = false
            if !parts.contains("allio") {
                parts.insert("allio", at: 0)
                changed = true
            }
            if !parts.contains("manage") {
                if let i = parts.firstIndex(of: "disklist") {
                    parts.insert("manage", at: parts.index(after: i))
                } else {
                    parts.append("manage")
                }
                changed = true
            }
            if !parts.contains("drop") {
                if let i = parts.firstIndex(of: "manage") {
                    parts.insert("drop", at: parts.index(after: i))
                } else {
                    parts.append("drop")
                }
                changed = true
            }
            let migrated = parts.joined(separator: ",")
            self.moduleOrderRaw = migrated
            if changed { defaults.set(migrated, forKey: Keys.moduleOrder) }
        }
        // 9) v0.6.1 polish-H:Popover 隐藏模块(CSV)— 缺省空字符串表示全显
        if let stored = defaults.string(forKey: Keys.hiddenModules) {
            self.hiddenModulesRaw = stored
        }
        if let stored = defaults.string(forKey: Keys.defaultFormat),
           ["APFS", "ExFAT", "FAT32", "NTFSKit"].contains(stored) {
            self.defaultFormatRaw = stored
        }
        self.manageIntroDone = defaults.bool(forKey: Keys.manageIntro)
        if defaults.object(forKey: Keys.autoMountAfterFormat) != nil {
            self.autoMountAfterFormat = defaults.bool(forKey: Keys.autoMountAfterFormat)
        } else {
            self.autoMountAfterFormat = true
        }
        if let stored = defaults.string(forKey: Keys.ioWindow),
           ["h1", "h24", "d7"].contains(stored) {
            self.ioMeanWindowRaw = stored
        }
        if let stored = defaults.string(forKey: Keys.diskMarks) {
            self.diskMarksJSON = stored
        }
        if let stored = defaults.string(forKey: Keys.ioHours) {
            self.ioHoursJSON = stored
        }
        if let stored = defaults.string(forKey: Keys.logDir) {
            self.logDirectoryPath = stored
        }
        if defaults.object(forKey: Keys.cacheLimitMB) != nil {
            let v = defaults.integer(forKey: Keys.cacheLimitMB)
            self.cacheLimitMB = max(0, min(v, 8192))
        }
        if defaults.object(forKey: Keys.rawHistoryDays) != nil {
            let v = defaults.integer(forKey: Keys.rawHistoryDays)
            self.rawHistoryDays = max(1, min(v, 90))
        }
    }

    // MARK: - 持久化 helper

    /// 任何 setter 调一次:写 UserDefaults + clamp + 触发 didChange
    func setPollInterval(_ value: Double) {
        let v = Self.clamp(value, low: 1, high: 60)
        if pollIntervalSeconds != v {
            pollIntervalSeconds = v
            UserDefaults.standard.set(v, forKey: Keys.pollInterval)
            notifyDidChange()
        }
    }

    func setWarning(_ value: Int) {
        let v = Self.clamp(value, low: 50, high: 95)
        if warningTempCelsius != v {
            warningTempCelsius = v
            UserDefaults.standard.set(v, forKey: Keys.warning)
            notifyDidChange()
        }
    }

    func setCritical(_ value: Int) {
        let v = Self.clamp(value, low: 50, high: 100)
        if criticalTempCelsius != v {
            criticalTempCelsius = v
            UserDefaults.standard.set(v, forKey: Keys.critical)
            notifyDidChange()
        }
    }

    func setLanguage(_ value: String) {
        let v = ["en", "zh-Hans"].contains(value) ? value : "zh-Hans"
        if language != v {
            language = v
            UserDefaults.standard.set(v, forKey: Keys.language)
            // String(localized:) 走 .current bundle,不在这里动 Bundle;
            // 切换后用户重启 app 才完全生效(Date/Number/Text(LK) 立即随 .environment(\.locale) 切)
            notifyDidChange()
        }
    }

    func setTemperatureUnit(_ value: String) {
        let v = ["celsius", "fahrenheit"].contains(value) ? value : "celsius"
        if temperatureUnit != v {
            temperatureUnit = v
            UserDefaults.standard.set(v, forKey: Keys.unit)
            notifyDidChange()
        }
    }

    func setLaunchAtLogin(_ value: Bool) {
        if launchAtLogin != value {
            launchAtLogin = value
            UserDefaults.standard.set(value, forKey: Keys.launchAtLogin)
            applyLaunchAtLogin()
            notifyDidChange()
        }
    }

    func setShowMenuBarPulse(_ value: Bool) {
        if showMenuBarPulse != value {
            showMenuBarPulse = value
            UserDefaults.standard.set(value, forKey: Keys.menuBarPulse)
            notifyDidChange()
        }
    }

    func setMenuBarMode(_ raw: String) {
        let v = ["temperature", "health", "sparkline", "ok"].contains(raw) ? raw : "temperature"
        if menuBarModeRaw != v {
            menuBarModeRaw = v
            UserDefaults.standard.set(v, forKey: Keys.menuBarMode)
            notifyDidChange()
        }
    }

    func setAutoOKWhenHealthy(_ on: Bool) {
        if autoOKWhenHealthy != on {
            autoOKWhenHealthy = on
            UserDefaults.standard.set(on, forKey: Keys.autoOK)
            notifyDidChange()
        }
    }

    func setMenuBarColorScope(_ raw: String) {
        let v = ["worst", "selected"].contains(raw) ? raw : "worst"
        if menuBarColorScopeRaw != v {
            menuBarColorScopeRaw = v
            UserDefaults.standard.set(v, forKey: Keys.menuBarColor)
            notifyDidChange()
        }
    }

    func setNotifyOnRecover(_ on: Bool) {
        if notifyOnRecover != on {
            notifyOnRecover = on
            UserDefaults.standard.set(on, forKey: Keys.notifyRecover)
            notifyDidChange()
        }
    }

    // v0.6.1 polish-H + v0.8 polish-M:模块顺序 / 隐藏 setter
    // - 顺序:CSV 写入,空数组 fallback 到默认 9 模块顺序
    //   (v0.8 polish-M:加 bench + fs,共 9 模块)
    // - 隐藏:Set → sorted → CSV(确定性持久化,避免 Set 顺序漂移)
    func setModuleOrder(_ order: [String]) {
        let v = order.isEmpty
            ? "allio,health,temperature,capacity,power,disklist,manage,chartmini,link,test,bench,fs"
            : order.joined(separator: ",")
        if moduleOrderRaw != v {
            moduleOrderRaw = v
            UserDefaults.standard.set(v, forKey: Keys.moduleOrder)
            notifyDidChange()
        }
    }

    func setHiddenModules(_ hidden: Set<String>) {
        let v = hidden.sorted().joined(separator: ",")
        if hiddenModulesRaw != v {
            hiddenModulesRaw = v
            UserDefaults.standard.set(v, forKey: Keys.hiddenModules)
            notifyDidChange()
        }
    }

    func setDefaultFormat(_ raw: String) {
        let allowed = ["APFS", "ExFAT", "FAT32", "NTFSKit"]
        let v = allowed.contains(raw) ? raw : "ExFAT"
        if defaultFormatRaw != v {
            defaultFormatRaw = v
            UserDefaults.standard.set(v, forKey: Keys.defaultFormat)
            notifyDidChange()
        }
    }

    func setAutoMountAfterFormat(_ on: Bool) {
        if autoMountAfterFormat != on {
            autoMountAfterFormat = on
            UserDefaults.standard.set(on, forKey: Keys.autoMountAfterFormat)
            notifyDidChange()
        }
    }

    var isManageModuleVisible: Bool {
        moduleOrder.contains("manage") && !hiddenModules.contains("manage")
    }

    func setManageIntroDone(_ on: Bool) {
        if manageIntroDone != on {
            manageIntroDone = on
            UserDefaults.standard.set(on, forKey: Keys.manageIntro)
            notifyDidChange()
        }
    }

    func setIOMeanWindow(_ raw: String) {
        let v = ["h1", "h24", "d7"].contains(raw) ? raw : "h24"
        if ioMeanWindowRaw != v {
            ioMeanWindowRaw = v
            UserDefaults.standard.set(v, forKey: Keys.ioWindow)
            notifyDidChange()
        }
    }

    var diskMarks: DiskMarkStore {
        DiskMarkStore.parse(diskMarksJSON)
    }

    func setDiskMark(_ mark: DiskUserMark, for uuid: String) {
        var store = diskMarks
        store.set(mark, for: uuid)
        let json = store.json()
        if diskMarksJSON != json {
            diskMarksJSON = json
            UserDefaults.standard.set(json, forKey: Keys.diskMarks)
            notifyDidChange()
        }
    }

    func setIOHoursJSON(_ json: String) {
        if ioHoursJSON != json {
            ioHoursJSON = json
            UserDefaults.standard.set(json, forKey: Keys.ioHours)
        }
    }

    var isDropModuleVisible: Bool {
        moduleOrder.contains("drop") && !hiddenModules.contains("drop")
    }

    func setDropModuleVisible(_ on: Bool) {
        var order = moduleOrder
        if !order.contains("drop") {
            if let i = order.firstIndex(of: "manage") {
                order.insert("drop", at: order.index(after: i))
            } else {
                order.append("drop")
            }
            setModuleOrder(order)
        }
        var hidden = hiddenModules
        if on { hidden.remove("drop") } else { hidden.insert("drop") }
        setHiddenModules(hidden)
    }

    func setManageModuleVisible(_ on: Bool) {
        var order = moduleOrder
        if !order.contains("manage") {
            if let i = order.firstIndex(of: "disklist") {
                order.insert("manage", at: order.index(after: i))
            } else {
                order.append("manage")
            }
            setModuleOrder(order)
        }
        var hidden = hiddenModules
        if on { hidden.remove("manage") } else { hidden.insert("manage") }
        setHiddenModules(hidden)
    }

    // MARK: - 日志与缓存

    func setLogDirectoryPath(_ path: String) {
        let v = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if logDirectoryPath != v {
            logDirectoryPath = v
            UserDefaults.standard.set(v, forKey: Keys.logDir)
            // 若旧目录已有 drop-events，迁到新目录（新路径缺文件时）
            migrateDropEventsIfNeeded(to: DiskMonDataPaths.logDirectory(customPath: v))
            DiskMonDataPaths.appendActivity("log directory set to \(v.isEmpty ? "default" : v)", customPath: v)
            notifyDidChange()
        }
    }

    private func migrateDropEventsIfNeeded(to destDir: URL) {
        let fm = FileManager.default
        let dest = destDir.appendingPathComponent("drop-events.json")
        guard !fm.fileExists(atPath: dest.path) else { return }
        let legacy = DiskMonDataPaths.defaultDirectory.appendingPathComponent("drop-events.json")
        guard fm.fileExists(atPath: legacy.path) else { return }
        try? fm.copyItem(at: legacy, to: dest)
    }

    func setCacheLimitMB(_ mb: Int) {
        let v = max(0, min(mb, 8192))
        if cacheLimitMB != v {
            cacheLimitMB = v
            UserDefaults.standard.set(v, forKey: Keys.cacheLimitMB)
            notifyDidChange()
        }
    }

    func setRawHistoryDays(_ days: Int) {
        let v = max(1, min(days, 90))
        if rawHistoryDays != v {
            rawHistoryDays = v
            UserDefaults.standard.set(v, forKey: Keys.rawHistoryDays)
            notifyDidChange()
        }
    }

    // MARK: - 静态 helpers

    private static func detectSystemLanguage() -> String {
        let preferred = Locale.preferredLanguages.first ?? "en"
        if preferred.lowercased().hasPrefix("zh") { return "zh-Hans" }
        return "en"
    }

    private static func clamp<T: Comparable>(_ value: T, low: T, high: T) -> T {
        min(max(value, low), high)
    }

    // MARK: - 登录启动集成

    private func applyLaunchAtLogin() {
        // SMAppService 在 macOS 13+ 提供登录启动管理
        if #available(macOS 13, *) {
            let service = SMAppService.mainApp
            do {
                if launchAtLogin {
                    if service.status != .enabled {
                        try service.register()
                    }
                } else {
                    if service.status == .enabled {
                        try service.unregister()
                    }
                }
            } catch {
                NSLog("DiskMon: SMAppService toggle failed: \(error)")
            }
        }
    }

    // MARK: - 通知

    /// AppSettings 字段变更通知(给 HealthMonitor 订阅用)
    /// 用 NotificationCenter 而不是 Combine,简单可靠
    static let didChangeNotification = Notification.Name("AppSettings.didChange")

    /// 显式触发 didChange(Preferences 改完调一次,触发外部重读)
    func notifyDidChange() {
        NotificationCenter.default.post(
            name: Self.didChangeNotification, object: self
        )
    }
}
