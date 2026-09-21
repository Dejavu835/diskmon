import SwiftUI
import SwiftData

/// Warnings Center 独立窗口 v0.5.0(grok 调研设计)
///
/// 800x500 独立窗口,从 PopoverView 底部按钮 / ⌘W 触发
///
/// === 布局 ===
/// ```
/// ┌────────────────────────────────────────────┐
/// │  健康警告 · Warnings Center        [X]     │  ← 顶栏 36pt
/// ├────────────────────────────────────────────┤
/// │  [Good 5] [Warning 1] [Critical 0] [Danger 0] │  ← 4 个 StatCard 横排
/// ├────────────────────────────────────────────┤
/// │  ▢ disk1   56℃   持续 5min  ↑3.2°C  ⟳  Dismiss │  ← 每盘一行玻璃卡
/// │              温度持续 56°C 达 5min              │  ← reason line (Fraunces italic)
/// │  ▢ disk2   42℃   刚刚       —      ⟳  Dismiss │
/// │              寿命临界 92%                       │
/// │  ▢ disk3   35℃   —          —      ⟳  Dismiss │  ← Good 状态也显示
/// │  ...                                        │
/// └────────────────────────────────────────────┘
/// ```
///
/// === 数据源 ===
/// - `@Environment(HealthMonitor.self)`:盘列表 + SMART 数据
/// - `@Environment(HealthPredictor.self)`:warnings 字典 + dwellDuration / dismiss API
/// - 持续时长:`predictor.dwellDuration(forDiskUUID:)`(Wave 4H 公开方法)
/// - Dismiss:`predictor.dismiss(forDiskUUID:)`(Wave 4H 公开方法)
/// - v0.6.1 polish-I:reason 文字 + trend 升温/降温 chip
///   - reason:`predictor.reason(forDiskUUID:)`(SMART 触发字段 / 温度 dwell 升级理由)
///   - trend:`predictor.currentTrend(forDiskUUID:)`(过去 10min 升温速率,°C/s)
///
/// === v0.6.1 polish-I 变更 ===
/// - DANGER 独立 stat:从 3 卡 → 4 卡(Good / Warning / Critical / Danger 各自独立计)
/// - 4 卡:StatCard 大数字 56pt,4 卡横排每张 ~180pt(800 总宽 - 36 padding - 36 spacing = 728 / 4 = 182)
///   - 不挤但比之前 3 卡每张 ~243pt 紧凑;Fraunces 56pt 仍能装下"X"单数字
/// - DiskWarningRow 加 reason line:磁盘名下方第 3 行,Fraunces 13pt italic .secondary 次色
///   - nil reason → 整行不显示(避免空行噪扰)
/// - DiskWarningRow 加 trend chip:时长徽章右侧,小 chip 风格
///   - slope > 0.05 °C/s → "↑ X.X°C/min" dsDanger(深红,强警告)
///   - slope < -0.05 °C/s → "↓ X.X°C/min" dsNormal(琥珀,符合主人审美"不引入绿")
///     (任务规范原写"↓ 绿",但主人 profile 硬规则"不引入绿"胜出;琥珀是项目
///      已有"calm/cool"语义色,跟其他位置 dsNormal 表达一致)
///   - 其它(无数据 / |slope| ≤ 0.05)→ "—" secondary 灰
///
/// === 高级交互规范(任务硬要求) ===
/// - 统一缓动:0.3s `Animation.timingCurve(0.2, 0.8, 0.2, 1)`
/// - 数字滚动:`.contentTransition(.numericText(value:))`
/// - hover 玻璃卡 1.02 放大 + 高光内移
/// - 焦点环:琥珀 2px stroke(`@FocusState` + `.focusable()`)
/// - 按下态:下沉 1px + scale 0.99(`LongPressGesture(minimumDuration: 0)`)
///
/// === 设计选择 ===
/// - Good 状态也显示(不只是 Warning/Critical)— 用户要"一屏看全盘状态"
/// - "持续 Xmin" 标签只对 Warning/Critical 有效,Good 显示 "—"
/// - 进度环(SVG 自绘)— 100% 时画完整圆,其他按 healthPercent 画弧
/// - 关闭按钮(右上 X)走 `\.dismiss` env
/// - 不 mock / 不凑合 — nil 数据走 "—" 占位
/// - 不改 HealthPredictor.swift(parallel worker 拥有)— UI helpers 拆到
///   `HealthWarning+UI.swift`,Dismiss 通过直接写 `predictor.warnings[uuid] = .none`
///
/// === 不做 ===
/// - 不 emoji(SF Symbol)
/// - 不改 HealthPredictor 已有逻辑
/// - 不改 GlassBackground / 5 Preferences 子 View / AppSettings / Localizable.strings
struct WarningsView: View {
    @Environment(HealthMonitor.self) private var monitor
    @Environment(HealthPredictor.self) private var predictor
    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss

