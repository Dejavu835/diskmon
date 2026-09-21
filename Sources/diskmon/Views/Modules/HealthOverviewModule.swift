import SwiftUI

/// 综合健康概览模块 v0.4.0 wave-4F(高级交互规范版)
/// v0.6.1 polish-G:接 HealthPredictor + 4 metric 改 0-100 健康度
/// v0.6.1 polish-J:Health 卡底部加 1 行 SMART 真字段(mediaErrors + critical warning bits)
///
/// 单一职责:接收 `HealthMonitor` + `HealthPredictor` → 渲染 220×180 玻璃卡内的 2×2 数字矩阵
///   - Health  :所有盘平均健康度(0-100,基础 100 / .warning 60 / .critical 30 / .danger 0)
///   - Danger  :HealthPredictor.warnings 中 .danger 盘数
///   - Warning :HealthPredictor.warnings 中 .warning 盘数
///   - Disks   :watchedDisks.count
/// v0.6.1 polish-J 新增底部 SMART 摘要行:
///   - mediaErrors(主盘当前值)+ critical warning bits 解析(>0 时显示 bit 0/4,否则 0)
///   - 数据源:`monitor.currentByUUID[selectedDisk?.volumeUUID]`
///   - 颜色根据 averageHealthScore(0 红 / 30 琥珀深 / 60 琥珀 / 100 米白 — 阈值同 HealthPredictor)
///   - 无 SMART 数据 → "—"
///
/// === 设计选择(高级交互规范) ===
/// - **大数字**:Fraunces 24pt em italic,琥珀 `.dsNormal`(= 主人审美不引入绿)
///   - `nil` / 0 → "—" 文字次色
///   - 数字滚动:`.contentTransition(.numericText(value:))` + 0.3s easeInOut
/// - **小标签**:9px SF Mono uppercase letter-spacing 0.5em 文字三级
/// - **玻璃卡规范**:统一走 `Views/Preferences/GlassBackground.swift` 的 `.glass()` 接口
///   (macOS 26 真液态玻璃 + macOS 14-25 NSVisualEffectView 兜底 + 1px 边 + 阴影 + 20px 圆角 + 噪点)
/// - **hover 交互**:
///   - 整个 module 数字行 1.02 放大(轻)
/// - **焦点环**:琥珀 2px stroke(`focusable() + focusEffectDisabled() + @FocusState`)
/// - **按下态**:`LongPressGesture(minimumDuration: 0)` → 下沉 1px + scale 0.99 + 阴影收缩
///
/// === v0.6.1 polish-G 关键决策 ===
/// - **真接 HealthPredictor.warnings 字典**(不是 evaluate(smart:) 老逻辑)
///   - evaluate(smart:) 走 HealthLevel 旧枚举,跟 HealthPredictor 状态完全脱节
///   - 改接 HealthPredictor 后:SMART bit0/bit4 / mediaErrors / trend 加速 / 命终 都能正确反映
/// - **0-100 健康度算法**:基础 100,每盘按 HealthWarning 等级扣分
///   - 主人审美"克制 + 高级":不用绿,健康用琥珀;危险用 dsDanger / dsCritical 视觉警示
///
/// === 不做 ===
/// - 不写 SwiftData(纯展示)
/// - 不 mock 数据(nil / 0 → "—")
/// - 不动 `GlassBackground.swift` / `AppSettings.swift` / 5 Preferences 子 View
struct HealthOverviewModule: View {
    /// v0.4.0 polish-D:tab 切换标识(总览 tab)
    /// 标识本模块属于"总览"分类,PopoverView 切换 tab 时按此过滤显示
    enum Detail { case overview, temperature, capacity, power, smart }
    static let moduleTab: Detail = .overview

    @Environment(HealthMonitor.self) private var monitor
    @Environment(AppSettings.self) private var settings

    // MARK: - 交互状态

