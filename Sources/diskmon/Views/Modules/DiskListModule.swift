import SwiftUI

/// 磁盘列表 mini 模块 v0.4.0 wave-4F(高级交互规范版)
/// v0.6.1 polish-G:状态点从 Circle → SF Symbol health dot(读 HealthPredictor)
///
/// 单一职责:接收 `HealthMonitor` + `HealthPredictor` → 渲染 220×180 玻璃卡内最多 3 盘 mini 列表
///   - 每行:状态 SF Symbol + 盘名(短名) + 温度数字
///   - 选中态:琥珀背景高亮(0.12 alpha)+ 1px 右侧琥珀 border
///   - hover 态:1px 右侧琥珀 border
///   - 点击:切换 `monitor.selectedDiskUUID` → 影响 ChartMiniModule / DiskDetailView
///
/// === 设计选择(高级交互规范) ===
/// - **状态点 v0.6.1 polish-G**:从 `Circle` (5px 圆点) → SF Symbol(11pt)
///   - `.none`     → "checkmark.circle.fill"(健康)
///   - `.warning`  → "exclamationmark.triangle.fill"
///   - `.critical` → "xmark.octagon.fill"
///   - `.danger`   → "exclamationmark.octagon.fill"
///   - 颜色走 HealthWarning.color(`.dsNormal`/`.dsWarning`/`.dsCritical`/`.dsDanger`)
///   - 不再走 `evaluate(smart:)`(老逻辑) / 直接读 `HealthPredictor.warnings[uuid]`
///   - 这样 SMART bit0/bit4 / mediaErrors / trend 加速 / 命终都正确反映
/// - **温度数字**:`SF Mono` 11pt 文字次色,selected 时跟主色同色
/// - **盘名**:system 11pt medium,长名省略号
/// - **hover / focus / press 规范**:与 HealthOverviewModule 一致(整卡 hover + 1px border)
/// - **空态**:`String(localized: "disk.empty", defaultValue: ...)`(跟 DiskPickerView 共用 key)
/// - **超出 3 盘**:"+N more" 提示
///
/// === 不做 ===
/// - 不在 UI 直接跑 `smartctl`
/// - 不写 SwiftData
/// - 不动 `GlassBackground.swift` / 5 Preferences 子 View / `AppSettings.swift` /
///   `Localizable.strings`
struct DiskListModule: View {
    /// v0.4.0 polish-D:tab 切换标识(总览 tab,作为 mini 列表展示)
    enum Detail { case overview, temperature, capacity, power, smart }
    static let moduleTab: Detail = .overview

    @Environment(HealthMonitor.self) private var monitor
    /// v0.6.1 polish-G:接 HealthPredictor,状态点从 Circle 改 SF Symbol
    @Environment(HealthPredictor.self) private var predictor

    // MARK: - 交互状态

    @State private var isCardHovered: Bool = false
    @State private var isPressed: Bool = false
    @FocusState private var isFocused: Bool
    @State private var hoveredRowUUID: String?

