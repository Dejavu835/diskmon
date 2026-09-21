import SwiftUI

/// 顶栏 tab 标识 v0.4.0 polish-D(macOS 控制中心风格)
/// v0.6.0 polish-A:修 tab click bug — `simultaneousGesture(LongPressGesture)` 跟 Button action
/// 抢手势,改成 `PressedButtonStyle` 注入 0.97 scale
/// v0.8 polish-L:加 2 个 tab — `.link`(TB4/USB4 协商 link)+ `.test`(SMART self-test 闭环)
///   主人审美 + macOS 控制中心惯例:5-7 个 tab 可接受(原生 macOS 13+ Mail 有 7+ tab)
///   7 tab 在 popover 720 宽度下:`logo + 7 tab + time` 等宽仍可放下(~80px/tab)
/// v0.8 polish-M:再加 2 个 tab — `.bench`(custom Swift POSIX I/O 测速)+ `.fs`(diskutil verifyVolume)
///   9 tab 在 popover 720 宽度下:`logo + 9 tab + time` 仍可放(~60px/tab,更紧凑),
///   主人审美可接受(原生 Mail 8+ tab 不觉多,系统设置 10+ tab 一样日常)
/// v0.9.1 polish-O1:9 tab 在 720pt 容器内挤到 ~60px/tab,
///   文字截断("Lin"/"Tes"/"Ben"/"FS"),违背主人审美"克制 + 高级"。
///   macOS 控制中心原版 5-7 tab 范围更稳;改成 5 main tab + 1 `...` 按钮触发 MoreSheet。
///   4 secondary 模块(Link / Test / Bench / FS)改放 MoreSheet 内 LazyVGrid 2 列入口卡。
///   5 main tab 文字 14pt(v0.8 polish-M 是 11pt,确实太小,polish-O1 顺便放大到 14pt,
///   5 tab + 1 ellipsis 算下来 720 容器内 ~90pt/tab 充裕,文字不截断)。
///
/// enum 现在 5 main + 1 `.more`(状态用,不在 tab strip 渲染):
/// - overview: 6 模块网格
/// - temperature: 温度卡 + 24h 折线
/// - capacity: 容量卡 + 已用列表
/// - power: 功耗卡 + 24h 折线
/// - smart: SMART 卡 + 全字段
/// - more: PopoverView 弹 MoreSheet,内含 4 入口卡(link / test / bench / fs 的入口)
///
/// === 设计选择 ===
/// - `Hashable` + `Identifiable`:方便 `ForEach` + `Binding` 切换
/// - 不在 `CaseIterable`:`.more` 不应被默认遍历(不是主 tab)
/// - `String` rawValue:可持久化(留接口,polish-D 不写磁盘)
/// - `mainTabs` 静态属性:5 main case 顺序固定,topBar UI 用它渲染
/// - 每个 main case 自带 `title` / `sfSymbol`:统一渲染入口
/// - `.more` 仅作状态标记,不在 tab strip 渲染;点 `...` 按钮设置 currentTab = .more
enum TopBarTab: String, Hashable, Identifiable {
    case overview, temperature, capacity, manage, power, smart
    case more

    var id: String { rawValue }

    /// Main tabs for the capsule. ViewThatFits drops titles if this row is tight.
    static let mainTabs: [TopBarTab] = [
        .overview, .temperature, .capacity, .manage, .power, .smart
    ]

    func title(language: String) -> String {
        switch self {
        case .overview:
            return L10n.t("topbar.tab.overview", zh: "总览", en: "Overview", language: language)
        case .temperature:
            return L10n.t("topbar.tab.temperature", zh: "温度", en: "Temp", language: language)
        case .capacity:
            return L10n.t("topbar.tab.capacity", zh: "容量", en: "Capacity", language: language)
        case .manage:
            return L10n.t("topbar.tab.manage", zh: "管理", en: "Disks", language: language)
        case .power:
            return L10n.t("topbar.tab.power", zh: "功耗", en: "Power", language: language)
        case .smart:
            return L10n.t("topbar.tab.smart", zh: "SMART", en: "SMART", language: language)
        case .more:
            return L10n.t("topbar.tab.more", zh: "更多", en: "More", language: language)
        }
    }

