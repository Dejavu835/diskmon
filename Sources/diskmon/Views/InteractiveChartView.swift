import SwiftUI
import Charts

// MARK: - Public Types

/// 通用图表数据点 v0.4.0
///  - `id` 用于 SwiftUI ForEach 稳定 diff
///  - `label` 用于 tooltip 文本
///  - `value` 主轴 Y 值(温度/功耗/容量… 由调用方解释)
///  - `secondaryValue` 双轴时的副轴值(可选)
///  - `color` 自定义单点颜色(可选,默认用 InteractiveChartView 的 `color` 参数)
///  - `date` X 轴时间
struct ChartDataPoint: Identifiable, Equatable {
    let id: UUID
    let label: String
    let value: Double
    let secondaryValue: Double?
    let color: Color?
    let date: Date

    init(
        id: UUID = UUID(),
        label: String,
        value: Double,
        secondaryValue: Double? = nil,
        color: Color? = nil,
        date: Date
    ) {
        self.id = id
        self.label = label
        self.value = value
        self.secondaryValue = secondaryValue
        self.color = color
        self.date = date
    }
}

/// 图表类型 v0.4.0
/// v0.6 polish-C:dualAxis 现在画 AreaMark + LineMark 双层(之前只 LineMark)
enum ChartType: Equatable {
    case line     // LineMark + AreaMark 阴影底
    case area     // 同 line,但强调 area 视觉
    case bar      // BarMark 柱状
    case dualAxis // AreaMark + LineMark 主轴(实线)+ AreaMark + LineMark 副轴(虚线)
}

/// 时间范围 v0.4.0
enum ChartRange: String, CaseIterable, Identifiable {
    case h1  = "1H"
    case h24 = "24H"
    case d7  = "7D"
    case d30 = "30D"

    var id: String { rawValue }
    var localizedLabel: String {
        switch self {
        case .h1:  return String(localized: "chart.window.1h",  defaultValue: "1H")
        case .h24: return String(localized: "chart.window.24h", defaultValue: "24H")
        case .d7:  return String(localized: "chart.window.7d",  defaultValue: "7D")
        case .d30: return String(localized: "chart.window.30d", defaultValue: "30D")
        }
    }
    var seconds: TimeInterval {
        switch self {
        case .h1:  return 3600
        case .h24: return 86_400
        case .d7:  return 7 * 86_400
        case .d30: return 30 * 86_400
        }
    }
}

/// 阈值参考线 v0.4.0 — 水平 RuleMark,用于温度告警阈值等
struct ChartReferenceLine: Equatable {
    let label: String
    let value: Double
    let color: Color
    let dashed: Bool
}

// MARK: - InteractiveChartView

/// 通用交互式图表 v0.4.0
///  - Swift Charts 折线 / 柱状 / 双轴
///  - hover tooltip + crosshair(鼠标位置反查最近点)
///  - 时间范围切换(1H/24H/7D/30D)
///  - 可选双指缩放(`enableZoom: true`)
///  - 玻璃质感 + 35mm 噪点 + vignette
///
/// 用法:
/// ```swift
/// InteractiveChartView(
///     data: snaps.map { ChartDataPoint(label: "...", value: $0.celsius, date: $0.timestamp) },
///     type: .area,
///     title: "History",
///     unit: "°C",
///     color: monitor.healthLevel.color,
///     rangeOptions: [.h1, .h24, .d7],
///     referenceLines: [
///         ChartReferenceLine(label: "Critical", value: 85, color: .dsCritical, dashed: true)
///     ]
/// )
/// ```
struct InteractiveChartView: View {
    // MARK: Input
    let data: [ChartDataPoint]
    let type: ChartType
    let title: String
    let unit: String
    let color: Color
    let rangeOptions: [ChartRange]
    var referenceLines: [ChartReferenceLine] = []
    var secondaryColor: Color = .dsNormal
    /// v0.6 polish-C:副轴单位(dualAxis 模式副轴 label 用)
    var secondaryUnit: String = ""
    var enableZoom: Bool = false
    var height: CGFloat = 220
    /// 嵌进模块卡时关掉自己的玻璃/内边距/分段选择，避免叠层和撑破格子
    var compact: Bool = false
    /// 外层已经按窗口拉数时，用这个窗口画 X 轴，不再用内部 Picker 的 range
    var displayRange: ChartRange? = nil
    /// range 变化回调(让 caller 重新 fetch 对应 granularity 的数据)
    var onRangeChange: (ChartRange) -> Void = { _ in }

