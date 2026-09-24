import SwiftUI
import SwiftData
import DiskMonCore

/// Popover tab 内容视图 v0.4.0 polish-D
/// v0.6.0 polish-A:OverviewContent 真 6 模块 LazyVGrid(2 列 × 3 行)
/// - 原 v0.4.3 polish-H "HERO 720x130 + 3 DiskCard 720x420" 删了
/// - 复用 6 个现有 Module:HealthOverview / Temperature / Capacity / Power / DiskList / ChartMini
/// v0.6.1 polish-H:OverviewContent 模块顺序 + 隐藏 持久化
///   - 渲染顺序来自 `settings.moduleOrder`,过滤 `settings.hiddenModules`
///   - EditMode:每模块右上角 "−" 隐藏 + 底部 "Add Module" 按钮 + Restore Sheet
///   - 简化版:不做 drag 手势,只做 toggle visibility
/// v0.9 polish-N2:OverviewContent EditMode 升级到 iOS Control Center 风格
///   - **Jiggle 抖动**:`JiggleEffect` modifier → rotationEffect sin(t*8)*0.6 + scaleEffect 0.96
///   - **拖动重排(真做)**:`DragGesture(minimumDistance: 4)` → onChanged 抬升卡(1.05 + shadow + zIndex)
///     → onEnded 调 setModuleOrder + `.animation(.easeInOut(duration: 0.3), value: settings.moduleOrder)`
///     在 LazyVGrid 上 → 0.3s 平滑重排
///   - **隐藏 × 升级**:`minus.circle.fill` → `xmark.circle.fill` 17pt 琥珀背景(iOS CC 风格),
///     点 × 触发卡 0.2s scale 1.0 → 0.0 退场动画(由 `EditModeModuleOverlay` modifier 管)
///   - **AddModulesSheet 升级**:`RestoreModulesSheet`(只列 hidden)→ `AddModulesSheet`(全 11 module),
///     LazyVGrid 2 列,玻璃卡 160×80,已显 module 灰显 + "Visible" 标签,未显 "Add" 按钮
///   - 共享 modifier + View 抽到 `Views/EditMode.swift`
///
/// 5 个 tab 各自有专属内容:
/// - OverviewContent:6 模块 LazyVGrid(总览)
/// - TemperatureContent:TemperatureModule + 24h 折线
/// - CapacityContent:CapacityModule + 已用列表
/// - PowerContent:PowerModule + 24h 功耗折线
/// - SMARTContent:SMARTModule + 全字段表
///
/// === 设计选择 ===
/// - **复用现有 Modules**:不重新实现 Temperature/Capacity/Power/SMART
/// - **图表**:`InteractiveChartView` 复用(wave-4D),带玻璃 + 噪点 + 35mm
/// - **数据**:`SwiftData` 拉 `SmartSnapshot`,真数据,不 mock
/// - **过渡**:`opacity` 0.3s(跟 TopBar 同步,统一缓动)

// MARK: - Overview Content(总览)

/// 总览 tab v0.6.0 polish-A(真 6 模块 LazyVGrid)
/// v0.6.1 polish-H:模块顺序 + 隐藏 持久化驱动
///   - 渲染顺序来自 `settings.moduleOrder`(默认 6 模块原始顺序)
///   - `settings.hiddenModules` 里的 key 被过滤(从网格里消失)
///   - EditMode 时每模块右上角 "−" 按钮(overlay)→ 调 setHiddenModules
///   - EditMode 时底部 "Add Module" 按钮 → sheet 列出已隐藏 → 点恢复
/// v0.9 polish-N2:EditMode 升级到 iOS Control Center 风格
///   - **Jiggle 抖动**:每 module 卡 `.jiggleEffect(isEditing:)` → 2-3° 高频 + 0.96 抬升
///   - **拖动重排(真做)**:`.gesture(DragGesture(minimumDistance: 4))` →
///     onChanged 抬升卡(scale 1.05 + shadow + zIndex 1)→
///     onEnded 调 setModuleOrder + .animation(.easeInOut(duration: 0.3)) 在 grid 上驱动平滑重排
///   - **隐藏 × 升级**:`.editModeModuleOverlay(key:isEditing:onHide:)` modifier
///     替换原 `hideButton` overlay,`xmark.circle.fill` 17pt 琥珀 + 0.2s scale 1.0→0.0 退场
///   - **AddModulesSheet 升级**:从 `RestoreModulesSheet`(只列 hidden)
///     换成 `AddModulesSheet`(全 11 module 总表,LazyVGrid 2 列,玻璃卡 160×80,已显灰显)
///   - 共享 modifier 抽到 `Views/EditMode.swift`(本 View 只做 wiring)
///
/// === 布局(720x600 popover tab 内容区,固定 6 模块网格) ===
/// - 6 模块 2 列 × 3 行 `GridItem(.adaptive(minimum: 180, maximum: 240), spacing: 16)`
///   1. `HealthOverviewModule` — 4 metric 总览(盘数 / 容量 / 通电 / 警告)
///   2. `TemperatureModule` — 最热盘实时温度 + 24h sparkline
///   3. `CapacityModule` — 主盘容量饼图
///   4. `PowerModule` — 主盘实时功耗(W)
///   5. `DiskListModule` — 最多 3 盘 mini 列表(可点击切 selectedDisk)
///   6. `ChartMiniModule` — selected disk 1H/24H 温度时间序列
///
/// === 设计选择(v0.6.0 polish-A + v0.6.1 polish-H + v0.9 polish-N2) ===
/// - **真 LazyVGrid**(`GridItem.adaptive(min: 180, max: 240)`,spacing 16) — 720 容器内 2 列自适应
///   - 180..240 → popover 720 - 36 padding = 684 → 240x2 + 16 spacing = 496,剩 188 → 完美 2 列
/// - **模块高度 180**(`minHeight: 140, idealHeight: 180, maxHeight: 220`) — 6 模块 3 行 = 540
///   + 2 spacing 32 = 572,完美填 600 内容区
/// - **复用现有 Modules**(不动 module 本体):switch on key 渲染对应 module
/// - **v0.9 polish-N2 拖动重排**:
///   - **不是 full drag-follow**(避免 custom Layout hitTest),拖动时只抬升卡,松手时 reorder
///   - **拖动阈值**:`DragGesture(minimumDistance: 4)` + 80pt 阈值决定方向(水平/垂直)
///   - **3 列网格**:684pt / 3 = 228pt 一列(实测 `adaptive(min:180,max:240)` 3 列最密)
///     → 水平 1 列 ~ 244pt(228+16),垂直 1 行 ~ 196pt(180+16)
///   - **持久化**:onEnded 调 `settings.setModuleOrder(newOrder)` → didChangeNotification
///     → `.animation(_:value:settings.moduleOrder)` 在 grid 上 → 0.3s 平滑重排
/// - **v0.9 polish-N2 隐藏 ×**:
///   - `xmark.circle.fill` 17pt 琥珀(SF Symbol 自然 fill = 琥珀实心圆 + 镂空 X)
///   - `.editModeModuleOverlay` modifier 内部管 `isHiding` @State → 0.2s scale 1.0→0.0 退场
///     → 0.2s 后调 onHide → setHiddenModules
/// - **v0.9 polish-N2 AddModulesSheet**:
///   - 全 11 module 总表(ModuleRegistry.defaultOrder + moduleDisplayNames)
///   - LazyVGrid 2 列 + 160×80 玻璃卡
///   - 已显 = moduleOrder 有 + hiddenModules 无(opacity 0.55 + "Visible" 标签)
///   - 未显 = "Add" 按钮 → onAdd(key) → remove from hidden + append to order(if not in)
///
/// === 不做 ===
/// - 不动现有 6 个 module 本体
/// - 不改 5 Preferences 子 View / AppSettings / Localizable.strings
/// - 不引入新依赖
struct OverviewContent: View {
    let monitor: HealthMonitor
    let power: PowerService
    let settings: AppSettings
    /// v0.9.1 polish-O2:rename `primaryDisk` → `selectedDisk`(统一切盘概念)
    /// - 旧 `primaryDisk` 派生 = "celsius 最大的盘",跟 `selectedDisk`(用户切盘)分裂
    /// - 新:PopoverView 直接传 `monitor.selectedDisk ?? monitor.watchedDisks.first`
    ///   跟 9 tab Content + DiskPickerView 走同一来源(单一真相)
    let selectedDisk: DiskInfo?
    /// v0.6.1 polish-H:Edit 模式状态(由 PopoverView 注入)
    var isEditing: Bool = false
    /// v0.9.1 polish-O2:加 module 回调(由 PopoverView 注入,OverviewContent 持久化后
    /// 调 `onModuleAdded?(key)` → PopoverView 决定是否切 tab)
    /// - 当前用途:加 SMART module → PopoverView 切到 .smart tab
    /// - 其他 module → 回调不做事(保持当前 tab,让用户继续看 Overview 全貌)
    var onModuleAdded: ((String) -> Void)? = nil

