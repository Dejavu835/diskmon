import SwiftUI
import SwiftData

/// Popover 主容器 v0.4.0 polish-D(macOS 控制中心 顶栏 tab 切换版)
/// v0.4.0 polish-C:自适应窗口(640..980 × 480..820)
/// v0.6.1 polish-H:Popover 模块化 EditMode 入口
///   - TopBar.trailingAccessory 槽注入 Edit 按钮(square.grid.2x2 / pencil.circle.fill)
///   - isEditing 状态驱动:Edit 模式 → 顶栏下出现说明条 + OverviewContent 每模块右上角 −
///   - 关闭 Edit 模式 → 还原正常 6 模块渲染,无 overlay
///   - 简化版:不做 drag 手势,只做 toggle visibility + 顺序(顺序当前来自 settings.moduleOrder)
/// v0.9 polish-N2:EditMode 升级到 iOS Control Center 风格
///   - 0.5s 长按 topBar 任意位置 / editButton → 进入 EditMode(原 tap toggle 保留)
///   - editHint 文案改 iOS CC 风格:"Tap ✕ to hide. Drag to rearrange. Tap + to add."
///   - 隐藏 × / jiggle / 拖动重排 / AddModulesSheet 全 11 module → 在 OverviewContent 实现
///     (共享 modifier 抽到 `Views/EditMode.swift`)
/// v0.9.1 polish-O1:9 tab 减到 5 main + 1 `...` 按钮触发 MoreSheet
///   - switch currentTab 砍掉 `.link/.test/.bench/.fs` 4 case
///   - 加 `.more` case → currentTab 变 .more 时 .onChange 自动开 MoreSheet
///   - MoreSheet 玻璃背景 + LazyVGrid 2 列 + 4 入口卡(link / test / bench / fs)
///   - 关闭 MoreSheet 自动 reset currentTab 回 .overview(避免 .more 卡死状态)
///   - 主人审美"克制 + 高级" + macOS CC 原版 5-7 tab 范围更稳
/// v0.9.1 polish-O2:整合 DiskPickerView 引用到 Popover 顶栏,统一"切盘"概念
///   - 解决 v0.9.0 polish-N1 旧问题:DiskPickerView 130 行零引用,Popover 没切盘 UI
///     (主人切盘要开 detail window),现在注入到 TopBar.leadingAccessory 槽
///   - 解决"primaryDisk vs selectedDisk"概念分裂:9 tab Content 一律用
///     `monitor.selectedDisk ?? monitor.watchedDisks.first` 替代原 `primaryDisk` 派生
///   - 加 SMART module 自动切 tab:OverviewContent → onModuleAdded 回调 → PopoverView
///     决定是否切到 .smart(其他 module 不切)
///
/// === 整体布局(自适应 760×640 起步)===
/// - **顶部 TopBar**(~52pt,内容自适应)
///   - 左侧:`logo` "diskmon" Fraunces 14pt italic
///   - 中间:5 个 tab 玻璃按钮(总览 / 温度 / 容量 / 功耗 / SMART)
///   - 右侧:`time` SF Mono HH:mm(TimelineView 每秒刷)
///   - 选中 tab 琥珀高光 + 1px 底 border 琥珀
/// - **中部 tab content**(flex 撑开,随 tab 切换)
///   - 总览 tab:`OverviewContent` 2-4 列自适应模块网格(`GridItem(.adaptive)`)
///   - 温度 tab:`TemperatureContent`(TemperatureModule + 24h 折线,左 flex / 右 flex)
///   - 容量 tab:`CapacityContent`(CapacityModule + 已用列表,左固定 / 右 flex)
///   - 功耗 tab:`PowerContent`(PowerModule + 24h 功耗折线,左 flex / 右 flex)
///   - SMART tab:`SMARTContent`(SMARTModule + 全字段,左固定 / 右 flex)
/// - **底部状态栏**(~60pt,固定 — 3 按钮不缩)
///   - Preferences… 按钮(走 `\.openSettings` env,SwiftUI 14+ 官方打开 Settings scene)
///   - Open Disk Detail… 按钮(`openWindow(id: "disk-detail")`)
///   - Quit 按钮(`NSApp.terminate(nil)`)
///   - ⌘, 走 `.keyboardShortcut(",", modifiers: .command)` — popover 弹出时可触发
/// - 整个 PopoverView 外层 `.glassChrome(cornerRadius: 16)`(统一接口,真液态玻璃)
/// - 35mm 噪点 + vignette 复用 `NoiseOverlay`
/// - tab 切换动画:`Animation.timingCurve(0.2, 0.8, 0.2, 1)` 0.3s(淡入淡出)
///
/// === 设计选择(polish-D) ===
/// - **macOS 控制中心 顶栏**:`Views/TopBar.swift` 独立组件,5 tab 等宽分布
/// - **tab 切换驱动内容**:`@State currentTab` + `switch` 决定中部内容
/// - **不引入绿**(主人审美):选中态用 `Color.dsNormal`(琥珀)
/// - **不 loop 动画 / 不弹跳**:0.3s 一次性淡入淡出
/// - **不 mock 数据**;nil / 0 → "—"
/// - **不动** 5 个 Preferences 子 View / AppSettings / Localizable.strings /
///   GlassBackground / 现有 Modules(只加 `Detail` 标识)
/// - **新 i18n key**:`String(localized: "...", defaultValue: "...")` 兜底模式,
///   不写 Localizable.strings(任务硬规则)
struct PopoverView: View {
    @Environment(HealthMonitor.self) private var monitor
    @Environment(PowerService.self) private var power
    @Environment(AppSettings.self) private var settings
    @Environment(\.openWindow) private var openWindow
    // v0.4.0 polish-E:用 SwiftUI 14+ 官方 openSettings 替代 NSApp.sendAction(Selector("showPreferencesWindow:"))
    // 原 selector 不是 SwiftUI Settings scene 注册的标准 action(标准是 showSettingsWindow:),导致 ⌘, 无反应
    @Environment(\.openSettings) private var openSettings