    /// SF Symbol 图标(任务硬规则:不用 emoji)
    var sfSymbol: String {
        switch self {
        case .overview:    return "rectangle.grid.2x2"
        case .temperature: return "thermometer.medium"
        case .capacity:    return "internaldrive"
        case .manage:      return "wrench.and.screwdriver"
        case .power:       return "bolt"
        case .smart:       return "list.bullet.rectangle"
        case .more:        return "ellipsis"
        }
    }

    /// 液态玻璃弹簧：选中胶囊滑动 + tab 内容衔接
    static let transition: Animation = DiskMonMotion.tab
}

// MARK: - TopBar View

/// macOS 控制中心 顶栏 tab 切换 v0.4.0 polish-D
///
/// 严格按任务规范:
/// - 40-48px 高玻璃条,占满宽度
/// - 左侧:`logo` "diskmon" Fraunces 14pt
/// - 中间:5 个玻璃 tab 按钮(等宽分布)
/// - 右侧:`time` SF Mono HH:mm
/// - 选中 tab 琥珀高光 + 1px 底 border 琥珀
/// - 35mm 噪点 + 顶边高光 LinearGradient(0.08 → clear)
/// - 切换动画 0.3s `Animation.timingCurve(0.2, 0.8, 0.2, 1)`(淡入淡出)
///
/// === 设计选择 ===
/// - **不引入绿**(主人审美):选中态用 `Color.dsNormal`(琥珀 #D97706)
/// - **不 loop 动画 / 不弹跳**:0.3s 一次性淡入淡出
/// - **不 mock 数据**:时间由 `TimelineView(.periodic)` 真驱动,每秒刷
struct TopBar: View {
    @Binding var currentTab: TopBarTab

    /// logo 标题(默认 "diskmon",可由 PopoverView 注入)
    var logoTitle: String = String(
        localized: "app.name", defaultValue: "diskmon"
    )

    /// v0.9.1 polish-O2:左侧 leading accessory 槽(放在 logo 右边 / tabStrip 之前)
    /// - 解决 v0.9.0 polish-N1 旧问题:DiskPickerView 130 行零引用,Popover 没切盘 UI
    ///   (主人切盘要开 detail window),现在注入到顶栏 logo 右边
    /// - 缺省 nil,PopoverView 注入 DiskPickerView(无盘时不注入)
    /// v0.9.1 build fix:声明顺序放到 trailingAccessory 之前 — PopoverView 按
    ///   "leading → trailing" 自然顺序传参,SwiftUI 调用约定要求 leading 在前
    var leadingAccessory: (() -> AnyView)? = nil

    /// v0.6.1 polish-H:右侧 trailing accessory 槽(放在 time 左边)
    /// - 缺省 nil,PopoverView 在 EditMode 时注入 Edit 按钮
    /// - 不用 @ViewBuilder(stored property 不支持 result builder,PopoverView 在闭包里包 AnyView)
    var trailingAccessory: (() -> AnyView)? = nil

    /// 当前选中的 tab(外部驱动,主要给 View 测试 / 调试用)
    /// v0.9.1 polish-O1:从 `TopBarTab.allCases` 改成 `mainTabs` —
    ///   9 tab 太挤,只渲染 5 main + 1 `...` 按钮触发 MoreSheet
    private let tabs = TopBarTab.mainTabs

    @Namespace private var tabNS