    /// 双列打包。`allio` 独占一行（两格宽），其余两两成行。
    private let dragColumnsPerRow: Int = 2
    private let dragThreshold: CGFloat = 80
    private let spanTwo: Set<String> = ["allio"]

    /// v0.6.1 polish-H:渲染的模块 key 列表(顺序 + 过滤 hidden)
    /// - moduleOrder 缺失的 key 自动跳过(防御性,避免未来增删模块时崩溃)
    private var visibleModuleKeys: [String] {
        let hidden = settings.hiddenModules
        return settings.moduleOrder.filter { !hidden.contains($0) }
    }

    /// 把模块排成行：`allio` 独占整行，其余两两一对。
    private var packedRows: [[String]] {
        var rows: [[String]] = []
        var pair: [String] = []
        for key in visibleModuleKeys {
            if spanTwo.contains(key) {
                if !pair.isEmpty {
                    rows.append(pair)
                    pair = []
                }
                rows.append([key])
            } else {
                pair.append(key)
                if pair.count == 2 {
                    rows.append(pair)
                    pair = []
                }
            }
        }
        if !pair.isEmpty { rows.append(pair) }
        return rows
    }

    /// v0.9 polish-N2:有"非 visible"模块时(Edit 模式),底部 "Add Module" 按钮显示
    /// - "非 visible" = 不在 moduleOrder ∪ 在 hiddenModules
    /// - 11 module - 显的 module = 可 add 数;为 0 时按钮不显
    private var hasAddableModules: Bool {
        let visible = Set(visibleModuleKeys)
        return ModuleRegistry.defaultOrder.contains { !visible.contains($0) }
    }

    /// v0.9 polish-N2:AddModulesSheet 显示状态
    @State private var showAddSheet: Bool = false

    /// v0.9 polish-N2:拖动状态(单卡拖动,拖动中保持 tracked key 抬升)
    @State private var draggedKey: String? = nil

    /// v0.6.1 polish-H:兜底 DiskInfo(无主盘时,CapacityModule / PowerModule 仍渲染)
    private var fallbackDisk: DiskInfo {
        DiskInfo(
            bsdName: "—",
            volumeUUID: "empty",
            mountPoint: nil,
            isInternal: false,
            sizeBytes: 0
        )
    }

    /// v0.6.1 polish-H:key → module View 工厂
    /// - 拆成两个 @ViewBuilder 函数,避免 let 绑定(result builder 不支持)
    /// - moduleBody 只做 switch on key → 渲染对应 module
    /// - moduleView 在 moduleBody 外面包 overlay(Edit 模式)+ jiggle + drag
    @ViewBuilder
    private func moduleBody(for key: String) -> some View {
        switch key {
        case "health":
            HealthOverviewModule()
        case "temperature":
            TemperatureModule()
        case "capacity":
            CapacityModule(disk: selectedDisk ?? fallbackDisk)
        case "power":
            PowerModule(
                power: power,
                diskBSDName: selectedDisk?.bsdName ?? "—"
            )
        case "disklist":
            DiskListModule()
        case "chartmini":
            ChartMiniModule()
        case "allio":
            AllDisksIOModule()
        // v0.8 polish-L:加 2 个新 module — Link + Test
        case "link":
            LinkHealthModule()
        case "test":
            DiagnosticTestModule()
        // v0.8 polish-M:再加 2 个新 module — Bench + FS
        case "bench":
            BenchmarkModule()
        case "fs":
            FSIntegrityModule()
        case "manage":
            DiskManageModule()
        case "drop":
            DropWatchModule()
        default:
            // 未知 key:不渲染(LazyVGrid 不会画空 view,但保留一行高度占位)
            EmptyView()
        }
    }

