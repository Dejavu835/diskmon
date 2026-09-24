import SwiftUI

/// EditMode 共享 modifier + View v0.9 polish-N2
/// - iOS Control Center 风格:长按进入 EditMode / jiggle 抖动 / 拖动重排 / 隐藏 × / AddModulesSheet
/// - 复用给 `OverviewContent` 渲染每 module 卡 + `PopoverView` 顶栏长按入口
/// - 不动:`PreferencesView` / 5 Preferences 子 View / `AppSettings` 已有 key 之外 /
///   `Localizable.strings` / 现有 Module 主体 / `GlassBackground`
///
/// === 设计选择 ===
/// - **共享 modifier**:EditModeModuleOverlay / JiggleEffect 都做成 `ViewModifier` + extension
///   → PopoverTabContent / 后续其他 tab 复用同一套规范
/// - **TimelineView(.animation)**:60Hz 驱动 jiggle rotation,关闭 Edit 立即停止(swiftUI 自动
///   重建 modifier 树,TimelineView 被移除,没有 Timer leak)
/// - **静态 moduleRegistry**:11 module key 总表 + icon + 描述,跟 `AppSettings.moduleOrder` 同步
///   → AddModulesSheet 一次渲染完所有 module,已显灰显 + "Visible" 标签,未显 "Add" 按钮
/// - **不做 full drag-follow**:模块卡在拖动时只抬升(scale 1.05 + shadow + zIndex),
///   不跟随手指移动(简化 layout,避免 custom Layout + hitTest 复杂度)
/// - **真实持久化**:setModuleOrder / setHiddenModules 仍调,AppSettings didChange 已有,
///   .animation(_:value:settings.moduleOrder) 在 grid 上驱动 0.3s 重排动画
///
/// === 不做 ===
/// - 不 mock 数据 / 不引入新 UserDefaults key / 不写 Localizable.strings
/// - 不改 5 Preferences 子 View / 不改 Module 主体 / 不改 AppSettings

// MARK: - ModuleRegistry(11 module 总表)

/// v0.9 polish-N2:11 module key 总表(全 11 module 显示名 + icon + 描述)
/// - 顺序:跟默认 `AppSettings.moduleOrder` 一致 + "smart"(默认未在 order,需手动 add)
/// - `AddModulesSheet` 用此字典渲染 2 列 LazyVGrid
/// - tuple 不用 struct(简单 + 静态表,named tuple 字段已经够读)
enum ModuleRegistry {
    /// 11 module 显示名 / SF Symbol / 一行描述
    /// - name:中文(主人审美优先,跟 .localized 互斥,这里是直接中文)
    /// - icon:SF Symbol(任务硬规则:不用 emoji)
    /// - desc:1 行简短说明(给 AddModulesSheet 玻璃卡用)
    static let moduleDisplayNames: [String: (name: String, icon: String, desc: String)] = [
        "allio":      ("全部读写", "waveform.path.ecg",           "所有外接盘实时读写"),
        "health":     ("健康度",   "heart.fill",                  "整体健康 + SMART 摘要"),
        "temperature": ("温度",    "thermometer.medium",          "最热盘温度 + 趋势"),
        "capacity":   ("容量",     "chart.pie.fill",              "已用 / 空闲 / 系统"),
        "power":      ("功耗",     "bolt.fill",                   "主盘功耗 + smartctl"),
        "smart":      ("SMART",    "list.bullet.rectangle",       "完整 NVMe 字段"),
        "disklist":   ("磁盘列表", "externaldrive.fill",          "watched 盘 mini 列表"),
        "chartmini":  ("迷你图表", "chart.line.uptrend.xyaxis",   "1H/24H 折线"),
        "link":       ("链接健康", "cable.connector",             "TB4/PCIe/USB 协商"),
        "test":       ("自检",     "checkmark.shield",            "SMART self-test 结果"),
        "bench":      ("性能",     "speedometer",                 "顺序写读 MB/s"),
        "fs":         ("文件系统", "folder.fill.badge.gearshape", "diskutil verifyVolume"),
        "manage":     ("磁盘管理", "wrench.and.screwdriver", "格式化 / 推出外接盘"),
        "drop":       ("掉盘",     "externaldrive.badge.xmark", "意外掉盘 vs 推出")
    ]

