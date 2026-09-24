import SwiftUI
import SwiftData
import Charts  // v0.9.3:BenchmarkWidget live chart(LineMark / AreaMark)
import AppKit  // v0.9.1 polish-Q:NSWorkspace.shared.open for FDA Settings deep link
import DiskMonCore

/// 磁盘详情深看页 v0.9 polish-N1
/// 主人 v0.9 反馈"详情界面太大" → 整体改造为 macOS Tahoe Control Center 风格
///
/// v0.9.4:widget 布局改用 `Grid` + `GridRow`(grok 1 调研)+ cell 锁 size
///   - 不用 LazyVGrid / 不用 HStack+VStack 嵌套,改 SwiftUI 14+ `Grid` API
///   - 每个 widget 加 `.clipped() + .contentShape(Rectangle())` 防止 hit-test 溢出
///   - parent widgetGrid 加 `.fixedSize(horizontal: false, vertical: true)` 让 height
///     报 ideal,容器不会被子 widget 的 maxHeight: .infinity 撑成 0
///   - 删 inner GeometryReader 报 0 高的死循环
///
/// === 设计参考(基于 grok 调研) ===
/// - macOS Tahoe CC:
///   - Edit Controls 按钮 + Done
///   - **不用 jiggle** animation
///   - Resize via Control-click menu: Small / Medium / Large(1 / 2 / 4 slots)
/// - iOS 18 CC(参考交互):
///   - + 按钮添加 + − 删除
///   - 右下 drag handle,8×4 grid snap resize
///   - Add a Control sheet(searchable + categorized)
/// - 主人审美"克制":pick 1 个简单交互 = Resize segmented control(3 选 1,1×1 / 2×1 / 2×2)
///   **不用** jiggle / 不用 drag handle / 不用 long-press / 不用 Edit/Done toggle
///   → 主人硬规则:不引入未在 spec 出现的交互
///
/// === 布局(720x580 窗口) ===
/// ```
/// ┌──────────────────────────────────────────────────────────┐
/// │  DiskDetail (Fraunces 14pt)              [xmark 琥珀]   │  36pt 顶栏
/// ├────────────┬─────────────────────────────────────────────┤
/// │            │  Resize: [1×1] [2×1] [2×2]  Fraunces 13pt   │  32pt resize
/// │  Sidebar   ├─────────────────────────────────────────────┤
/// │  220pt     │  Widget Grid(嵌套 HStack/VStack):           │
/// │            │                                              │
/// │  WATCHED   │  ┌──────────┬──────────────────┐             │
/// │  DISKS 3   │  │  HERO    │  Temperature 2x1 │             │
/// │  ───       │  │  2x2     ├──────────────────┤             │
/// │  disk1 ◉  │  │  244x280 │  Power      2x1  │             │
/// │  disk2 ◯  │  ├──────────┼────────┬─────────┤             │
/// │  disk3 ◯  │  │  SMART   │ Health │  Link   │             │
/// │            │  │  2x2     ├────────┼─────────┤             │
/// │            │  │  244x280 │ SelfT. │ Bench   │             │
/// │            │  ├──────────┴────────┴─────────┤             │
/// │            │  │  FSIntegrity 1x1 (244 wide)  │             │
/// │            │  └──────────────────────────────┘             │
/// └────────────┴─────────────────────────────────────────────┘
/// ```
///
/// === 颜色 / 字体 / 玻璃(沿用 v0.8.0 规范) ===
/// - 玻璃黑 + 琥珀 `#C8956C` + 米白 `#F5F2EC` + 红 `#C84A4A` + 蓝 `#6C95C8`(读)+ 绿 `#6CC895`(写)
/// - Fraunces(衬线,标题 + 大数字 18-44pt)+ -apple-system 正文 + SF Mono 数字
/// - 标签 11px uppercase letter-spacing 0.06-0.08em
/// - 玻璃:`.glass(cornerRadius: 20)` / `.glassChrome(cornerRadius: 0)`
/// - 35mm 噪点由根 `NoiseOverlay()` 覆盖
///
/// === 高级交互规范(主人硬要求) ===
/// - 数字滚动:`.contentTransition(.numericText())` + 0.3s easeInOut
/// - hover 玻璃卡:0.3s `cubic-bezier(0.2, 0.8, 0.2, 1)`
/// - 焦点环:琥珀 2px(`focusable() + focusEffectDisabled() + @FocusState` + 自绘)
/// - 按下态:下沉 1px + scale 0.99(`LongPressGesture(minimumDuration: 0)`)
/// - 侧栏磁盘项 hover:琥珀胶囊光带(polish-H 已实现)
/// - 不 loop 动画(任务硬规则)
/// - 不弹跳 / 不夸张
/// - nil 数据优雅显 "—"(Fraunces italic 24-28pt)
/// - 加载中:`ProgressView` 琥珀
///
/// === 数据接入 ===
/// - `HealthMonitor`:`Environment(HealthMonitor.self)`,读 `monitor.watchedDisks` /
///   `monitor.currentByUUID[uuid]`
/// - `AppSettings`:`Environment(AppSettings.self)`,读 `settings.temperatureUnit` / 阈值
/// - `PowerService`:`Environment(PowerService.self)`,Power widget 读
/// - `HealthPredictor.shared`:`Environment(HealthPredictor.self)`,Health widget 读
/// - `LinkHealthService`:`Environment(LinkHealthService.self)`,Link widget 读
/// - `DiagnosticTestService`:`Environment(DiagnosticTestService.self)`,SelfTest widget 读
/// - `BenchmarkService`:`Environment(BenchmarkService.self)`,Benchmark widget 读
/// - `FSIntegrityService`:`Environment(FSIntegrityService.self)`,FSIntegrity widget 读
/// - 选中盘:`@State selectedUUID` 默认 first
/// - SMART 历史:SwiftData `@Query`(`SmartSnapshot` granularity = minute 映射) — 由各 widget 按需 fetch
///
/// === 严禁 ===
/// - 不 mock 数据(失败 nil + "—")
/// - 不 emoji(用 SF Symbols)
/// - 不 loop 动画
/// - 不动 `GlassBackground.swift` / 5 Preferences 子 View / `AppSettings` /
///   `Localizable.strings`(任务硬规则)
/// - 不改 5 Preferences 子 View
/// - 不写 /Volumes/applelog/diskmon/ 之外
struct DiskDetailView: View {
    @Environment(HealthMonitor.self) private var monitor
    @Environment(AppSettings.self) private var settings
    @Environment(PowerService.self) private var power
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    // 选中盘 UUID(默认 first)
    @State private var selectedUUID: String? = nil
    // 侧栏 disk hover
    @State private var hoveredDiskUUID: String? = nil
    // v0.9 polish-N1:widget 密度(1×1 / 2×1 / 2×2)— 默认 2×1 平衡
    @State private var density: WidgetDensity = .medium

    /// v0.9.3 minimax-C:What's New sheet 显示状态
    /// - 触发:onAppear 调 `OnboardingStore.shouldShowWhatsNew` →
    ///   major.minor version 跟 stored 不一致时显一次
    /// - 关闭:点 OK / Esc → 写回当前 major.minor(下次启动同版本不重显)
    @State private var showWhatsNew: Bool = false

    /// v0.9.3 minimax-C:跟 PopoverView 共享同一 @AppStorage key
    /// - 已有 = true(走完 Popover 5 步或主动 skip) → What's New 可显
    /// - 已有 = false(首次启动) → What's New 不显,先让 5 步 onboarding 走完
    @AppStorage(OnboardingStore.hasCompletedKey) private var hasOnboarded: Bool = false

    /// v0.9.3 minimax-C:What's New 触发的"上次 major.minor"
    /// - 空字符串 = 首次启动,不显 What's New(让 5 步 onboarding 优先)
    /// - 非空 + 跟当前 major.minor 不一致 = 显一次
    @AppStorage(OnboardingStore.lastKnownVersionKey) private var lastKnownVersion: String = ""

    // MARK: - body

    var body: some View {
        ZStack {
            // 背景:35mm 噪点
            NoiseOverlay()
                .accessibilityHidden(true)
            // v0.9 polish-N1:NavigationSplitView,sidebar 220pt(可拖 200..320)
            // + detail column 装 widget 网格
            NavigationSplitView(columnVisibility: .constant(.all)) {
                sidebarColumn
                    .navigationSplitViewColumnWidth(
                        min: 220, ideal: 260, max: 360
                    )
            } detail: {
                detailColumn
            }
            .navigationSplitViewStyle(.balanced)
        }
        // v0.9.4:删 minWidth/640 minHeight/520 锁死,改 DiskMonApp WindowGroup 的
        // `.windowResizability(.contentMinSize)` + flexible frame 控制
        // (主人 bug:"窗口不能调整大小 + 内容不自适应")
        // - 旧版 minWidth: 640 锁死,改用 .contentMinSize 让内容真正主导
        // - 内部 NavigationSplitView 自带 column min 200..320 ideal 220 max 320,
        //   已足够灵活,不再需要外层 frame 锁死
        .frame(minWidth: 360, idealWidth: 720, maxWidth: .infinity,
               minHeight: 360, idealHeight: 580, maxHeight: .infinity)
        .background(
            ResizableWindowConfigurator(minSize: CGSize(width: 360, height: 360))
        )
        .glassChromeUniform(cornerRadius: 0)
        .onAppear {
            if selectedUUID == nil {
                selectedUUID = monitor.selectedDiskUUID ?? monitor.watchedDisks.first?.volumeUUID
            }
            // v0.9.3 minimax-C:What's New 触发检查
            if !showWhatsNew,
               OnboardingStore.shouldShowWhatsNew(hasCompletedOnboarding: hasOnboarded) {
                showWhatsNew = true
            }
        }
        .onChange(of: monitor.selectedDiskUUID) { _, new in
            if let new, new != selectedUUID { selectedUUID = new }
        }
        .onChange(of: selectedUUID) { _, new in
            if let new, monitor.selectedDiskUUID != new {
                monitor.selectedDiskUUID = new
            }
        }
        .onChange(of: monitor.watchedDisks.map(\.volumeUUID)) { _, ids in
            if selectedUUID == nil || !(ids.contains(selectedUUID ?? "")) {
                selectedUUID = monitor.selectedDiskUUID ?? ids.first
            }
        }
        // v0.9.3 minimax-C:What's New sheet(简短 changelog)
        // - 玻璃背景 + 大标题 + bullet list + 右下 "Got it" 按钮
        // - dismiss 走 SwiftUI .sheet 机制,关闭时 onClose 回调记当前 major.minor
        .sheet(isPresented: $showWhatsNew) {
            WhatsNewSheet(onClose: { showWhatsNew = false })
        }
    }

    // MARK: - 顶栏(36pt:logo + close)

    private var topBar: some View {
        HStack(alignment: .center, spacing: 0) {
            // v0.9 polish-N1:logo "DiskDetail" Fraunces 14pt italic(精简版,跟 Popover TopBar 一致)
            Text(String(localized: "detail.title", defaultValue: "DiskDetail"))
                .font(.fraunces(size: 14, weight: .regular, italic: true))
                .foregroundStyle(Color.themeFgDark)
            Spacer()
            // v0.9 polish-N1:右上关闭按钮(SF Symbol xmark.circle.fill 琥珀 22pt)
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(Color.dsNormal.opacity(0.7))
            }
            .buttonStyle(.plain)
            .help(String(localized: "ui.close", defaultValue: "Close"))
            .onHover { hovering in
                if hovering {
                    NSCursor.pointingHand.push()
                } else {
                    NSCursor.pop()
                }
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 36)
        // v0.9.1 polish-P2:顶栏走真液态玻璃(替换 .regularMaterial,跟主体 .glass() 一致)
        .glassChromeUniform(cornerRadius: 12)
    }

    // MARK: - 左栏 sidebar(220pt · 磁盘列表 3 项)