    /// 当前选中的 tab
    @State private var currentTab: TopBarTab = .overview

    /// v0.6.1 polish-H:Popover 模块化 EditMode 开关
    /// - 开启:每模块右上角出现 "−" 隐藏按钮 + 底部 Add Module 按钮
    /// - 关闭:正常 6 模块渲染,无 overlay
    @State private var isEditing: Bool = false

    /// v0.9.1 polish-O1:MoreSheet 关闭后回到的主 tab(.overview 默认)
    /// - 进入 .more 前记住 lastMainTab,关闭 MoreSheet 后恢复
    /// - 默认 .overview,5 main tab 切换也更新此值
    @State private var lastMainTab: TopBarTab = .overview
    @State private var moreInitialRoute: MoreSheet.Route = .menu

    /// v0.9.3 minimax-C:Onboarding 持久化(@AppStorage 跨 launch 保留)
    /// - false = 首次启动 → topBar 下方显 TipView(DiskmonOnboardingTips) 5 步教程
    /// - true = 用户点 "Don't show again" / 走完 5 步 / 旧版本已 onboarding 过 → 不显
    /// - 跟 TipKit datastore 双轨:AppStorage = 永久跳过标志,datastore = 本次 5 步走完状态
    @AppStorage(OnboardingStore.hasCompletedKey) private var hasOnboarded: Bool = false

    /// 状态徽章数据(用于底部 / tab 切换)
    private var healthyCount: Int {
        monitor.watchedDisks.filter { monitor.level(for: $0.volumeUUID) == .normal }.count
    }

    private var worstLevel: HealthLevel {
        monitor.worstLevel
    }