    /// 11 module 顺序(AddModulesSheet 用此顺序渲染)
    /// - 跟 AppSettings.moduleOrder 默认值一致 + "smart"(默认未在 order)
    static let defaultOrder: [String] = [
        "allio", "health", "temperature", "capacity", "power",
        "disklist", "manage", "drop", "chartmini", "link", "test", "bench", "fs", "smart"
    ]
}

// MARK: - EditMode Module Overlay(隐藏 × 按钮 overlay)

/// v0.9 polish-N2:EditMode 隐藏按钮 overlay modifier
/// - Edit 模式时:左上角 overlay `EditModeBadge`(琥珀背景 `xmark.circle.fill` 17pt)
/// - 隐藏退场动画:点 × 触发 isHiding → 0.2s scale 1.0 → 0.0 + opacity 1.0 → 0.0
///   → 0.2s 后调 onHide() → setHiddenModules 真正从 visible 移除(ForEach 自动 dismiss)
/// - 单独管 isHiding 状态:modifier 内部 @State,生命周期跟 moduleView 一致
struct EditModeModuleOverlay: ViewModifier {
    let key: String
    let isEditing: Bool
    let onHide: () -> Void

    /// 隐藏退场中(true 时 overlay badge 消失 + 卡 0.2s scale 1.0 → 0.0)
    @State private var isHiding: Bool = false

    func body(content: Content) -> some View {
        content
            .scaleEffect(isHiding ? 0.0 : 1.0)
            .opacity(isHiding ? 0.0 : 1.0)
            .animation(.easeIn(duration: 0.2), value: isHiding)
            .overlay(alignment: .topLeading) {
                if isEditing && !isHiding {
                    EditModeBadge(key: key) {
                        // 触发退场动画 → 0.2s 后真正 hide
                        withAnimation(.easeIn(duration: 0.2)) {
                            isHiding = true
                        }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                            onHide()
                            // 备:重置 isHiding(下次如果同 key 重新显示,modifier 重新创建,
                            //   但保险起见让状态干净)
                            isHiding = false
                        }
                    }
                    .padding(6)
                    .transition(.scale.combined(with: .opacity))
                }
            }
    }
}

extension View {
    /// EditMode 隐藏按钮 overlay(iOS CC 风格)
    /// - Edit 模式:左上角琥珀 `xmark.circle.fill` 17pt
    /// - 点 ×:卡 0.2s scale 1.0 → 0.0 退场,onHide 触发(由 caller 调 setHiddenModules)
    /// - 非 Edit 模式:无 overlay,scale 1.0
    /// - Parameter key:module key(给 EditModeBadge 做 help tooltip 区分用)
    /// - Parameter isEditing:Edit 模式开关(由 PopoverView isEditing 注入)
    /// - Parameter onHide:点 × 退场动画结束后触发
    func editModeModuleOverlay(
        key: String,
        isEditing: Bool,
        onHide: @escaping () -> Void
    ) -> some View {
        modifier(EditModeModuleOverlay(key: key, isEditing: isEditing, onHide: onHide))
    }
}

// MARK: - EditModeBadge(琥珀 × 按钮)

/// v0.9 polish-N2:Edit 模式 × 隐藏按钮
/// - iOS CC 风格:`xmark.circle.fill` SF Symbol 17pt + 琥珀前景(SF Symbol 自然 fill = 实心圆 + 镂空 X)
/// - hover 反馈:0.15s easeOut,scale 1.0 → 1.08(轻)
struct EditModeBadge: View {
    let key: String
    let onTap: () -> Void

    @State private var isHovered: Bool = false

    var body: some View {
        Button {
            onTap()
        } label: {
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 17, weight: .semibold))
                // 琥珀前景 → SF Symbol 自然 fill = 琥珀实心圆 + 镂空 X(玻璃卡透出)
                .foregroundStyle(Color.dsNormal)
                .scaleEffect(isHovered ? 1.08 : 1.0)
                .shadow(color: .black.opacity(0.18), radius: 2, y: 1)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(String(
            localized: "popover.edit.hide",
            defaultValue: "Hide this module"
        ))
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
        .accessibilityLabel(String(
            localized: "popover.edit.hide",
            defaultValue: "Hide this module"
        ))
    }
}

// MARK: - Jiggle Effect(iOS CC 抖动)