    private var sidebarColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            // sidebar 标题
            sidebarHeader
            Divider()
                .background(Color.white.opacity(0.04))
            // 列表(v0.9 polish-N1:删 polish-D 4 tab,只留磁盘列表,跟 macOS CC 风格一致)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    if monitor.watchedDisks.isEmpty {
                        sidebarEmpty
                    } else {
                        ForEach(monitor.watchedDisks) { disk in
                            sidebarRow(disk)
                        }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 10)
            }
            Spacer(minLength: 0)
        }
        .glassChrome(cornerRadius: 0)
    }

    private var sidebarHeader: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(String(localized: "disk.watched", defaultValue: "WATCHED DISKS"))
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .tracking(0.8)
                .foregroundStyle(.secondary)
            Spacer()
            Text("\(monitor.watchedDisks.count)")
                .font(.system(size: 14, weight: .light, design: .rounded))
                .foregroundStyle(.tertiary)
                .monospacedDigit()
                .contentTransition(.numericText(value: Double(monitor.watchedDisks.count)))
        }
        .padding(.horizontal, 14)
        .padding(.top, 14)
        .padding(.bottom, 10)
    }

    private var sidebarEmpty: some View {
        HStack(spacing: 10) {
            Image(systemName: "externaldrive.badge.questionmark")
                .font(.system(size: 16))
                .foregroundStyle(.secondary)
            Text(String(localized: "disk.empty", defaultValue: "No external disks"))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .padding(10)
    }

    /// 侧栏磁盘项:身份芯片 + 平均读写 + 故障红标
    private func sidebarRow(_ disk: DiskInfo) -> some View {
        let isSelected = (selectedUUID ?? "") == disk.volumeUUID
        let isHovered = (hoveredDiskUUID ?? "") == disk.volumeUUID
        let smart = monitor.currentByUUID[disk.volumeUUID]
        let level = monitor.level(for: disk.volumeUUID)
        let levelColor = level.color
        let trouble = settings.diskMarks.mark(for: disk.volumeUUID) == .trouble
        let window = IOWindow(rawValue: settings.ioMeanWindowRaw) ?? .h24
        let mean = monitor.ioMean(for: disk.volumeUUID, window: window)
        let chips = disk.identityChips
        return Button {
            withAnimation(.easeInOut(duration: 0.3)) {
                selectedUUID = disk.volumeUUID
            }
        } label: {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: disk.isInternal ? "internaldrive" : "externaldrive")
                    .font(.system(size: 14, weight: .regular))
                    .foregroundStyle(isSelected ? Color.dsNormal : .secondary)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(disk.displayName)
                            .font(.fraunces(size: 14, weight: .regular, italic: true))
                            .foregroundStyle(isSelected ? Color.dsNormal : Color.themeFgDark)
                            .lineLimit(1)
                        if trouble {
                            Image(systemName: "exclamationmark.circle.fill")
                                .font(.system(size: 10))
                                .foregroundStyle(Color.dsDanger)
                        }
                    }
                    HStack(spacing: 6) {
                        Text(ByteFormatter.bytes(disk.sizeBytes))
                            .font(.system(size: 11, weight: .regular, design: .monospaced))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                        let speed = disk.interfaceSpeedLabel
                        if speed != "—" {
                            Text("·")
                                .font(.system(size: 11))
                                .foregroundStyle(.tertiary)
                            Text(speed)
                                .font(.system(size: 11, weight: .regular, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        if let s = smart {
                            Text("·")
                                .font(.system(size: 11))
                                .foregroundStyle(.tertiary)
                            Text(s.celsius.map { "\($0)°" } ?? "—")
                                .font(.system(size: 11, weight: .medium, design: .monospaced))
                                .monospacedDigit()
                                .foregroundStyle(levelColor)
                                .contentTransition(.numericText(value: Double(s.celsius ?? 0)))
                        }
                    }
                    if !chips.isEmpty {
                        ChipFlow(spacing: 4) {
                            ForEach(chips, id: \.self) { chip in
                                Text(chip)
                                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1)
                                    .background(Capsule(style: .continuous).fill(Color.white.opacity(0.06)))
                            }
                        }
                    }
                    Text(sidebarIOLine(mean: mean))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Circle()
                    .fill(trouble ? Color.dsDanger : levelColor)
                    .frame(width: 6, height: 6)
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.dsNormal)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(
                        isSelected
                            ? Color.dsNormal.opacity(0.10)
                            : (isHovered ? Color.white.opacity(0.04) : .clear)
                    )
            )
            .overlay(alignment: .leading) {
                // polish-H:Capsule 琥珀光带 24pt 高 + 8px 模糊
                if isSelected {
                    Capsule()
                        .fill(Color.dsNormal)
                        .frame(width: 2, height: 24)
                        .shadow(color: Color.dsNormal.opacity(0.6), radius: 8)
                        .padding(.leading, 2)
                        .frame(maxHeight: .infinity, alignment: .center)
                        .transition(.opacity)
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(
                        isSelected ? Color.dsNormal.opacity(0.35) : .clear,
                        lineWidth: 1
                    )
            )
            .padding(.leading, isHovered && !isSelected ? 4 : 0)
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .contextMenu {
            if trouble {
                Button {
                    settings.setDiskMark(.none, for: disk.volumeUUID)
                } label: {
                    Text(L10n.t("detail.mark.clear", zh: "清除故障标记", en: "Clear trouble mark", language: settings.language))
                }
            } else {
                Button {
                    settings.setDiskMark(.trouble, for: disk.volumeUUID)
                } label: {
                    Text(L10n.t("detail.mark.trouble", zh: "标记为经常出错", en: "Mark as trouble", language: settings.language))
                }
            }
        }
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.2)) {
                hoveredDiskUUID = hovering ? disk.volumeUUID : (
                    hoveredDiskUUID == disk.volumeUUID ? nil : hoveredDiskUUID
                )
            }
        }
    }

    private func sidebarIOLine(mean: (read: Double?, write: Double?)) -> String {
        let r = mean.read.map { IOMean.formatMBps($0) } ?? "—"
        let w = mean.write.map { IOMean.formatMBps($0) } ?? "—"
        return "R \(r) · W \(w) MB/s"
    }

    // MARK: - 右栏 detailColumn(顶栏 + resize handle + widget grid)

    private var detailColumn: some View {
        VStack(spacing: 0) {
            // 顶栏(36pt)
            topBar
            Divider()
                .background(Color.white.opacity(0.04))
            // resize handle(32pt)
            resizeHandle
            Divider()
                .background(Color.white.opacity(0.04))
            // 主区:widget 网格(可滚动)
            ScrollView {
                widgetGrid
                    .padding(14)
            }
        }
    }

    // MARK: - Resize handle(v0.9 polish-N1 · macOS CC 风格)

    /// 顶部 Resize 控件:1×1 / 2×1 / 2×2 3 选 1 segmented control
    /// - Fraunces 13pt italic 标签
    /// - 选中态琥珀高亮 + 底 border
    /// - 切换 → widget 整体密度变化(1×1 compact / 2×1 默认 / 2×2 宽松)
    /// - **不** drag handle / **不** jiggle / **不** long-press(主人硬规则)
    private var resizeHandle: some View {
        HStack(spacing: 8) {
            Text(String(localized: "detail.resize", defaultValue: "Resize"))
                .font(.fraunces(size: 13, weight: .regular, italic: true))
                .foregroundStyle(.secondary)
            // 3 选 1 segmented control(macOS 风格)
            HStack(spacing: 0) {
                ForEach(WidgetDensity.allCases) { d in
                    Button {
                        withAnimation(.timingCurve(0.2, 0.8, 0.2, 1, duration: 0.3)) {
                            density = d
                        }
                    } label: {
                        Text(d.label)
                            .font(.fraunces(size: 12, weight: .regular, italic: true))
                            .foregroundStyle(density == d ? Color.dsNormal : Color.themeFgDark.opacity(0.7))
                            .frame(minWidth: 38, minHeight: 22)
                            .background(
                                RoundedRectangle(cornerRadius: 5, style: .continuous)
                                    .fill(density == d ? Color.dsNormal.opacity(0.15) : .clear)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 5, style: .continuous)
                                    .stroke(
                                        density == d ? Color.dsNormal.opacity(0.5) : Color.white.opacity(0.10),
                                        lineWidth: 1
                                    )
                            )
                    }
                    .buttonStyle(.plain)
                    .help(d.help)
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.white.opacity(0.04))
            )
            Spacer()
        }
        .padding(.horizontal, 14)
        .frame(height: 32)
    }

    // MARK: - Widget grid(9 widgets · Grid + GridRow)

    /// 9 widget 网格布局(v0.9.4 改用 SwiftUI `Grid` + `GridRow`):
    /// - Row 1: [Hero 2x2] [VStack: Temp 2x1, Power 2x1]
    /// - Row 2: [SMART 2x2] [VStack: [HStack: Health 1x1, Link 1x1], [HStack: SelfTest 1x1, Bench 1x1]]
    /// - Row 3: [FSIntegrity 1x1] (左 1 col)
    ///
    /// 关键(grok 1 调研):
    /// - `Grid` + `GridRow` 提供 macOS CC 风格的对齐 + 列宽,代替 HStack/VStack 嵌套
    /// - 每个 widget 套 `.clipped() + .contentShape(Rectangle())` 防止 hit-test 溢出
    ///   到相邻 widget 区域(主人 bug:"DISKS list 跟下面 widget 重叠")
    /// - 容器加 `.fixedSize(horizontal: false, vertical: true)` 让 height 报 ideal,
    ///   容器不会被 maxHeight: .infinity 撑成 0 高
    @ViewBuilder
    private var widgetGrid: some View {
        if let disk = currentDisk {
            let h = density.quadHeight
            let s = density.subRowHeight
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 12) {
                // Row 1:Hero(2x2 col-span)| Temp(2x1) | Power(2x1)
                GridRow {
                    HeroWidget(disk: disk)
                        .frame(maxWidth: .infinity, minHeight: h, alignment: .topLeading)
                        .contentShape(Rectangle())
                    VStack(spacing: 12) {
                        TemperatureWidget(disk: disk)
                            .frame(maxWidth: .infinity, minHeight: s, alignment: .topLeading)
                            .contentShape(Rectangle())
                        PowerWidget(disk: disk)
                            .frame(maxWidth: .infinity, minHeight: s, alignment: .topLeading)
                            .contentShape(Rectangle())
                    }
                    .frame(maxWidth: .infinity, minHeight: h, alignment: .top)
                }
                GridRow {
                    SMARTWidget(disk: disk)
                        .frame(maxWidth: .infinity, minHeight: h, alignment: .topLeading)
                        .contentShape(Rectangle())
                    VStack(spacing: 12) {
                        HStack(spacing: 12) {
                            HealthWidget(disk: disk)
                                .frame(maxWidth: .infinity, minHeight: s, alignment: .topLeading)
                                .contentShape(Rectangle())
                            LinkWidget(disk: disk)
                                .frame(maxWidth: .infinity, minHeight: s, alignment: .topLeading)
                                .contentShape(Rectangle())
                        }
                        HStack(spacing: 12) {
                            SelfTestWidget(disk: disk)
                                .frame(maxWidth: .infinity, minHeight: s, alignment: .topLeading)
                                .contentShape(Rectangle())
                            BenchmarkWidget(disk: disk)
                                .frame(maxWidth: .infinity, minHeight: s, alignment: .topLeading)
                                .contentShape(Rectangle())
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: h, alignment: .top)
                }
                GridRow {
                    FSIntegrityWidget(disk: disk)
                        .frame(maxWidth: .infinity, minHeight: s, alignment: .topLeading)
                        .contentShape(Rectangle())
                    Color.clear
                        .frame(maxWidth: .infinity, minHeight: s)
                }
                GridRow {
                    ManageWidget(disk: disk)
                        .gridCellColumns(2)
                        .frame(maxWidth: .infinity, minHeight: s + 48, alignment: .topLeading)
                        .contentShape(Rectangle())
                }
                GridRow {
                    DropHistoryWidget(disk: disk)
                        .gridCellColumns(2)
                        .frame(maxWidth: .infinity, minHeight: s, alignment: .topLeading)
                        .contentShape(Rectangle())
                }
            }
        } else {
            emptyWidgetGrid
        }
    }

    /// 空态(没 watch 盘)
    private var emptyWidgetGrid: some View {
        VStack(spacing: 12) {
            Image(systemName: "externaldrive.badge.questionmark")
                .font(.system(size: 32, weight: .light))
                .foregroundStyle(.tertiary)
            Text(String(localized: "disk.empty", defaultValue: "No external disks"))
                .font(.fraunces(size: 16, weight: .regular, italic: true))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 200)
        .glassChrome(cornerRadius: 20)
    }

    // MARK: - 选中盘 / SMART

    private var currentDisk: DiskInfo? {
        let uuid = selectedUUID ?? monitor.selectedDisk?.volumeUUID
        return uuid.flatMap { id in
            monitor.watchedDisks.first(where: { $0.volumeUUID == id })
        }
    }

    private var currentSmart: SmartData? {
        if let uuid = selectedUUID, let s = monitor.currentByUUID[uuid] {
            return s
        }
        return monitor.selectedDisk.flatMap { monitor.currentByUUID[$0.volumeUUID] }
    }

    // MARK: - helpers

    private func shortName(_ path: String) -> String {
        if let last = path.split(separator: "/").last {
            return String(last)
        }
        return path
    }
}

// MARK: - WidgetDensity 枚举(v0.9 polish-N1)

/// Widget 密度(v0.9 polish-N1:macOS Tahoe CC 风格 Resize 控件)
/// - compact:rowH=100pt / quad=212pt
/// - medium :rowH=140pt / quad=292pt(默认 2×1 平衡)
/// - large  :rowH=180pt / quad=372pt
/// 720x580 窗口下默认 medium 完美适配:
///   36 top + 32 resize + 12*3 pad = 104 chrome,内容 476pt
///   row1 quad (292) + row2 quad (292) + row3 (140) + 12*2 spacing = 756pt → 滚动
///   (主人审美:可滚动,但默认能看 ~1.5 屏)
enum WidgetDensity: String, CaseIterable, Identifiable {
    case compact, medium, large

    var id: String { rawValue }

    var label: String {
        switch self {
        case .compact: return "1×1"
        case .medium:  return "2×1"
        case .large:   return "2×2"
        }
    }

    var help: String {
        switch self {
        case .compact: return "Compact (1×1)"
        case .medium:  return "Medium (2×1) — default"
        case .large:   return "Large (2×2)"
        }
    }

    /// 1×1 / 2×1 widget 的高度(sub-row,1 个)
    var subRowHeight: CGFloat {
        switch self {
        case .compact: 120
        case .medium:  168
        case .large:   210
        }
    }

    /// 2×2 widget 的高度(= subRowHeight × 2 + 12 spacing)
    var quadHeight: CGFloat {
        subRowHeight * 2 + 12
    }
}

// MARK: - Widget 通用壳(玻璃卡 + padding + 标准边距)

/// Widget 通用壳:玻璃卡背景 + 16pt padding + 14pt 圆角
/// v0.9 polish-N1:macOS CC 风格 widget 卡片,所有 9 widget 统一套这个
private struct WidgetShell<Content: View>: View {
    let content: () -> Content
    let cornerRadius: CGFloat

    init(cornerRadius: CGFloat = 16, @ViewBuilder content: @escaping () -> Content) {
        self.cornerRadius = cornerRadius
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content()
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .glass(cornerRadius: cornerRadius)
    }
}

/// Widget 顶部小标签(SF Symbol + Fraunces 13pt italic 灰)
private struct WidgetHeader: View {
    let systemImage: String
    let title: String
    var color: Color = .secondary

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: systemImage)
                .font(.system(size: 10, weight: .regular))
                .foregroundStyle(color.opacity(0.85))
            Text(title)
                .font(.fraunces(size: 12, weight: .regular, italic: true))
                .foregroundStyle(color)
                .lineLimit(1)
        }
    }
}

// MARK: - Widget 1:Hero 2x2(磁盘名 + 健康度环 + 4 大数字)

/// Hero 2x2 widget
/// - 顶:磁盘名(Fraunces 18pt italic,em 局部琥珀)+ 副标(bsdName · modelName)
/// - 中:健康度环 56×56 + "Health X%" 大字
/// - 下:2×2 数字网格(温度 / 寿命 / 累计通电 / 累计写入)
private struct HeroWidget: View {
    let disk: DiskInfo
    @Environment(HealthMonitor.self) private var monitor
    @Environment(AppSettings.self) private var settings

    private var smart: SmartData? {
        monitor.currentByUUID[disk.volumeUUID]
    }

    private var level: HealthLevel {
        monitor.level(for: disk.volumeUUID)
    }

    private var lifePercentText: String {
        guard let used = smart?.percentageUsed else { return "—" }
        return "\(max(0, 100 - used))"
    }