    var body: some View {
        ZStack {
            // 35mm 噪点 + vignette(覆盖整个 popover)
            NoiseOverlay()
                .accessibilityHidden(true)

            // v0.4.0 polish-C:GeometryReader 读可用尺寸 → topBar 固定 ~52,bottomBar ~60,tabContent flex
            GeometryReader { geo in
                VStack(spacing: 12) {
                    topBar
                    // v0.9.3 minimax-C:Onboarding 5 步 TipKit(首次启动显)
                    // - !hasOnboarded → topBar 下方插入 TipView(DiskmonOnboardingTips())
                    // - 5 Tip 顺序展示(MenuBarTemp → PickVolume → SmartHealth → HistoryChart → NotificationsFDA)
                    // - TipView 自带 skip / next 按钮(系统默认 UI),用户 Esc / click-outside 自动 dismiss
                    // - 走完 5 步 / Esc 跳过 → hasOnboarded = true(下次启动不显)
                    // - 显式 "Don't show again" 按钮(Skip All) 也在此卡右上 — 永久跳过
                    if !hasOnboarded && currentTab == .overview {
                        onboardingCard
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                    // v0.6.1 polish-H:Edit 模式时插入说明条
                    if isEditing {
                        editHint
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                    tabContent
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .clipped()
                    bottomBar
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 14)
                .frame(width: geo.size.width, height: geo.size.height)
                .clipped()
            }
        }
        // P1-4 polish-H:design 方案A 720x640 固定(不是自适应)
        // - design HTML .popover-wrap { width: 720px; height: 640px; } 硬性固定
        // - 旧 min 640 / ideal 760 / max 980 + min 480 / ideal 640 / max 820 自适应版,
        //   主人 0.5.1 校准:popover 不应该"长高" — 固定大小 = 视觉锚点稳定
        // - MenuBarExtra(.window) 仍走 NSPopover,但 720x640 内部 1:1 固定,不受内容驱动
        .frame(minWidth: 560, idealWidth: 720, maxWidth: .infinity,
               minHeight: 480, idealHeight: 640, maxHeight: .infinity)
        .background(ResizableWindowConfigurator(minSize: CGSize(width: 560, height: 480)))
        // v0.4.3 polish-G P0-3:从 `.glassChrome` 改 `.glass`(带阴影版,自带 0 24px 48px rgba(0,0,0,0.4) 阴影)
        // - 任务规范:Popover 主容器升级为"带阴影"玻璃(之前 chrome 不投影,视觉锚点弱)
        // - 圆角从 16 升到 20(更柔和,跟 macOS 26 液态玻璃风格统一)
        // - 阴影规范 0 24px 48px rgba(0,0,0,0.4) — CSS:offset-x:0 / offset-y:24px / blur:48px
        // - 注意:SwiftUI `.shadow(radius:x:y:)` 的 radius 是 blur 半径,所以 radius:48 y:24
        //   (原 GlassBackground 默认 0 12px 24px 偏弱,polish-G 升级到 0 24px 48px 强一档)
        // - macOS 26+ 走 `backgroundExtensionEffect()`(系统级液态玻璃)
        // - macOS 14-25 走 NSVisualEffectView(`.hudWindow` + 40px blur + 1.8 saturation)兜底
        .glass(cornerRadius: 20)
        .environment(\.openDiskManage, OpenDiskManageAction {
            withAnimation(TopBarTab.transition) {
                currentTab = .manage
            }
        })
        .environment(\.openTest, OpenTestAction {
            moreInitialRoute = .test
            withAnimation(TopBarTab.transition) {
                currentTab = .more
            }
        })
        .onAppear {
            NotificationService.shared.requestAuthorizationIfNeeded()
        }
        // v0.9.1 polish-O1:currentTab 变 .more → 弹 MoreSheet
        // - TopBar `...` 按钮 → currentTab = .more → 这里 .onChange 同步 showMoreSheet = true
        // - MoreSheet 关闭 → showMoreSheet = false → .onChange(of: showMoreSheet) 同步
        //   currentTab 回 lastMainTab,避免 .more 状态卡死(下次切其他 tab 正常)
        // - 主 tab 切换(.overview/.temperature/...)也更新 lastMainTab(记最后主 tab)
        .onChange(of: currentTab) { _, newValue in
            switch newValue {
            case .more:
                break
            case .overview, .temperature, .capacity, .manage, .power, .smart:
                lastMainTab = newValue
            }
        }
    }

    // MARK: - 顶栏(macOS 控制中心 风格)

    private var topBar: some View {
        TopBar(
            currentTab: $currentTab,
            // v0.9.1 polish-O2:leading accessory 槽注入 DiskPickerView
            // - 解决 v0.9.0 polish-N1 旧问题:DiskPickerView 130 行零引用,Popover 没切盘 UI
            //   (只有 DiskDetail sidebar 有 disk picker),主人切盘要开 detail
            // - 设计位置:logo "diskmon" 右边,tab 玻璃按钮之前;在 trailing Edit 按钮前
            // - 形态:小玻璃卡 + 盘 SF Symbol + 当前盘名(Fraunces italic)+ chevron.down
            //   点击 → 弹小 sheet 列出所有 watchedDisks,点切到 selectedDiskUUID
            // - 兜底:无 selectedDisk → 显示 watchedDisks.first(跟原 primaryDisk 行为一致)
            //   让"切盘"在 popover 主屏就跟"主盘"统一成同一概念(避免分裂)
            leadingAccessory: {
                AnyView(
                    DiskPickerView(
                        disk: monitor.selectedDisk ?? monitor.watchedDisks.first
                    )
                    .transition(.opacity)
                )
            },
            // v0.6.1 polish-H:trailing accessory 槽注入 Edit 按钮
            // - SF Symbol `square.grid.2x2`(跟 topbar.overview.tab 同 icon,语义"模块网格")
            // - Edit 模式时:琥珀高亮 + 0.5s 一次性淡入
            // - 非 Edit 模式:secondary 文字色 + 0.15s hover 反馈
            trailingAccessory: {
                AnyView(
                    editButton
                        .transition(.opacity)
                )
            }
        )
        .transition(.opacity)
        // v0.9 polish-N2:0.5s 长按 topBar 任意位置 → 进入 EditMode(iOS CC 风格)
        // - 跟 tab 按钮的 tap 手势不冲突:tab 走 Button action,长按走 onLongPressGesture
        // - 跟 editButton 内部 Button 共存:tap 走 toggle,长按走 enter(只 set true)
        // - 视觉反馈不做(scale topBar 太重);主人审美"克制 + 高级"
        .onLongPressGesture(minimumDuration: 0.5) {
            enterEditMode()
        }
    }

    /// v0.6.1 polish-H:Edit 切换按钮(放进 TopBar.trailingAccessory)
    /// - isEditing = true → 琥珀高亮 + `pencil.circle.fill` icon
    /// - isEditing = false → secondary 灰 + `square.grid.2x2` icon
    /// - 点击 toggle isEditing
    /// v0.9 polish-N2:加 0.5s 长按 → 强制进入 EditMode(只置 true,不 toggle)
    ///   iOS CC 风格入口:点击 = toggle,长按 = enter(快速操作)
    private var editButton: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                isEditing.toggle()
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: isEditing ? "checkmark" : "square.grid.2x2")
                    .font(.system(size: 12, weight: .semibold))
                Text(isEditing
                     ? L10n.t("popover.edit.done", zh: "完成", en: "Done", language: settings.language)
                     : L10n.t("popover.edit.start", zh: "编辑", en: "Edit", language: settings.language))
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(isEditing ? Color.dsNormal : Color.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isEditing ? Color.dsNormal.opacity(0.18) : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(isEditing
              ? String(localized: "popover.edit.done", defaultValue: "Done")
              : String(localized: "popover.edit.start", defaultValue: "Edit modules"))
        .accessibilityLabel(
            isEditing
                ? String(localized: "popover.edit.done", defaultValue: "Done")
                : String(localized: "popover.edit.start", defaultValue: "Edit modules")
        )
        // v0.9 polish-N2:长按 0.5s 直接进入 EditMode(只 set true;tap 走 toggle)
        .onLongPressGesture(minimumDuration: 0.5) {
            enterEditMode()
        }
    }

    /// v0.9 polish-N2:Edit 模式说明文字(在 TopBar 下方,tabContent 上方)
    /// - 11pt secondary 文字,Edit 模式显示
    /// - 文案 iOS CC 风格:"Tap ✕ to hide. Drag to rearrange. Tap + to add."
    ///   跟 EditModeBadge(SF Symbol `xmark.circle.fill` 17pt 琥珀)对应
    private var editHint: some View {
        Text(L10n.t(
            "popover.edit.hint",
            zh: "点 ✕ 隐藏模块，拖动卡片排序，点 + 添加",
            en: "Tap ✕ to hide. Drag to rearrange. Tap + to add.",
            language: settings.language
        ))
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.primary.opacity(0.03))
        )
    }

    // MARK: - v0.9.3 minimax-C:Onboarding 5 步 TipKit 卡

    /// v0.9.3 minimax-C:Onboarding 教程卡(OnboardingTipView 5 步顺序展示)
    /// - 5 步自管:Back / "1/5" / Next / Skip
    /// - 走完 5 步 → finishOnboarding()(hasOnboarded = true,AppStorage gate 永久关)
    /// - 永久跳过 → skipOnboarding()(同上)
    /// - 玻璃背景(RoundedRectangle 0.04 alpha,跟 editHint / menuBarExtra 风格一致)
    /// - 高度:OnboardingTipView 内部自适应(50-100pt),不挤压 tabContent
    /// - macOS 14+ guard:老系统降级为纯文字"Welcome to diskmon"
    private var onboardingCard: some View {
        OnboardingTipView(
            onFinish: { finishOnboarding() },
            onSkip: { skipOnboarding() }
        )
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.primary.opacity(0.06), lineWidth: 0.5)
        )
    }

    /// v0.9.3 minimax-C:走完 5 步 → 标记完成 + 0.3s 淡出
    /// - AppStorage hasOnboarded = true(下次启动不显)
    /// - 不调 Tips.invalidate()(保留 5 tip "未展示" 状态 — 用户在 Preferences reset 后还能再看 5 步)
    private func finishOnboarding() {
        withAnimation(.easeInOut(duration: 0.3)) {
            hasOnboarded = true
        }
        OnboardingStore.markCompleted()
    }

    /// v0.9.3 minimax-C:永久跳过 onboarding
    /// - AppStorage hasOnboarded = true(下次启动不显)
    /// - 不调 Tips.invalidate()(同上,保留 reset 能力)
    /// - 0.3s easeInOut 淡出动画(走 SwiftUI .transition)
    private func skipOnboarding() {
        withAnimation(.easeInOut(duration: 0.3)) {
            hasOnboarded = true
        }
        OnboardingStore.markCompleted()
    }

    // MARK: - 长按进入 EditMode(iOS CC 风格)

    /// v0.9 polish-N2:顶栏长按进入 EditMode(iOS CC 风格)
    /// - 0.5s 长按 topBar 任意位置 → isEditing = true(只置 true,不 toggle)
    /// - 原 editButton tap 仍可 toggle;长按跟 tap 共存(SwiftUI gesture system 自动区分)
    /// - 退出 EditMode 走 editButton tap(变 `pencil.circle.fill` 琥珀态)或自动 close
    private func enterEditMode() {
        guard !isEditing else { return }
        withAnimation(.easeInOut(duration: 0.25)) {
            isEditing = true
        }
    }

    // MARK: - tab 内容(macOS 控制中心 切换)

    @ViewBuilder
    private var tabContent: some View {
        // 切换动画:0.3s `cubic-bezier(0.2, 0.8, 0.2, 1)`(跟 TopBar 同步)
        let animation = TopBarTab.transition
        // v0.9.1 polish-O2:统一切盘概念 — 9 tab Content 一律用
        // `monitor.selectedDisk ?? monitor.watchedDisks.first`(原 primaryDisk 派生删)
        // - 原 `primaryDisk` 派生 = "celsius 最大的盘"(只反映"温度最热"),跟 `selectedDisk`
        //   (用户 selectedDiskUUID 选中的盘)是两个不同概念,导致切盘 UI 切到 X 盘,
        //   tab 仍显示 Y 盘(celsius 最大)→ 主人体感"切盘不灵"
        // - 统一切盘概念后:DiskPickerView 切 selectedDiskUUID → 9 tab 同步切到该盘
        //   兜底:无 selectedDiskUUID → watchedDisks.first(原 primaryDisk 行为,保留)
        let selectedDisk = monitor.selectedDisk ?? monitor.watchedDisks.first
        Group {
            switch currentTab {
            case .overview:
                OverviewContent(
                    monitor: monitor,
                    power: power,
                    settings: settings,
                    selectedDisk: selectedDisk,
                    // v0.6.1 polish-H:EditMode 状态注入(让 OverviewContent 渲染 − overlay)
                    isEditing: isEditing,
                    // v0.9.1 polish-O2:加 SMART module 自动切 tab — OverviewContent
                    // handleAdd 完成持久化后,回调 → PopoverView 决定是否切到 .smart
                    onModuleAdded: { key in handleModuleAdded(key) }
                )
                .transition(DiskMonMotion.tabInsert)
            case .temperature:
                TemperatureContent(
                    monitor: monitor,
                    power: power,
                    settings: settings,
                    selectedDisk: selectedDisk
                )
                .transition(DiskMonMotion.tabInsert)
            case .capacity:
                CapacityContent(
                    monitor: monitor,
                    settings: settings,
                    selectedDisk: selectedDisk
                )
                .transition(DiskMonMotion.tabInsert)
            case .manage:
                DiskManageContent(monitor: monitor, selectedDisk: selectedDisk)
                    .transition(DiskMonMotion.tabInsert)
            case .power:
                PowerContent(
                    monitor: monitor,
                    power: power,
                    settings: settings,
                    selectedDisk: selectedDisk
                )
                .transition(DiskMonMotion.tabInsert)
            case .smart:
                SMARTContent(
                    monitor: monitor,
                    selectedDisk: selectedDisk
                )
                .transition(DiskMonMotion.tabInsert)
            // v0.9.1 polish-O1:5 main + 1 more,secondary 4 个 (link/test/bench/fs) 改放 MoreSheet
            // - .more 时主区显示空(MoreSheet .sheet(isPresented:) 覆盖在上)
            // - MoreSheet 内 LazyVGrid 2 列入口卡,点卡后扩展成对应全屏 view
            case .more:
                MoreSheet(
                    monitor: monitor,
                    selectedDisk: selectedDisk,
                    initialRoute: moreInitialRoute,
                    onClose: {
                        moreInitialRoute = .menu
                        withAnimation(TopBarTab.transition) {
                            currentTab = lastMainTab
                        }
                    }
                )
                .id(moreInitialRoute)
                .transition(DiskMonMotion.tabInsert)
            }
        }
        .animation(animation, value: currentTab)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // v0.9.1 polish-O2:删 `PopoverView.primaryDisk` 派生(改用
    // `monitor.selectedDisk ?? monitor.watchedDisks.first` 直接走 monitor 状态)
    // - 旧 `primaryDisk` 用 celsius 最大当主盘,只反映"温度最热",跟用户切盘意愿分裂
    // - 新模型:PopoverView 不再派生"主盘"概念,9 tab Content 直接用
    //   `monitor.selectedDisk ?? monitor.watchedDisks.first`(`selectedDisk` 已在
    //   HealthMonitor 里定义为 selectedDiskUUID ?? watchedDisks.first)

    // MARK: - v0.9.1 polish-O2:OverviewContent 添加 module 回调

    /// v0.9.1 polish-O2:AddModulesSheet 选中 "smart" 时,自动切到 SMART tab
    /// - 修旧问题:用户加 SMART module 后 Overview 仍显示 Overview tab,
    ///   SMART module 已 append 到 moduleOrder 末尾,但用户看不到新增效果
    ///   → 体感"加了没用",实际上 SMART 已加,只是需要切 tab 才看到
    /// - 修后:加 SMART → 切到 .smart tab(0.3s 淡入淡出 + 跟其他 tab 切换一致动画)
    /// - 加其他 module → 不切(用户大概率想看 Overview 全貌)
    /// - currentTab == .smart 时不重复切(避免无谓 animation)
    private func handleModuleAdded(_ key: String) {
        guard key == "smart", currentTab != .smart else { return }
        withAnimation(TopBarTab.transition) {
            currentTab = .smart
        }
    }

    // MARK: - 底部状态栏(保持不变)

    private var bottomBar: some View {
        HStack(spacing: 8) {
            // 左:错误提示(若有)
            if let err = monitor.lastError {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.dsWarning)
                    Text(err)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Spacer()
            }
            // 右:5 按钮(原 3 + v0.5.0 新增 2)
            // v0.4.0 polish-E:用 SwiftUI 14+ 官方 openSettings env 打开 Settings scene
            // 原 NSApp.sendAction(Selector("showPreferencesWindow:")) 不会触发 SwiftUI Settings scene
            // (Settings scene 注册的是 showSettingsWindow:,不是 showPreferencesWindow:)
            // .keyboardShortcut(",", modifiers: .command) 已转移到 DiskMonApp 的
            // CommandGroup(replacing: .appSettings) { SettingsLink() },避免重复 ⌘, 路由冲突
            // v0.5.0:加 ⌘W(Open Warnings)/ ⌘E(Export Report),由 DiskMonApp 的
            // CommandMenu("View") 里的 OpenWindowButton 注入,菜单项快捷键全局生效
            bottomBarIcon(
                systemImage: "gearshape",
                title: String(localized: "popover.preferences", defaultValue: "Preferences…"),
                action: { openSettings() }
            )
            bottomBarIcon(
                systemImage: "exclamationmark.triangle",
                title: String(localized: "popover.warnings", defaultValue: "Warnings"),
                action: { openWindow(id: "warnings") },
                badge: monitor.worstLevel.rank >= HealthLevel.warning.rank
            )
            bottomBarIcon(
                systemImage: "externaldrive",
                title: String(localized: "popover.detail", defaultValue: "Disk Detail"),
                action: { openWindow(id: "disk-detail") },
                disabled: monitor.watchedDisks.isEmpty
            )
            Button {
                NSApp.terminate(nil)
            } label: {
                Text(L10n.t("popover.quit", zh: "退出", en: "Quit", language: settings.language))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
            }
            .buttonStyle(.plain)
            .help(L10n.t("popover.quit", zh: "退出 DiskMon", en: "Quit DiskMon", language: settings.language))
        }
        .frame(height: 60)
    }

    /// 底部按钮统一工厂(高级交互规范)
    /// - 主文本前景色 themeFgDark + 0.05 alpha 背景(跟原 3 按钮一致)
    /// - hover/focus/press 走 macOS 控制中心标准反馈
    private func bottomBarIcon(
        systemImage: String,
        title: String,
        action: @escaping () -> Void,
        disabled: Bool = false,
        badge: Bool = false
    ) -> some View {
        Button(action: action) {
            ZStack(alignment: .topTrailing) {
                Image(systemName: systemImage)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(disabled ? AnyShapeStyle(.tertiary) : AnyShapeStyle(Color.themeFgDark))
                    .frame(width: 28, height: 22)
                if badge {
                    Circle()
                        .fill(monitor.worstLevel.color)
                        .frame(width: 6, height: 6)
                        .offset(x: 2, y: -1)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .help(title)
    }
}

// MARK: - HealthLevel 排序扩展

// MARK: - PopoverGlassBackground 已删除 v0.4.0 polish-B
// 整个 PopoverView 外层玻璃现在统一走 `Views/Preferences/GlassBackground.swift` 的 `.glassChrome()` 接口
// - macOS 26+:`backgroundExtensionEffect()`(系统级液态玻璃)
// - macOS 14-25:NSVisualEffectView(`.popover` + `vibrantDark`)兜底
// 35mm 噪点由 PopoverView 顶层 `NoiseOverlay()` 覆盖,不挪到玻璃层

// MARK: - MoreSheet(v0.9.1 polish-O1, 4 secondary 入口 + 全屏内容)

/// MoreSheet v0.9.1 polish-O1
/// - Popover 顶栏 `...` 按钮 → 弹此 sheet
/// - 状态 1:`\.menu` — 4 入口卡 LazyVGrid 2 列(link / test / bench / fs)
/// - 状态 2:选中卡后 → 渲染对应 LinkContent / TestContent / BenchContent / FSContent
///   全屏版,顶部 back 按钮返回入口网格
/// - 关闭:右上 × → dismiss → PopoverView.onChange(showMoreSheet) → 复位 currentTab 回 lastMainTab
///
/// === 设计选择 ===
/// - **复用 4 个现有 Content View**(LinkContent / TestContent / BenchContent / FSContent):
///   polish-O1 不重写模块,只把"在 popover 主区放"改成"在 sheet 内放"
/// - **sheet 尺寸**:480x520(比 popover 主区 720x640 略小,符合 iOS/macOS sheet "次级弹窗" 视觉规范)
/// - **入口卡 2 列 LazyVGrid**:AddModulesSheet 已用同模式(160x80 玻璃卡,icon + 标题 + 描述),polish-O1 复用规范
/// - **不写 Localizable.strings**:全部用 `String(localized: ..., defaultValue: ...)` 兜底
struct MoreSheet: View {
    let monitor: HealthMonitor
    let selectedDisk: DiskInfo?
    let onClose: () -> Void

    enum Route: Hashable {
        case menu
        case manage
        case link
        case test
        case bench
        case fs
    }

    @State private var route: Route

    init(
        monitor: HealthMonitor,
        selectedDisk: DiskInfo?,
        initialRoute: Route = .menu,
        onClose: @escaping () -> Void
    ) {
        self.monitor = monitor
        self.selectedDisk = selectedDisk
        self.onClose = onClose
        _route = State(initialValue: initialRoute)
    }

    /// v0.9.1 polish-O1:2 列 LazyVGrid(每列 flexible + 10pt spacing)— 跟 AddModulesSheet 一致
    private let columns: [GridItem] = [
        GridItem(.flexible(), spacing: 10),
        GridItem(.flexible(), spacing: 10)
    ]

    /// v0.9.1 polish-O1:4 入口卡静态表 — (icon, title, desc, route)
    /// - 跟 ModuleRegistry.moduleDisplayNames 的 link/test/bench/fs 一致
    /// - 不复用 ModuleRegistry(它有 11 项,本 sheet 只列 4 secondary)
    private struct Entry: Identifiable {
        let id: Route
        let icon: String
        let title: String
        let desc: String
    }

    private let entries: [Entry] = [
        Entry(
            id: .link,
            icon: "cable.connector",
            title: String(localized: "more.entry.link.title", defaultValue: "Link Health"),
            desc: String(localized: "more.entry.link.desc", defaultValue: "TB4 / PCIe / USB 协商")
        ),
        Entry(
            id: .test,
            icon: "checkmark.shield",
            title: String(localized: "more.entry.test.title", defaultValue: "Self-Test"),
            desc: String(localized: "more.entry.test.desc", defaultValue: "SMART self-test 闭环")
        ),
        Entry(
            id: .bench,
            icon: "gauge.with.dots.needle.67percent",
            title: String(localized: "more.entry.bench.title", defaultValue: "Benchmark"),
            desc: String(localized: "more.entry.bench.desc", defaultValue: "顺序写读 MB/s")
        ),
        Entry(
            id: .fs,
            icon: "checkmark.seal",
            title: String(localized: "more.entry.fs.title", defaultValue: "FS Integrity"),
            desc: String(localized: "more.entry.fs.desc", defaultValue: "diskutil verifyVolume")
        )
    ]

    var body: some View {
        VStack(spacing: 0) {
            // 顶栏:back(路由 != .menu)或 title + close(路由 == .menu)
            header
            Divider().background(Color.white.opacity(0.06))

            // 内容:按 route 切
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - 顶栏(back / title / close)

    /// v0.9.1 polish-O1:MoreSheet 顶栏
    /// - .menu 状态:左 title "More Tools" + SF Symbol `square.grid.2x2.fill` 琥珀
    ///   右侧 close(`xmark.circle.fill`)
    /// - 非 .menu 状态:左 back chevron + 中央 title(对应 secondary 名)+ 右侧 close
    private var header: some View {
        HStack(spacing: 8) {
            // 左:back 或 title(if 块只占位左,spacer 推到中间 / 右)
            Group {
                if route == .menu {
                    HStack(spacing: 6) {
                        Image(systemName: "square.grid.2x2.fill")
                            .font(.system(size: 14, weight: .regular))
                            .foregroundStyle(Color.dsNormal)
                        Text(String(
                            localized: "more.title",
                            defaultValue: "More Tools"
                        ))
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color.themeFgDark)
                    }
                } else {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            route = .menu
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 11, weight: .semibold))
                            Text(String(
                                localized: "more.back",
                                defaultValue: "Back"
                            ))
                            .font(.system(size: 12, weight: .medium))
                        }
                        .foregroundStyle(Color.dsNormal)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(String(localized: "more.back.help", defaultValue: "Back to tools"))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // 中央:路由标题(只在非 .menu 状态显,跟左 back 配对;menu 状态左已有 title)
            if route != .menu {
                Text(currentRouteTitle)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.themeFgDark)
                    .lineLimit(1)
                    .fixedSize()  // 标题固定尺寸,不被 spacer 挤压
            }

            Spacer(minLength: 0)

            // 右:close ×
            Button {
                onClose()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .help(String(localized: "common.close", defaultValue: "Close"))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - 内容(route 切换)

    /// v0.9.1 polish-O1:MoreSheet 主区内容 — 按 route 切
    @ViewBuilder
    private var content: some View {
        switch route {
        case .menu:
            // 4 入口卡 LazyVGrid 2 列 — 跟 AddModulesSheet 一致规范
            ScrollView(.vertical, showsIndicators: false) {
                LazyVGrid(columns: columns, spacing: 10) {
                    ForEach(entries) { entry in
                        entryCard(entry)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 14)
            }
        case .manage:
            DiskManageContent(monitor: monitor, selectedDisk: selectedDisk)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .link:
            LinkContent(monitor: monitor, selectedDisk: selectedDisk)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(12)
        case .test:
            TestContent(monitor: monitor, selectedDisk: selectedDisk)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(12)
        case .bench:
            BenchContent(monitor: monitor, selectedDisk: selectedDisk)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(12)
        case .fs:
            FSContent(monitor: monitor, selectedDisk: selectedDisk)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(12)
        }
    }

    // MARK: - 入口卡(.menu 状态)

    /// v0.9.1 polish-O1:单入口卡(160x80)— icon + 标题 + 描述
    /// - 复用 AddModulesSheet.moduleCell 设计语言(玻璃卡 + 圆角 + 1px 边)
    /// - 点击 → route = entry.id → 主区切到对应 Content
    /// - hover:0.15s easeOut 抬升(背景 0.6 → 0.7)
    /// - 选中态:进入对应 route 后 0.2s 高亮琥珀边
    @State private var hoveredEntry: Route? = nil

    private func entryCard(_ entry: Entry) -> some View {
        let isHovered = (hoveredEntry == entry.id)
        return Button {
            withAnimation(.easeInOut(duration: 0.25)) {
                route = entry.id
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: entry.icon)
                    .font(.system(size: 18, weight: .regular))
                    .foregroundStyle(Color.dsNormal)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.themeFgDark)
                        .lineLimit(1)
                    Text(entry.desc)
                        .font(.system(size: 9.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.tail)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                // 右侧 chevron(暗示"展开")
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 10)
            .frame(height: 80)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.themeBgElevated.opacity(isHovered ? 0.75 : 0.6))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(
                        isHovered
                            ? Color.dsNormal.opacity(0.45)
                            : Color.white.opacity(0.08),
                        lineWidth: 1
                    )
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.15)) {
                hoveredEntry = hovering ? entry.id : nil
            }
        }
        .help(entry.title)
    }

    // MARK: - 计算属性

    /// v0.9.1 polish-O1:路由标题(中央显示)
    private var currentRouteTitle: String {
        switch route {
        case .menu: return ""
        case .manage: return String(localized: "more.route.manage", defaultValue: "Disk Manage")
        case .link: return String(localized: "more.route.link", defaultValue: "Link Health")
        case .test: return String(localized: "more.route.test", defaultValue: "Self-Test")
        case .bench: return String(localized: "more.route.bench", defaultValue: "Benchmark")
        case .fs: return String(localized: "more.route.fs", defaultValue: "FS Integrity")
        }
    }
}