    var body: some View {
        cardBody
            // v0.4.0 polish-C:自适应 min/ideal/max(配合 PopoverView LazyVGrid adaptive)
            .frame(minWidth: 180, idealWidth: 220, maxWidth: 280,
                   minHeight: 140, idealHeight: 180, maxHeight: .infinity)
            // 玻璃底 — v0.4.0 polish-B:真液态玻璃 + 35mm 噪点(走 `.glass(withNoise: true)` 统一接口)
            // - macOS 26+ 走 `backgroundExtensionEffect()`(系统级液态玻璃)
            // - macOS 14-25 走 NSVisualEffectView(`.popover` + `vibrantDark`)兜底
            // - BG + 1px 边 + 顶高光 + 阴影都在 modifier 里
            // - 旧"按下时阴影收缩"在统一接口里不保留(用户硬规则:同一接口,不加 press state 参数)
            .glass(cornerRadius: 20, withNoise: true)
            .focusable()
            .focusEffectDisabled()
            .focused($isFocused)
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(Color.dsNormal, lineWidth: isFocused ? 2 : 0)
                    .padding(isFocused ? 2 : 0)
                    .allowsHitTesting(false)
            )
            .scaleEffect(isPressed ? 0.99 : 1.0)
            .offset(y: isPressed ? 1 : 0)
            .simultaneousGesture(
                LongPressGesture(minimumDuration: 0)
                    .onChanged { _ in isPressed = true }
                    .onEnded { _ in isPressed = false }
            )
            .onHover { isCardHovered = $0 }
            .animation(
                .timingCurve(0.2, 0.8, 0.2, 1, duration: 0.3),
                value: isCardHovered
            )
            .animation(.easeOut(duration: 0.15), value: isFocused)
            .animation(.easeInOut(duration: 0.12), value: isPressed)
            .animation(.easeInOut(duration: 0.18), value: hoveredRowUUID)
    }

    // MARK: - 卡片本体

    private var cardBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            // === 顶部:小标签 "DISKS" ===
            HStack(spacing: 4) {
                Image(systemName: "externaldrive.fill")
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(.tertiary)
                Text(String(localized: "module.disklist.title", defaultValue: "DISKS"))
                    .font(.system(size: 11, weight: .medium, design: .default))
                    .tracking(0.6)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 2)

            Spacer(minLength: 4)

            // === 中部:最多 3 行 ===
            if monitor.watchedDisks.isEmpty {
                emptyView
            } else {
                VStack(spacing: 2) {
                    ForEach(displayDisks, id: \.volumeUUID) { disk in
                        diskRow(disk)
                    }
                    if monitor.watchedDisks.count > 3 {
                        Text(String(
                            format: String(
                                localized: "module.disklist.more",
                                defaultValue: "+%d more"
                            ),
                            monitor.watchedDisks.count - 3
                        ))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 6)
                        .padding(.top, 2)
                    }
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 14)
        // v0.4.0 polish-C:让 cardBody 填满外层 frame(min/ideal/max)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: - 单行

    @ViewBuilder
    private func diskRow(_ disk: DiskInfo) -> some View {
        let smart = monitor.currentByUUID[disk.volumeUUID]
        // v0.6.1 polish-G:接 HealthPredictor 字典(替代 evaluate(smart:) 老逻辑)
        let warning = predictor.warning(forDiskUUID: disk.volumeUUID)
        let temp = smart?.celsius ?? 0
        let isSelected = monitor.selectedDisk?.volumeUUID == disk.volumeUUID
        let isHovered = hoveredRowUUID == disk.volumeUUID
        let tempColor: Color = isSelected ? Color.dsNormal : warning.color

        Button {
            monitor.selectedDiskUUID = disk.volumeUUID
        } label: {
            HStack(spacing: 6) {
                // v0.6.1 polish-G:状态点从 Circle 改 SF Symbol
                // - 11pt SF Symbol(系统 symbol,跟主人审美"克制 + 高级"一致)
                // - 颜色按 HealthWarning 等级
                Image(systemName: warning.sfSymbol)
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(warning.color)
                    .frame(width: 14)
                Text(displayName(for: disk))
                    .font(.system(size: 11, weight: isSelected ? .semibold : .medium))
                    .foregroundStyle(isSelected ? Color.dsNormal : Color.themeFgDark)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 4)
                Text(rowTrailing(disk, temp: temp))
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(tempColor)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(isSelected ? Color.dsNormal.opacity(0.12) : Color.clear)
            )
            .overlay(
                // 1px 右侧琥珀 border(任务:selected / hover 都显)
                HStack {
                    Spacer()
                    Rectangle()
                        .fill(Color.dsNormal)
                        .frame(width: 1)
                        .opacity(isSelected || isHovered ? 0.7 : 0)
                }
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            if hovering {
                hoveredRowUUID = disk.volumeUUID
            } else if hoveredRowUUID == disk.volumeUUID {
                hoveredRowUUID = nil
            }
        }
    }

    // MARK: - 空态

    private var emptyView: some View {
        HStack {
            Spacer()
            Text(String(localized: "disk.empty", defaultValue: "No external disks"))
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .padding(.vertical, 4)
    }

    // MARK: - 派生

    private var displayDisks: [DiskInfo] {
        Array(monitor.watchedDisks.prefix(3))
    }

    private func displayName(for disk: DiskInfo) -> String {
        disk.displayName
    }

    private func rowTrailing(_ disk: DiskInfo, temp: Int) -> String {
        if temp > 0 { return "\(temp)°" }
        let speed = disk.interfaceSpeedLabel
        if speed != "—" { return speed.replacingOccurrences(of: "USB ", with: "") }
        if disk.isUSBBridgeWithoutSMART { return "USB" }
        return "—"
    }
}