    var body: some View {
        WidgetShell {
            VStack(alignment: .leading, spacing: 8) {
                // 顶:disk name + em 局部琥珀
                headerDiskNameSplit
                Text(headerSubtitle)
                    .font(.system(size: 10, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)

                // 中:健康度环 + 大字
                HStack(alignment: .center, spacing: 10) {
                    HealthRingView(smart: smart, settings: settings, level: level, size: 56)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(String(localized: "card.health", defaultValue: "Health"))
                            .font(.system(size: 9, weight: .medium, design: .monospaced))
                            .tracking(0.5)
                            .foregroundStyle(.tertiary)
                        Text(lifePercentText == "—" ? "—" : "\(lifePercentText)%")
                            .font(.fraunces(size: 24, weight: .regular, italic: true))
                            .foregroundStyle(level.color)
                            .monospacedDigit()
                            .lineLimit(1)
                        Text(level.rawValue.uppercased())
                            .font(.system(size: 9, weight: .semibold, design: .monospaced))
                            .tracking(0.4)
                            .foregroundStyle(level.color.opacity(0.85))
                    }
                    Spacer(minLength: 0)
                }

                // 下:2×2 stat grid
                statsGrid
            }
        }
    }

    // MARK: Hero 内部

    private var headerDiskName: String {
        if let model = disk.modelName, !model.isEmpty { return model }
        return shortName(disk.mountPoint ?? disk.bsdName)
    }

    private var headerSubtitle: String {
        var parts: [String] = [disk.bsdName]
        if let m = disk.mountPoint { parts.append(m) }
        return parts.joined(separator: "  ·  ")
    }

    private var headerDiskNameParts: (prefix: String, em: String, suffix: String) {
        let raw = headerDiskName
        let tokens = raw.split(separator: " ", omittingEmptySubsequences: false)
        var emRange: Range<Int>? = nil
        for (i, tok) in tokens.enumerated() {
            let s = String(tok)
            let hasLetter = s.contains(where: { $0.isLetter })
            let hasDigit  = s.contains(where: { $0.isNumber })
            if hasLetter && hasDigit {
                emRange = i..<(i + 1)
                break
            }
        }
        guard let r = emRange else { return (raw, "", "") }
        let prefix = tokens[..<r.lowerBound].joined(separator: " ")
        let em     = tokens[r].map { String($0) }.joined()
        let suffix = tokens[r.upperBound...].joined(separator: " ")
        let prefixFinal = prefix.isEmpty ? "" : (prefix + " ")
        let suffixFinal = suffix.isEmpty ? "" : (" " + suffix)
        return (prefixFinal, em, suffixFinal)
    }

    @ViewBuilder
    private var headerDiskNameSplit: some View {
        let parts = headerDiskNameParts
        if parts.em.isEmpty {
            Text(parts.prefix.isEmpty ? headerDiskName : parts.prefix)
                .font(.fraunces(size: 18, weight: .regular, italic: true))
                .foregroundStyle(Color.themeFgDark)
                .lineLimit(1)
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                Text(parts.prefix)
                    .font(.fraunces(size: 18, weight: .regular, italic: false))
                    .foregroundStyle(Color.themeFgDark)
                Text(parts.em)
                    .font(.fraunces(size: 18, weight: .regular, italic: true))
                    .foregroundStyle(Color.dsNormal)
                Text(parts.suffix)
                    .font(.fraunces(size: 18, weight: .regular, italic: false))
                    .foregroundStyle(Color.themeFgDark)
            }
            .lineLimit(1)
        }
    }

    /// 2×2 stat grid:温度 / 寿命 / 累计通电 / 累计写入
    private var statsGrid: some View {
        let s = smart
        return VStack(spacing: 6) {
            HStack(spacing: 6) {
                heroStat(
                    label: String(localized: "card.temperature", defaultValue: "Temperature"),
                    // v0.9.1 polish-P2:nil/0 → "—",走统一规则
                    value: {
                        guard let s = s, let c = s.celsius, c > 0 else { return "—" }
                        return String(format: "%.0f", settings.displayTemperature(celsius: Double(c)))
                    }(),
                    unit: settings.temperatureUnitSymbol,
                    color: monitor.level(for: disk.volumeUUID).color,
                    systemImage: "thermometer.medium"
                )
                heroStat(
                    label: String(localized: "card.lifetime", defaultValue: "Lifetime"),
                    value: {
                        guard let used = s?.percentageUsed else { return "—" }
                        return "\(max(0, 100 - used))"
                    }(),
                    unit: "%",
                    color: {
                        guard let used = s?.percentageUsed else { return Color.secondary }
                        if used >= 90 { return Color.dsCritical }
                        if used >= 70 { return Color.dsWarning }
                        return Color.themeFgDark
                    }(),
                    systemImage: "leaf"
                )
            }
            HStack(spacing: 6) {
                heroStat(
                    label: String(localized: "smart.powerOnHours", defaultValue: "Power On"),
                    value: s.map { "\(($0.powerOnHours ?? 0) / 24)" } ?? "—",
                    unit: String(localized: "unit.days", defaultValue: "days"),
                    color: Color.themeFgDark,
                    systemImage: "powerplug"
                )
                heroStat(
                    label: String(localized: "smart.dataWritten", defaultValue: "Written"),
                    value: s.map { String(format: "%.1f", $0.dataUnitsWrittenTB ?? 0) } ?? "—",
                    unit: "TB",
                    color: Color.themeFgDark,
                    systemImage: "arrow.up.to.line"
                )
            }
        }
    }

    /// 单个 stat cell
    private func heroStat(
        label: String,
        value: String,
        unit: String,
        color: Color,
        systemImage: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 3) {
                Image(systemName: systemImage)
                    .font(.system(size: 9, weight: .regular))
                    .foregroundStyle(.tertiary)
                Text(label.uppercased())
                    .font(.system(size: 9, weight: .medium, design: .default))
                    .tracking(0.5)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value)
                    .font(.fraunces(size: 18, weight: .regular, italic: false))
                    .foregroundStyle(Color.themeFgDark)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .contentTransition(.numericText())
                    .animation(.easeInOut(duration: 0.3), value: value)
                Text(unit)
                    .font(.fraunces(size: 11, weight: .regular, italic: true))
                    .foregroundStyle(color)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.white.opacity(0.06), lineWidth: 1)
        )
    }

    private func shortName(_ path: String) -> String {
        if let last = path.split(separator: "/").last { return String(last) }
        return path
    }
}

// MARK: - Widget 2:Temperature 2x1(温度折线 + 阈值 RuleMark)

/// Temperature 2x1 widget
/// - 顶:标签 + 当前温度大数字(Fraunces 32pt italic)
/// - 中:24h sparkline(琥珀色,含 0.5 透明 area fill)
/// - 底:副标(盘名 + 趋势)— sparkline 下方
private struct TemperatureWidget: View {
    let disk: DiskInfo
    @Environment(HealthMonitor.self) private var monitor
    @Environment(AppSettings.self) private var settings
    @Environment(\.modelContext) private var modelContext

    @State private var sparklineValues: [Double] = []

    private var smart: SmartData? {
        monitor.currentByUUID[disk.volumeUUID]
    }

    private var celsius: Double {
        Double(smart?.celsius ?? 0)
    }

    private var level: HealthLevel {
        monitor.level(for: disk.volumeUUID)
    }

    private var tempColor: Color {
        if celsius >= Double(settings.criticalTempCelsius) { return Color.dsCritical }
        if celsius >= Double(settings.warningTempCelsius)  { return Color.dsWarning }
        return Color.dsNormal
    }

    private var tempText: String {
        // v0.9.1 polish-P2:走 SmartDataFormatter.celsius(nil/0 → "—",跟 SMARTModule 统一)
        // 注意:tempText 单位是用户偏好的 °C/°F(走 settings.displayTemperature),
        // 不用 .celsius() 的 "X°C" 后缀(自带 °C)
        guard let s = smart, (s.celsius ?? 0) > 0 else { return "—" }
        return String(format: "%.0f", settings.displayTemperature(celsius: celsius))
    }

    private var tempUnit: String { settings.temperatureUnitSymbol }

    private var subtitleText: String {
        let name = shortName(disk.mountPoint ?? disk.bsdName)
        return "\(name)  ·  \(celsius == 0 ? "—" : String(format: "%.0f°", celsius))C"
    }

    var body: some View {
        WidgetShell {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    WidgetHeader(systemImage: "thermometer.medium",
                                 title: String(localized: "card.temperature", defaultValue: "Temperature"),
                                 color: .secondary)
                    HStack(alignment: .firstTextBaseline, spacing: 2) {
                        Text(tempText)
                            .font(.fraunces(size: 32, weight: .regular, italic: true))
                            .foregroundStyle(tempColor)
                            .monospacedDigit()
                            .contentTransition(.numericText(value: celsius))
                            .lineLimit(1)
                        Text(tempUnit)
                            .font(.system(size: 12, weight: .regular, design: .monospaced))
                            .foregroundStyle(.tertiary)
                    }
                    Text(subtitleText)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                SparklineView(
                    values: sparklineValues,
                    lineColor: tempColor,
                    fillColor: tempColor.opacity(0.20),
                    frameSize: CGSize(width: 80, height: 38),
                    lineWidth: 1.2
                )
            }
        }
        .task(id: disk.volumeUUID) { await fetchSparkline() }
    }

    private func fetchSparkline() async {
        let now = Date()
        let start = now.addingTimeInterval(-24 * 3600)
        let granularity = SmartSnapshot.granularityMinute
        let descriptor = FetchDescriptor<SmartSnapshot>(
            predicate: #Predicate<SmartSnapshot> { snap in
                snap.diskUUID == disk.volumeUUID
                && snap.granularity == granularity
                && snap.timestamp >= start
                && snap.timestamp <= now
            },
            sortBy: [SortDescriptor(\.timestamp, order: .forward)]
        )
        let snaps = (try? modelContext.fetch(descriptor)) ?? []
        sparklineValues = snaps.map { Double($0.celsius) }
    }

    private func shortName(_ path: String) -> String {
        if let last = path.split(separator: "/").last { return String(last) }
        return path
    }
}

// MARK: - Widget 3:Power 2x1(功耗读数 + sparkline)

/// Power 2x1 widget
/// - 大数字:当前功耗(Fraunces 32pt italic)+ "W" 单位
/// - sparkline:实时功耗曲线(从 PowerService 或 smartctl powerConsumptionWatts 拉)
/// - 副标:数据源(smartctl / system estimated / Not available)
private struct PowerWidget: View {
    let disk: DiskInfo
    @Environment(HealthMonitor.self) private var monitor
    @Environment(AppSettings.self) private var settings

    private var smart: SmartData? {
        monitor.currentByUUID[disk.volumeUUID]
    }

    private var watts: Double? {
        if let w = smart?.powerConsumptionWatts, w > 0 { return w }
        return nil
    }

    private var dataSourceLabel: String {
        if watts != nil {
            return L10n.t("module.power.ratedLive", zh: "额定峰值，非实时瓦数", en: "Rated peak, not live watts", language: settings.language)
        }
        if disk.isUSBBridgeWithoutSMART {
            return L10n.t("module.power.usbNever", zh: "USB 桥不提供功耗", en: "USB bridge has no power", language: settings.language)
        }
        return String(localized: "module.power.notAvailable", defaultValue: "Not available")
    }

    /// v0.9.1 polish-P2:功耗显示文本(走 SmartDataFormatter.power,nil/0 → "—")
    /// 跟 PowerModule + PowerWidget 统一,主人硬规则"不 mock"
    private var powerText: String {
        // watts 已做 > 0 过滤(none / 0 → nil),但用 SmartDataFormatter 兜底保险
        if let w = watts {
            return String(format: "%.2f", w)
        }
        return "—"
    }