    @State private var isCardHovered: Bool = false
    @State private var isPressed: Bool = false
    @FocusState private var isFocused: Bool

    var body: some View {
        cardBody
            // v0.4.0 polish-C:自适应 min/ideal/max(配合 PopoverView LazyVGrid adaptive)
            .frame(minWidth: 180, idealWidth: 220, maxWidth: .infinity,
                   minHeight: 140, idealHeight: 200, maxHeight: .infinity)
            // 玻璃底 — v0.4.0 polish-B:真液态玻璃 + 35mm 噪点(走 `.glass(withNoise: true)` 统一接口)
            // - macOS 26+ 走 `backgroundExtensionEffect()`(系统级液态玻璃)
            // - macOS 14-25 走 NSVisualEffectView(`.popover` + `vibrantDark`)兜底
            // - BG + 1px 边 + 顶高光 + 阴影都在 modifier 里
            // - 旧"按下时阴影收缩"在统一接口里不保留(用户硬规则:同一接口,不加 press state 参数)
            .glass(cornerRadius: 20, withNoise: true)
            // 焦点环(任务:琥珀 2px)
            .focusable()
            .focusEffectDisabled()
            .focused($isFocused)
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(Color.dsNormal, lineWidth: isFocused ? 2 : 0)
                    .padding(isFocused ? 2 : 0)
                    .allowsHitTesting(false)
            )
            // 按下态(任务:下沉 1px + scale 0.99)
            .scaleEffect(isPressed ? 0.99 : 1.0)
            .offset(y: isPressed ? 1 : 0)
            .simultaneousGesture(
                LongPressGesture(minimumDuration: 0)
                    .onChanged { _ in isPressed = true }
                    .onEnded { _ in isPressed = false }
            )
            .onHover { isCardHovered = $0 }
            // 缓动曲线(任务:0.3s `cubic-bezier(0.2, 0.8, 0.2, 1)` → Animation.timingCurve)
            .animation(
                .timingCurve(0.2, 0.8, 0.2, 1, duration: 0.3),
                value: isCardHovered
            )
            .animation(.easeOut(duration: 0.15), value: isFocused)
            .animation(.easeInOut(duration: 0.12), value: isPressed)
    }

    // MARK: - 卡片本体（消费级：先说结论）

    private var cardBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 4) {
                Image(systemName: "heart.text.square")
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(.tertiary)
                Text(L10n.t("module.overview.title", zh: "状态", en: "Status", language: settings.language))
                    .font(.system(size: 11, weight: .medium, design: .default))
                    .tracking(0.6)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                if let chip = statusChipText {
                    Text(chip)
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .foregroundStyle(statusChipColor)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(statusChipColor.opacity(0.16)))
                }
            }
            .padding(.top, 2)

            Text(headline)
                .font(.fraunces(size: 26, weight: .regular, italic: true))
                .foregroundStyle(headlineColor)
                .lineLimit(2)
                .minimumScaleFactor(0.7)
                .scaleEffect(isCardHovered ? 1.02 : 1.0)
                .contentTransition(.numericText(value: Double(averageHealthScore ?? 0)))
                .animation(.easeInOut(duration: 0.3), value: headline)

            Text(footnote)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: - 结论文案

    private var headline: String {
        let lang = settings.language
        if monitor.watchedDisks.isEmpty {
            return L10n.t("module.overview.empty", zh: "没有外接硬盘", en: "No external disk", language: lang)
        }
        if dangerCount > 0 {
            return L10n.t("module.overview.backup", zh: "建议尽快备份", en: "Back up soon", language: lang)
        }
        if warningCount > 0 || (averageHealthScore ?? 100) < 90 {
            return L10n.t("module.overview.attention", zh: "有需要留意的", en: "Needs attention", language: lang)
        }
        return L10n.t("module.overview.ok", zh: "一切正常", en: "All good", language: lang)
    }

    private var headlineColor: Color {
        if dangerCount > 0 { return Color.dsDanger }
        if warningCount > 0 { return Color.dsWarning }
        return Color.themeFgDark
    }

    private var statusChipText: String? {
        let lang = settings.language
        if monitor.watchedDisks.isEmpty { return nil }
        if dangerCount > 0 { return L10n.t("module.overview.chip.danger", zh: "尽快备份", en: "Backup", language: lang) }
        if warningCount > 0 { return L10n.t("module.overview.chip.warn", zh: "注意", en: "Watch", language: lang) }
        return L10n.t("module.overview.chip.ok", zh: "正常", en: "OK", language: lang)
    }

    private var statusChipColor: Color {
        if dangerCount > 0 { return Color.dsDanger }
        if warningCount > 0 { return Color.dsWarning }
        return Color.dsNormal
    }

    /// 一行补充：盘数 + 健康度 + 自然句摘要（不用 mediaErrors 调试格式）
    private var footnote: String {
        let lang = settings.language
        if monitor.watchedDisks.isEmpty {
            return L10n.t("module.overview.emptyHelp", zh: "插上外接硬盘后会自动出现。", en: "Connect a drive and it will appear.", language: lang)
        }
        let n = monitor.watchedDisks.count
        let disksPart = L10n.t("module.overview.disksN", zh: "%d 块硬盘", en: "%d disk(s)", language: lang)
            .replacingOccurrences(of: "%d", with: "\(n)")
        var parts = [disksPart]
        if let s = averageHealthScore {
            parts.append(L10n.t("module.overview.healthN", zh: "健康度 %d", en: "health %d", language: lang)
                .replacingOccurrences(of: "%d", with: "\(s)"))
        }
        if let smartLine = naturalSmartLine {
            parts.append(smartLine)
        }
        return parts.joined(separator: " · ")
    }

    /// 人话 SMART 摘要；无数据 / USB 不支持时返回 nil（不写 — 调试行）
    private var naturalSmartLine: String? {
        let lang = settings.language
        guard let uuid = monitor.selectedDisk?.volumeUUID,
              let smart = monitor.currentByUUID[uuid] else {
            return nil
        }
        let crit = smart.criticalWarningRaw ?? 0
        if (crit & 0x01) != 0 || (crit & 0x10) != 0 || (smart.mediaErrors ?? 0) > 0 {
            return L10n.t("module.overview.smartBad", zh: "发现异常记录", en: "issues found", language: lang)
        }
        if let used = smart.percentageUsed, used >= 70 {
            return L10n.t("module.overview.smartWorn", zh: "寿命消耗较多", en: "worn", language: lang)
        }
        if smart.percentageUsed != nil || smart.mediaErrors != nil {
            return L10n.t("module.overview.smartOk", zh: "未发现错误", en: "no errors", language: lang)
        }
        return nil
    }

    // MARK: - 健康聚合

    private var averageHealthScore: Int? {
        let disks = monitor.watchedDisks
        guard !disks.isEmpty else { return nil }
        let scores = disks.compactMap { disk -> Int? in
            if monitor.currentByUUID[disk.volumeUUID] == nil,
               monitor.smartErrorByUUID[disk.volumeUUID] != nil {
                return nil
            }
            switch monitor.level(for: disk.volumeUUID) {
            case .normal: return 100
            case .warning: return 60
            case .critical: return 30
            case .danger: return 0
            }
        }
        guard !scores.isEmpty else { return nil }
        return scores.reduce(0, +) / scores.count
    }

    private var dangerCount: Int {
        monitor.watchedDisks.reduce(0) { acc, d in
            acc + (monitor.level(for: d.volumeUUID) == .danger ? 1 : 0)
        }
    }

    private var warningCount: Int {
        monitor.watchedDisks.reduce(0) { acc, d in
            let w = monitor.level(for: d.volumeUUID)
            return acc + (w == .warning || w == .critical ? 1 : 0)
        }
    }
}
