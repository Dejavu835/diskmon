import SwiftUI
import SwiftData
import DiskMonCore

/// 温度 mini chart 模块 v0.4.0 wave-4F
/// v0.6.1 polish-G:加 SMART toggle,展开显示 mediaErrors / criticalWarningRaw timeline
/// v0.6.1 polish-J:SMART toggle 默认 true(让 SMART 真字段立即可见,温度 24h 已在 Temperature tab 主图)
///
/// 单一职责:接收 `HealthMonitor` + `modelContext` → 渲染 220×220 格内 1H 默认的
/// `InteractiveChartView` 迷你版,展示 selected disk 的 SMART / 温度时间序列
///
/// === 数据来源(全部真实) ===
/// - 温度:`SwiftData` 拉 `SmartSnapshot(granularity: .raw for 1H, .minute for 24H)`
///   - 选 `monitor.selectedDisk?.volumeUUID`
///   - 1H = raw(5s 轮询粒度);24H = minute 桶
/// - v0.6.1 polish-G SMART timeline:`SmartSnapshot(granularity: .raw for 1H)`
///   - 拆成 2 个迷你 chart 上下排:mediaErrors / criticalWarningRaw
///   - 0/0 起步,任何 >=1 都用 .dsDanger 红 强调
/// - 外层一张玻璃卡;嵌进去的 InteractiveChartView 走 compact,不再套第二层玻璃
///
/// === 设计选择(高级交互规范) ===
/// - **标题**:"Temperature · 24h"(spec 原文;InteractiveChartView 内部 uppercase → "TEMPERATURE · 24H")
///   - 但默认 range = .h1(spec),所以 picker 切到 24H 时数据才全
/// - **range 选项**:`[.h1, .h24]`(spec 1H 默认,24H 可选)
/// - **chart 颜色**:`monitor.healthLevel.color`(主盘的等级色)
/// - **v0.6.1 polish-G SMART toggle**:右上角小 SF Symbol 按钮(`chart.line.uptrend.xyaxis` /
///   `bolt.shield`),展开时切到 2 个 SMART 迷你 chart
/// - compact InteractiveChartView:无内层玻璃 / 无内层 picker,空状态替换坐标轴
///
/// === 不做 ===
/// - 不在 UI 直接跑 `smartctl`
/// - 不写自定义 chart(Spec 硬要求复用 InteractiveChartView)
struct ChartMiniModule: View {
    /// v0.4.0 polish-D:tab 切换标识(总览 tab,作为 mini 折线展示)
    enum Detail { case overview, temperature, capacity, power, smart }
    static let moduleTab: Detail = .overview

    @Environment(HealthMonitor.self) private var monitor
    @Environment(\.modelContext) private var modelContext

    // MARK: - 状态

    @State private var dataPoints: [ChartDataPoint] = []
    @State private var range: ChartRange = .h1
    /// v0.6.1 polish-G:SMART 模式 toggle — 切到 SMART 时显示 mediaErrors / criticalWarningRaw timeline
    /// v0.6.1 polish-J:默认 true,让 SMART 真字段立即可见(温度 24h 主图已在 Temperature tab)
    @State private var showSMART: Bool = true
    /// SMART timeline data points(mediaErrors)
    @State private var mediaErrorsPoints: [ChartDataPoint] = []
    /// SMART timeline data points(criticalWarningRaw)
    @State private var criticalWarningPoints: [ChartDataPoint] = []