    /// v0.9 polish-N2:module View 包装(jiggle + EditMode overlay + drag + 拖动抬升)
    /// - `JiggleEffect` modifier 抖动(Edit 模式 + 未在拖)
    /// - `EditModeModuleOverlay` 隐藏 × overlay(Edit 模式)
    /// - drag 抬升:isDragging 时 scale 1.05 + shadow + zIndex 1
    /// - drag 手势:Edit 模式 + 4pt 最小距离 → onChanged 抬升 / onEnded reorder
    /// - 直接调 ViewModifier struct(不用 extension 包装方法),避免 chain
    ///   `.modifier(extension func returning some View)` 触发 Swift 6 opaque 类型歧义
    @ViewBuilder
    private func moduleView(for key: String) -> some View {
        let isDragging = (draggedKey == key)
        moduleBody(for: key)
            .modifier(JiggleEffect(
                isEditing: isEditing,
                // v0.9.1 polish-O2:`pauseScale` → `isDragging`,真停 rotation + scale 两个
                // (旧 pauseScale 只停 scale,rotation 仍 60Hz 抖 → jiggle stuck 体感)
                isDragging: isDragging
            ))
            .modifier(EditModeModuleOverlay(
                key: key,
                isEditing: isEditing,
                onHide: { handleHide(key) }
            ))
            // 拖动抬升(scale 1.05 + shadow + zIndex)
            .scaleEffect(isDragging ? 1.05 : 1.0)
            .shadow(
                color: .black.opacity(isDragging ? 0.20 : 0),
                radius: isDragging ? 12 : 0,
                y: isDragging ? 4 : 0
            )
            .zIndex(isDragging ? 1 : 0)
            .animation(.easeOut(duration: 0.2), value: isDragging)
            .gesture(
                isEditing
                    ? DragGesture(minimumDistance: 4)
                        .onChanged { _ in
                            if draggedKey == nil {
                                draggedKey = key
                            }
                        }
                        .onEnded { value in
                            handleDragEnd(key: key, translation: value.translation)
                            draggedKey = nil
                        }
                    : nil
            )
    }

    /// v0.9 polish-N2:点 × 退场动画结束后,把 key 加进 hiddenModules
    /// - 0.2s 退场动画由 `EditModeModuleOverlay` 内部 isHiding @State 驱动
    /// - 0.2s 后调 onHide → 本方法 → setHiddenModules(真正从 visible 移除,ForEach dismiss)
    private func handleHide(_ key: String) {
        var hidden = settings.hiddenModules
        hidden.insert(key)
        settings.setHiddenModules(hidden)
    }

    /// v0.9 polish-N2:拖动松手时,根据 translation 计算目标位置 + 调 setModuleOrder
    /// - 阈值 80pt:水平 / 垂直方向位移 > 80pt 才触发位移
    /// - 水平方向:1 列左移 / 1 列右移
    /// - 垂直方向:1 行上移 / 1 行下移
    /// - 边缘保护:目标 index 不能 < 0 / > keys.count
    /// v0.9.1 polish-O2:修复 `setModuleOrder(visibleModuleKeys)` 把 hidden keys 从
    /// moduleOrder 删掉的 bug
    /// - 旧:`visibleModuleKeys` = moduleOrder.filter(!hidden),set 回去时 hidden keys
    ///   全部丢失 → 用户 unhide module,`handleAdd` 走 append 末尾,相对位置破坏
    /// - 修后:在完整 moduleOrder 上 reorder,把 dragged key 移走 + 重新插回,
    ///   hidden keys 在 moduleOrder 里的相对位置保持不变
    private func handleDragEnd(key: String, translation: CGSize) {
        // v0.9.1 polish-O2:用完整 moduleOrder(包含 hidden)做 reorder 基准
        // 不要 `visibleModuleKeys`(会丢 hidden)
        let currentOrder = settings.moduleOrder
        guard let currentIndex = currentOrder.firstIndex(of: key) else { return }

        // 计算方向(水平 vs 垂直,取绝对值大者)
        let horizontalShift: Int
        if translation.width > dragThreshold {
            horizontalShift = 1
        } else if translation.width < -dragThreshold {
            horizontalShift = -1
        } else {
            horizontalShift = 0
        }

        let verticalShift: Int
        if translation.height > dragThreshold {
            verticalShift = 1
        } else if translation.height < -dragThreshold {
            verticalShift = -1
        } else {
            verticalShift = 0
        }

        // 计算目标 index(在完整列表里)
        let newIndex: Int
        if horizontalShift != 0 {
            let target = currentIndex + horizontalShift
            guard target >= 0, target < currentOrder.count else { return }
            newIndex = target
        } else if verticalShift != 0 {
            let currentRow = currentIndex / dragColumnsPerRow
            let currentCol = currentIndex % dragColumnsPerRow
            let newRow = currentRow + verticalShift
            guard newRow >= 0 else { return }
            let target = newRow * dragColumnsPerRow + currentCol
            guard target >= 0, target < currentOrder.count else { return }
            newIndex = target
        } else {
            return  // 拖动幅度不够,不 reorder
        }

        guard newIndex != currentIndex else { return }

        // v0.9.1 polish-O2:在完整 moduleOrder 上 reorder,hidden keys 位置不变
        // - 旧:keys = visibleModuleKeys → setModuleOrder(keys) 丢 hidden
        // - 新:完整列表 remove + insert,只动 dragged key
        var newOrder = currentOrder
        let keyToMove = newOrder.remove(at: currentIndex)
        newOrder.insert(keyToMove, at: newIndex)
        settings.setModuleOrder(newOrder)
    }