/// v0.9 polish-N2:jiggle 抖动 modifier
/// - Edit 模式时:`rotationEffect(.degrees(sin(t * 8) * 0.6))` 2-3° 高频 + scaleEffect(0.96) 抬升
/// - TimelineView(.animation) 60Hz 驱动;非 Edit 模式:modifier 不挂 TimelineView,零开销
/// - pauseScale:拖动时跳过 0.96 scale(让 drag 1.05 scale 单独生效,避免 stack 后 1.008)
/// v0.9.1 polish-O2:`pauseScale` → `isDragging`,**真停 rotation + scale 两个**
/// - 旧 bug:拖动时只暂停 scale,rotation 仍 60Hz 抖,跟 drag 视觉冲突(卡感觉在颤)
///   → 主人反馈"jiggle stuck" — 实际不是 stuck,是被 rotation 持续叠加
/// - 修后:拖动时 `isEditing && !isDragging` 表达式整体 → false,scale=1.0,rotation=0°
///   drag 抬升的 1.05 scale 干净生效,松手立即恢复 jiggle
/// - 驱动方式:从 `TimelineView(.animation)` 改为 `@State now: Date` + `.task(id: isEditing)`
///   16ms(≈60Hz)sleep 刷新 `now` — 让 rotation 和 scale 共用同一个 `now`(动画一致性更好)
struct JiggleEffect: ViewModifier {
    let isEditing: Bool
    /// v0.9.1 polish-O2:`pauseScale`(只停 scale)→ `isDragging`(停 scale + rotation)
    /// - 拖动时整组都停,避免 rotation 跟 drag 抬升打架
    let isDragging: Bool

    /// v0.9.1 polish-O2:统一时间源 — scale 和 rotation 都基于 `now`
    @State private var now: Date = Date()

    func body(content: Content) -> some View {
        // 顶层 content 修饰:scale + rotation 都根据 (isEditing && !isDragging) 决定
        // - 真停 jiggle:拖动时 isEditing=true && isDragging=true → 整体停(scale=1.0, rotation=0°)
        // - 性能:非 Edit 模式不挂 .task(不 16ms 刷新),零开销
        let active = isEditing && !isDragging
        content
            .scaleEffect(active ? 0.96 : 1.0)
            .rotationEffect(.degrees(active ? sin(now.timeIntervalSinceReferenceDate * 8) * 0.6 : 0), anchor: .center)
            // v0.9.1 polish-O2:用 `now` 驱动 60Hz 动画 — 1/60 = 16ms
            // - Edit 模式:linear(1/60) 让 rotation 跟 sin 同步,无 lag
            // - 非 Edit 模式:default 让 modifier 退出时回弹到位
            .animation(isEditing ? .linear(duration: 1.0 / 30.0) : .default, value: now)
            .onAppear { now = Date() }
            // v0.9.1 polish-O2:Edit 模式启动 60Hz 刷新 task
            // - task(id: isEditing):isEditing 切换 → 取消旧 task / 启动新 task
            // - sleep 16ms + 更新 now → 触发 .animation 跑新帧
            // - Task.isCancelled 自动捕获,modifier 卸载时立即停(无 Timer leak)
            .task(id: isEditing) {
                guard isEditing else { return }
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(33))
                    now = Date()
                }
            }
    }
}

extension View {
    /// Edit 模式时 jiggle 抖动(iOS CC 风格)
    /// - rotationEffect `sin(t * 8) * 0.6` 2-3° 高频
    /// - scaleEffect(0.96) 抬升(被 isDragging 跳过给 drag scale 让位)
    /// - `@State now` + `.task(id: isEditing)` 60Hz 驱动,modifier 卸载即停
    /// - v0.9.1 polish-O2:`pauseScale` → `isDragging`,真停 rotation + scale
    /// - Parameter isEditing:Edit 模式开关
    /// - Parameter isDragging:拖动中开关(供 OverviewContent 传入 `draggedKey == key`)
    func jiggleEffect(isEditing: Bool, isDragging: Bool = false) -> some View {
        modifier(JiggleEffect(isEditing: isEditing, isDragging: isDragging))
    }
}

// MARK: - AddModulesSheet(iOS CC 风格全 11 module 总表)

