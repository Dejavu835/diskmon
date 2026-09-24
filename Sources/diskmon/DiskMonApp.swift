import SwiftUI
import SwiftData
import Foundation
// v0.9.3 minimax-C:TipKit 5 步 onboarding(macOS 14+ 真实首次启动教程)
// - Tips.configure([.displayFrequency(.immediate), .datastoreLocation(.applicationSupport)])
//   在 App.init() 调一次,创建 TipKit datastore(~/Library/Application Support/diskmon/tipkit/)
// - 必须在 init() 调,不能在 .onAppear(那样首次 MenuBarExtra 弹出才 config,首 step 错过)
// - macOS 14+ guard 一下,老系统不引入 TipKit 也不 crash
import TipKit

@main
struct DiskMonApp: App {
    // v0.4.0 wave-4g:显式持有 PowerService 实例再传给 HealthMonitor,确保两者共享同一 @Observable
    // (HealthMonitor.pollOnce 每 5s 采功耗;View 也用同一个实例做实时显示)
    @State private var power = PowerService()
    @State private var monitor: HealthMonitor
    @State private var settings = AppSettings.shared
    // v0.8 polish-L:LinkHealthService(TB4/USB4 协商 link 监控)
    // + DiagnosticTestService(SMART self-test 闭环)— 跟 monitor 一样 @State + env 注入
    @State private var linkHealth = LinkHealthService()
    @State private var diagnostic = DiagnosticTestService()
    // v0.8 polish-M:BenchmarkService(顺序写+读测速,fcntl F_NOCACHE + F_PREALLOCATE + F_FULLFSYNC)
    // + FSIntegrityService(diskutil verifyVolume 只读)— 跟 monitor 一样 @State + env 注入
    @State private var benchmark = BenchmarkService()
    @State private var fsIntegrity = FSIntegrityService()
    @State private var diskFormat = DiskFormatService()