    /// v0.9 polish-N2:AddModulesSheet 触发"Add"回调
    /// - 从 hidden 移除 → setHiddenModules
    /// - 如果 key 不在 moduleOrder,append 到末尾 → setModuleOrder
    ///   (例:"smart" 默认不在 moduleOrder,add 后追加到末尾显示)
    /// v0.9.1 polish-O2:持久化后,调 `onModuleAdded?(key)` 通知 PopoverView
    /// - 当前用途:加 SMART module → PopoverView 自动切到 .smart tab(让用户立刻看到效果)
    /// - 其他 module → PopoverView 回调不切(保持 Overview tab)
    private func handleAdd(_ key: String) {
        var hidden = settings.hiddenModules
        hidden.remove(key)
        settings.setHiddenModules(hidden)

        let order = settings.moduleOrder
        if !order.contains(key) {
            settings.setModuleOrder(order + [key])
        }

        // v0.9.1 polish-O2:通知 PopoverView 做切 tab 决策
        onModuleAdded?(key)
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 12) {
                VStack(spacing: 16) {
                    ForEach(packedRows, id: \.self) { row in
                        HStack(spacing: 16) {
                            ForEach(row, id: \.self) { key in
                                moduleView(for: key)
                                    .frame(maxWidth: .infinity, alignment: .top)
                            }
                            if row.count == 1 && !spanTwo.contains(row[0]) {
                                Color.clear
                                    .frame(maxWidth: .infinity)
                                    .frame(minHeight: 1)
                                    .accessibilityHidden(true)
                            }
                        }
                    }
                }
                .padding(.horizontal, 18)
                .padding(.top, 14)
                .animation(DiskMonMotion.appear, value: settings.moduleOrder)

                // v0.9 polish-N2:Edit 模式 + 有可 add 模块时,底部 "Add Module" 按钮
                if isEditing && hasAddableModules {
                    addModuleButton
                        .padding(.horizontal, 18)
                        .padding(.bottom, 14)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay {
            if showAddSheet {
                ZStack {
                    Color.black.opacity(0.35)
                        .ignoresSafeArea()
                        .onTapGesture { showAddSheet = false }
                    AddModulesSheet(
                        settings: settings,
                        onAdd: { key in
                            handleAdd(key)
                            showAddSheet = false
                        }
                    )
                    .frame(width: 420, height: 460)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(Color.white.opacity(0.08), lineWidth: 1)
                    )
                }
            }
        }
    }

    /// v0.9 polish-N2:底部 "Add Module" 按钮(Edit 模式 + 有可 add 时)
    private var addModuleButton: some View {
        Button {
            showAddSheet = true
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 14, weight: .regular))
                Text(String(
                    localized: "popover.edit.addModule",
                    defaultValue: "Add Module"
                ))
                .font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(Color.dsNormal)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.dsNormal.opacity(0.10))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.dsNormal.opacity(0.30), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .help(String(
            localized: "popover.edit.addModule.help",
            defaultValue: "Show all available modules"
        ))
    }
}

// MARK: - Restore Modules Sheet 已删除 v0.9 polish-N2
// 原 `RestoreModulesSheet`(只列 hidden module + Restore 按钮)替换为 `Views/EditMode.swift` 里的
// `AddModulesSheet`(全 11 module 总表,已显灰显 + "Visible" 标签,未显 "Add" 按钮)
// - iOS CC 风格入口 — 用户看到完整 module 池,主动选 Add
// - 解决 "smart" 默认不在 moduleOrder 的问题:Add 时如果 key 不在 order,自动 append 到末尾
// - sheet 名字/文案变更:"Restore Hidden Modules" → "Edit Modules"

// MARK: - Temperature Content(温度)

/// 温度 tab:TemperatureModule + 24h 折线
///
/// v0.9.4:`TemperatureContent` 已正确把 `selectedDisk` 透传给 `TemperatureModule`
/// (通过 @Environment(HealthMonitor.self) — 间接走 monitor.selectedDisk)
/// - 旧版 `TemperatureModule` 内部用 `hottest` 派生(celsius 最大盘),跟用户切盘概念分裂
///   → 切盘 UI 切到 X 盘,但温度 tab 仍显示 Y 盘(celsius 最大)
/// - v0.9.4 修:Module 内部用 `monitor.selectedDisk ?? monitor.watchedDisks.first`
///   → 切盘联动一致(跟其他 8 tab Content 完全一致)
struct TemperatureContent: View {
    @Environment(\.modelContext) private var modelContext

    let monitor: HealthMonitor
    let power: PowerService
    let settings: AppSettings
    /// v0.9.1 polish-O2:rename `primaryDisk` → `selectedDisk`(统一切盘概念)
    /// v0.9.4:`TemperatureModule` 已通过 @Environment 读 monitor.selectedDisk,
    /// 本字段目前用于 24h InteractiveChartView 拉数据(`fetchTempData`)
    let selectedDisk: DiskInfo?

    @State private var tempDataPoints: [ChartDataPoint] = []
    @State private var tempRange: ChartRange = .h24

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            TemperatureModule()
                .frame(minWidth: 200, idealWidth: 240, maxWidth: 280)
                .frame(maxHeight: .infinity)

            InteractiveChartView(
                data: tempDataPoints,
                type: .area,
                title: L10n.t("tab.temperature.chartTitle", zh: "温度", en: "Temp", language: settings.language),
                unit: settings.temperatureUnitSymbol,
                color: monitor.healthLevel.color,
                rangeOptions: [.h1, .h24, .d7],
                referenceLines: [
                    ChartReferenceLine(
                        label: "Critical",
                        value: Double(monitor.criticalTempCelsius),
                        color: .dsCritical,
                        dashed: true
                    ),
                    ChartReferenceLine(
                        label: "Warning",
                        value: Double(monitor.warningTempCelsius),
                        color: .dsWarning,
                        dashed: true
                    )
                ],
                height: 180
            ) { newRange in
                withAnimation(.easeInOut(duration: 0.3)) {
                    tempRange = newRange
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: tempRange) { await fetchTempData() }
        .task(id: monitor.selectedDisk?.volumeUUID) { await fetchTempData() }
    }

    private func fetchTempData() async {
        let uuid = monitor.selectedDisk?.volumeUUID ?? selectedDisk?.volumeUUID
        guard let uuid else {
            tempDataPoints = []
            return
        }
        let now = Date()
        let start = now.addingTimeInterval(-tempRange.seconds)
        let gran = primaryGranularity(tempRange)
        var snaps = fetchSnaps(uuid: uuid, granularity: gran, start: start, now: now)
        if snaps.isEmpty {
            for fallback in fallbackGranularities(tempRange) {
                snaps = fetchSnaps(uuid: uuid, granularity: fallback, start: start, now: now)
                if !snaps.isEmpty { break }
            }
        }
        tempDataPoints = snaps.map { snap in
            ChartDataPoint(
                label: snap.timestamp.formatted(.dateTime.hour().minute()),
                value: Double(snap.celsius),
                date: snap.timestamp
            )
        }
    }

    private func primaryGranularity(_ range: ChartRange) -> String {
        switch range {
        case .h1: return SmartSnapshot.granularityRaw
        case .h24: return SmartSnapshot.granularityMinute
        case .d7, .d30: return SmartSnapshot.granularityHour
        }
    }