/// v0.9 polish-N2:Edit Mode 添加模块 sheet(替代 `RestoreModulesSheet`)
/// - 全 11 module 总表(LazyVGrid 2 列 + 玻璃卡 160×80)
/// - 已显 module 灰显 + "Visible" 标签
/// - 未显 module 显示 "Add" 按钮 → onAdd callback
/// - 也支持"已显模块点 Hide 隐藏"?:不做(spec 只要求 Add,已显灰显即可)
struct AddModulesSheet: View {
    let settings: AppSettings
    let onAdd: (String) -> Void

    @Environment(\.dismiss) private var dismiss

    /// 11 module key 顺序(ModuleRegistry.defaultOrder)
    private static let allKeys: [String] = ModuleRegistry.defaultOrder

    /// 2 列 LazyVGrid(每列 flexible + 10pt spacing → 360 sheet 宽度 / 2 = 170pt 一列)
    /// - spec 要求 160×80 卡;10pt 间距,正好 2 列
    private let columns: [GridItem] = [
        GridItem(.flexible(), spacing: 10),
        GridItem(.flexible(), spacing: 10)
    ]

    var body: some View {
        VStack(spacing: 0) {
            // 标题栏
            HStack(spacing: 8) {
                Image(systemName: "square.grid.2x2.fill")
                    .font(.system(size: 14, weight: .regular))
                    .foregroundStyle(Color.dsNormal)
                Text(String(
                    localized: "popover.edit.sheetTitle",
                    defaultValue: "Edit Modules"
                ))
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.themeFgDark)
                Spacer()
                Button {
                    dismiss()
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
            Divider().background(Color.white.opacity(0.06))

            // 11 module 2 列 LazyVGrid
            ScrollView(.vertical, showsIndicators: false) {
                LazyVGrid(columns: columns, spacing: 10) {
                    ForEach(Self.allKeys, id: \.self) { key in
                        moduleCell(key)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 14)
            }
        }
        .frame(width: 380, height: 580)
        .background(.regularMaterial)
    }

    /// 单个 module 玻璃卡(160×80)
    /// - 已显:opacity 0.55 + "Visible" 标签
    /// - 未显:琥珀 "Add" 按钮 + onAdd 触发
    /// - 玻璃卡:themeBgElevated 0.6 + 1px 0.08 白边 + 8pt 圆角
    private func moduleCell(_ key: String) -> some View {
        let info = ModuleRegistry.moduleDisplayNames[key]
        let isVisible = !settings.hiddenModules.contains(key)
            && settings.moduleOrder.contains(key)

        return HStack(spacing: 10) {
            // 图标(琥珀 / 灰 secondary 0.5)
            Image(systemName: info?.icon ?? "square.dashed")
                .font(.system(size: 18, weight: .regular))
                .foregroundStyle(isVisible ? AnyShapeStyle(Color.dsNormal) : AnyShapeStyle(Color.secondary.opacity(0.5)))
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(info?.name ?? key)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(isVisible ? AnyShapeStyle(Color.themeFgDark) : AnyShapeStyle(Color.secondary))
                    .lineLimit(1)
                Text(info?.desc ?? "")
                    .font(.system(size: 9.5))
                    .foregroundStyle(AnyShapeStyle(Color.secondary.opacity(0.6)))
                    .lineLimit(2)
                    .truncationMode(.tail)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // 右侧:Visible 标签 或 Add 按钮
            if isVisible {
                Text(String(
                    localized: "popover.edit.visible",
                    defaultValue: "Visible"
                ))
                .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                .tracking(0.5)
                .foregroundStyle(AnyShapeStyle(Color.secondary.opacity(0.6)))
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(
                    Capsule()
                        .fill(Color.themeBgSunken.opacity(0.6))
                )
            } else {
                Button {
                    onAdd(key)
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "plus")
                            .font(.system(size: 9, weight: .bold))
                        Text(String(
                            localized: "popover.edit.add",
                            defaultValue: "Add"
                        ))
                        .font(.system(size: 10, weight: .medium))
                    }
                    .foregroundStyle(Color.dsNormal)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(Color.dsNormal.opacity(0.10))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .stroke(Color.dsNormal.opacity(0.28), lineWidth: 0.5)
                    )
                }
                .buttonStyle(.plain)
                .help(String(
                    localized: "popover.edit.add.help",
                    defaultValue: "Add this module"
                ))
            }
        }
        .frame(height: 80)
        .padding(.horizontal, 10)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.themeBgElevated.opacity(0.6))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
        .opacity(isVisible ? 0.55 : 1.0)
    }
}