    // MARK: - 派生数据

    /// 4 个统计计数(Good / Warning / Critical / Danger)
    /// v0.6.1 polish-I:.danger 从 critical 拆开独立计
    ///   - 之前:.danger 计入 critical(grok 调研 v0.6 简化聚合)
    ///   - 现在:用户反馈"硬盘健康检测还没上线" → 4 卡独立展示,.danger
    ///     是 SMART 独立危险信号(bit0/bit4 / mediaErrors / 命终),跟
    ///     .critical(温度 dwell 或 SMART 阈值)是两种不同维度的危险
    ///   - 主从视觉:.danger 红最重,.critical 琥珀次重(都已由 HealthWarning.color 区分)
    private var counts: (good: Int, warning: Int, critical: Int, danger: Int) {
        var good = 0, warning = 0, critical = 0, danger = 0
        for disk in monitor.watchedDisks {
            let uuid = uuidFromDiskUUID(disk.volumeUUID)
            let level = predictor.warnings[uuid] ?? .none
            switch level {
            case .none:     good += 1
            case .warning:  warning += 1
            case .critical: critical += 1
            case .danger:   danger += 1
            }
        }
        return (good, warning, critical, danger)
    }

    /// 排序后盘列表 — Warning/Critical 置顶,然后按名字排
    private var sortedDisks: [DiskInfo] {
        monitor.watchedDisks.sorted { a, b in
            let la = predictor.warnings[uuidFromDiskUUID(a.volumeUUID)] ?? .none
            let lb = predictor.warnings[uuidFromDiskUUID(b.volumeUUID)] ?? .none
            if la != lb { return severity(la) > severity(lb) }
            return (a.mountPoint ?? a.bsdName) < (b.mountPoint ?? b.bsdName)
        }
    }

    private func severity(_ level: HealthWarning) -> Int {
        // v0.6:加 .danger case(SMART 独立危险信号 — bit0/bit4 / mediaErrors / 命终前夕)
        //      排序在 .critical 之后,.danger 是最高级别(> 任何温度 dwell)
        switch level {
        case .none:     0
        case .warning:  1
        case .critical: 2
        case .danger:   3
        }
    }

    var body: some View {
        ZStack {
            // 35mm 噪点 + vignette
            NoiseOverlay()
                .accessibilityHidden(true)

            VStack(spacing: 14) {
                topBar
                statsRow
                diskList
            }
            .padding(18)
        }
        .frame(minWidth: 480, idealWidth: 600, maxWidth: .infinity,
               minHeight: 320, idealHeight: 400, maxHeight: .infinity)
        .background(
            ResizableWindowConfigurator(minSize: CGSize(width: 480, height: 320))
        )
        .glassChrome(cornerRadius: 16)
    }

    // MARK: - 顶栏