    init() {
        // v0.9.3 minimax-C:TipKit configure(必须在 init 调,不能在 .onAppear)
        // - macOS 14+ API,老系统 guard 一下,失败 NSLog 不 crash
        // - .displayFrequency(.immediate) 5 步立即按顺序显,不等用户行为
        // - .datastoreLocation(.applicationSupport) 存到 ~/Library/Application Support/diskmon/
        //   (避开 default Caches,避免系统清理)
        if #available(macOS 14, *) {
            do {
                // v0.9.3 minimax-C:TipKit datastore 默认 ~/Library/Application Support/<bundle id>/
                // (即 diskmon)下,跟 .applicationDefault 行为一致(系统管 lifecycle,不丢)
                // - grok 调研:macOS 14+ 只暴露 .applicationDefault / .groupContainer / .url
                // - 旧 .applicationSupport API 在 SDK 14 已被合并到 applicationDefault
                try Tips.configure([
                    .displayFrequency(.immediate),
                    .datastoreLocation(.applicationDefault)
                ])
            } catch {
                NSLog("diskmon: TipKit configure failed: \(error)")
            }
        }
        // 先建 PowerService,再注入到 HealthMonitor(避免 HealthMonitor 拿 fallback singleton)
        let p = PowerService()
        // v0.8 polish-L:LinkHealthService + DiagnosticTestService 也建实例
        // 跟 monitor 一样共享同一 @Observable(避免双实例)
        let lh = LinkHealthService()
        let dt = DiagnosticTestService()
        // v0.8 polish-M:BenchmarkService + FSIntegrityService 也建实例
        // 跟 monitor 一样共享同一 @Observable(避免双实例)
        let bm = BenchmarkService()
        let fs = FSIntegrityService()
        let df = DiskFormatService()
        _power = State(initialValue: p)
        _linkHealth = State(initialValue: lh)
        _diagnostic = State(initialValue: dt)
        _benchmark = State(initialValue: bm)
        _fsIntegrity = State(initialValue: fs)
        _diskFormat = State(initialValue: df)
        // v0.8 polish-L:把 LinkHealthService + DiagnosticTestService 注入 HealthMonitor
        // (HealthMonitor 在 discoverOnce / pollOnce 末尾主动拉 link / self-test 写回 DiskInfo)
        _monitor = State(initialValue: HealthMonitor(
            powerService: p,
            linkHealthService: lh,
            diagnosticTestService: dt,
            benchmarkService: bm,
            fsIntegrityService: fs
        ))
        _settings = State(initialValue: AppSettings.shared)
    }

    var body: some Scene {
        // 字体 stack(全 app 统一):
        //   body / 正文  →  Font.system(size:, weight:, design: .default)  macOS 自动 PingFang SC fallback
        //   标题 / 大数字 →  .fraunces(size:, weight:, italic:)             嵌入 Fraunces Variable + Italic
        //   数字 / 单色  →  Font.system(size:, weight:, design: .monospaced)  SF Mono
        // Locale 通过 .environment(\.locale, settings.locale) 注入每个根 view
        MenuBarExtra {
            PopoverView()
                .environment(monitor)
                .environment(settings)
                .environment(power)
                // v0.6.1 polish-G:PopoverView 里 6 个 Module 都接 HealthPredictor
                // (HealthOverview / Temperature / Capacity / Power / DiskList / ChartMini
                //  + SMARTModule 在 SMART tab 内的 SMARTModule 子页)
                .environment(HealthPredictor.shared)
                // v0.8 polish-L:LinkHealthService + DiagnosticTestService
                // - PopoverView 的 LinkHealthModule / DiagnosticTestModule 读
                .environment(linkHealth)
                .environment(diagnostic)
                // v0.8 polish-M:BenchmarkService + FSIntegrityService
                // - PopoverView 的 BenchmarkModule / FSIntegrityModule 读
                .environment(benchmark)
                .environment(fsIntegrity)
                .environment(diskFormat)
                .environment(\.locale, settings.locale)
                // v0.8 polish-L:popover 首次出现时,延迟 200ms 等 HealthMonitor 首次
                // discoverOnce 完成,再 linkHealth.refreshAll()(避免 race 时
                // watchedDisks 还没填充,refreshAll 走 0 mountPoints no-op)
                .task {
                    try? await Task.sleep(nanoseconds: 200_000_000)
                    let mps = monitor.watchedDisks.compactMap { $0.mountPoint }
                    await linkHealth.refreshAll(mountPoints: mps)
                    // v0.8 polish-M:同样延迟 200ms 后调 benchmark + fsIntegrity
                    // refreshAll(避免 race 时 watchedDisks 还没填充)
                    // 注:benchmark / fsIntegrity.refreshAll 当前是 no-op(用户主动点按钮触发),
                    // 但保持一致调用模式,留给未来需要时启用
                    await benchmark.refreshAll(mountPoints: mps)
                    await fsIntegrity.refreshAll(mountPoints: mps)
                }
        } label: {
            // MenuBarLabel 需要 settings + monitor(取最差等级作 menu bar 颜色)
            // v0.4.4 fix-A Gap B:也注入 power,允许 MenuBarLabel 读 power.currentWatts / isAvailable
            @Bindable var m = monitor
            @Bindable var s = settings
            MenuBarLabel(monitor: m)
                .environment(s)
                .environment(power)
                // v0.4.0 polish-F:菜单栏 label 也走中文 bundle(温度数字 ℃ / ℉ 上下文字符串)
                .environment(\.locale, settings.locale)
        }
        .menuBarExtraStyle(.window)
        .modelContainer(monitor.modelContainer)

        Settings {
            PreferencesView()
                .environment(monitor)
                .environment(settings)
                .environment(power)
                // v0.8 polish-L:Settings scene 也注入 LinkHealth + Diagnostic(future-proof,Preferences
                // 当前未用,但保持 env chain 一致,避免后续 worker 改同样的坑)
                .environment(linkHealth)
                .environment(diagnostic)
                // v0.8 polish-M:同样注入 Benchmark + FSIntegrity(env chain 一致)
                .environment(benchmark)
                .environment(fsIntegrity)
                .environment(diskFormat)
                .environment(\.locale, settings.locale)
        }
        // v0.9.5:Settings 之前被 PreferencesView 固定 880×580 锁死,用户拖不动
        .defaultSize(width: 880, height: 580)
        .windowResizability(.automatic)
        // v0.4.4 fix-A Gap A:Settings scene 也注入 SwiftData 容器,允许子 View
        // 读 @Environment(\.modelContext) / @Query(目前 PreferencesView 未用,
        // 但 5 子 View 未来若要展示历史采样曲线必须依赖 modelContext,先 wire 上避免后续
        // 修同样的坑)。
        .modelContainer(monitor.modelContainer)
        // v0.4.0 polish-E:在 Settings scene 上加 .commands group,显式注册 ⌘, → openSettings()
        // MenuBarExtra + LSUIElement=true 下,SwiftUI 不会自动加 Preferences menu item,
        // 默认 ⌘, 也不响应。用 .commands { CommandGroup(replacing: .appSettings) { SettingsLink() } }
        // 把 ⌘, 注入到 first responder chain(LSUIElement=true 仍 work),让 popover 没弹出时按 ⌘,
        // 也能打开 Settings。SettingsLink 是 macOS 14+ SwiftUI 官方 view,自动绑 ⌘,。
        .commands {
            CommandGroup(replacing: .appSettings) {
                SettingsLink {
                    Text(String(localized: "ui.preferences", defaultValue: "Preferences…"))
                }
            }
            // v0.5.0:加 ⌘W / ⌘E 快捷键 — 用 CommandMenu("View") 注册 2 个 openWindow 入口
            // - OpenWindowButton 内置 @Environment(\.openWindow),SwiftUI 14+ 官方支持
            //   (CommandMenu 闭包本身拿不到 environment value,必须用 View wrapper)
            // - 快捷键 ⌘W / ⌘E 在 macOS 上通常被系统占用(关闭窗口),但在 menu bar app
            //   + LSUIElement=true + 没有 standard window focus 的场景下,系统级 ⌘W 不工作,
            //   我们 binding 到菜单后,菜单 action 永远生效(用户可显式选 X 关窗)
            CommandMenu(L10n.t("menu.view", zh: "显示", en: "View", language: settings.language)) {
                OpenWindowButton(
                    windowId: "warnings",
                    title: L10n.t("popover.warnings", zh: "警告…", en: "Warnings…", language: settings.language),
                    shortcut: "w",
                    modifiers: [.command, .shift]
                )
                OpenWindowButton(
                    windowId: "export",
                    title: L10n.t("popover.export", zh: "导出报告…", en: "Export Report…", language: settings.language),
                    shortcut: "e",
                    modifiers: [.command]
                )
                OpenWindowButton(
                    windowId: "disk-detail",
                    title: L10n.t("popover.detail", zh: "磁盘详情…", en: "Disk Detail…", language: settings.language),
                    shortcut: "d",
                    modifiers: [.command]
                )
            }
        }

        // 磁盘详情深看页(WindowGroup,openWindow(id: "disk-detail") 触发)
        // v0.4.0 wave-4E:升级到 1280x800 匹配 2 列布局(左 320 侧栏 + 右 1000 主区)
        // v0.4.0 wave-5 polish-C:defaultSize 1100x700(响应式起点)+ .windowResizability(.contentSize)
        // 允许用户拖大缩小,内部用 NavigationSplitView / GeometryReader 自适应
        // v0.4.4 fix-A Gap A:补 .modelContainer(monitor.modelContainer) — DiskDetailView
        // + Modules/ChartMiniModule/TemperatureModule 都用 @Environment(\.modelContext),
        // 缺这个会导致窗口打开后 chartmini/temperature 模块 fetch 抛 nil,空 chart。
        // v0.9 polish-N1:主人说"详情界面太大",defaultSize 缩到 720x580 接近 Popover 视觉锚点
        // — 内部改 macOS Tahoe CC 风格模块化 widget 网格(9 widget + Resize handle),
        // 720x580 是 220 sidebar + 500 detail(2 列 × 244pt + 12pt gap)合理起点
        // v0.9.4:.windowResizability(.contentSize) → .contentMinSize(grok 3 调研)
        //   - 旧 .contentSize 锁死窗口 size,不能放大缩小(主人 bug:"窗口不能调整大小")
        //   - 改 .contentMinSize 让 min 由 .frame(minWidth:minHeight:) 决定,max 由内容决定
        //   - 加 .windowToolbarStyle(.unified) 让窗口显示 unified toolbar(主人审美"克制")
        //   - 内部 DiskDetailView .frame(minWidth: 360, idealWidth: 720, maxWidth: .infinity,
        //     minHeight: 360, idealHeight: 580, maxHeight: .infinity) 自适应
        WindowGroup("DiskDetail", id: "disk-detail") {
            DiskDetailView()
                .environment(monitor)
                .environment(settings)
                .environment(power)
                // v0.6.1 polish-G:DiskDetail 内嵌 SMARTModule / CapacityModule / PowerModule
                // 全部接 HealthPredictor,需要 env 注入
                .environment(HealthPredictor.shared)
                // v0.8 polish-L:DiskDetailView 的 SMART pane 加 health ring + self-test CTA,
                // 读 DiagnosticTestService
                .environment(diagnostic)
                // v0.9.1 polish-O2:补 LinkHealthService env — 修 v0.9.0 polish-N1
                // 缺 linkHealth env 阻断 LinkWidget crash。
                // DiskDetailView 内的 LinkWidget(@Environment(LinkHealthService.self))
                // 走 mountPoint → LinkHealthService.snapshots dict 查 link 协商。
                // 之前 v0.9.0 只注入 monitor/settings/power/diagnostic/benchmark/fsIntegrity
                // 漏 linkHealth → 打开 DiskDetail 即触发 fatalError: No ObservableObject
                // of type LinkHealthService available,LinkWidget 渲染即崩。
                .environment(linkHealth)
                // v0.8 polish-M:DiskDetailView 的 SMART pane 加 benchmark + integrity CTA
                .environment(benchmark)
                .environment(fsIntegrity)
                .environment(diskFormat)
                .environment(\.locale, settings.locale)
        }
        .defaultSize(width: 720, height: 580)
        .windowResizability(.automatic)
        .windowToolbarStyle(.unified)
        .modelContainer(monitor.modelContainer)

        // v0.5.0:Warnings Center 独立窗口
        // - grok 调研:加 sibling WindowGroup + modelContainer + env chain
        // - env chain 跟 MenuBarExtra / Settings / DiskDetail 一致
        //   (monitor / settings / power / locale + HealthPredictor.shared + modelContainer)
        // - HealthPredictor.shared 单例跟 HealthMonitor 同生命周期(DiskMonApp 持有)
        // - 800x500 固定窗口(任务硬规则),不允许拖大缩小
        // v0.8 polish-M:Warnings 窗口也注入 BenchmarkService + FSIntegrityService(env chain 一致)
        // v0.9.4:.contentSize → .contentMinSize + 600x400 ideal(主人 bug:窗口不能调)
        WindowGroup("Warnings", id: "warnings") {
            WarningsView()
                .environment(monitor)
                .environment(settings)
                .environment(power)
                .environment(HealthPredictor.shared)
                .environment(benchmark)
                .environment(fsIntegrity)
                .environment(diskFormat)
                .environment(\.locale, settings.locale)
        }
        .defaultSize(width: 600, height: 400)
        .windowResizability(.automatic)
        .windowToolbarStyle(.unified)
        .modelContainer(monitor.modelContainer)

        // v0.5.0:Export Report 独立窗口
        // - 同样 800x500 固定,modelContainer 注入(给 SmartSnapshot fetchCount 用)
        // - 不需要 HealthPredictor(只查 SwiftData 走 modelContext)
        // v0.9.4:.contentSize → .contentMinSize + 600x400 ideal(主人 bug:窗口不能调)
        WindowGroup("Export", id: "export") {
            ExportView()
                .environment(monitor)
                .environment(settings)
                .environment(power)
                .environment(\.locale, settings.locale)
        }
        .defaultSize(width: 600, height: 400)
        .windowResizability(.automatic)
        .windowToolbarStyle(.unified)
        .modelContainer(monitor.modelContainer)
    }
}

// MARK: - OpenWindowButton(v0.5.0 菜单命令桥)

/// 菜单命令里的 openWindow 入口(grok 调研设计)
/// - CommandMenu 闭包本身拿不到 @Environment(\.openWindow),必须用 View wrapper
/// - SwiftUI 14+ 官方支持:Button 内可调 openWindow env action
/// - keyboardShortcut 让 ⌘W / ⌘E 全局生效(macOS menu bar 焦点)
struct OpenWindowButton: View {
    let windowId: String
    let title: String
    let shortcut: String
    var modifiers: EventModifiers = .command

    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button(title) {
            openWindow(id: windowId)
        }
        .keyboardShortcut(
            KeyEquivalent(Character(shortcut)),
            modifiers: modifiers
        )
    }
}