    private func fallbackGranularities(_ range: ChartRange) -> [String] {
        switch range {
        case .h1: return [SmartSnapshot.granularityMinute]
        case .h24: return [SmartSnapshot.granularityRaw, SmartSnapshot.granularityHour]
        case .d7, .d30: return [SmartSnapshot.granularityMinute, SmartSnapshot.granularityRaw]
        }
    }

    private func fetchSnaps(uuid: String, granularity: String, start: Date, now: Date) -> [SmartSnapshot] {
        let gran = granularity
        let descriptor = FetchDescriptor<SmartSnapshot>(
            predicate: #Predicate<SmartSnapshot> { s in
                s.diskUUID == uuid
                && s.granularity == gran
                && s.timestamp >= start
                && s.timestamp <= now
            },
            sortBy: [SortDescriptor(\.timestamp, order: .forward)]
        )
        return (try? modelContext.fetch(descriptor)) ?? []
    }
}

// MARK: - Capacity Content(容量)

/// 容量 tab:CapacityModule + 已用列表
struct CapacityContent: View {
    let monitor: HealthMonitor
    let settings: AppSettings
    /// v0.9.1 polish-O2:rename `primaryDisk` → `selectedDisk`(统一切盘概念)
    let selectedDisk: DiskInfo?

    var body: some View {
        let listShape = RoundedRectangle(cornerRadius: 20, style: .continuous)
        HStack(alignment: .top, spacing: 12) {
            CapacityModule(disk: selectedDisk ?? DiskInfo(
                bsdName: "—",
                volumeUUID: "empty",
                mountPoint: nil,
                isInternal: false,
                sizeBytes: 0
            ))
            .frame(minWidth: 200, idealWidth: 240, maxWidth: 260)

            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 6) {
                    Image(systemName: "internaldrive")
                        .font(.system(size: 11, weight: .regular))
                        .foregroundStyle(.tertiary)
                    Text(String(localized: "tab.capacity.listTitle", defaultValue: "ALL DISKS · CAPACITY"))
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .tracking(0.6)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 14)
                .padding(.top, 14)
                .padding(.bottom, 8)
                Divider()
                    .background(Color.white.opacity(0.04))

                if monitor.watchedDisks.isEmpty {
                    emptyList
                } else {
                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(spacing: 0) {
                            ForEach(monitor.watchedDisks) { disk in
                                capacityListRow(disk)
                                if disk.volumeUUID != monitor.watchedDisks.last?.volumeUUID {
                                    Divider()
                                        .background(Color.white.opacity(0.03))
                                        .padding(.horizontal, 14)
                                }
                            }
                        }
                    }
                }
            }
            .frame(minWidth: 220, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(CapacityListBackground(cornerRadius: 20))
            .overlay(listShape.stroke(Color.white.opacity(0.08), lineWidth: 1))
            .clipShape(listShape)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyList: some View {
        HStack {
            Spacer()
            Text(String(localized: "disk.empty", defaultValue: "No external disks"))
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .padding(.vertical, 24)
    }

    private func capacityListRow(_ disk: DiskInfo) -> some View {
        let total = disk.totalBytes.map { Int64($0) } ?? disk.sizeBytes
        let pct: Double = {
            guard let used = disk.usedBytes, total > 0 else { return 0 }
            return Double(used) / Double(total)
        }()
        let usedText: String = disk.usedBytes.map { ByteFormatter.bytes(Int64($0)) } ?? "—"
        let totalText: String = ByteFormatter.bytes(total)
        let pctText = disk.usedBytes == nil ? "—" : "\(Int((pct * 100).rounded()))%"
        return HStack(alignment: .center, spacing: 10) {
            Image(systemName: disk.isInternal ? "internaldrive" : "externaldrive")
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(.secondary)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(disk.displayName)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.themeFgDark)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text("\(usedText) / \(totalText)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(pctText)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(pct > 0.9 ? Color.dsCritical : (pct > 0.7 ? Color.dsWarning : Color.themeFgDark))
                .monospacedDigit()
                .fixedSize()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }
}

// MARK: - Power Content(功耗)

/// 功耗 tab:额定峰值卡 + Power States 阶梯 + 真实读写曲线（不是瓦特曲线）
struct PowerContent: View {
    let monitor: HealthMonitor
    let power: PowerService
    let settings: AppSettings
    let selectedDisk: DiskInfo?

    private var lang: String { settings.language }

    private var states: [NVMePowerState] {
        guard let uuid = selectedDisk?.volumeUUID else { return [] }
        return monitor.currentByUUID[uuid]?.nvmePowerStates ?? []
    }

    var body: some View {
        let _ = monitor.ioGeneration
        HStack(alignment: .top, spacing: 12) {
            if let primary = selectedDisk {
                PowerModule(power: power, diskBSDName: primary.bsdName)
                    .frame(maxWidth: 320)
            } else {
                PowerModule(power: power, diskBSDName: "—")
                    .frame(maxWidth: 320)
            }

            VStack(alignment: .leading, spacing: 10) {
                PowerStatesLadder(states: states, language: lang)
                VStack(alignment: .leading, spacing: 6) {
                    Text(L10n.t("tab.power.ioTitle", zh: "实时读写", en: "Live I/O", language: lang))
                        .font(.system(size: 11, weight: .medium))
                        .tracking(0.5)
                        .foregroundStyle(.secondary)
                    DualIOChart(
                        history: ioHistory,
                        showsAxes: true,
                        maxPoints: 180
                    )
                    .frame(maxWidth: .infinity, minHeight: 140, maxHeight: .infinity)
                    Text(L10n.t("tab.power.ioHint", zh: "这是 IO，不是瓦特。macOS 没有每盘实时功率。", en: "I/O, not watts. macOS has no per-disk wattmeter.", language: lang))
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
                .padding(12)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .glass(cornerRadius: 16)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var ioHistory: [HealthMonitor.IOHistoryPoint] {
        guard let uuid = selectedDisk?.volumeUUID else { return [] }
        return monitor.ioHistoryByUUID[uuid] ?? []
    }
}

/// Horizontal rated-power steps. Operational states amber; idle states muted.
struct PowerStatesLadder: View {
    let states: [NVMePowerState]
    let language: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.t("tab.power.states", zh: "功耗状态（额定）", en: "Power states (rated)", language: language))
                .font(.system(size: 11, weight: .medium))
                .tracking(0.4)
                .foregroundStyle(.secondary)
            if states.isEmpty {
                Text(L10n.t("tab.power.states.empty", zh: "这块盘没有 Power States 表。", en: "No power-state table on this disk.", language: language))
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            } else {
                HStack(alignment: .bottom, spacing: 6) {
                    ForEach(states) { st in
                        VStack(spacing: 4) {
                            Text(formatW(st.maxWatts))
                                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                                .foregroundStyle(st.operational ? Color.dsNormal : Color.secondary.opacity(0.55))
                                .lineLimit(1)
                                .minimumScaleFactor(0.7)
                            RoundedRectangle(cornerRadius: 3, style: .continuous)
                                .fill(st.operational ? Color.dsNormal.opacity(0.55) : Color.white.opacity(0.10))
                                .frame(height: barHeight(st))
                            Text("PS\(st.index)")
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(.tertiary)
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
                .frame(height: 72)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glass(cornerRadius: 16)
    }

    private func formatW(_ w: Double) -> String {
        if w >= 1 { return String(format: "%.1fW", w) }
        return String(format: "%.3fW", w)
    }

    private func barHeight(_ st: NVMePowerState) -> CGFloat {
        let peak = NVMePowerStateParser.peakWatts(from: states) ?? 1
        let ratio = max(0.08, min(1, st.maxWatts / max(peak, 0.001)))
        return 8 + ratio * 40
    }
}

// MARK: - SMART Content(SMART)

/// SMART tab:SMARTModule + 全字段表
/// v0.6.1 polish-J:右侧 10 行 ATA 占位换 10 行真 NVMe 字段(从 monitor.currentByUUID 取)
struct SMARTContent: View {
    let monitor: HealthMonitor
    /// v0.9.1 polish-O2:rename `primaryDisk` → `selectedDisk`(统一切盘概念)
    let selectedDisk: DiskInfo?

    var body: some View {
        // 双列会互相盖:左 SMARTModule 字段+描述溢出 maxHeight,右 REFERENCE 是同一份数据。
        // 单列 ScrollView,一张卡看完。
        ScrollView(.vertical, showsIndicators: false) {
            Group {
                if let primary = selectedDisk,
                   let smart = monitor.currentByUUID[primary.volumeUUID],
                   smart.hasSensorFields {
                    SMARTModule(smart: smart)
                } else {
                    smartPlaceholder
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .padding(.bottom, 8)
        }
    }

    private var smartPlaceholder: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "list.bullet.rectangle")
                    .font(.system(size: 18, weight: .light))
                    .foregroundStyle(.tertiary)
                Text(smartPlaceholderTitle)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let disk = selectedDisk {
                let id = disk.identityLine
                if !id.isEmpty {
                    Text(id)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let serial = disk.serialNumber, !serial.isEmpty {
                    Text("S/N  \(serial)")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
                if let fw = disk.firmwareRevision, !fw.isEmpty {
                    Text("FW   \(fw)")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(minHeight: 160)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(.regularMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
    }

    private var smartPlaceholderTitle: String {
        guard let disk = selectedDisk else {
            return String(localized: "tab.smart.noData", defaultValue: "No SMART data")
        }
        if disk.isUSBBridgeWithoutSMART {
            if disk.usbLinuxType?.hasPrefix("snt") == true {
                let chip = disk.bridgeChipName ?? disk.productName ?? "USB NVMe"
                return "\(chip) has SMART; macOS USB UAS does not pass it (Linux: -d \(disk.usbLinuxType ?? "sntasmedia"))"
            }
            return String(
                localized: "tab.smart.usbBridge",
                defaultValue: "USB bridge does not pass SMART — identity still captured"
            )
        }
        if disk.smartUnavailableKind == .pending {
            return String(
                localized: "module.temperature.waiting",
                defaultValue: "Appears in ~5s (first poll)"
            )
        }
        return String(localized: "tab.smart.noData", defaultValue: "No SMART data")
    }

}

/// v0.6.1 polish-J:SMART 字段行(name + 真值 + 描述 + 状态)

// MARK: - v0.8 polish-L:Link Content(TB4/PCIe/USB 协商 vs 期望)

/// Link tab:LinkHealthModule(主区撑开,跟 Temperature/Power 一致)
/// - 跟 SMARTContent 设计模式一样:左 Module flex / 右 list flex
/// - 暂时只显示左 Module(单列),右侧空着给后续 worker 扩"全盘 link table"
struct LinkContent: View {
    let monitor: HealthMonitor
    /// v0.9.1 polish-O2:rename `primaryDisk` → `selectedDisk`(统一切盘概念)
    let selectedDisk: DiskInfo?

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 12) {
                LinkHealthModule()
                    .frame(maxWidth: .infinity)
                    .fixedSize(horizontal: false, vertical: true)
                linkListPanel
            }
        }
    }

    /// 全盘 link 列表 — 720 主区右侧 flex 撑开
    /// - 每行:盘名 + BusProtocol + negotiated vs expected 状态点
    /// - 数据源:`monitor.watchedDisks[].linkSnapshot` + `.mountPoint`
    private var linkListPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 标题
            HStack(spacing: 6) {
                Image(systemName: "bolt.horizontal.fill")
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(.tertiary)
                Text(String(localized: "tab.link.listTitle", defaultValue: "ALL DISKS · LINK"))
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .tracking(0.8)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 8)
            Divider()
                .background(Color.white.opacity(0.04))

            if monitor.watchedDisks.isEmpty {
                HStack {
                    Spacer()
                    Text(String(localized: "disk.empty", defaultValue: "No external disks"))
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                    Spacer()
                }
                .padding(.vertical, 24)
            } else {
                VStack(spacing: 0) {
                    ForEach(monitor.watchedDisks) { disk in
                        linkListRow(disk)
                        if disk.volumeUUID != monitor.watchedDisks.last?.volumeUUID {
                            Divider()
                                .background(Color.white.opacity(0.03))
                                .padding(.horizontal, 16)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(
            CapacityListBackground(cornerRadius: 20)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
    }

    /// 单行 link 数据
    /// - 真实数据:monitor.watchedDisks[].linkSnapshot
    /// - 没 linkSnapshot → 显 "—"
    private func linkListRow(_ disk: DiskInfo) -> some View {
        let snap = disk.linkSnapshot
        let statusColor: Color = {
            guard let s = snap else { return Color.secondary.opacity(0.5) }
            return LinkHealthService.isDegraded(s) ? Color.dsWarning : Color.dsNormal
        }()
        let negotiatedText: String = {
            guard let s = snap,
                  let speed = s.negotiatedSpeedGTs,
                  let width = s.negotiatedWidth else { return "—" }
            return String(format: "%.1f GT/s ×%d", speed, width)
        }()
        let expectedText: String = {
            guard let s = snap,
                  let speed = s.expectedSpeedGTs,
                  let width = s.expectedWidth else { return "—" }
            return String(format: "%.0f GT/s ×%d", speed, width)
        }()
        return HStack(spacing: 8) {
            Image(systemName: disk.isInternal ? "internaldrive" : "externaldrive")
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(.secondary)
                .frame(width: 18)
            Text(disk.displayName)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.themeFgDark)
                .lineLimit(1)
                .layoutPriority(1)
            Spacer(minLength: 6)
            VStack(alignment: .trailing, spacing: 1) {
                Text(negotiatedText)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(statusColor)
                    .monospacedDigit()
                    .lineLimit(1)
                Text("exp \(expectedText)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            Circle()
                .fill(statusColor)
                .frame(width: 5, height: 5)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

// MARK: - v0.8 polish-L:Test Content(SMART self-test 状态 + Run CTA)

/// Test tab:DiagnosticTestModule + 全盘 self-test 列表
/// - 设计模式:跟 SMARTContent 一致(左 Module flex / 右 列表 flex)
struct TestContent: View {
    let monitor: HealthMonitor
    /// v0.9.1 polish-O2:rename `primaryDisk` → `selectedDisk`(统一切盘概念)
    let selectedDisk: DiskInfo?
    @Environment(AppSettings.self) private var settings

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 12) {
                DiagnosticTestModule(role: .panel)
                    .frame(maxWidth: .infinity)
                    .fixedSize(horizontal: false, vertical: true)
                testListPanel
            }
        }
    }

    /// 全盘 self-test 列表
    /// - 每行:盘名 + short/long 状态 + Run CTA
    /// - 数据源:`monitor.watchedDisks[].lastTest`
    private var testListPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 标题
            HStack(spacing: 6) {
                Image(systemName: "checkmark.shield")
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(.tertiary)
                Text(L10n.t("tab.test.listTitle", zh: "全部磁盘 · 自检", en: "ALL DISKS · SELF-TEST", language: settings.language))
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .tracking(0.8)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 8)
            Divider()
                .background(Color.white.opacity(0.04))

            if monitor.watchedDisks.isEmpty {
                HStack {
                    Spacer()
                    Text(String(localized: "disk.empty", defaultValue: "No external disks"))
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                    Spacer()
                }
                .padding(.vertical, 24)
            } else {
                VStack(spacing: 0) {
                    ForEach(monitor.watchedDisks) { disk in
                        testListRow(disk)
                        if disk.volumeUUID != monitor.watchedDisks.last?.volumeUUID {
                            Divider()
                                .background(Color.white.opacity(0.03))
                                .padding(.horizontal, 16)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(
            CapacityListBackground(cornerRadius: 20)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
    }

    /// 单行 self-test 数据
    /// - 显示 short + long 状态简写
    /// - 状态颜色按 SelfTestResult case 区分
    private func testListRow(_ disk: DiskInfo) -> some View {
        let test = disk.lastTest
        let shortStatus: DiagnosticTestService.SelfTestResult = test?.lastShortTest ?? .idle
        let longStatus: DiagnosticTestService.SelfTestResult = test?.lastLongTest ?? .idle
        return HStack(spacing: 8) {
            Image(systemName: disk.isInternal ? "internaldrive" : "externaldrive")
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(disk.displayName)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.themeFgDark)
                    .lineLimit(1)
                    .layoutPriority(1)
                if disk.isUSBBridgeWithoutSMART {
                    Text(L10n.t("module.test.usbNever", zh: "USB 桥不能跑自检", en: "USB bridge: no self-test", language: settings.language))
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                } else if let at = test?.capturedAt {
                    Text(Self.relative(at, lang: settings.language))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 6)
            Text("S \(Self.statusText(for: shortStatus))")
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(Self.statusColor(for: shortStatus))
                .lineLimit(1)
            Text("L \(Self.statusText(for: longStatus))")
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(Self.statusColor(for: longStatus))
                .lineLimit(1)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    /// SelfTestResult → 1 字母简写
    private static func statusText(for r: DiagnosticTestService.SelfTestResult) -> String {
        switch r {
        case .passed:  return "PASS"
        case .failed:  return "FAIL"
        case .running: return "RUN"
        case .aborted: return "ABRT"
        case .idle:    return "—"
        }
    }

    private static func relative(_ date: Date, lang: String) -> String {
        let s = Date().timeIntervalSince(date)
        if s < 60 { return L10n.t("module.drop.just", zh: "刚刚", en: "just now", language: lang) }
        if s < 3600 { return "\(Int(s / 60))m" }
        if s < 86_400 { return "\(Int(s / 3600))h" }
        return "\(Int(s / 86_400))d"
    }

    /// SelfTestResult → 颜色
    private static func statusColor(for r: DiagnosticTestService.SelfTestResult) -> Color {
        switch r {
        case .passed:  return Color.dsNormal
        case .failed:  return Color.dsDanger
        case .running: return Color.dsWarning
        case .aborted: return .secondary
        case .idle:    return Color.secondary.opacity(0.5)
        }
    }

}

// MARK: - Shared:玻璃背景(列表专用)

/// 列表 / 解释面板 玻璃背景(容量 tab 已用列表 / SMART tab 字段说明 / Link / Test tab 用)
struct CapacityListBackground: View {
    var cornerRadius: CGFloat = 20

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(.regularMaterial)
            // 顶边高光
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(
                    LinearGradient(
                        stops: [
                            .init(color: Color.white.opacity(0.06), location: 0),
                            .init(color: .clear, location: 0.5)
                        ],
                        startPoint: .top,
                        endPoint: .center
                    )
                )
                .blendMode(.overlay)
            // 35mm 噪点
            NoiseOverlay()
        }
    }
}

// MARK: - v0.8 polish-M:Bench Content(custom Swift POSIX I/O 测速显示)

/// Bench tab:BenchmarkModule(主区撑开,跟 Temperature/Power 一致)
/// - 跟 SMARTContent 设计模式一样:左 Module flex / 右 list flex
/// - 暂时只显示左 Module(单列),右侧空着给后续 worker 扩"全盘 benchmark table"
struct BenchContent: View {
    let monitor: HealthMonitor
    /// v0.9.1 polish-O2:rename `primaryDisk` → `selectedDisk`(统一切盘概念)
    let selectedDisk: DiskInfo?

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 12) {
                BenchmarkModule()
                    .frame(maxWidth: .infinity)
                    .fixedSize(horizontal: false, vertical: true)
                benchListPanel
            }
        }
    }

    /// 全盘 benchmark 列表 — 720 主区右侧 flex 撑开
    /// - 每行:盘名 + W/R MBps + 状态点(降级琥珀 / 正常米白)
    /// - 数据源:`monitor.watchedDisks[].benchmark`
    private var benchListPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 标题
            HStack(spacing: 6) {
                Image(systemName: "gauge.with.dots.needle.67percent")
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(.tertiary)
                Text(String(localized: "tab.bench.listTitle", defaultValue: "ALL DISKS · BENCH"))
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .tracking(0.8)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 8)
            Divider()
                .background(Color.white.opacity(0.04))

            if monitor.watchedDisks.isEmpty {
                HStack {
                    Spacer()
                    Text(String(localized: "disk.empty", defaultValue: "No external disks"))
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                    Spacer()
                }
                .padding(.vertical, 24)
            } else {
                VStack(spacing: 0) {
                    ForEach(monitor.watchedDisks) { disk in
                        benchListRow(disk)
                        if disk.volumeUUID != monitor.watchedDisks.last?.volumeUUID {
                            Divider()
                                .background(Color.white.opacity(0.03))
                                .padding(.horizontal, 16)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(
            CapacityListBackground(cornerRadius: 20)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
    }

    /// 单行 benchmark 数据
    /// - 真实数据:monitor.watchedDisks[].benchmark
    /// - 没 benchmark → 显 "—"
    private func benchListRow(_ disk: DiskInfo) -> some View {
        let bench = disk.benchmark
        let writeText: String = {
            guard let b = bench, let w = b.writeMBps else { return "—" }
            return String(format: "%.0f", w)
        }()
        let readText: String = {
            guard let b = bench, let r = b.readMBps else { return "—" }
            return String(format: "%.0f", r)
        }()
        let statusColor: Color = {
            guard let b = bench, let w = b.writeMBps,
                  let expected = b.expectedWriteMBps, expected > 0 else {
                return Color.secondary.opacity(0.5)
            }
            return w < expected * 0.7 ? Color.dsWarning : Color.dsNormal
        }()
        return HStack(spacing: 8) {
            Image(systemName: disk.isInternal ? "internaldrive" : "externaldrive")
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(.secondary)
                .frame(width: 18)
            Text(disk.displayName)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.themeFgDark)
                .lineLimit(1)
                .layoutPriority(1)
            Spacer(minLength: 6)
            Text("W \(writeText)")
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(statusColor)
                .lineLimit(1)
            Text("R \(readText)")
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(statusColor)
                .lineLimit(1)
            Circle()
                .fill(statusColor)
                .frame(width: 5, height: 5)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

// MARK: - v0.8 polish-M:FS Content(diskutil verifyVolume 显示)

/// FS tab:FSIntegrityModule(主区撑开,跟 Temperature/Power 一致)
/// - 跟 LinkContent 设计模式一样:左 Module flex / 右 list flex
struct FSContent: View {
    let monitor: HealthMonitor
    /// v0.9.1 polish-O2:rename `primaryDisk` → `selectedDisk`(统一切盘概念)
    let selectedDisk: DiskInfo?

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 12) {
                FSIntegrityModule()
                    .frame(maxWidth: .infinity)
                    .fixedSize(horizontal: false, vertical: true)
                fsListPanel
            }
        }
    }

    /// 全盘 FS integrity 列表
    /// - 每行:盘名 + IntegrityStatus 简写 + 时间戳
    /// - 数据源:`monitor.watchedDisks[].integrity`
    private var fsListPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 标题
            HStack(spacing: 6) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(.tertiary)
                Text(String(localized: "tab.fs.listTitle", defaultValue: "ALL DISKS · FS INTEGRITY"))
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .tracking(0.8)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 8)
            Divider()
                .background(Color.white.opacity(0.04))

            if monitor.watchedDisks.isEmpty {
                HStack {
                    Spacer()
                    Text(String(localized: "disk.empty", defaultValue: "No external disks"))
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                    Spacer()
                }
                .padding(.vertical, 24)
            } else {
                VStack(spacing: 0) {
                    ForEach(monitor.watchedDisks) { disk in
                        fsListRow(disk)
                        if disk.volumeUUID != monitor.watchedDisks.last?.volumeUUID {
                            Divider()
                                .background(Color.white.opacity(0.03))
                                .padding(.horizontal, 16)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(
            CapacityListBackground(cornerRadius: 20)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
    }

    /// 单行 integrity 数据
    /// - 显示 IntegrityStatus 简写(OK / WARN / FAIL / ...)
    /// - 状态颜色按 IntegrityStatus case 区分
    private func fsListRow(_ disk: DiskInfo) -> some View {
        let integrity = disk.integrity
        let status: FSIntegrityService.IntegrityStatus = integrity?.status ?? .unknown
        return HStack(spacing: 8) {
            Image(systemName: disk.isInternal ? "internaldrive" : "externaldrive")
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(.secondary)
                .frame(width: 18)
            Text(disk.displayName)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.themeFgDark)
                .lineLimit(1)
                .layoutPriority(1)
            Spacer(minLength: 6)
            Text(Self.statusText(for: status))
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(Self.statusColor(for: status))
                .lineLimit(1)
            Circle()
                .fill(Self.statusColor(for: status))
                .frame(width: 5, height: 5)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    /// IntegrityStatus → 4 字母简写
    private static func statusText(for s: FSIntegrityService.IntegrityStatus) -> String {
        switch s {
        case .verified:  return "OK"
        case .warning:   return "WARN"
        case .failed:    return "FAIL"
        case .verifying: return "..."
        case .unknown:   return "—"
        }
    }

    /// IntegrityStatus → 颜色
    private static func statusColor(for s: FSIntegrityService.IntegrityStatus) -> Color {
        switch s {
        case .verified:  return Color.dsNormal    // 琥珀(主人硬规则:不引入绿)
        case .warning:   return Color.dsWarning
        case .failed:    return Color.dsDanger
        case .verifying: return Color.dsWarning
        case .unknown:   return Color.secondary.opacity(0.5)
        }
    }
}