    var body: some View {
        VStack(spacing: 8) {
            identityRow
            chromeCapsule
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Top Bar")
    }

    // MARK: - Identity row（logo 永不截断，不跟 tab 抢宽度）

    private var identityRow: some View {
        HStack(spacing: 10) {
            logo
                .layoutPriority(2)
            Spacer(minLength: 8)
            if let trailingAccessory {
                trailingAccessory()
                    .fixedSize()
            }
            time
                .fixedSize()
        }
        .padding(.horizontal, 4)
        .frame(minHeight: 28)
    }

    // MARK: - Logo

    private var logo: some View {
        HStack(spacing: 7) {
            Image(systemName: "circle.hexagongrid.fill")
                .font(.system(size: 15, weight: .regular))
                .foregroundStyle(Color.dsNormal)
                .symbolRenderingMode(.hierarchical)
            Text(logoTitle)
                .font(.fraunces(size: 16, weight: .regular, italic: true))
                .foregroundStyle(Color.themeFgDark)
                .fixedSize()
        }
    }

    // MARK: - Liquid glass capsule（tab + 切盘）

    private var chromeCapsule: some View {
        HStack(spacing: 6) {
            tabStrip
            if let leadingAccessory {
                leadingAccessory()
                    .layoutPriority(1)
            }
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 4)
        .background {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(.regularMaterial)
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(
                        LinearGradient(
                            stops: [
                                .init(color: Color.white.opacity(0.10), location: 0),
                                .init(color: .clear, location: 0.55)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .blendMode(.overlay)
                    .allowsHitTesting(false)
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.white.opacity(0.10), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    // MARK: - Tab Strip

    /// 优先图标+文字；这一行放不下时 ViewThatFits 落到纯图标。
    /// 不用 GeometryReader：它会把宽度估小，明明有空位却只画图标。
    private var tabStrip: some View {
        ViewThatFits(in: .horizontal) {
            tabButtons(showsTitle: true, pillID: "tab-pill-labeled")
            tabButtons(showsTitle: false, pillID: "tab-pill-icon")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func tabButtons(showsTitle: Bool, pillID: String) -> some View {
        HStack(spacing: 2) {
            ForEach(tabs) { tab in
                TopBarTabButton(
                    tab: tab,
                    isSelected: currentTab == tab,
                    showsTitle: showsTitle,
                    namespace: tabNS,
                    pillID: pillID
                ) {
                    withAnimation(TopBarTab.transition) {
                        currentTab = tab
                    }
                }
            }
            moreButton(pillID: pillID)
        }
        .animation(TopBarTab.transition, value: currentTab)
    }

    private func moreButton(pillID: String) -> some View {
        let isSelected = (currentTab == .more)
        return Button {
            withAnimation(TopBarTab.transition) {
                currentTab = .more
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(isSelected ? Color.dsNormal : Color.secondary)
                .frame(width: 28, height: 26)
                .background {
                    if isSelected {
                        Capsule(style: .continuous)
                            .fill(Color.themeFgDark.opacity(0.10))
                            .overlay(
                                Capsule(style: .continuous)
                                    .stroke(Color.dsNormal.opacity(0.28), lineWidth: 1)
                            )
                            .matchedGeometryEffect(id: pillID, in: tabNS)
                    }
                }
        }
        .buttonStyle(PressedButtonStyle())
        .contentShape(Rectangle())
        .help(String(
            localized: "topbar.tab.more.help",
            defaultValue: "More tools"
        ))
        .accessibilityLabel(String(
            localized: "topbar.tab.more",
            defaultValue: "More"
        ))
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    }

    // MARK: - Time(右侧,SF Mono HH:mm)

    private var time: some View {
        // TimelineView(.periodic) 每秒刷,不用 Timer
        TimelineView(.periodic(from: .now, by: 1)) { context in
            Text(timeString(for: context.date))
                .font(.system(size: 12, weight: .regular, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .padding(.trailing, 6)
        }
    }

    /// 格式化 HH:mm(本地时区)— 缓存 formatter，避免每秒新建
    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    private func timeString(for date: Date) -> String {
        Self.timeFormatter.string(from: date)
    }
}

// MARK: - TopBar Tab Button(单 tab 按钮)

/// v0.6.0 polish-A:按下态走 `ButtonStyle`(原 `simultaneousGesture(LongPressGesture(minimumDuration: 0))`
/// 跟 `.plain` Button 的 onTap 抢手势,导致 onTap 不触发 — grok 调研确认)
/// - 删 simultaneousGesture,改用 `PressedButtonStyle` 注入 0.97 scale 反馈
/// - onTap 现在走 SwiftUI 14+ 原生 Button action,稳定触发
private struct PressedButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .animation(.easeInOut(duration: 0.15), value: configuration.isPressed)
    }
}

/// 玻璃 tab 按钮(任务硬规则:选中琥珀高光 + 1px 底 border 琥珀)
private struct TopBarTabButton: View {
    let tab: TopBarTab
    let isSelected: Bool
    var showsTitle: Bool = true
    let namespace: Namespace.ID
    var pillID: String = "tab-selection"
    let onTap: () -> Void

    @Environment(AppSettings.self) private var settings

    @State private var isHovered: Bool = false

    private var titleText: String { tab.title(language: settings.language) }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 5) {
                Image(systemName: tab.sfSymbol)
                    .font(.system(size: 12, weight: .regular))
                if showsTitle {
                    Text(titleText)
                        .font(.system(size: 12.5, weight: isSelected ? .semibold : .medium))
                        .lineLimit(1)
                }
            }
            .foregroundStyle(textColor)
            .padding(.horizontal, showsTitle ? 10 : 8)
            .padding(.vertical, 6)
            .background {
                ZStack {
                    if isHovered && !isSelected {
                        Capsule(style: .continuous)
                            .fill(Color.white.opacity(0.06))
                    }
                    if isSelected {
                        Capsule(style: .continuous)
                            .fill(Color.themeFgDark.opacity(0.10))
                            .overlay(
                                Capsule(style: .continuous)
                                    .stroke(Color.dsNormal.opacity(0.28), lineWidth: 1)
                            )
                            .matchedGeometryEffect(id: pillID, in: namespace)
                    }
                }
            }
        }
        .buttonStyle(PressedButtonStyle())
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(DiskMonMotion.hover) {
                isHovered = hovering
            }
        }
        .accessibilityLabel(titleText)
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
        .help(titleText)
    }

    private var textColor: Color {
        if isSelected { return Color.dsNormal }
        if isHovered { return Color.themeFgDark }
        return .secondary
    }
}

// MARK: - TopBar ViewModifier(任务规范 #2)

/// TopBar ViewModifier(任务规范:`TopBar(currentTab: Binding<Tab>, tabs: [Tab], onClose: () -> Void)`)
/// - 当前 PopoverView 不用 onClose(关 popover 由 NSPopover 自己管),但保留 modifier 接口方便后续扩展
struct TopBarModifier: ViewModifier {
    @Binding var currentTab: TopBarTab
    let tabs: [TopBarTab]
    let onClose: () -> Void

    func body(content: Content) -> some View {
        // polish-D 实现:onClose 暂未启用(NSPopover 关闭是系统行为,不是 SwiftUI onTap),
        // 但 modifier 接口按任务规范留好,后续可在 window 模式下用
        content
            .safeAreaInset(edge: .top, spacing: 0) {
                TopBar(currentTab: $currentTab)
                    .padding(.horizontal, 14)
                    .padding(.top, 12)
                    .padding(.bottom, 10)
            }
            .onAppear {
                // 触发 onClose 引用,避免 unused warning(API 留扩展)
                _ = onClose
            }
    }
}

extension View {
    /// 应用 macOS 控制中心 顶栏 tab 切换(polish-D)
    /// - Parameters:
    ///   - currentTab: 当前选中的 tab(双向绑定)
    ///   - tabs: tab 列表(默认 `TopBarTab.mainTabs` — v0.9.1 polish-O1 不再走
    ///     `allCases`,因为 .more 是状态用,不应被遍历)
    ///   - onClose: 顶栏 close 回调(留接口,当前未启用)
    func topBar(
        currentTab: Binding<TopBarTab>,
        tabs: [TopBarTab] = TopBarTab.mainTabs,
        onClose: @escaping () -> Void = {}
    ) -> some View {
        modifier(TopBarModifier(
            currentTab: currentTab,
            tabs: tabs,
            onClose: onClose
        ))
    }
}