    // MARK: State
    @Environment(\.colorScheme) private var colorScheme
    @Environment(AppSettings.self) private var settings
    @State private var range: ChartRange
    @State private var hoverPoint: ChartDataPoint?
    @State private var crosshairX: CGFloat?       // 鼠标在 chart 局部坐标的 x
    @State private var crosshairY: CGFloat?       // 鼠标在 chart 局部坐标的 y
    @State private var didAnimate: Bool = false
    @State private var xDomain: ClosedRange<Date>?
    @GestureState private var zoom: CGFloat = 1.0

    // MARK: Init

    init(
        data: [ChartDataPoint],
        type: ChartType = .area,
        title: String,
        unit: String,
        color: Color,
        rangeOptions: [ChartRange],
        referenceLines: [ChartReferenceLine] = [],
        secondaryColor: Color = .dsNormal,
        secondaryUnit: String = "",
        enableZoom: Bool = false,
        height: CGFloat = 220,
        compact: Bool = false,
        displayRange: ChartRange? = nil,
        onRangeChange: @escaping (ChartRange) -> Void = { _ in }
    ) {
        self.data = data
        self.type = type
        self.title = title
        self.unit = unit
        self.color = color
        self.rangeOptions = rangeOptions
        self.referenceLines = referenceLines
        self.secondaryColor = secondaryColor
        self.secondaryUnit = secondaryUnit
        self.enableZoom = enableZoom
        self.height = height
        self.compact = compact
        self.displayRange = displayRange
        self.onRangeChange = onRangeChange
        _range = State(initialValue: displayRange ?? rangeOptions.first ?? .h1)
    }

    // MARK: Body

    var body: some View {
        let stacked = mainStack
            .frame(maxWidth: .infinity, alignment: .leading)
        Group {
            if compact {
                stacked
                    .frame(minHeight: 48)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                stacked
                    .frame(minHeight: min(height, 180))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(14)
                    .background { backgroundLayer }
                    .overlay(borderOverlay)
                    .overlay(highlightOverlay)
            }
        }
        .onAppear {
            startAnimation()
            if !compact && !rangeOptions.isEmpty {
                onRangeChange(range)
            }
        }
        .onChange(of: range) { _, newValue in
            startAnimation()
            if !compact {
                onRangeChange(newValue)
            }
        }
        .onChange(of: displayRange) { _, _ in
            startAnimation()
        }
    }

    // MARK: Sub-views(拆分以让 type-checker 不超时)

    private var activeRange: ChartRange {
        displayRange ?? range
    }

    private var mainStack: some View {
        VStack(alignment: .leading, spacing: compact ? 4 : 10) {
            header
            chartBody
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
        }
    }