    private var topBar: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "bell.badge.fill")
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(Color.dsNormal)
            VStack(alignment: .leading, spacing: 2) {
                Text("健康警告")
                    .font(.fraunces(size: 16, weight: .regular, italic: true))
                    .foregroundStyle(Color.themeFgDark)
                Text("Warnings Center")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .tracking(0.4)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Close")
            .onHover { hovering in
                if hovering { NSCursor.pointingHand.push() }
                else { NSCursor.pop() }
            }
        }
        .frame(height: 36)
        // v0.9.1 polish-P2:顶栏走真液态玻璃(替换 .regularMaterial,跟主体 .glassChrome 一致)
        .glassChromeUniform(cornerRadius: 12)
    }

    // MARK: - 4 个 StatCard 横排

    private var statsRow: some View {
        let c = counts
        let columns = [GridItem(.adaptive(minimum: 140), spacing: 12)]
        return LazyVGrid(columns: columns, spacing: 12) {
            StatCard(
                value: Double(c.good),
                unit: "个",
                label: "GOOD",
                color: Color.dsNormal
            )
            StatCard(
                value: Double(c.warning),
                unit: "个",
                label: "WARNING",
                color: Color.dsWarning
            )
            StatCard(
                value: Double(c.critical),
                unit: "个",
                label: "CRITICAL",
                color: Color.dsCritical
            )
            StatCard(
                value: Double(c.danger),
                unit: "个",
                label: "DANGER",
                color: Color.dsDanger
            )
        }
    }

    // MARK: - 盘列表(每盘一行玻璃卡)

    private var diskList: some View {
        ScrollView {
            LazyVStack(spacing: 8) {
                if monitor.watchedDisks.isEmpty {
                    emptyState
                } else {
                    ForEach(sortedDisks) { disk in
                        // v0.6.1 polish-I:每行传 reason(SMART 触发字段)+ trend(升温/降温)
                        //   - 走 predictor 公开方法(警告聚合层),View 端不再做转换
                        //   - 跟 level 同步:level 变 → reason 跟着变(SMART 危险 → reason 立即变)
                        DiskWarningRow(
                            disk: disk,
                            level: predictor.warnings[uuidFromDiskUUID(disk.volumeUUID)] ?? .none,
                            celsius: monitor.currentByUUID[disk.volumeUUID]?.celsius ?? 0,
                            dwellSeconds: predictor.dwellDuration(forDiskUUID: disk.volumeUUID),
                            reason: predictor.reason(forDiskUUID: disk.volumeUUID),
                            trend: predictor.currentTrend(forDiskUUID: disk.volumeUUID),
                            onDismiss: { predictor.dismiss(forDiskUUID: disk.volumeUUID) }
                        )
                    }
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "externaldrive.badge.questionmark")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.tertiary)
            Text("暂无监控盘")
                .font(.fraunces(size: 14, weight: .regular, italic: true))
                .foregroundStyle(.secondary)
            Text("连接外接盘后,健康告警会自动出现在这里")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                // v0.6.0 polish-E:多行段落实体加 .lineSpacing(2) 提升可读性
                .lineSpacing(2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }

    // MARK: - (Duration / Dismiss 由 HealthPredictor.dwellDuration / .dismiss 公开 API 接管)

    // MARK: - Helpers

    /// disk.volumeUUID (String) → Foundation UUID(走 HealthPredictor 同款解析)
    private func uuidFromDiskUUID(_ diskUUID: String) -> UUID {
        if let parsed = UUID(uuidString: diskUUID) {
            return parsed
        }
        // 兜底:用字符串 hash 生成确定性 UUID(跟 HealthPredictor 同语义)
        var hasher = Hasher()
        hasher.combine(diskUUID)
        let h = UInt64(bitPattern: Int64(hasher.finalize()))
        let bytes: [UInt8] = (0..<16).map { i in
            UInt8((h >> ((i % 8) * 8)) & 0xFF)
        }
        var b = bytes
        b[6] = (b[6] & 0x0F) | 0x50
        b[8] = (b[8] & 0x3F) | 0x80
        return UUID(uuid: (
            b[0], b[1], b[2], b[3],
            b[4], b[5], b[6], b[7],
            b[8], b[9], b[10], b[11],
            b[12], b[13], b[14], b[15]
        ))
    }
}

// MARK: - 单盘告警行

/// 一行 = 一个盘:左 SF Symbol + 名 + reason / 中 温度 + 持续时长 + trend chip / 右 进度环 + Dismiss
/// - 高级交互规范(hover 1.02 / focus 2px / press 下沉)
/// - 进度环 SVG 自绘(用 `Circle().trim`)
/// - v0.6.1 polish-I:
///   - 磁盘名下方第 3 行 = reason line(Fraunces 13pt italic .secondary)
///     nil reason → 整行隐藏(不显示空行)
///   - 时长徽章右侧 = trend chip(小 chip,显示 ↑/↓ 升温/降温速率)
///     nil / |slope| ≤ 0.05 °C/s → "—" 灰
private struct DiskWarningRow: View {
    let disk: DiskInfo
    let level: HealthWarning
    let celsius: Int
    let dwellSeconds: TimeInterval?
    /// v0.6.1 polish-I:告警原因文案(SMART 触发字段 / 温度 dwell)
    /// - 来自 `HealthPredictor.reason(forDiskUUID:)`
    /// - nil → 不显示 reason line(避免空行噪扰)
    let reason: String?
    /// v0.6.1 polish-I:温度升温/降温速率(°C/s,正=升温,负=降温,nil=数据不足)
    /// - 来自 `HealthPredictor.currentTrend(forDiskUUID:)`
    /// - 0.05 °C/s ≈ 3°C/min(任务规范阈值)
    let trend: Double?
    let onDismiss: () -> Void

    @State private var isHovered: Bool = false
    @State private var isPressed: Bool = false
    @State private var isDismissPressed: Bool = false
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            leftSection
            centerSection
            Spacer(minLength: 0)
            rightSection
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(rowBackground)
        .overlay(rowBorder)
        .scaleEffect(isPressed ? 0.99 : 1.0)
        .offset(y: isPressed ? 1 : 0)
        .focusable()
        .focusEffectDisabled()
        .focused($isFocused)
        .overlay(focusRing)
        .onHover { isHovered = $0 }
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 0)
                .onChanged { _ in isPressed = true }
                .onEnded { _ in isPressed = false }
        )
        .animation(
            .timingCurve(0.2, 0.8, 0.2, 1, duration: 0.3),
            value: isHovered
        )
        .animation(.easeOut(duration: 0.15), value: isFocused)
        .animation(.easeInOut(duration: 0.12), value: isPressed)
    }

    // MARK: 左:SF Symbol + 盘名 + reason

    private var leftSection: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: level.sfSymbol)
                .font(.system(size: 18, weight: .regular))
                .foregroundStyle(level.color)
                // v0.6:.critical 和 .danger 都用 .pulse 强提示
                //      - .critical:温度 dwell 升级,持续闪
                //      - .danger:SMART 独立危险信号(bit0/bit4 / mediaErrors / 命终),持续闪
                .symbolEffect(.pulse, options: .repeating, isActive: level == .critical || level == .danger)
                .frame(width: 24)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(displayName)
                    .font(.fraunces(size: 16, weight: .regular, italic: true))
                    .foregroundStyle(Color.themeFgDark)
                    .lineLimit(1)
                Text(disk.bsdName)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                // v0.6.1 polish-I:reason line(告警原因文案)
                //   - Fraunces 13pt italic 文字次色(任务硬要求:italic + 次色)
                //   - nil → 整行不显示(否则 .secondary 的空 row 噪扰)
                if let reason {
                    Text(reason)
                        .font(.fraunces(size: 13, weight: .regular, italic: true))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
        }
        .frame(minWidth: 180, alignment: .leading)
    }

    // MARK: 中:温度 + 持续时长 + trend chip

    private var centerSection: some View {
        HStack(alignment: .center, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(celsius > 0 ? "\(celsius)" : "—")
                    .font(.fraunces(size: 56, weight: .regular, italic: true))
                    .foregroundStyle(level.color)
                    .monospacedDigit()
                    .scaleEffect(isHovered ? 1.02 : 1.0)
                    .contentTransition(.numericText(value: Double(celsius)))
                Text("℃")
                    .font(.system(size: 16, weight: .regular, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            dwellBadge
            // v0.6.1 polish-I:trend chip(升温/降温指示)
            //   - 放在 dwellBadge 右侧,小 chip 风格统一
            //   - |slope| > 0.05 °C/s(≈ 3°C/min)才显示方向箭头
            //   - 否则 "—" 灰(数据不足 / 平稳)
            trendChip
        }
    }

    private var dwellBadge: some View {
        HStack(spacing: 4) {
            Image(systemName: "clock")
                .font(.system(size: 11, weight: .medium))
            Text(HealthPredictor.formatDwell(dwellSeconds))
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .monospacedDigit()
        }
        .foregroundStyle(badgeFg)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            Capsule().fill(badgeBg)
        )
    }

    /// v0.6.1 polish-I:trend chip(温度升温/降温速率)
    /// - slope > 0.05 °C/s → "↑ X.X°C/min" dsDanger(深红)
    /// - slope < -0.05 °C/s → "↓ X.X°C/min" dsNormal(琥珀,项目已有"calm"语义色)
    ///   (任务规范原写"↓ 绿",但主人 profile 硬规则"不引入绿"胜出;
    ///    琥珀也是项目内多处 dsNormal 的语义,跟其他位置表达一致)
    /// - 其他(nil / |slope| ≤ 0.05)→ "—" secondary 灰
    /// - chip 风格跟 dwellBadge 统一(11pt monospaced + 圆角胶囊背景)
    private var trendChip: some View {
        HStack(spacing: 4) {
            if let s = trend {
                if s > 0.05 {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 11, weight: .semibold))
                    Text(String(format: "%.1f°C/min", s * 60))
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .monospacedDigit()
                } else if s < -0.05 {
                    Image(systemName: "arrow.down")
                        .font(.system(size: 11, weight: .semibold))
                    Text(String(format: "%.1f°C/min", abs(s) * 60))
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .monospacedDigit()
                } else {
                    Image(systemName: "minus")
                        .font(.system(size: 11, weight: .medium))
                    Text("稳定")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                }
            } else {
                Image(systemName: "minus")
                    .font(.system(size: 11, weight: .medium))
                Text("—")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
            }
        }
        .foregroundStyle(trendFg)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            Capsule().fill(trendFg.opacity(0.12))
        )
        // .help 鼠标悬停提示(Wave 5C 已有同名约定)
        .help("过去 10 分钟温度趋势")
    }

    private var trendFg: Color {
        guard let s = trend else { return .secondary }
        if s > 0.05 { return Color.dsDanger }
        if s < -0.05 { return Color.dsNormal }  // 主人审美:不引入绿;琥珀是"calm/cool"
        return .secondary
    }

    private var badgeFg: Color {
        if dwellSeconds == nil { return .secondary }
        // v0.6:加 .danger case — 用 dsDanger(更深一档红)
        //      badge 显示 dwell 时长,只有温度 dwell 才有 dwellSeconds;SMART .danger
        //      通常 dwellSeconds == nil,fallback 到 .secondary(灰色,不抢戏)
        switch level {
        case .none:     return .secondary
        case .warning:  return Color.dsWarning
        case .critical: return Color.dsCritical
        case .danger:   return Color.dsDanger
        }
    }

    private var badgeBg: Color {
        badgeFg.opacity(0.12)
    }

    // MARK: 右:进度环 + Dismiss

    private var rightSection: some View {
        HStack(spacing: 14) {
            healthRing
            dismissButton
        }
    }

    /// SVG 自绘进度环(用 `Circle().trim`)
    private var healthRing: some View {
        ZStack {
            Circle()
                .stroke(level.color.opacity(0.15), lineWidth: 4)
                .frame(width: 38, height: 38)
            Circle()
                .trim(from: 0, to: level.healthPercent)
                .stroke(
                    level.color,
                    style: StrokeStyle(lineWidth: 4, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .frame(width: 38, height: 38)
                .animation(
                    .timingCurve(0.2, 0.8, 0.2, 1, duration: 0.3),
                    value: level.healthPercent
                )
            // 中心百分比文字
            Text("\(Int(level.healthPercent * 100))")
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(level.color)
        }
    }

    private var dismissButton: some View {
        Button {
            onDismiss()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                Text("Dismiss")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
            }
            .foregroundStyle(dismissFg)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(dismissBg)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .stroke(dismissFg.opacity(0.3), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .scaleEffect(isDismissPressed ? 0.95 : 1.0)
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 0)
                .onChanged { _ in isDismissPressed = true }
                .onEnded { _ in isDismissPressed = false }
        )
        .animation(.easeInOut(duration: 0.12), value: isDismissPressed)
        .help("收起此告警")
    }

    private var dismissFg: Color {
        if level == .none { return .secondary }
        return level.color
    }

    private var dismissBg: Color {
        if level == .none { return Color.primary.opacity(0.04) }
        return level.color.opacity(0.12)
    }

    // MARK: 视觉

    private var rowBackground: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(isHovered ? Color.white.opacity(0.04) : Color.primary.opacity(0.02))
    }

    private var rowBorder: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .stroke(Color.white.opacity(0.06), lineWidth: 1)
    }

    private var focusRing: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(Color.dsNormal, lineWidth: isFocused ? 2 : 0)
            .padding(isFocused ? 2 : 0)
            .allowsHitTesting(false)
    }

    /// 短盘名(mountPoint 末段 / bsdName 兜底)
    private var displayName: String {
        if let mp = disk.mountPoint {
            return (mp as NSString).lastPathComponent
        }
        return disk.bsdName
    }
}