    var body: some View {
        let cardShape = RoundedRectangle(cornerRadius: 20, style: .continuous)
        VStack(alignment: .leading, spacing: 6) {
            headerBar
            Group {
                if showSMART {
                    smartTimelineView
                } else {
                    temperatureChartView
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 10)
        .frame(minWidth: 180, idealWidth: 220, maxWidth: 280,
               minHeight: 140, idealHeight: 180, maxHeight: 220)
        .background(cardShape.fill(.regularMaterial))
        .overlay(cardShape.stroke(Color.white.opacity(0.08), lineWidth: 1))
        .clipShape(cardShape)
        .contentShape(cardShape)
        .task(id: range) {
            await reload()
        }
        .task(id: monitor.selectedDisk?.volumeUUID) {
            await reload()
        }
        .task(id: showSMART) {
            await reload()
        }
    }

    private var headerBar: some View {
        HStack(spacing: 6) {
            Text(String(localized: "module.chartmini.title", defaultValue: "Temperature · 24h"))
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .tracking(0.6)
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            Spacer(minLength: 4)
            Picker("Range", selection: $range) {
                Text(ChartRange.h1.localizedLabel).tag(ChartRange.h1)
                Text(ChartRange.h24.localizedLabel).tag(ChartRange.h24)
            }
            .pickerStyle(.segmented)
            .controlSize(.mini)
            .frame(width: 78)
            .labelsHidden()
            Button {
                withAnimation(.easeInOut(duration: 0.25)) {
                    showSMART.toggle()
                }
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: showSMART ? "bolt.shield.fill" : "bolt.shield")
                        .font(.system(size: 10, weight: .regular))
                    Text("SMART")
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .tracking(0.5)
                }
                .foregroundStyle(showSMART ? Color.dsNormal : Color.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Color.white.opacity(showSMART ? 0.08 : 0.04))
                )
            }
            .buttonStyle(.plain)
            .help(String(localized: "module.chartmini.smartHelp", defaultValue: "Toggle SMART timeline"))
        }
    }

    // MARK: - 温度折线

    private var temperatureChartView: some View {
        InteractiveChartView(
            data: dataPoints,
            type: .area,
            title: String(localized: "module.chartmini.tempTitle", defaultValue: "Temperature"),
            unit: "°C",
            color: monitor.healthLevel.color,
            rangeOptions: [],
            referenceLines: referenceLines,
            compact: true,
            displayRange: range
        )
        .id("temp-\(range.rawValue)")
    }

    // MARK: - v0.6.1 polish-G:SMART timeline(2 个迷你 chart)

    /// SMART 模式:2 个迷你 chart 上下排,共用外层 1H/24H,不再各自套一层玻璃卡
    private var smartTimelineView: some View {
        VStack(spacing: 4) {
            InteractiveChartView(
                data: mediaErrorsPoints,
                type: .area,
                title: "Media Errors",
                unit: "count",
                color: smartLineColor(forValues: mediaErrorsPoints),
                rangeOptions: [],
                referenceLines: [
                    ChartReferenceLine(
                        label: "0",
                        value: 0,
                        color: .secondary,
                        dashed: true
                    )
                ],
                compact: true,
                displayRange: range
            )
            InteractiveChartView(
                data: criticalWarningPoints,
                type: .area,
                title: "Critical Warning",
                unit: "raw",
                color: smartLineColor(forValues: criticalWarningPoints),
                rangeOptions: [],
                referenceLines: [
                    ChartReferenceLine(
                        label: "0",
                        value: 0,
                        color: .secondary,
                        dashed: true
                    )
                ],
                compact: true,
                displayRange: range
            )
        }
        .id("smart-\(range.rawValue)")
    }

    private func reload() async {
        if showSMART {
            await fetchSMARTData()
        } else {
            await fetchData()
        }
    }

    /// SMART 折线颜色:任意值 >0 → 暗红(dsDanger);全部 ==0 → 琥珀(dsNormal)
    private func smartLineColor(forValues points: [ChartDataPoint]) -> Color {
        points.contains(where: { $0.value > 0 }) ? .dsDanger : .dsNormal
    }

    // MARK: - 阈值参考线

    private var referenceLines: [ChartReferenceLine] {
        [
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
            ),
        ]
    }

    // MARK: - 数据

    /// 拉 [now - range.seconds, now] 区间内的 SmartSnapshot(温度)
    private func fetchData() async {
        guard let uuid = monitor.selectedDisk?.volumeUUID else {
            dataPoints = []
            return
        }
        let now = Date()
        let start = now.addingTimeInterval(-range.seconds)
        let granularity: String = (range == .h1)
            ? SmartSnapshot.granularityRaw
            : SmartSnapshot.granularityMinute
        let descriptor = FetchDescriptor<SmartSnapshot>(
            predicate: #Predicate<SmartSnapshot> { s in
                s.diskUUID == uuid
                && s.granularity == granularity
                && s.timestamp >= start
                && s.timestamp <= now
            },
            sortBy: [SortDescriptor(\.timestamp, order: .forward)]
        )
        let snaps = (try? modelContext.fetch(descriptor)) ?? []
        dataPoints = snaps.compactMap { s in
            guard SmartParse.isPlausibleCelsius(s.celsius) else { return nil }
            return ChartDataPoint(
                label: s.timestamp.formatted(.dateTime.hour().minute()),
                value: Double(s.celsius),
                date: s.timestamp
            )
        }
    }

    /// v0.6.1 polish-G:拉 SMART timeline(mediaErrors / criticalWarningRaw)
    /// - 1H raw(5s 粒度)或 24H minute(分钟桶)
    private func fetchSMARTData() async {
        guard let uuid = monitor.selectedDisk?.volumeUUID else {
            mediaErrorsPoints = []
            criticalWarningPoints = []
            return
        }
        let now = Date()
        let start = now.addingTimeInterval(-range.seconds)
        let granularity: String = (range == .h1)
            ? SmartSnapshot.granularityRaw
            : SmartSnapshot.granularityMinute
        let descriptor = FetchDescriptor<SmartSnapshot>(
            predicate: #Predicate<SmartSnapshot> { s in
                s.diskUUID == uuid
                && s.granularity == granularity
                && s.timestamp >= start
                && s.timestamp <= now
            },
            sortBy: [SortDescriptor(\.timestamp, order: .forward)]
        )
        let snaps = (try? modelContext.fetch(descriptor)) ?? []
        mediaErrorsPoints = snaps.map { s in
            ChartDataPoint(
                label: s.timestamp.formatted(.dateTime.hour().minute()),
                value: Double(s.mediaErrors),
                date: s.timestamp
            )
        }
        criticalWarningPoints = snaps.map { s in
            ChartDataPoint(
                label: s.timestamp.formatted(.dateTime.hour().minute()),
                value: Double(s.criticalWarningRaw),
                date: s.timestamp
            )
        }
    }
}