    @ViewBuilder
    private var backgroundLayer: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.regularMaterial)
            Image("35mm")
                .resizable(resizingMode: .tile)
                .opacity(0.04)
                .blendMode(.overlay)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            if colorScheme == .dark {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(
                        RadialGradient(
                            colors: [Color.clear, Color.black.opacity(0.12)],
                            center: .center,
                            startRadius: 80,
                            endRadius: 280
                        )
                    )
                    .blendMode(.multiply)
            }
        }
    }

    private var borderOverlay: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .stroke(Color.white.opacity(0.08), lineWidth: 1)
    }

    private var highlightOverlay: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [Color.white.opacity(0.06), .clear],
                    startPoint: .top,
                    endPoint: .center
                )
            )
            .blendMode(.overlay)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .center, spacing: 8) {
            Text(title)
                .font(.fraunces(size: compact ? 10 : 14, weight: .regular, italic: true))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .layoutPriority(1)
            if !unit.isEmpty {
                Text(unit)
                    .font(.system(size: compact ? 9 : 11, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .fixedSize()
            }
            Spacer(minLength: 6)
            if !compact, !rangeOptions.isEmpty {
                Picker("Range", selection: $range) {
                    ForEach(rangeOptions) { r in
                        Text(rangeLabel(r)).tag(r)
                    }
                }
                .pickerStyle(.segmented)
                .fixedSize()
                .labelsHidden()
                .layoutPriority(2)
            }
        }
    }

    private func rangeLabel(_ r: ChartRange) -> String {
        switch r {
        case .h1: return L10n.t("chart.window.1h", zh: "1时", en: "1H", language: settings.language)
        case .h24: return L10n.t("chart.window.24h", zh: "24时", en: "24H", language: settings.language)
        case .d7: return L10n.t("chart.window.7d", zh: "7天", en: "7D", language: settings.language)
        case .d30: return L10n.t("chart.window.30d", zh: "30天", en: "30D", language: settings.language)
        }
    }

    // MARK: Chart

    @ViewBuilder
    private var chartBody: some View {
        // 当前范围内的数据
        let now = Date()
        let start = now.addingTimeInterval(-activeRange.seconds)
        let filtered = data.filter { $0.date >= start && $0.date <= now }
        let values = filtered.map { $0.value }
        let secondaryValues = filtered.compactMap { $0.secondaryValue }
        let referenceValues = referenceLines.map { $0.value }
        let allValues = values + secondaryValues + referenceValues
        let yRange = yDomain(values: allValues)

        if filtered.isEmpty {
            emptyPlaceholder
        } else {
        Chart {
            switch type {
            case .line, .area:
                // AreaMark 阴影底(line/area 都画,area 类型更明显)
                ForEach(filtered) { p in
                    AreaMark(
                        x: .value("Time", p.date),
                        y: .value(unit, p.value)
                    )
                    .foregroundStyle(
                        .linearGradient(
                            colors: [color.opacity(0.22), .clear],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .interpolationMethod(.catmullRom)
                }
                // LineMark 主线
                ForEach(filtered) { p in
                    LineMark(
                        x: .value("Time", p.date),
                        y: .value(unit, p.value)
                    )
                    .foregroundStyle(color.opacity(type == .area ? 0.85 : 0.95))
                    .lineStyle(StrokeStyle(lineWidth: 1.4, lineCap: .round))
                    .interpolationMethod(.catmullRom)
                }
            case .bar:
                ForEach(filtered) { p in
                    BarMark(
                        x: .value("Time", p.date),
                        y: .value(unit, p.value)
                    )
                    .foregroundStyle(p.color ?? color.opacity(0.85))
                    .cornerRadius(2)
                }
            case .dualAxis:
                // v0.6 polish-C:主轴 AreaMark 阴影 + LineMark 实线
                ForEach(filtered) { p in
                    AreaMark(
                        x: .value("Time", p.date),
                        y: .value(unit, p.value)
                    )
                    .foregroundStyle(
                        .linearGradient(
                            colors: [color.opacity(0.20), .clear],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .interpolationMethod(.catmullRom)
                }
                ForEach(filtered) { p in
                    LineMark(
                        x: .value("Time", p.date),
                        y: .value(unit, p.value)
                    )
                    .foregroundStyle(color.opacity(0.9))
                    .lineStyle(StrokeStyle(lineWidth: 1.4, lineCap: .round))
                    .interpolationMethod(.catmullRom)
                }
                // v0.6 polish-C:副轴 AreaMark 阴影 + LineMark 虚线
                ForEach(filtered) { p in
                    if p.secondaryValue != nil {
                        AreaMark(
                            x: .value("Time", p.date),
                            y: .value(secondaryUnit.isEmpty ? "Secondary" : secondaryUnit, p.secondaryValue ?? 0)
                        )
                        .foregroundStyle(
                            .linearGradient(
                                colors: [secondaryColor.opacity(0.14), .clear],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .interpolationMethod(.catmullRom)
                    }
                }
                ForEach(filtered) { p in
                    if let s = p.secondaryValue {
                        LineMark(
                            x: .value("Time", p.date),
                            y: .value(secondaryUnit.isEmpty ? "Secondary" : secondaryUnit, s)
                        )
                        .foregroundStyle(secondaryColor.opacity(0.85))
                        .lineStyle(StrokeStyle(lineWidth: 1.2, lineCap: .round, dash: [3, 2]))
                        .interpolationMethod(.catmullRom)
                    }
                }
            }

            // 阈值参考线
            ForEach(referenceLines, id: \.label) { line in
                RuleMark(y: .value(line.label, line.value))
                    .foregroundStyle(line.color.opacity(0.4))
                    .lineStyle(
                        StrokeStyle(
                            lineWidth: 0.6,
                            dash: line.dashed ? [3, 3] : []
                        )
                    )
            }
        }
        .chartXScale(domain: xDomain ?? (start...now))
        .chartYScale(domain: yRange)
        .chartXAxis {
            // v0.6 polish-C:X 轴日期格式,刻度自动 4
            AxisMarks(values: .automatic(desiredCount: compact ? 3 : 4)) { _ in
                AxisGridLine().foregroundStyle(.tertiary)
                AxisValueLabel(format: axisFormat, centered: false)
                    .font(.system(size: compact ? 9 : 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: compact ? 3 : 5)) { value in
                AxisGridLine().foregroundStyle(.tertiary)
                AxisValueLabel {
                    if let dbl = value.as(Double.self) {
                        Text("\(Int(dbl.rounded()))")
                            .font(.system(size: compact ? 9 : 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .animation(.easeInOut(duration: 0.6), value: xDomain)
        .animation(.easeInOut(duration: 0.3), value: activeRange)
        // 交互层:onContinuousHover + crosshair + tooltip
        .chartOverlay { proxy in
            GeometryReader { geo in
                ZStack(alignment: .topLeading) {
                    // 全透明 hover 捕获
                    Rectangle()
                        .fill(Color.clear)
                        .contentShape(Rectangle())
                        .onContinuousHover { phase in
                            switch phase {
                            case .active(let pos):
                                handleHover(at: pos, proxy: proxy, geo: geo)
                            case .ended:
                                hoverPoint = nil
                                crosshairX = nil
                                crosshairY = nil
                            }
                        }
                    // Crosshair 垂直线
                    if let x = crosshairX {
                        Path { p in
                            p.move(to: CGPoint(x: x, y: 0))
                            p.addLine(to: CGPoint(x: x, y: geo.size.height))
                        }
                        .stroke(
                            Color.themeFgDark.opacity(0.25),
                            style: StrokeStyle(lineWidth: 0.5, dash: [2, 2])
                        )
                        // 水平 crosshair(可选 — 在 hover 到 y 时显示)
                        if let y = crosshairY {
                            Path { p in
                                p.move(to: CGPoint(x: 0, y: y))
                                p.addLine(to: CGPoint(x: geo.size.width, y: y))
                            }
                            .stroke(
                                Color.themeFgDark.opacity(0.15),
                                style: StrokeStyle(lineWidth: 0.5, dash: [2, 2])
                            )
                        }
                    }
                    // 浮动 tooltip
                    if let point = hoverPoint, let x = crosshairX {
                        tooltipView(for: point, anchorX: x, geo: geo)
                    }
                }
            }
            // 缩放手势(可选)
            .gesture(
                enableZoom
                    ? MagnificationGesture()
                        .updating($zoom) { value, state, _ in
                            state = value
                        }
                        .onEnded { value in
                            applyZoom(value)
                        }
                    : nil
            )
        }
        } // filtered.isEmpty else
    }

    private var emptyPlaceholder: some View {
        VStack(spacing: 4) {
            if !compact {
                Image(systemName: "chart.line.uptrend.xyaxis")
                    .font(.system(size: 16))
                    .foregroundStyle(.tertiary)
            }
            Text(L10n.t("chart.empty", zh: "这一段还没有记录", en: "No samples in this range", language: settings.language))
                .font(.system(size: compact ? 10 : 11))
                .foregroundStyle(.tertiary)
                .lineLimit(2)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Tooltip

    @ViewBuilder
    private func tooltipView(for point: ChartDataPoint, anchorX: CGFloat, geo: GeometryProxy) -> some View {
        let tooltipWidth: CGFloat = 140
        let tooltipHeight: CGFloat = 50
        // 优先右,不够则左
        let xPosition = min(
            max(anchorX + 12, tooltipWidth / 2 + 4),
            geo.size.width - tooltipWidth / 2 - 4
        )
        VStack(alignment: .leading, spacing: 2) {
            Text(point.label)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Circle()
                    .fill(point.color ?? color)
                    .frame(width: 5, height: 5)
                Text(formatValue(point.value))
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(Color.themeFgDark)
                Text(unit)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                if let s = point.secondaryValue {
                    Text("·")
                        .foregroundStyle(.tertiary)
                    Text(formatValue(s))
                        .font(.system(size: 11, design: .monospaced))
                        .monospacedDigit()
                        .foregroundStyle(secondaryColor)
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .frame(width: tooltipWidth, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(.regularMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(Color.themeFgDark.opacity(0.12), lineWidth: 0.5)
        )
        .shadow(color: Color.black.opacity(0.12), radius: 6, x: 0, y: 2)
        .position(x: xPosition, y: tooltipHeight / 2 + 4)
    }

    // MARK: Hover Handling

    private func handleHover(at pos: CGPoint, proxy: ChartProxy, geo: GeometryProxy) {
        guard !data.isEmpty else { return }
        // pos 是 chart 局部坐标系
        let plotFrame: CGRect
        if let anchor = proxy.plotFrame {
            plotFrame = geo[anchor]
        } else {
            plotFrame = geo.frame(in: .local)
        }
        let xInPlot = pos.x - plotFrame.minX
        guard plotFrame.width > 0,
              xInPlot >= 0,
              xInPlot <= plotFrame.width else {
            return
        }
        // 反查 X 对应的 Date
        guard let date: Date = proxy.value(atX: xInPlot) else { return }
        // 找最近数据点
        let nearest = data.min { lhs, rhs in
            abs(lhs.date.timeIntervalSince(date)) < abs(rhs.date.timeIntervalSince(date))
        }
        guard let near = nearest else { return }
        hoverPoint = near
        // crosshair X 落在该点对应的 plot x
        if let pointX: CGFloat = proxy.position(forX: near.date) {
            crosshairX = plotFrame.minX + pointX
        } else {
            crosshairX = pos.x
        }
        // crosshair Y 落在该点对应的 plot y
        if let pointY: CGFloat = proxy.position(forY: near.value) {
            crosshairY = plotFrame.minY + pointY
        } else {
            crosshairY = pos.y
        }
    }

    // MARK: Zoom

    private func applyZoom(_ value: CGFloat) {
        guard enableZoom, let current = xDomain else { return }
        let center = current.lowerBound.addingTimeInterval(
            current.upperBound.timeIntervalSince(current.lowerBound) / 2
        )
        let halfSpan = current.upperBound.timeIntervalSince(current.lowerBound) / 2 / Double(value)
        let newStart = center.addingTimeInterval(-halfSpan)
        let newEnd = center.addingTimeInterval(halfSpan)
        withAnimation(.easeOut(duration: 0.2)) {
            xDomain = newStart...newEnd
        }
    }

    // MARK: Helpers

    private func formatValue(_ v: Double) -> String {
        if abs(v) >= 100 {
            return String(format: "%.0f", v)
        } else if abs(v) >= 10 {
            return String(format: "%.1f", v)
        } else {
            return String(format: "%.2f", v)
        }
    }

    private var axisFormat: Date.FormatStyle {
        switch activeRange {
        case .h1:  return .dateTime.hour().minute()
        case .h24: return .dateTime.hour().minute()
        case .d7:  return .dateTime.month(.abbreviated).day()
        case .d30: return .dateTime.month(.abbreviated).day()
        }
    }

    /// v0.6 polish-C:Y 轴自适应 — 不再固定 0 起
    ///  - 取 data min/max,加 5% 下 padding + 10% 上 padding
    ///  - flat data(min == max):中心 ± 1 兜底,避免 0 span
    ///  - empty:0...1
    ///  - 参考 spec:`chartYScale(domain: min...max*1.1)` 的思路
    private func yDomain(values: [Double]) -> ClosedRange<Double> {
        guard let mn = values.min(), let mx = values.max() else {
            return 0.0...1.0
        }
        if mx <= mn {
            // flat / single-value:中心 ± 1
            let base = mn
            return (base - 1.0)...(base + 1.0)
        }
        let span = mx - mn
        // 至少 1.0 unit span 防止 W(0-5)被压扁
        let paddedSpan = max(span, 1.0)
        let lo = mn - paddedSpan * 0.05
        let hi = mx + paddedSpan * 0.10
        return lo...hi
    }

    /// Trim 动画:从终点往左展开
    private func startAnimation() {
        let now = Date()
        let start = now.addingTimeInterval(-activeRange.seconds)
        if !didAnimate {
            xDomain = now...now
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                withAnimation(.easeInOut(duration: 0.6)) {
                    xDomain = start...now
                }
            }
            didAnimate = true
        } else {
            xDomain = start...now
        }
    }
}