    var body: some View {
        let _ = monitor.ioGeneration
        WidgetShell {
            VStack(alignment: .leading, spacing: 6) {
                WidgetHeader(systemImage: "bolt.fill",
                             title: L10n.t("card.power", zh: "功耗", en: "Power", language: settings.language),
                             color: .secondary)
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    HStack(alignment: .firstTextBaseline, spacing: 2) {
                        Text(powerText)
                            .font(.fraunces(size: 28, weight: .regular, italic: true))
                            .foregroundStyle(Color.dsNormal)
                            .monospacedDigit()
                            .contentTransition(.numericText(value: watts ?? 0))
                            .lineLimit(1)
                        Text("W")
                            .font(.system(size: 11, weight: .regular, design: .monospaced))
                            .foregroundStyle(.tertiary)
                    }
                    Spacer(minLength: 4)
                    VStack(alignment: .trailing, spacing: 1) {
                        Text("\(L10n.t("module.disk.io.read", zh: "读", en: "R", language: settings.language)) \(ByteFormatter.bps(monitor.ioLiveSample(for: disk.volumeUUID)?.readBps))")
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(.secondary)
                        Text("\(L10n.t("module.disk.io.write", zh: "写", en: "W", language: settings.language)) \(ByteFormatter.bps(monitor.ioLiveSample(for: disk.volumeUUID)?.writeBps))")
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
                DualIOChart(
                    history: monitor.ioHistoryByUUID[disk.volumeUUID] ?? [],
                    showsAxes: false,
                    maxPoints: 60
                )
                .frame(height: 28)
                Text(dataSourceLabel)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
    }
}

// MARK: - Widget 4:SMART 2x2(10 真 NVMe 字段)

/// SMART 2x2 widget
/// - 10 真 NVMe 字段(任务硬规则:v0.6.1 polish-G 删 6 ATA placeholder,只显示 NVMe 字段)
/// - 单行:左 字段名 + 右 value + 状态点
/// - 颜色阈值:mediaErrors>0 红 / availableSpare<10 红 / percentageUsed>=90 红 / 警告温度时间>0 琥珀
private struct SMARTWidget: View {
    let disk: DiskInfo
    @Environment(HealthMonitor.self) private var monitor

    private var smart: SmartData? {
        monitor.currentByUUID[disk.volumeUUID]
    }

    fileprivate struct Row {
        let id: String
        let name: String
        let value: String
        let status: Status
        enum Status { case normal, warning, critical, danger }
    }

    private var rows: [Row] {
        guard let s = smart else {
            return Self.fieldNames.map { f in
                Row(id: f.id, name: f.name, value: "—", status: .normal)
            }
        }
        let crit = (s.celsius ?? 0) >= 80
        let warn = (s.celsius ?? 0) >= 70
        return [
            Row(id: "celsius", name: String(localized: "smart.temperature", defaultValue: "Temperature"),
                // v0.9.1 polish-P2:nil/0 → "—",跟 SMARTModule 统一走 SmartDataFormatter.celsius
                value: SmartDataFormatter.celsius(s.celsius),
                status: crit ? .critical : (warn ? .warning : .normal)),
            Row(id: "pct", name: String(localized: "smart.percentageUsed", defaultValue: "Percentage Used"),
                // v0.9.1 polish-P2:nil → "—",0 → "0%"(新盘合法),走 SmartDataFormatter.percentageUsed
                value: SmartDataFormatter.percentageUsed(s.percentageUsed),
                status: {
                    guard let used = s.percentageUsed else { return Row.Status.normal }
                    if used >= 90 { return .critical }
                    if used >= 70 { return .warning }
                    return .normal
                }()),
            Row(id: "spare", name: String(localized: "smart.availableSpare", defaultValue: "Available Spare"),
                // v0.9.1 polish-P2:走 SmartDataFormatter.availableSpare(nil → "—",0 → "0%")
                value: SmartDataFormatter.availableSpare(s.availableSpare),
                status: (s.availableSpare ?? 100) <= 10 ? .critical
                       : (s.availableSpare ?? 100) <= 30 ? .warning : .normal),
            Row(id: "media", name: String(localized: "smart.mediaErrors", defaultValue: "Media Errors"),
                // v0.9.1 polish-P2:走 SmartDataFormatter.mediaErrors(nil → "—",0 → "0")
                value: SmartDataFormatter.mediaErrors(s.mediaErrors),
                status: (s.mediaErrors ?? 0) > 0 ? .danger : .normal),
            Row(id: "unsafe", name: String(localized: "smart.unsafeShutdowns", defaultValue: "Unsafe Shutdowns"),
                // v0.9.1 polish-P2:走 SmartDataFormatter.unsafeShutdowns(nil → "—",0 → "0")
                value: SmartDataFormatter.unsafeShutdowns(s.unsafeShutdowns),
                status: (s.unsafeShutdowns ?? 0) > 50 ? .warning : .normal),
            Row(id: "poh", name: String(localized: "smart.powerOnHours", defaultValue: "Power On Hours"),
                // v0.9.1 polish-P2:走 SmartDataFormatter.powerOnHours(nil → "—",0 → "0 h")
                value: SmartDataFormatter.powerOnHours(s.powerOnHours),
                status: .normal),
            Row(id: "poc", name: String(localized: "smart.powerCycles", defaultValue: "Power Cycles"),
                // v0.9.1 polish-P2:走 SmartDataFormatter.powerCycles(nil → "—",0 → "0")
                value: SmartDataFormatter.powerCycles(s.powerCycles),
                status: .normal),
            Row(id: "dwr", name: String(localized: "smart.dataRead", defaultValue: "Data Read"),
                value: String(format: "%.1f TB", s.dataUnitsReadTB ?? 0),
                status: .normal),
            Row(id: "dww", name: String(localized: "smart.dataWritten", defaultValue: "Data Written"),
                value: String(format: "%.1f TB", s.dataUnitsWrittenTB ?? 0),
                status: .normal),
            Row(id: "cw", name: String(localized: "smart.warningTempTime", defaultValue: "Critical Warn"),
                value: String(format: "0x%02X", s.criticalWarningRaw ?? 0),
                status: criticalWarningStatus(s.criticalWarningRaw))
        ]
    }

    private static let fieldNames: [(id: String, name: String)] = [
        ("celsius",  "Temperature"),
        ("pct",      "Percentage Used"),
        ("spare",    "Available Spare"),
        ("media",    "Media Errors"),
        ("unsafe",   "Unsafe Shutdowns"),
        ("poh",      "Power On Hours"),
        ("poc",      "Power Cycles"),
        ("dwr",      "Data Read"),
        ("dww",      "Data Written"),
        ("cw",       "Critical Warn")
    ]

    /// NVMe Critical Warning bits 解析
    /// - bit0(spare below threshold)→ .danger
    /// - bit4(backup failed)→ .danger
    /// - 其他位(bit1 temp / bit2 reliability / bit3 read-only / bit5...)→ .warning
    private func criticalWarningStatus(_ raw: Int?) -> Row.Status {
        guard let r = raw, r > 0 else { return .normal }
        if r & 0b00001 != 0 || r & 0b10000 != 0 { return .danger }
        return .warning
    }

    var body: some View {
        WidgetShell {
            VStack(alignment: .leading, spacing: 0) {
                WidgetHeader(systemImage: "list.bullet.rectangle",
                             title: String(localized: "card.smart", defaultValue: "SMART"),
                             color: .secondary)
                    .padding(.bottom, 6)
                Divider()
                    .background(Color.white.opacity(0.05))
                    .padding(.bottom, 4)
                VStack(spacing: 0) {
                    ForEach(rows, id: \.id) { r in
                        HStack(spacing: 6) {
                            Text(r.name)
                                .font(.system(size: 10, weight: .regular, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .lineLimit(1)
                            Text(r.value)
                                .font(.system(size: 10, weight: .medium, design: .monospaced))
                                .monospacedDigit()
                                .foregroundStyle(r.status.color)
                                .frame(width: 80, alignment: .trailing)
                                .lineLimit(1)
                                .contentTransition(.numericText())
                                .animation(.easeInOut(duration: 0.3), value: r.value)
                            Circle()
                                .fill(r.status.color)
                                .frame(width: 5, height: 5)
                        }
                        .padding(.vertical, 3)
                    }
                }
            }
        }
    }
}

extension SMARTWidget.Row.Status {
    var color: Color {
        switch self {
        case .normal:   .primary
        case .warning:  Color.dsWarning
        case .critical: Color.dsCritical
        case .danger:   Color.dsDanger
        }
    }
}

// MARK: - Widget 5:Health 1x1(HealthPredictor 警告数字 + DANGER 独立 chip)

/// Health 1x1 widget
/// - 大数字:HealthPredictor.healthScore(0-100,Fraunces 28pt italic)
/// - 副标:警告等级文字 + 颜色 chip(.danger / .critical / .warning / .none)
/// - .danger 状态额外加独立 DANGER chip(任务硬规则)
/// v0.9.3 健康 UX 升级(DriveDx 风格 0-100 + 4 标签 + actionable):
///   - 大字 0-100 评分(保留)
///   - 4 标签 GOOD / AVERAGE / LOW / BAD 取代原 .none/.warning/.critical/.danger 4 段
///     (HealthLabel 枚举,grok 3 调研 2025-09)
///   - 颜色:.good 琥珀(dsNormal)/ .average 蓝(dsInfo)/ .low 黄(dsLow)/ .bad 红(dsDanger)
///   - 大字下面 1 行 actionable 摘要(4 标签对应 4 段 DriveDx 风文案)
///   - "Show Details" 跳 SMART tab(任务硬规则:不写 SwiftData,只是视觉提醒;
///     DiskDetailView 已经在 SMART tab 同一面板,这里指视觉上"提示用户去看 SMART 模块")
private struct HealthWidget: View {
    let disk: DiskInfo
    @Environment(HealthMonitor.self) private var monitor
    @Environment(HealthPredictor.self) private var predictor

    /// v0.9.4:per-disk SMART 拉取 — 跟其他 widget 一致(从 monitor.currentByUUID 读)
    /// - 之前完全没读 monitor,导致 no-SMART 状态仍走 HealthPredictor 兜底 .none
    ///   → healthScore 0 + DANGER chip 假象(主人 bug:"健康度 100/100 仍显 DANGER 0")
    /// - 现在显式检测:无 SMART 数据 → 显 "—" + 隐藏 DANGER chip
    private var smart: SmartData? {
        monitor.currentByUUID[disk.volumeUUID]
    }

    /// v0.9.4:无 SMART 数据时显 "—"(健康度没有值,不显示 0 假象)
    /// - 主人硬规则"不 mock":no SMART data → 不报 0 也不报 100,直接 "—"
    /// - 这个状态在 ssd 512 内部盘上常见(无 SMART sensor)或 SMART poll 失败
    private var hasHealthData: Bool {
        guard let s = smart else { return false }
        return s.percentageUsed != nil || s.criticalWarningRaw != nil || s.mediaErrors != nil
    }

    private var warning: HealthWarning {
        predictor.warning(forDiskUUID: disk.volumeUUID)
    }

    private var healthScore: Int? {
        // v0.9.4:无 SMART 数据 → nil(显 "—",不显 "0")
        guard hasHealthData else { return nil }
        return HealthPredictor.healthScore(for: warning)
    }

    /// v0.9.3:0-100 → 4 标签(HealthLabel 枚举,SmartData.swift 定义)
    private var healthLabel: HealthLabel {
        if let score = healthScore {
            return HealthLabel.label(for: score)
        }
        // v0.9.4:无数据时 unknown 标签
        return .unknown
    }

    private var healthSummaryLine: String {
        if disk.isUSBBridgeWithoutSMART {
            let id = disk.identityLine
            if id.isEmpty {
                return String(
                    localized: "card.health.smartUnavailable",
                    defaultValue: "SMART not available on this USB disk"
                )
            }
            return id
        }
        if let reason = monitor.smartErrorByUUID[disk.volumeUUID], !reason.isEmpty {
            return reason
        }
        return healthLabel.actionableSummary
    }

    var body: some View {
        WidgetShell {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    WidgetHeader(systemImage: warning.sfSymbol,
                                 title: String(localized: "card.health", defaultValue: "Health"),
                                 color: healthLabel.color)
                    Spacer()
                    // v0.9.4:.danger 状态独立 DANGER chip,但仅在有数据时显
                    if warning == .danger, hasHealthData {
                        // 任务硬规则:.danger 状态独立 DANGER chip
                        Text(String(localized: "card.health.danger", defaultValue: "DANGER"))
                            .font(.system(size: 8, weight: .heavy, design: .monospaced))
                            .tracking(0.5)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(
                                RoundedRectangle(cornerRadius: 3, style: .continuous)
                                    .fill(Color.dsDanger)
                            )
                    }
                }
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    // v0.9.4:healthScore nil → 显 "—",不显 "0" 假象
                    Text(healthScore.map(String.init) ?? "—")
                        .font(.fraunces(size: 24, weight: .regular, italic: true))
                        .foregroundStyle(healthLabel.color)
                        .monospacedDigit()
                        .contentTransition(.numericText(value: Double(healthScore ?? 0)))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    if hasHealthData {
                        Text("/100")
                            .font(.system(size: 11, weight: .regular, design: .monospaced))
                            .foregroundStyle(.tertiary)
                    }
                }
                // v0.9.3:4 标签(取代原 warning 等级文字)
                Text(healthLabel.displayName)
                    .font(.system(size: 10, weight: .heavy, design: .monospaced))
                    .tracking(0.6)
                    .foregroundStyle(healthLabel.color)
                    .lineLimit(1)
                // v0.9.5:USB 桥接无 SMART 时写清楚原因,不要只丢一行被 clip 的英文
                Text(healthSummaryLine)
                    .font(.system(size: 9, weight: .regular, design: .default))
                    .italic()
                    .foregroundStyle(healthLabel.color.opacity(0.85))
                    .lineLimit(3)
                    .minimumScaleFactor(0.85)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

// MARK: - Widget 6:Link 1x1(LinkHealthService)

/// Link 1x1 widget
/// - 大数字:negotiatedSpeedGTs(Fraunces 24pt italic,GT/s)
/// - 副标:width(× lanes)+ busProtocol
/// - 颜色:negotiated < expected → dsWarning / 正常 dsNormal
private struct LinkWidget: View {
    let disk: DiskInfo
    @Environment(LinkHealthService.self) private var linkHealth

    private var link: LinkHealthService.LinkSnapshot? {
        // 优先:disk 自身缓存的 linkSnapshot(HealthMonitor 已写回)
        if let s = disk.linkSnapshot { return s }
        // 兜底:LinkHealthService.snapshots 字典(key = mountPoint)
        if let mp = disk.mountPoint { return linkHealth.snapshots[mp] }
        return nil
    }

    private var gtText: String {
        guard let g = link?.negotiatedSpeedGTs, g > 0 else { return "—" }
        return String(format: "%.1f", g)
    }

    private var widthText: String {
        guard let w = link?.negotiatedWidth, w > 0 else { return "—" }
        return "×\(w)"
    }

    private var protocolText: String {
        link?.busProtocol ?? "—"
    }

    private var isDegraded: Bool {
        guard let l = link, let n = l.negotiatedSpeedGTs, let e = l.expectedSpeedGTs, e > 0 else {
            return false
        }
        return n < e
    }

    private var linkColor: Color {
        isDegraded ? Color.dsWarning : Color.dsNormal
    }

    var body: some View {
        WidgetShell {
            VStack(alignment: .leading, spacing: 4) {
                WidgetHeader(systemImage: "bolt.horizontal.fill",
                             title: String(localized: "card.link", defaultValue: "Link"),
                             color: linkColor)
                Spacer(minLength: 0)
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text(gtText)
                        .font(.fraunces(size: 28, weight: .regular, italic: true))
                        .foregroundStyle(linkColor)
                        .monospacedDigit()
                        .contentTransition(.numericText())
                        .lineLimit(1)
                    Text("GT/s")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.tertiary)
                    Spacer(minLength: 4)
                    Text(widthText)
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 4) {
                    Text(protocolText)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                    if isDegraded {
                        Text(String(localized: "card.link.degraded", defaultValue: "DEGRADED"))
                            .font(.system(size: 8, weight: .heavy, design: .monospaced))
                            .tracking(0.4)
                            .foregroundStyle(Color.dsWarning)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(
                                RoundedRectangle(cornerRadius: 3, style: .continuous)
                                    .fill(Color.dsWarning.opacity(0.15))
                            )
                    }
                }
            }
        }
    }
}

// MARK: - Widget 7:SelfTest 1x1(DiagnosticTestService)

/// SelfTest 1x1 widget v0.9.3
/// 4 态状态机 + 进度条 + ETA + Cancel + Retry(grok 1 调研)
/// - 状态机:TestRunState { idle / running / success / failed }
/// - idle  → "Run Short Test" / "Run Long Test" 2 按钮
/// - running → "Stop" + ProgressView(value:) + 进度% + ETA
/// - success → ✓ "Test Passed" + 持续时长 + "Re-run" 按钮
/// - failed  → ✗ "Test Failed" + 错误原因 + "Retry" + (FDA 错) "Open Settings" 按钮
/// - v0.9.3:历史 last-run hero(timestamp / duration / pass-fail)内嵌在 idle/success/failed
/// - v0.9.3:用 Task { try await ... } 支持 Cancel(Stop 按钮)
private struct SelfTestWidget: View {
    let disk: DiskInfo
    @Environment(HealthMonitor.self) private var monitor
    @Environment(DiagnosticTestService.self) private var diagnostic

    // v0.9.3:4 态状态机 — 每个 type (short / long) 独立
    @State private var shortState: SelfTestRunState = .idle
    @State private var longState: SelfTestRunState = .idle
    // v0.9.3:当前选中的 type(idle 时 UI 显示 short / long 信息)
    @State private var selectedType: SelfTestType = .short
    // v0.9.3:错误 alert 状态
    @State private var testError: DiagnosticTestService.SelfTestError?
    // v0.9.3:run task 引用(用于 Cancel 按钮)
    @State private var runTask: Task<Void, Never>?

    private var lastTest: DiagnosticTestService.TestSnapshot? {
        disk.lastTest
    }

    private var currentState: SelfTestRunState {
        selectedType == .short ? shortState : longState
    }

    private var currentResult: DiagnosticTestService.SelfTestResult {
        let t = lastTest
        return selectedType == .short ? (t?.lastShortTest ?? .idle) : (t?.lastLongTest ?? .idle)
    }

    var body: some View {
        WidgetShell {
            VStack(alignment: .leading, spacing: 3) {
                // === 顶:header + type segmented ===
                header
                // === 状态文字 + 进度条 / 历史 ===
                stateContent
                Spacer(minLength: 0)
                // === 按钮区(随状态变化) ===
                actionButtons
            }
        }
        // v0.9.3:错误 alert(走 SelfTestError 直抛,跟 v0.9.1 polish-Q 一致)
        .alert(
            "Test Failed",
            isPresented: Binding(
                get: { testError != nil },
                set: { if !$0 { testError = nil } }
            ),
            presenting: testError
        ) { err in
            Button("OK", role: .cancel) { testError = nil }
            if err.requiresOpenSettings {
                Button("Open Settings") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
                        NSWorkspace.shared.open(url)
                    }
                    testError = nil
                }
            }
        } message: { err in
            Text(err.errorDescription ?? "Unknown error")
        }
    }

    // MARK: - Header(SF Symbol + "Self-Test" + Short/Long segmented)

    private var header: some View {
        HStack(spacing: 4) {
            WidgetHeader(
                systemImage: "checkmark.shield.fill",
                title: String(localized: "card.selfTest", defaultValue: "Self-Test"),
                color: stateColor
            )
            Spacer(minLength: 0)
            // v0.9.3:type 切换 segmented(只在 idle 状态可点,running 时禁用)
            typeSegmented
        }
    }

    private var typeSegmented: some View {
        HStack(spacing: 1) {
            ForEach([SelfTestType.short, .long], id: \.self) { t in
                Button {
                    if case .idle = currentState {
                        selectedType = t
                    }
                } label: {
                    Text(t.shortLabel)
                        .font(.system(size: 8, weight: .semibold, design: .monospaced))
                        .tracking(0.3)
                        .foregroundStyle(selectedType == t ? Color.dsNormal : Color.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(
                            RoundedRectangle(cornerRadius: 3, style: .continuous)
                                .fill(selectedType == t ? Color.dsNormal.opacity(0.18) : .clear)
                        )
                }
                .buttonStyle(.plain)
                .disabled({
                    if case .running = currentState { return true }
                    return false
                }())
            }
        }
    }

    // MARK: - State content(随状态变化:大数字 + 进度条 + ETA + last run hero)

    @ViewBuilder
    private var stateContent: some View {
        switch currentState {
        case .idle:
            idleContent
        case .running(let progress, let eta):
            runningContent(progress: progress, eta: eta)
        case .success(let date, let duration, let summary):
            successContent(date: date, duration: duration, summary: summary)
        case .failed(let date, let error):
            failedContent(date: date, error: error)
        }
    }

    /// idle:大数字 "—" + 副标 "Tap to run"
    private var idleContent: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text("—")
                    .font(.fraunces(size: 22, weight: .regular, italic: true))
                    .foregroundStyle(Color.secondary.opacity(0.5))
                Text("not run")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
            // v0.9.3:历史 last-run hero(显示上次 short/long 结果,有就显)
            if let last = lastRunHero {
                Text(last)
                    .font(.system(size: 9, weight: .regular, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
    }

    /// running:大数字 "23%" + ProgressView(value:) + ETA "ETA 1m 15s"
    private func runningContent(progress: Double, eta: TimeInterval?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("\(Int(progress * 100))%")
                    .font(.fraunces(size: 22, weight: .regular, italic: true))
                    .foregroundStyle(Color.dsWarning)
                    .monospacedDigit()
                    .contentTransition(.numericText(value: progress))
                    .lineLimit(1)
                if let eta = eta {
                    Text(SelfTestWidget.formatETA(eta))
                        .font(.system(size: 9, weight: .regular, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            // v0.9.3:ProgressView(value:) 进度条
            ProgressView(value: progress)
                .progressViewStyle(.linear)
                .tint(Color.dsWarning)
        }
    }

    /// success:大数字 "PASSED" + duration + last run time
    private func successContent(date: Date, duration: TimeInterval, summary: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(Color.dsNormal)
                Text("PASSED")
                    .font(.fraunces(size: 20, weight: .regular, italic: true))
                    .foregroundStyle(Color.dsNormal)
                    .lineLimit(1)
            }
            HStack(spacing: 4) {
                Text(SelfTestWidget.formatDuration(duration))
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(Color.dsNormal)
                Text("·")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                Text(SelfTestWidget.formatRelativeTime(date))
                    .font(.system(size: 9, weight: .regular, design: .monospaced))
                    .foregroundStyle(.tertiary)
                if !summary.isEmpty {
                    Text("·")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                    Text(summary)
                        .font(.system(size: 9, weight: .regular, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
        }
    }

    /// failed:大数字 "FAILED" + error reason + last run time
    private func failedContent(date: Date, error: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(Color.dsDanger)
                Text("FAILED")
                    .font(.fraunces(size: 20, weight: .regular, italic: true))
                    .foregroundStyle(Color.dsDanger)
                    .lineLimit(1)
            }
            HStack(spacing: 4) {
                Text(SelfTestWidget.formatRelativeTime(date))
                    .font(.system(size: 9, weight: .regular, design: .monospaced))
                    .foregroundStyle(.tertiary)
                if !error.isEmpty {
                    Text("·")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                    Text(error)
                        .font(.system(size: 9, weight: .regular, design: .monospaced))
                        .foregroundStyle(Color.dsDanger.opacity(0.85))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
        }
    }

    // MARK: - Action buttons(随状态变化)

    @ViewBuilder
    private var actionButtons: some View {
        switch currentState {
        case .idle:
            HStack(spacing: 4) {
                stateActionButton(
                    label: "Run Short",
                    color: Color.dsNormal,
                    enabled: true,
                    action: { runTest(type: .short) }
                )
                stateActionButton(
                    label: "Run Long",
                    color: Color.dsNormal,
                    enabled: true,
                    action: { runTest(type: .long) }
                )
            }
        case .running:
            // 琥珀 Stop 按钮
            stateActionButton(
                label: "Stop",
                color: Color.dsWarning,
                enabled: true,
                showProgress: true,
                action: { cancelTest() }
            )
        case .success:
            // 重测按钮(同 type)
            stateActionButton(
                label: "Re-run \(selectedType.shortLabel)",
                color: Color.dsNormal,
                enabled: true,
                action: { runTest(type: selectedType) }
            )
        case .failed(_, let error):
            HStack(spacing: 4) {
                // Retry 按钮
                stateActionButton(
                    label: "Retry",
                    color: Color.dsDanger,
                    enabled: true,
                    action: { runTest(type: selectedType) }
                )
                // 如果是 FDA 错误,加 "Open Settings" 按钮
                if SelfTestWidget.errorRequiresOpenSettings(errorString: error) {
                    stateActionButton(
                        label: "Settings",
                        color: Color.dsWarning,
                        enabled: true,
                        action: { openFDASettings() }
                    )
                }
            }
        }
    }

    private func stateActionButton(
        label: String,
        color: Color,
        enabled: Bool,
        showProgress: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if showProgress {
                    ProgressView()
                        .controlSize(.mini)
                        .tint(color)
                }
                Text(label)
                    .font(.system(size: 9, weight: .semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(color)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(color.opacity(0.12))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .stroke(color.opacity(0.30), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }

    // MARK: - Computed

    private var stateColor: Color {
        switch currentState {
        case .idle:              return .secondary
        case .running:           return Color.dsWarning
        case .success:           return Color.dsNormal
        case .failed:            return Color.dsDanger
        }
    }

    /// "last run hero" — 副标显示上次 short/long 结果(从 disk.lastTest 读)
    private var lastRunHero: String? {
        guard let t = lastTest else { return nil }
        let s = SelfTestWidget.statusShort(t.lastShortTest)
        let l = SelfTestWidget.statusShort(t.lastLongTest)
        if t.lastShortTest == .idle && t.lastLongTest == .idle { return nil }
        return "S:\(s) · L:\(l)"
    }

    // MARK: - Run / Cancel

    private func runTest(type: SelfTestType) {
        selectedType = type
        let bsd = disk.bsdName
        let startDate = Date()
        // v0.9.3:置 running(progress: 0, eta: nil)— 立即更新 UI
        let initialState = SelfTestRunState.running(progress: 0, eta: nil)
        if type == .short {
            shortState = initialState
        } else {
            longState = initialState
        }
        runTask?.cancel()
        runTask = Task {
            do {
                let progressHandler: (Double) -> Void = { p in
                    // v0.9.3:更新 progress + 计算 ETA
                    let elapsed = Date().timeIntervalSince(startDate)
                    let eta: TimeInterval? = {
                        guard p > 0.01 else {
                            return DiagnosticTestService.estimatedDuration(type: type.rawValue)
                        }
                        return elapsed * (1 - p) / p
                    }()
                    Task { @MainActor in
                        if type == .short {
                            shortState = .running(progress: p, eta: eta)
                        } else {
                            longState = .running(progress: p, eta: eta)
                        }
                    }
                }
                if type == .short {
                    try await diagnostic.runShortTest(bsdName: bsd, progress: progressHandler)
                } else {
                    try await diagnostic.runLongTest(bsdName: bsd, progress: progressHandler)
                }
                // 成功:从 disk.lastTest 读最新结果(v0.9.3:write-back 由 service 走 fetchLastResult 内部已设)
                let duration = Date().timeIntervalSince(startDate)
                if type == .short {
                    shortState = .success(
                        date: Date(),
                        duration: duration,
                        summary: "Short test completed"
                    )
                } else {
                    longState = .success(
                        date: Date(),
                        duration: duration,
                        summary: "Long test completed"
                    )
                }
                monitor.restartPolling()
            } catch is CancellationError {
                // v0.9.3:用户主动取消 → 回到 idle(设备 test 在后台继续跑)
                if type == .short {
                    shortState = .idle
                } else {
                    longState = .idle
                }
            } catch let err as DiagnosticTestService.SelfTestError {
                // v0.9.1 polish-Q:失败 alert
                testError = err
                if type == .short {
                    shortState = .failed(date: Date(), error: SelfTestWidget.errorToString(err))
                } else {
                    longState = .failed(date: Date(), error: SelfTestWidget.errorToString(err))
                }
            } catch {
                NSLog("DiskMon: SelfTestWidget \(type.rawValue) unexpected error: \(error)")
                if type == .short {
                    shortState = .failed(date: Date(), error: String(describing: error))
                } else {
                    longState = .failed(date: Date(), error: String(describing: error))
                }
            }
        }
    }

    private func cancelTest() {
        runTask?.cancel()
        runTask = nil
        let bsd = disk.bsdName
        Task { await diagnostic.abortTest(bsdName: bsd) }
    }

    private func openFDASettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Static helpers

    private static func statusShort(_ r: DiagnosticTestService.SelfTestResult) -> String {
        switch r {
        case .passed:  return "PASS"
        case .failed:  return "FAIL"
        case .running: return "RUN"
        case .aborted: return "ABRT"
        case .idle:    return "—"
        }
    }

    private static func formatDuration(_ seconds: TimeInterval) -> String {
        if seconds < 60 {
            return String(format: "%.0fs", seconds)
        } else if seconds < 3600 {
            let m = Int(seconds / 60)
            let s = Int(seconds.truncatingRemainder(dividingBy: 60))
            return "\(m)m \(s)s"
        } else {
            let h = Int(seconds / 3600)
            let m = Int((seconds.truncatingRemainder(dividingBy: 3600)) / 60)
            return "\(h)h \(m)m"
        }
    }

    private static func formatETA(_ seconds: TimeInterval) -> String {
        if seconds < 0 || seconds > 86400 * 30 {
            return "ETA —"
        }
        if seconds < 60 {
            return "ETA \(Int(seconds))s"
        } else if seconds < 3600 {
            return String(format: "ETA %dm %ds", Int(seconds / 60), Int(seconds.truncatingRemainder(dividingBy: 60)))
        } else {
            return String(format: "ETA %dh %dm", Int(seconds / 3600), Int((seconds.truncatingRemainder(dividingBy: 3600)) / 60))
        }
    }

    private static func formatRelativeTime(_ date: Date) -> String {
        let elapsed = Date().timeIntervalSince(date)
        if elapsed < 60 { return "just now" }
        if elapsed < 3600 { return "\(Int(elapsed / 60))m ago" }
        if elapsed < 86400 { return "\(Int(elapsed / 3600))h ago" }
        return "\(Int(elapsed / 86400))d ago"
    }

    private static func errorToString(_ err: DiagnosticTestService.SelfTestError) -> String {
        switch err {
        case .smartmontoolsNotFound: return "smartmontools not installed"
        case .fullDiskAccessRequired: return "Full Disk Access required"
        case .notSupported: return "Not supported on this disk"
        case .commandFailed(let code, _): return "smartctl exit \(code)"
        case .invalidBSDName: return "Invalid BSD name"
        case .timedOut: return "Timed out"
        }
    }

    private static func errorRequiresOpenSettings(errorString: String) -> Bool {
        return errorString.contains("Full Disk Access")
    }
}

// MARK: - SelfTestType / SelfTestRunState(v0.9.3 4 态状态机)

/// Self-test type(short / long)
enum SelfTestType: String, CaseIterable, Identifiable {
    case short, long
    var id: String { rawValue }
    var shortLabel: String { self == .short ? "Short" : "Long" }
}

/// SelfTest 4 态状态机(v0.9.3 grok 1 调研)
/// - idle:还没跑 / 跑了又清空
/// - running(progress, eta):正在跑(progress 0.0..1.0,eta 剩余秒数)
/// - success(date, duration, summary):跑成功
/// - failed(date, error):跑失败
enum SelfTestRunState: Equatable {
    case idle
    case running(progress: Double, eta: TimeInterval?)
    case success(date: Date, duration: TimeInterval, summary: String)
    case failed(date: Date, error: String)
}

// MARK: - Widget 8:Benchmark 1x1(BenchmarkService)

/// Benchmark 1x1 widget v0.9.3
/// 4 态状态机 + 进度条(5 阶段)+ Cancel + Retry + live chart(grok 1 调研)
/// - 状态机:BenchmarkRunState { idle / running(phase, progress) / success / failed }
/// - running:5 阶段进度(preparing 0-10% / writing 10-50% / syncing 50-60% /
///   reading 60-90% / unlinking 90-100%)+ live chart(50-200 pts ring buffer)
/// - 颜色:实测 < 期望 70% → dsWarning / 正常 dsNormal
/// - v0.9.3:history last-run hero(时间 / write+read / vs expected)内嵌在 idle/success
/// - v0.9.3:用 Task { try await ... } 支持 Cancel(Stop 按钮) + chunked I/O 内部响应
private struct BenchmarkWidget: View {
    let disk: DiskInfo
    @Environment(HealthMonitor.self) private var monitor
    @Environment(BenchmarkService.self) private var benchmark

    // v0.9.3:4 态状态机
    @State private var state: BenchmarkRunState = .idle
    // v0.9.3:错误 alert 状态
    @State private var benchError: BenchmarkService.BenchmarkError?
    // v0.9.3:run task 引用
    @State private var runTask: Task<Void, Never>?
    // v0.9.3:live chart ring buffer(BenchmarkLiveBuffer 是 fileprivate @Observable)
    @State private var chartBuffer: BenchmarkLiveBuffer = BenchmarkLiveBuffer()

    private var result: BenchmarkService.BenchmarkResult? {
        disk.benchmark
    }

    private var writeText: String {
        guard let w = result?.writeMBps, w > 0 else { return "—" }
        return String(format: "%.0f", w)
    }

    private var readText: String {
        guard let r = result?.readMBps, r > 0 else { return "—" }
        return String(format: "%.0f", r)
    }

    private var writeColor: Color {
        guard let w = result?.writeMBps, let e = result?.expectedWriteMBps, e > 0 else {
            return Color.dsNormal
        }
        return w < e * 0.7 ? Color.dsWarning : Color.dsNormal
    }

    private var hasMountPoint: Bool {
        disk.mountPoint != nil
    }

    var body: some View {
        WidgetShell {
            VStack(alignment: .leading, spacing: 3) {
                WidgetHeader(
                    systemImage: "gauge.with.dots.needle.67percent",
                    title: String(localized: "card.benchmark", defaultValue: "Benchmark"),
                    color: stateColor
                )
                stateContent
                Spacer(minLength: 0)
                actionButtons
            }
        }
        // v0.9.3:错误 alert(跟 v0.9.1 polish-Q 一致)
        .alert(
            "Benchmark Failed",
            isPresented: Binding(
                get: { benchError != nil },
                set: { if !$0 { benchError = nil } }
            ),
            presenting: benchError
        ) { err in
            Button("OK", role: .cancel) { benchError = nil }
            if err.requiresOpenSettings {
                Button("Open Settings") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
                        NSWorkspace.shared.open(url)
                    }
                    benchError = nil
                }
            }
        } message: { err in
            Text(err.errorDescription ?? "Unknown error")
        }
    }

    // MARK: - State content(随状态变化)

    @ViewBuilder
    private var stateContent: some View {
        switch state {
        case .idle:
            idleContent
        case .running(let phase, let progress):
            runningContent(phase: phase, progress: progress)
        case .success(let date, let duration, let w, let r):
            successContent(date: date, duration: duration, w: w, r: r)
        case .failed(let date, let error):
            failedContent(date: date, error: error)
        }
    }

    /// idle:大数字 writeMBps + 副标 readMBps + last run hero(若有)
    private var idleContent: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(writeText)
                    .font(.fraunces(size: 22, weight: .regular, italic: true))
                    .foregroundStyle(writeColor)
                    .monospacedDigit()
                    .contentTransition(.numericText(value: result?.writeMBps ?? 0))
                    .lineLimit(1)
                Text("MB/s")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
            HStack(spacing: 4) {
                Text("R:")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.tertiary)
                Text("\(readText) MB/s")
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if let hero = lastRunHero {
                Text(hero)
                    .font(.system(size: 9, weight: .regular, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
    }

    /// running:阶段文字 + 进度条 + live chart 缩略图
    private func runningContent(phase: BenchmarkService.BenchmarkPhase, progress: Double) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("\(Int(progress * 100))%")
                    .font(.fraunces(size: 20, weight: .regular, italic: true))
                    .foregroundStyle(Color.dsWarning)
                    .monospacedDigit()
                    .contentTransition(.numericText(value: progress))
                    .lineLimit(1)
                Text(phase.phaseLabel)
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            // v0.9.3:ProgressView(value:) 进度条
            ProgressView(value: progress)
                .progressViewStyle(.linear)
                .tint(Color.dsWarning)
            // v0.9.3:live chart 缩略图(24pt 高,ring buffer 50 pts)
            if !chartBuffer.points.isEmpty {
                liveChartStrip
                    .frame(height: 20)
            }
        }
    }

    /// success:大数字 "✓ MB/s" + 副标 read + last run hero
    private func successContent(date: Date, duration: TimeInterval, w: Double, r: Double) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.dsNormal)
                Text(String(format: "%.0f", w))
                    .font(.fraunces(size: 20, weight: .regular, italic: true))
                    .foregroundStyle(writeColor)
                    .monospacedDigit()
                    .lineLimit(1)
                Text("MB/s")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
            HStack(spacing: 4) {
                Text("R: \(Int(r)) MB/s")
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text("·")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                Text(BenchmarkWidget.formatDuration(duration))
                    .font(.system(size: 9, weight: .regular, design: .monospaced))
                    .foregroundStyle(.tertiary)
                Text("·")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                Text(BenchmarkWidget.formatRelativeTime(date))
                    .font(.system(size: 9, weight: .regular, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    /// failed:✗ + 错误原因 + last run time
    private func failedContent(date: Date, error: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(Color.dsDanger)
                Text("FAILED")
                    .font(.fraunces(size: 20, weight: .regular, italic: true))
                    .foregroundStyle(Color.dsDanger)
                    .lineLimit(1)
            }
            HStack(spacing: 4) {
                Text(BenchmarkWidget.formatRelativeTime(date))
                    .font(.system(size: 9, weight: .regular, design: .monospaced))
                    .foregroundStyle(.tertiary)
                Text("·")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                Text(error)
                    .font(.system(size: 9, weight: .regular, design: .monospaced))
                    .foregroundStyle(Color.dsDanger.opacity(0.85))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
    }

    // MARK: - Live chart(ring buffer 50-200 pts,throttled)

    /// live chart strip — 20pt 高的 LineMark 折线,显示 ring buffer 中所有点
    /// - Swift Charts LineMark 实时刷新
    /// - 颜色:琥珀(dsWarning)— 跟 running 阶段一致
    /// - 注:用 chartBuffer.points(只存 MB/s 数值,X 用 index)
    private var liveChartStrip: some View {
        Chart {
            ForEach(Array(chartBuffer.points.enumerated()), id: \.offset) { idx, v in
                LineMark(
                    x: .value("t", idx),
                    y: .value("MB/s", v)
                )
                .foregroundStyle(Color.dsWarning)
                .interpolationMethod(.monotone)
                .lineStyle(StrokeStyle(lineWidth: 1.0))
                AreaMark(
                    x: .value("t", idx),
                    y: .value("MB/s", v)
                )
                .foregroundStyle(Color.dsWarning.opacity(0.18))
                .interpolationMethod(.monotone)
            }
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartLegend(.hidden)
        .chartYScale(domain: chartBuffer.yDomain)
    }

    // MARK: - Action buttons

    @ViewBuilder
    private var actionButtons: some View {
        switch state {
        case .idle:
            benchActionButton(
                label: hasMountPoint
                    ? "Run Benchmark"
                    : "No mount point",
                color: hasMountPoint ? Color.dsNormal : .secondary,
                enabled: hasMountPoint,
                action: { runBenchmark() }
            )
        case .running:
            benchActionButton(
                label: "Stop",
                color: Color.dsWarning,
                enabled: true,
                showProgress: true,
                action: { cancelBenchmark() }
            )
        case .success:
            benchActionButton(
                label: "Re-run",
                color: Color.dsNormal,
                enabled: hasMountPoint,
                action: { runBenchmark() }
            )
        case .failed(_, let error):
            HStack(spacing: 4) {
                benchActionButton(
                    label: "Retry",
                    color: Color.dsDanger,
                    enabled: hasMountPoint,
                    action: { runBenchmark() }
                )
                if BenchmarkWidget.errorRequiresOpenSettings(errorString: error) {
                    benchActionButton(
                        label: "Settings",
                        color: Color.dsWarning,
                        enabled: true,
                        action: { openFDASettings() }
                    )
                }
            }
        }
    }

    private func benchActionButton(
        label: String,
        color: Color,
        enabled: Bool,
        showProgress: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if showProgress {
                    ProgressView()
                        .controlSize(.mini)
                        .tint(color)
                }
                Text(label)
                    .font(.system(size: 9, weight: .semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(color)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(color.opacity(0.12))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .stroke(color.opacity(0.30), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }

    // MARK: - Computed

    private var stateColor: Color {
        switch state {
        case .idle:    return .secondary
        case .running: return Color.dsWarning
        case .success: return Color.dsNormal
        case .failed:  return Color.dsDanger
        }
    }

    /// "last run hero" — 显示 write / read / vs expected / 时间
    private var lastRunHero: String? {
        guard let r = result else { return nil }
        var parts: [String] = []
        if let w = r.writeMBps { parts.append(String(format: "W:%.0f", w)) }
        if let re = r.readMBps { parts.append(String(format: "R:%.0f", re)) }
        if let e = r.expectedWriteMBps, e > 0 {
            parts.append(String(format: "exp:%.0f MB/s", e))
        }
        let relTime = BenchmarkWidget.formatRelativeTime(r.completedAt)
        parts.append(relTime)
        return parts.joined(separator: " · ")
    }

    // MARK: - Run / Cancel

    private func runBenchmark() {
        guard let mp = disk.mountPoint else { return }
        let startDate = Date()
        chartBuffer.clear()
        state = .running(phase: .preparing, progress: 0.0)
        runTask?.cancel()
        runTask = Task {
            do {
                let progressHandler: (BenchmarkService.BenchmarkPhase, Double) -> Void = { phase, p in
                    // v0.9.3:更新 progress + 推 ring buffer(throttled at 8 Hz)
                    let mbps = Self.estimateMBps(progress: p, start: startDate, bytes: 1 << 30)
                    Task { @MainActor in
                        state = .running(phase: phase, progress: p)
                        chartBuffer.append(value: mbps)
                    }
                }
                let result = try await benchmark.run(
                    mountPoint: mp,
                    bytes: 1 << 30,
                    force: true,
                    progress: progressHandler
                )
                // 成功
                let duration = Date().timeIntervalSince(startDate)
                let w = result.writeMBps ?? 0
                let re = result.readMBps ?? 0
                state = .success(date: Date(), duration: duration, writeMBps: w, readMBps: re)
                monitor.restartPolling()
            } catch is CancellationError {
                // v0.9.3:用户取消 — 回到 idle
                state = .idle
                chartBuffer.clear()
            } catch let err as BenchmarkService.BenchmarkError {
                // v0.9.1 polish-Q:失败 alert
                benchError = err
                state = .failed(
                    date: Date(),
                    error: BenchmarkWidget.errorToString(err)
                )
                chartBuffer.clear()
            } catch {
                NSLog("DiskMon: BenchmarkWidget run unexpected error: \(error)")
                state = .failed(date: Date(), error: String(describing: error))
                chartBuffer.clear()
            }
        }
    }

    private func cancelBenchmark() {
        runTask?.cancel()
        runTask = nil
    }

    private func openFDASettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }

    /// 用 progress 推算瞬时 MB/s(给 live chart 用)— 假设总 IO bytes = 1 GB
    /// - 实际:elapsed 越久,bytesWritten 越多,MB/s ≈ bytesWritten / elapsed
    /// - 简化:用 progress × bytes / elapsed
    private static func estimateMBps(
        progress: Double,
        start: Date,
        bytes: UInt64
    ) -> Double {
        let elapsed = Date().timeIntervalSince(start)
        guard elapsed > 0.05 else { return 0 }
        return (Double(bytes) * progress / 1_000_000.0) / elapsed
    }

    // MARK: - Static helpers

    private static func formatDuration(_ seconds: TimeInterval) -> String {
        if seconds < 60 {
            return String(format: "%.1fs", seconds)
        } else {
            return String(format: "%.0fs", seconds)
        }
    }

    private static func formatRelativeTime(_ date: Date) -> String {
        let elapsed = Date().timeIntervalSince(date)
        if elapsed < 60 { return "just now" }
        if elapsed < 3600 { return "\(Int(elapsed / 60))m ago" }
        if elapsed < 86400 { return "\(Int(elapsed / 3600))h ago" }
        return "\(Int(elapsed / 86400))d ago"
    }

    private static func errorToString(_ err: BenchmarkService.BenchmarkError) -> String {
        switch err {
        case .mountPointMissing: return "Not mounted"
        case .fullDiskAccessRequired: return "Full Disk Access required"
        case .fileCreationFailed: return "Cannot create test file"
        case .ioFailed(let code, _): return "IO failed (\(code))"
        }
    }

    private static func errorRequiresOpenSettings(errorString: String) -> Bool {
        return errorString.contains("Full Disk Access")
    }
}

// MARK: - BenchmarkLiveBuffer(v0.9.3 live chart ring buffer)

/// Benchmark live chart ring buffer
/// - 容量 100 pts(实测 1 GB 写 + 读 跑 1-3s,8 Hz 取样 ≈ 16-24 pts,100 给 4-5s 缓冲)
/// - @Observable 触发 SwiftUI 自动 redraw
/// - yDomain:自适应,min / max × 0.9 / 1.1 给边距
/// - v0.9.3:internal 让 BenchmarkModule 共用(同 module 内部)
@Observable
final class BenchmarkLiveBuffer {
    /// ring buffer of recent MB/s values
    private(set) var points: [Double] = []
    /// 容量上限
    private let capacity: Int = 100

    func append(value: Double) {
        points.append(value)
        if points.count > capacity {
            points.removeFirst(points.count - capacity)
        }
    }

    func clear() {
        points.removeAll()
    }

    /// Y 轴 domain(0..max*1.1)— 给 Chart 用
    var yDomain: ClosedRange<Double> {
        guard let m = points.max(), m > 0 else { return 0...1000 }
        return 0...(m * 1.15)
    }
}

// MARK: - BenchmarkRunState(v0.9.3 4 态状态机)

/// Benchmark 4 态状态机(v0.9.3 grok 1 调研)
/// - idle:还没跑 / 跑了又清空
/// - running(phase, progress):正在跑
/// - success(date, duration, writeMBps, readMBps):跑成功
/// - failed(date, error):跑失败
enum BenchmarkRunState: Equatable {
    case idle
    case running(phase: BenchmarkService.BenchmarkPhase, progress: Double)
    case success(date: Date, duration: TimeInterval, writeMBps: Double, readMBps: Double)
    case failed(date: Date, error: String)
}

// MARK: - Widget 9:FSIntegrity 1x1(FSIntegrityService)

/// FSIntegrity 1x1 widget v0.9.3
/// 4 态状态机 + 进度条(time-based)+ Cancel + Retry(grok 1 调研)
/// - 状态机:FSRunState { idle / running(progress) / success(date, duration) / failed(date, error) }
/// - 进度:diskutil verifyVolume 不输出阶段,走 time-based(estimated 30s 推到 0.95)
/// - 颜色:.verified dsNormal / .warning dsWarning / .failed dsDanger / .unknown secondary
/// - v0.9.3:用 Task { try await ... } 支持 Cancel — proc.terminate(SIGTERM) 杀 diskutil
/// - v0.9.3:last run hero 内嵌在 idle/success/failed
private struct FSIntegrityWidget: View {
    let disk: DiskInfo
    @Environment(HealthMonitor.self) private var monitor
    @Environment(FSIntegrityService.self) private var fsIntegrity

    // v0.9.3:4 态状态机
    @State private var state: FSRunState = .idle
    // v0.9.3:错误 alert 状态
    @State private var verifyError: FSIntegrityService.FSIntegrityError?
    // v0.9.3:run task 引用
    @State private var runTask: Task<Void, Never>?

    private var result: FSIntegrityService.IntegrityResult? {
        disk.integrity
    }

    private var status: FSIntegrityService.IntegrityStatus {
        result?.status ?? .unknown
    }

    private var hasMountPoint: Bool {
        disk.mountPoint != nil
    }

    var body: some View {
        WidgetShell {
            VStack(alignment: .leading, spacing: 3) {
                WidgetHeader(
                    systemImage: "checkmark.seal.fill",
                    title: String(localized: "card.integrity", defaultValue: "FS Integrity"),
                    color: stateColor
                )
                stateContent
                Spacer(minLength: 0)
                actionButtons
            }
        }
        // v0.9.3:错误 alert(跟 v0.9.1 polish-Q 一致)
        .alert(
            "FS Verify Failed",
            isPresented: Binding(
                get: { verifyError != nil },
                set: { if !$0 { verifyError = nil } }
            ),
            presenting: verifyError
        ) { err in
            Button("OK", role: .cancel) { verifyError = nil }
            if err.requiresOpenSettings {
                Button("Open Settings") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
                        NSWorkspace.shared.open(url)
                    }
                    verifyError = nil
                }
            }
        } message: { err in
            Text(err.errorDescription ?? "Unknown error")
        }
    }

    // MARK: - State content

    @ViewBuilder
    private var stateContent: some View {
        switch state {
        case .idle:
            idleContent
        case .running(let progress):
            runningContent(progress: progress)
        case .success(let date, let duration):
            successContent(date: date, duration: duration)
        case .failed(let date, let error):
            failedContent(date: date, error: error)
        }
    }

    /// idle:大数字 status("OK"/"WARN"/"FAIL"/"—")+ reason + last run hero
    private var idleContent: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(FSIntegrityWidget.statusText(status))
                    .font(.fraunces(size: 28, weight: .regular, italic: true))
                    .foregroundStyle(FSIntegrityWidget.statusColor(status))
                    .monospacedDigit()
                    .contentTransition(.numericText(value: FSIntegrityWidget.statusNumericKey(status)))
                    .lineLimit(1)
                if let reason = FSIntegrityWidget.statusReason(status) {
                    Text(reason)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(FSIntegrityWidget.statusColor(status).opacity(0.8))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer(minLength: 0)
            }
            if let hero = lastRunHero {
                Text(hero)
                    .font(.system(size: 9, weight: .regular, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
    }

    /// running:大数字 "verifying" + 进度条(time-based 推到 0.95)
    private func runningContent(progress: Double) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("Verifying")
                    .font(.fraunces(size: 22, weight: .regular, italic: true))
                    .foregroundStyle(Color.dsWarning)
                    .lineLimit(1)
                Text("\(Int(progress * 100))%")
                    .font(.system(size: 11, weight: .regular, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
                    .contentTransition(.numericText(value: progress))
            }
            ProgressView(value: progress)
                .progressViewStyle(.linear)
                .tint(Color.dsWarning)
        }
    }

    /// success:大数字 "OK" + 副标 duration + time
    private func successContent(date: Date, duration: TimeInterval) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(Color.dsNormal)
                Text("OK")
                    .font(.fraunces(size: 24, weight: .regular, italic: true))
                    .foregroundStyle(Color.dsNormal)
                    .lineLimit(1)
            }
            HStack(spacing: 4) {
                Text(FSIntegrityWidget.formatDuration(duration))
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(Color.dsNormal)
                Text("·")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                Text(FSIntegrityWidget.formatRelativeTime(date))
                    .font(.system(size: 9, weight: .regular, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    /// failed:大数字 "FAIL" + reason + time
    private func failedContent(date: Date, error: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(Color.dsDanger)
                Text("FAIL")
                    .font(.fraunces(size: 24, weight: .regular, italic: true))
                    .foregroundStyle(Color.dsDanger)
                    .lineLimit(1)
            }
            HStack(spacing: 4) {
                Text(FSIntegrityWidget.formatRelativeTime(date))
                    .font(.system(size: 9, weight: .regular, design: .monospaced))
                    .foregroundStyle(.tertiary)
                if !error.isEmpty {
                    Text("·")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                    Text(error)
                        .font(.system(size: 9, weight: .regular, design: .monospaced))
                        .foregroundStyle(Color.dsDanger.opacity(0.85))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
        }
    }

    // MARK: - Action buttons

    @ViewBuilder
    private var actionButtons: some View {
        switch state {
        case .idle:
            fsActionButton(
                label: hasMountPoint
                    ? "Verify"
                    : "No mount point",
                color: hasMountPoint ? Color.dsNormal : .secondary,
                enabled: hasMountPoint,
                action: { runVerify() }
            )
        case .running:
            fsActionButton(
                label: "Stop",
                color: Color.dsWarning,
                enabled: true,
                showProgress: true,
                action: { cancelVerify() }
            )
        case .success:
            fsActionButton(
                label: "Re-verify",
                color: Color.dsNormal,
                enabled: hasMountPoint,
                action: { runVerify() }
            )
        case .failed(_, let error):
            HStack(spacing: 4) {
                fsActionButton(
                    label: "Retry",
                    color: Color.dsDanger,
                    enabled: hasMountPoint,
                    action: { runVerify() }
                )
                if FSIntegrityWidget.errorRequiresOpenSettings(errorString: error) {
                    fsActionButton(
                        label: "Settings",
                        color: Color.dsWarning,
                        enabled: true,
                        action: { openFDASettings() }
                    )
                }
            }
        }
    }

    private func fsActionButton(
        label: String,
        color: Color,
        enabled: Bool,
        showProgress: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if showProgress {
                    ProgressView()
                        .controlSize(.mini)
                        .tint(color)
                }
                Text(label)
                    .font(.system(size: 9, weight: .semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(color)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(color.opacity(0.12))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .stroke(color.opacity(0.30), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }

    // MARK: - Computed

    private var stateColor: Color {
        switch state {
        case .idle:    return FSIntegrityWidget.statusColor(status)
        case .running: return Color.dsWarning
        case .success: return Color.dsNormal
        case .failed:  return Color.dsDanger
        }
    }

    /// "last run hero" — 显示 capturedAt + status
    private var lastRunHero: String? {
        guard let r = result else { return nil }
        return FSIntegrityWidget.formatRelativeTime(r.capturedAt)
    }

    // MARK: - Run / Cancel

    private func runVerify() {
        guard let mp = disk.mountPoint else { return }
        let startDate = Date()
        state = .running(progress: 0.0)
        runTask?.cancel()
        runTask = Task {
            do {
                let progressHandler: (Double) -> Void = { p in
                    Task { @MainActor in
                        state = .running(progress: p)
                    }
                }
                _ = try await fsIntegrity.verify(mountPoint: mp, progress: progressHandler)
                let duration = Date().timeIntervalSince(startDate)
                state = .success(date: Date(), duration: duration)
                monitor.restartPolling()
            } catch is CancellationError {
                // v0.9.3:用户取消
                state = .idle
            } catch let err as FSIntegrityService.FSIntegrityError {
                verifyError = err
                state = .failed(date: Date(), error: FSIntegrityWidget.errorToString(err))
            } catch {
                NSLog("DiskMon: FSIntegrityWidget verify unexpected error: \(error)")
                state = .failed(date: Date(), error: String(describing: error))
            }
        }
    }

    private func cancelVerify() {
        runTask?.cancel()
        runTask = nil
    }

    private func openFDASettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Static helpers(status 映射 跟 v0.9.1 一致)

    private static func statusText(_ s: FSIntegrityService.IntegrityStatus) -> String {
        switch s {
        case .verified:  return "OK"
        case .warning:   return "WARN"
        case .failed:    return "FAIL"
        case .verifying: return "..."
        case .unknown:   return "—"
        }
    }

    private static func statusColor(_ s: FSIntegrityService.IntegrityStatus) -> Color {
        switch s {
        case .verified:  return Color.dsNormal
        case .warning:   return Color.dsWarning
        case .failed:    return Color.dsDanger
        case .verifying: return Color.dsWarning
        case .unknown:   return Color.secondary.opacity(0.5)
        }
    }

    private static func statusReason(_ s: FSIntegrityService.IntegrityStatus) -> String? {
        switch s {
        case .failed(let reason):  return reason
        case .warning(let reason): return reason
        case .verified, .verifying, .unknown: return nil
        }
    }

    private static func statusNumericKey(_ s: FSIntegrityService.IntegrityStatus) -> Double {
        switch s {
        case .unknown:   return 0
        case .verified:  return 1
        case .warning:   return 2
        case .failed:    return 3
        case .verifying: return 4
        }
    }

    private static func formatDuration(_ seconds: TimeInterval) -> String {
        if seconds < 60 {
            return String(format: "%.1fs", seconds)
        } else {
            return String(format: "%.0fs", seconds)
        }
    }

    private static func formatRelativeTime(_ date: Date) -> String {
        let elapsed = Date().timeIntervalSince(date)
        if elapsed < 60 { return "just now" }
        if elapsed < 3600 { return "\(Int(elapsed / 60))m ago" }
        if elapsed < 86400 { return "\(Int(elapsed / 3600))h ago" }
        return "\(Int(elapsed / 86400))d ago"
    }

    private static func errorToString(_ err: FSIntegrityService.FSIntegrityError) -> String {
        switch err {
        case .mountPointMissing: return "Not mounted"
        case .fullDiskAccessRequired: return "Full Disk Access required"
        case .verifyFailed(let code, _): return "diskutil exit \(code)"
        }
    }

    private static func errorRequiresOpenSettings(errorString: String) -> Bool {
        return errorString.contains("Full Disk Access")
    }
}

/// Wrap identity chips onto the next line instead of dropping serial / filesystem.
private struct DropHistoryWidget: View {
    let disk: DiskInfo
    @Environment(HealthMonitor.self) private var monitor
    @Environment(AppSettings.self) private var settings

    private var lang: String { settings.language }

    private var story: DropNowState {
        monitor.dropStory(for: disk.volumeUUID)
    }

    var body: some View {
        WidgetShell {
            VStack(alignment: .leading, spacing: 8) {
                WidgetHeader(
                    systemImage: "externaldrive.badge.xmark",
                    title: L10n.t("module.drop.title", zh: "掉盘", en: "DROP", language: lang),
                    color: .secondary
                )
                switch story {
                case .steady:
                    Text(L10n.t(
                        "module.drop.diskEmpty",
                        zh: "这块盘没有意外掉盘。推出或卸载不算。",
                        en: "No unexpected drop on this disk. Eject/unmount does not count.",
                        language: lang
                    ))
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                case .expectedGone(let ev):
                    Text(L10n.t("module.drop.ejected", zh: "已卸下", en: "Ejected", language: lang))
                        .font(.fraunces(size: 22, weight: .regular, italic: true))
                        .foregroundStyle(.secondary)
                    Text("\(relative(ev.at)) · \(L10n.t("module.drop.meaning.ok", zh: "不是故障。", en: "Not a fault.", language: lang))")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                case .missing(let ev):
                    Text(L10n.t("module.drop.gone", zh: "现在不在", en: "Missing now", language: lang))
                        .font(.fraunces(size: 22, weight: .regular, italic: true))
                        .foregroundStyle(Color.dsDanger)
                    Text("\(relative(ev.at)) · \(meaning(ev.hint))")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(action(ev.hint))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.dsNormal)
                        .fixedSize(horizontal: false, vertical: true)
                case .flap(let n, let ev):
                    Text(L10n.t("module.drop.chip.flap", zh: "反复掉线", en: "Flapping", language: lang))
                        .font(.fraunces(size: 22, weight: .regular, italic: true))
                        .foregroundStyle(Color.dsWarning)
                    Text("24h ×\(n) · \(relative(ev.at))")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Text(action(ev.hint))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.dsNormal)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func meaning(_ h: DropHint) -> String {
        switch h {
        case .afterSleep:
            return L10n.t("module.drop.meaning.sleep", zh: "发生在睡眠或唤醒附近。", en: "Near sleep or wake.", language: lang)
        case .flap:
            return L10n.t("module.drop.meaning.flap", zh: "短时间掉了又回来。", en: "Dropped and came back quickly.", language: lang)
        case .usbCableOrPort:
            return L10n.t("module.drop.meaning.usb", zh: "USB 盘从列表消失。", en: "USB disk vanished.", language: lang)
        default:
            return L10n.t("module.drop.meaning.unknown", zh: "不是本 App 推出的。", en: "This app did not eject it.", language: lang)
        }
    }

    private func action(_ h: DropHint) -> String {
        switch h {
        case .afterSleep:
            return L10n.t("module.drop.action.sleep", zh: "唤醒后看访达。可关 USB 节能，或换口再插。", en: "After wake, check Finder. Or replug.", language: lang)
        case .flap:
            return L10n.t("module.drop.action.flap", zh: "换口直连，少用 HUB。仍反复就换线。", en: "Direct port, skip hub. Still flapping? Change cable.", language: lang)
        default:
            return L10n.t("module.drop.action.usb", zh: "换口直连再插上。仍不出现再换线。", en: "Replug on another port. Still missing? Change cable.", language: lang)
        }
    }

    private func relative(_ date: Date) -> String {
        let s = Date().timeIntervalSince(date)
        if s < 60 { return L10n.t("module.drop.just", zh: "刚刚", en: "just now", language: lang) }
        if s < 3600 { return "\(Int(s / 60))m" }
        if s < 86_400 { return "\(Int(s / 3600))h" }
        return "\(Int(s / 86_400))d"
    }
}

private struct ChipFlow: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        layout(proposal: proposal, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let frames = layout(
            proposal: ProposedViewSize(width: bounds.width, height: bounds.height),
            subviews: subviews
        ).frames
        for (index, frame) in frames.enumerated() {
            subviews[index].place(
                at: CGPoint(x: bounds.minX + frame.origin.x, y: bounds.minY + frame.origin.y),
                proposal: ProposedViewSize(frame.size)
            )
        }
    }

    private func layout(proposal: ProposedViewSize, subviews: Subviews) -> (size: CGSize, frames: [CGRect]) {
        let maxWidth = proposal.width ?? .infinity
        var frames: [CGRect] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var maxX: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            frames.append(CGRect(origin: CGPoint(x: x, y: y), size: size))
            rowHeight = max(rowHeight, size.height)
            x += size.width + spacing
            maxX = max(maxX, x - spacing)
        }
        return (CGSize(width: maxX, height: y + rowHeight), frames)
    }
}

/// Disk manage widget — format / unmount / eject for the selected external disk.
private struct ManageWidget: View {
    let disk: DiskInfo
    @Environment(DiskFormatService.self) private var formatter
    @Environment(AppSettings.self) private var settings

    @State private var personality: FormatPersonality = .exfat
    @State private var volumeName: String = ""
    @State private var confirm: String = ""
    @State private var log: String = ""

    private var lang: String { settings.language }
    private var refused: Bool { disk.isInternal }
    private var trouble: Bool { settings.diskMarks.mark(for: disk.volumeUUID) == .trouble }
    private var confirmOK: Bool {
        let token = confirm.trimmingCharacters(in: .whitespacesAndNewlines)
        return token == disk.displayName || token == disk.bsdName
    }

    var body: some View {
        WidgetShell {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    WidgetHeader(
                        systemImage: "wrench.and.screwdriver",
                        title: L10n.t("card.manage", zh: "磁盘管理", en: "Manage", language: lang),
                        color: Color.dsNormal
                    )
                    Spacer()
                    Button {
                        settings.setDiskMark(trouble ? .none : .trouble, for: disk.volumeUUID)
                    } label: {
                        Image(systemName: trouble ? "exclamationmark.circle.fill" : "exclamationmark.circle")
                            .font(.system(size: 12))
                            .foregroundStyle(trouble ? AnyShapeStyle(Color.dsDanger) : AnyShapeStyle(.tertiary))
                    }
                    .buttonStyle(.plain)
                    .help(L10n.t("detail.mark.trouble", zh: "标记为经常出错", en: "Mark as trouble", language: lang))
                }

                if refused {
                    Text(L10n.t("manage.internal", zh: "系统盘，拒绝格式化。", en: "Internal disk — format refused.", language: lang))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                } else {
                    let access = disk.ntfsAccess(extensionOn: formatter.ntfsKitAvailable)
                    if disk.isNTFSVolume {
                        NTFSStatusRow(
                            access: access,
                            extensionOn: formatter.ntfsKitAvailable,
                            lang: lang,
                            compact: true,
                            busy: formatter.isBusy,
                            onEnable: { DiskFormatService.openFileSystemExtensions() },
                            onRemount: {
                                Task { log = await formatter.remount(disk: disk) }
                            }
                        )
                    }
                    FormatPersonalityChips(
                        personality: $personality,
                        canFormatNTFS: formatter.canFormatNTFS,
                        lang: lang
                    ) { p in
                        settings.setDefaultFormat(p.rawValue)
                    }
                    Text(personality.hint(lang: lang))
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 8) {
                        TextField(disk.displayName, text: $volumeName)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 11))
                        TextField(L10n.t("manage.confirm", zh: "确认盘名", en: "Confirm name", language: lang), text: $confirm)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 11, design: .monospaced))
                    }
                    HStack(spacing: 8) {
                        Button {
                            Task {
                                let name = volumeName.trimmingCharacters(in: .whitespacesAndNewlines)
                                log = await formatter.format(
                                    disk: disk,
                                    personality: personality,
                                    confirm: confirm,
                                    volumeName: name.isEmpty ? disk.displayName : name,
                                    remountAfter: settings.autoMountAfterFormat
                                )
                            }
                        } label: {
                            Text(L10n.t("manage.format", zh: "格式化", en: "Format", language: lang))
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(Color.themeFgDark)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(RoundedRectangle(cornerRadius: 6).fill(Color.dsNormal.opacity(confirmOK ? 0.28 : 0.10)))
                        }
                        .buttonStyle(.plain)
                        .disabled(formatter.isBusy || !confirmOK)
                        Button {
                            log = formatter.openInFinder(disk)
                        } label: {
                            Text(L10n.t("manage.finder", zh: "访达", en: "Finder", language: lang))
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .disabled(formatter.isBusy || disk.mountPoint == nil)
                        if disk.mountPoint == nil {
                            Button {
                                Task { log = await formatter.mount(disk: disk) }
                            } label: {
                                Text(L10n.t("manage.mount", zh: "挂载", en: "Mount", language: lang))
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .disabled(formatter.isBusy)
                        } else {
                            Button {
                                Task { log = await formatter.unmount(disk: disk) }
                            } label: {
                                Text(L10n.t("manage.unmount", zh: "推出", en: "Unmount", language: lang))
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .disabled(formatter.isBusy)
                        }
                        Button {
                            Task { log = await formatter.eject(disk: disk) }
                        } label: {
                            Text(L10n.t("manage.eject", zh: "弹出", en: "Eject", language: lang))
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .disabled(formatter.isBusy)
                        if formatter.isBusy { ProgressView().controlSize(.mini) }
                    }
                    if !log.isEmpty {
                        Text(log)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .lineLimit(2)
                    }
                }
            }
        }
        .task {
            await formatter.refreshProbe()
            if volumeName.isEmpty { volumeName = disk.displayName }
            if let raw = FormatPersonality(rawValue: settings.defaultFormatRaw) {
                personality = raw
            }
        }
        .onChange(of: disk.volumeUUID) { _, _ in
            volumeName = disk.displayName
            confirm = ""
            log = ""
        }
    }
}

// MARK: - FSRunState(v0.9.3 4 态状态机)

/// FSIntegrity 4 态状态机(v0.9.3 grok 1 调研)
/// - idle:还没跑 / 跑了又清空
/// - running(progress):正在跑(diskutil 不输出阶段,time-based 推 progress 0.0..0.95)
/// - success(date, duration):跑成功
/// - failed(date, error):跑失败
enum FSRunState: Equatable {
    case idle
    case running(progress: Double)
    case success(date: Date, duration: TimeInterval)
    case failed(date: Date, error: String)
}

// MARK: - 健康度进度环(SVG 自绘,保留 v0.8.0 实现)

/// 健康度进度环 — 圆环,默认 56×56(在 Hero widget 里用)
/// v0.9 polish-N1:支持自定义 size 参数(v0.8.0 默认 80x80 改为可配)
struct HealthRingView: View {
    let smart: SmartData?
    let settings: AppSettings
    let level: HealthLevel
    let size: CGFloat

    private let outerR: CGFloat
    private let innerR: CGFloat

    init(smart: SmartData?, settings: AppSettings, level: HealthLevel, size: CGFloat = 56) {
        self.smart = smart
        self.settings = settings
        self.level = level
        self.size = size
        // 按 size 缩放(80 → 56 系数 0.7)
        let s = size / 80.0
        self.outerR = 38 * s
        self.innerR = 28 * s
    }

    var body: some View {
        ZStack {
            // 背景环(玻璃黑)
            RingShape(outerR: outerR, innerR: innerR, progress: 1.0)
                .fill(Color.black.opacity(0.35))
            // 填充环(健康度颜色)
            RingShape(outerR: outerR, innerR: innerR, progress: progressValue)
                .fill(level.color)
                .opacity(0.9)
            // 中心文字
            VStack(spacing: 0) {
                Text(centerText)
                    .font(.fraunces(size: max(10, size * 0.20), weight: .regular, italic: true))
                    .foregroundStyle(centerColor)
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .animation(.easeInOut(duration: 0.3), value: centerText)
            }
        }
        .frame(width: size, height: size)  // 容器随 size 缩放
    }

    private var progressValue: CGFloat {
        guard let used = smart?.percentageUsed else { return 0 }
        return CGFloat(max(0, 100 - used)) / 100.0
    }

    private var centerText: String {
        guard let used = smart?.percentageUsed else { return "—" }
        return "\(max(0, 100 - used))%"
    }

    private var centerColor: Color {
        guard smart != nil else { return .secondary }
        return level.color
    }
}

// MARK: - 环 Shape(保留 v0.8.0 实现)

/// 圆环 Path 片段(0° 起点 = 12 点钟,顺时针为正)
struct RingShape: Shape {
    let outerR: CGFloat
    let innerR: CGFloat
    let progress: CGFloat

    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let sweepDeg = Double(progress) * 360.0
        if progress >= 0.9999 {
            return arcPath(center: center, startDeg: 0, sweepDeg: 360)
        }
        if progress <= 0.0001 {
            return Path()
        }
        return arcPath(center: center, startDeg: 0, sweepDeg: sweepDeg)
    }

    private func arcPath(center: CGPoint, startDeg: Double, sweepDeg: Double) -> Path {
        let startRad: Double = (startDeg - 90) * .pi / 180
        let endRad: Double = (startDeg + sweepDeg - 90) * .pi / 180
        func pt(radius: CGFloat, rad: Double) -> CGPoint {
            CGPoint(
                x: center.x + CGFloat(Double(radius) * cos(rad)),
                y: center.y + CGFloat(Double(radius) * sin(rad))
            )
        }
        let startPt = pt(radius: outerR, rad: startRad)
        let innerStart = pt(radius: innerR, rad: startRad)
        var p = Path()
        p.move(to: startPt)
        p.addArc(
            center: center, radius: outerR,
            startAngle: .radians(startRad),
            endAngle: .radians(endRad),
            clockwise: false
        )
        p.addLine(to: pt(radius: innerR, rad: endRad))
        p.addArc(
            center: center, radius: innerR,
            startAngle: .radians(endRad),
            endAngle: .radians(startRad),
            clockwise: true
        )
        p.closeSubpath()
        _ = innerStart
        return p
    }
}

// MARK: - v0.9.3 minimax-C: What's New sheet (major version bump changelog)

/// v0.9.3 minimax-C:What's New sheet(major.minor version 变更时弹 1 次)
/// - 触发:DiskDetailView.onAppear → `OnboardingStore.shouldShowWhatsNew` true 时
/// - 关闭:点 "Got it" / Esc / sheet dismiss → onClose() 回调 → 写回当前 major.minor
///   下次启动同 major.minor 不重显
/// - 布局:440x420 居中,玻璃背景,大标题 + bullet list + 右下 Got it 按钮
/// - 文案硬编码 v0.9.3 的真实 changelog(任务硬规则:不 mock / 不 emoji / 简短)
struct WhatsNewSheet: View {
    let onClose: () -> Void

    @Environment(\.dismiss) private var dismiss

    /// v0.9.3 minimax-C:changelog 内容(major.minor 升级时显示)
    /// - 跟 v0.9.2 → v0.9.3 实际改动一致
    /// - 每条 1 行 + SF Symbol 跟文字前部对齐
    /// - 不循环动画 / 不弹跳 / 不堆 emoji
    private struct Change: Identifiable {
        let id: Int
        let icon: String
        let text: String
    }

    private let changes: [Change] = [
        Change(
            id: 1,
            icon: "sparkles",
            text: String(localized: "whatsnew.0.9.3.1", defaultValue: "First-launch onboarding tour — 5 guided tips")
        ),
        Change(
            id: 2,
            icon: "rectangle.stack.badge.plus",
            text: String(localized: "whatsnew.0.9.3.2", defaultValue: "More menu — link / self-test / benchmark / fs integrity, all in one sheet")
        ),
        Change(
            id: 3,
            icon: "square.grid.2x2",
            text: String(localized: "whatsnew.0.9.3.3", defaultValue: "Disk picker in popover top bar — pick a drive without opening detail")
        ),
        Change(
            id: 4,
            icon: "checkmark.shield",
            text: String(localized: "whatsnew.0.9.3.4", defaultValue: "SMART module added to overview when needed — no extra setup")
        ),
        Change(
            id: 5,
            icon: "bolt.heart",
            text: String(localized: "whatsnew.0.9.3.5", defaultValue: "Faster SMART poll, cleaner temperature display, fewer false alerts")
        )
    ]

    var body: some View {
        VStack(spacing: 0) {
            // 顶栏:icon + 标题 + version
            header
            Divider()
                .background(Color.white.opacity(0.06))
            // changelog 列表
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(changes) { change in
                        changeRow(change)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 20)
            }
            Divider()
                .background(Color.white.opacity(0.06))
            // 底栏:Got it 按钮
            footer
        }
        .frame(width: 440, height: 420)
        .background(.regularMaterial)
    }

    /// v0.9.3 minimax-C:顶栏(SF Symbol sparkles 琥珀 + "What's New in diskmon" + 版本号)
    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .font(.system(size: 18, weight: .regular))
                    .foregroundStyle(Color.dsNormal)
                Text(String(localized: "whatsnew.title", defaultValue: "What's New in diskmon"))
                    .font(.fraunces(size: 18, weight: .regular, italic: true))
                    .foregroundStyle(Color.themeFgDark)
            }
            Text("v\(OnboardingStore.currentMajorMinor)")
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .tracking(0.8)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 24)
        .padding(.top, 22)
        .padding(.bottom, 14)
    }

    /// v0.9.3 minimax-C:changelog 单行(icon 琥珀 + 文字 13pt primary)
    private func changeRow(_ change: Change) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: change.icon)
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(Color.dsNormal)
                .frame(width: 18, alignment: .center)
            Text(change.text)
                .font(.system(size: 13))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// v0.9.3 minimax-C:底栏(右侧 Got it 按钮 — 琥珀胶囊)
    private var footer: some View {
        HStack {
            Spacer()
            Button {
                // 关闭 sheet + 写回当前 major.minor(下次同版本不重显)
                OnboardingStore.recordCurrentVersion()
                dismiss()
                onClose()
            } label: {
                Text(String(localized: "whatsnew.gotit", defaultValue: "Got it"))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.dsNormal)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background(
                        Capsule()
                            .fill(Color.dsNormal.opacity(0.15))
                    )
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }
}
