import SwiftUI
import SwiftData

/// 温度模块 v0.4.0 wave-4F(高级交互规范版)
/// v0.6.1 polish-G:副标加 1 行 "健康度 X/100 · 升温 +0.8°C/min"
/// v0.9.4:不再算 hottest,改用 `monitor.selectedDisk ?? monitor.watchedDisks.first`
///   - 旧 `hottest` 派生 = "celsius 最大的盘",跟 `selectedDisk`(用户切盘)分裂
///   - 修后:用户切盘 → 温度模块同步切到该盘(跟其他 8 tab Content 一致)
/// v0.9.4:smartctl 报"无温度传感器"的盘(常见 ssd 512 内部盘)— 显 "No temperature sensor"
///   - `celsius == nil` + 其他 SMART 字段有 → 琥珀 "No temperature sensor"
///   - `celsius == nil` + 无 SMART 任何数据 → 次色 "—"
///   - `disk == nil`(无任何盘)→ 次色 "No data"
///
/// 单一职责:接收 `HealthMonitor` + `AppSettings` + `HealthPredictor` + `modelContext`
///   → 渲染 220×180 玻璃卡内的"最热盘实时温度 + 24h 迷你 sparkline + 健康度副标 + 趋势"
///
/// === 数据来源(全部真实,不 mock) ===
/// - **大数字**:`monitor.watchedDisks` × `monitor.currentByUUID[uuid]` 的 max(celsius)
///   - celsius == 0 表示"还没采到"(磁盘刚发现 5s 窗口期),用 fallback 退回 first
///   - 单位转换:`AppSettings.displayTemperature(celsius:)`(℃/℉)
/// - **副标**:`modelName` 或 `mountPoint` lastPathComponent + 当前温度
/// - **sparkline 24h**:`SwiftData` 拉 `SmartSnapshot(granularity: .minute, last 24h)`
///   - 选中盘(hottest)的最近 24h 温度分钟桶
/// - **v0.6.1 polish-G 健康度副标**:
///   - "健康度 X/100" — `HealthPredictor.warning(forDiskUUID:)` → healthScore
///   - "升温 +0.8°C/min" / "降温 -0.5°C/min" / "稳定" — `HealthPredictor.currentTrend(forDiskUUID:)`
///     算 slope(°C/s) × 60 = °C/min
///
/// === 设计选择(高级交互规范) ===
/// - **大数字**:Fraunces 56pt em italic + `.contentTransition(.numericText(value:))` + 0.3s
/// - **副标**:SF Mono 11pt,hover 时从次色 → 主题前景
/// - **v0.6.1 polish-G 健康度副标**:SF Mono 10pt "健康度" + Fraunces 14pt italic "X/100 · 升温/降温/稳定"
/// - **温度 → 颜色**:
///   - `celsius >= criticalTempCelsius` → `.dsCritical`(红 `#A83838`)
///   - `celsius >= warningTempCelsius`  → `.dsWarning`(深琥珀 `#D97706`,跟 normal 同色,
///     用「脉冲 / 上下文」区分,Wave 5 加)
///   - 否则 `.dsNormal`(深琥珀)
///   - nil → 文字次色("—")
/// - **sparkline**:80×40 mini 琥珀色,数字旁右侧
/// - **hover / focus / press 规范**:与 HealthOverviewModule 一致
///
/// === 不做 ===
/// - 不 mock 数据(nil → "—" + "No data")
/// - 不在 UI 直接跑 `smartctl`(只读 `currentByUUID`)
/// - 不动 `GlassBackground.swift` / 5 Preferences 子 View / `AppSettings.swift` /
///   `Localizable.strings`
struct TemperatureModule: View {
    /// v0.4.0 polish-D:tab 切换标识(温度 tab)
    enum Detail { case overview, temperature, capacity, power, smart }
    static let moduleTab: Detail = .temperature

    @Environment(HealthMonitor.self) private var monitor
    @Environment(AppSettings.self) private var settings
    @Environment(\.modelContext) private var modelContext
    /// v0.6.1 polish-G:接 HealthPredictor(健康度 + 趋势)
    @Environment(HealthPredictor.self) private var predictor

    // MARK: - 交互状态

    @State private var isCardHovered: Bool = false
    @State private var isPressed: Bool = false
    @FocusState private var isFocused: Bool
    @State private var sparklineValues: [Double] = []

    var body: some View {
        cardBody
            // v0.4.0 polish-C:自适应 min/ideal/max(配合 PopoverView LazyVGrid adaptive)
            .frame(minWidth: 180, idealWidth: 220, maxWidth: .infinity,
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
            .animation(.easeInOut(duration: 0.3), value: tempText)
            // 切换 selected disk 时重拉 sparkline
            .task(id: monitor.selectedDisk?.volumeUUID) {
                while !Task.isCancelled {
                    await fetchSparkline()
                    try? await Task.sleep(nanoseconds: 15_000_000_000)
                }
            }
    }

    // MARK: - 卡片本体

    private var cardBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            // === 顶部:小标签(v0.9.4 从 "HOTTEST" 改 "SELECTED" — 走 monitor.selectedDisk) ===
            HStack(spacing: 4) {
                Image(systemName: "thermometer.medium")
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(.tertiary)
                Text(L10n.t("module.temperature.selected", zh: "当前盘", en: "SELECTED", language: settings.language))
                    .font(.system(size: 11, weight: .medium, design: .default))
                    .tracking(0.6)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 4)
                if let speed = selectedInterfaceSpeed {
                    Text(speed)
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
            }
            .padding(.top, 2)

            Spacer(minLength: 0)

            HStack(alignment: .firstTextBaseline, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text(tempText)
                        .font(.fraunces(size: 44, weight: .regular, italic: true))
                        .foregroundStyle(tempColor)
                        .monospacedDigit()
                        .scaleEffect(isCardHovered && !isPlaceholder ? 1.02 : 1.0)
                        .contentTransition(.numericText(value: numericKey))
                        .lineLimit(1)
                    if tempState == .ok {
                        Text(settings.temperatureUnitSymbol)
                            .font(.system(size: 13, weight: .regular, design: .monospaced))
                            .foregroundStyle(textTertiary)
                    }
                }
                Spacer(minLength: 4)
                VStack(alignment: .trailing, spacing: 2) {
                    if let hi = sparklineMax {
                        tempStatRow(
                            label: L10n.t("module.temperature.max", zh: "高", en: "Hi", language: settings.language),
                            value: formattedTemp(hi)
                        )
                    }
                    if let lo = sparklineMin {
                        tempStatRow(
                            label: L10n.t("module.temperature.min", zh: "低", en: "Lo", language: settings.language),
                            value: formattedTemp(lo)
                        )
                    }
                }
            }

            GeometryReader { geo in
                SparklineView(
                    values: sparklineDisplay,
                    lineColor: tempColor,
                    fillColor: tempColor.opacity(0.18),
                    frameSize: CGSize(width: geo.size.width, height: 42),
                    lineWidth: 1.5
                )
            }
            .frame(height: 42)
            .padding(.top, 6)
            .padding(.bottom, 4)

            Spacer(minLength: 0)

            Text(subtitleText)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(isCardHovered ? Color.themeFgDark : .secondary)
                .lineLimit(1)
                .truncationMode(.tail)

            // === v0.6.1 polish-G:底部副标 2:"健康度 X/100 · 升温/降温/稳定" ===
            // - 任务硬规则:Fraunces 14pt italic 琥珀 + 趋势文字
            // - 健康度按 HealthWarning 等级色
            // - 趋势:从 HealthPredictor.currentTrend(forDiskUUID:) 拿 °C/s,× 60 转 °C/min
            //   * > 0.02 °C/s  → "升温 +X.X°C/min"(深琥珀 dsWarning)
            //   * < -0.02 °C/s → "降温 -X.X°C/min"(琥珀 normal)
            //   * else         → "稳定"(次色)
            //   * nil (数据不足) → "—"
            if let healthLine = healthSubtitle, !healthLine.isEmpty {
                HStack(spacing: 4) {
                    Text(healthLine)
                        .font(.fraunces(size: 14, weight: .regular, italic: true))
                        .foregroundStyle(healthSubtitleColor)
                        .monospacedDigit()
                        .lineLimit(1)
                    if !trendText.isEmpty {
                        Text("·")
                            .font(.system(size: 11, weight: .regular, design: .monospaced))
                            .foregroundStyle(.tertiary)
                        Text(trendText)
                            .font(.system(size: 11, weight: .regular, design: .monospaced))
                            .foregroundStyle(trendColor)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(14)
        // v0.4.0 polish-C:让 cardBody 填满外层 frame(min/ideal/max)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: - 数据:选中盘(v0.9.4:从 hottest 改为 selectedDisk)

    /// v0.9.4:选中盘(跟其他 8 tab Content 一致)— 不再算 hottest
    /// - 跟 HealthMonitor.selectedDisk 同步,用户切盘 → 温度模块同步切到该盘
    /// - selectedDisk = selectedDiskUUID ?? watchedDisks.first(在 HealthMonitor 内已定义)
    /// - 兜底:无 selectedDisk → 显 "No data"(次色,跟"无盘"区分)
    private var disk: DiskInfo? {
        monitor.selectedDisk
    }

    /// v0.9.4:选中盘的 SMART 数据 — 跟其他 widget 一致走 monitor.currentByUUID
    /// - 选中盘存在但 SMART 还没采到(5s 窗口期) → nil,UI 显 "—"
    private var smart: SmartData? {
        guard let uuid = disk?.volumeUUID else { return nil }
        return monitor.currentByUUID[uuid]
    }

    /// v0.9.4:温度传感器状态 — 区分"无传感器"vs"无数据"vs"无盘"
    /// - 主人 bug:主人 ssd 512 内部盘无温度传感器,旧版 fall through 到其他盘的 hottest → 假数据
    /// - 现在显式 3 态:`.noSensor`(琥珀 No temperature sensor) / `.noData`(次色 "—") /
    ///   `.noDisk`(次色 No data)
    /// - 规则:
    ///   * disk == nil → .noDisk
    ///   * celsius != nil (含 celsius == 0) → .ok(走真实温度)
    ///   * celsius == nil + 其他 SMART 字段有(criticalWarningRaw / mediaErrors / percentageUsed)→ .noSensor
    ///   * celsius == nil + 整个 SMART 都空 → .noData
    private var tempState: TempSensorState {
        guard let disk else { return .noDisk }
        if let s = smart, s.celsius != nil { return .ok }
        if disk.isUSBBridgeWithoutSMART { return .usbBridge }
        if let s = smart, s.hasSensorFields, s.celsius == nil { return .noSensor }
        return .noData
    }

    private enum TempSensorState {
        case ok
        case noSensor
        case usbBridge
        case noData
        case noDisk
    }

    // MARK: - 文本

    private var isPlaceholder: Bool {
        tempState != .ok
    }

    private var tempText: String {
        switch tempState {
        case .ok:
            guard let c = smart?.celsius, c > 0 else { return "—" }
            let display = settings.displayTemperature(celsius: Double(c))
            return String(format: "%.0f", display)
        case .noDisk:
            return L10n.t(
                "module.temperature.noData",
                zh: "无数据",
                en: "No data",
                language: settings.language
            )
        case .noSensor, .usbBridge, .noData:
            return "—"
        }
    }

    /// `contentTransition(.numericText(value:))` 滚动需要的 `Double` 触发器
    private var numericKey: Double {
        guard tempState == .ok, let c = smart?.celsius else { return 0 }
        return settings.displayTemperature(celsius: Double(c))
    }

    private var subtitleText: String {
        guard let d = disk else {
            return L10n.t("module.temperature.noData", zh: "无数据", en: "No data", language: settings.language)
        }
        let name = displayName(for: d)
        switch tempState {
        case .ok:
            return name
        case .usbBridge, .noSensor:
            return "\(name)  ·  \(unavailableHint)"
        case .noData:
            return "\(name)  ·  \(L10n.t("module.temperature.waitingShort", zh: "正在读取…", en: "Reading…", language: settings.language))"
        case .noDisk:
            return L10n.t("module.temperature.noData", zh: "无数据", en: "No data", language: settings.language)
        }
    }

    private var unavailableHint: String {
        L10n.t(
            "module.temperature.unavailable",
            zh: "无法抓取温度数据",
            en: "Temperature unavailable",
            language: settings.language
        )
    }

    // MARK: - v0.6.1 polish-G:健康度副标 + 趋势

    /// 健康度副标文案:"健康度 X/100" — 走 HealthPredictor
    /// - 无 disk → nil(View 不显示)
    /// - 任务硬规则:Fraunces 14pt italic
    private var healthSubtitle: String? {
        guard let d = disk, tempState == .ok else { return nil }
        let warning = predictor.warning(forDiskUUID: d.volumeUUID)
        return String(
            format: String(
                localized: "module.temperature.healthLabel",
                defaultValue: "健康度 %d/100"
            ),
            warning.healthScore
        )
    }

    /// 健康度副标颜色:按 HealthWarning 等级
    private var healthSubtitleColor: Color {
        guard let d = disk else { return textTertiary }
        return predictor.warning(forDiskUUID: d.volumeUUID).color
    }

    /// 趋势文案:从 HealthPredictor.currentTrend(forDiskUUID:) 拿 °C/s,转 °C/min
    /// - > 0.02 °C/s  → "升温 +X.X°C/min"
    /// - < -0.02 °C/s → "降温 -X.X°C/min"
    /// - else         → "稳定"
    /// - nil (数据不足) → ""(View 不显示)
    private var trendText: String {
        guard let d = disk else { return "" }
        guard let slopePerSec = predictor.currentTrend(forDiskUUID: d.volumeUUID) else {
            return ""
        }
        let perMin = slopePerSec * 60
        if perMin > 0.02 {
            return String(
                format: String(
                    localized: "module.temperature.trendUp",
                    defaultValue: "升温 +%.1f°C/min"
                ),
                perMin
            )
        }
        if perMin < -0.02 {
            return String(
                format: String(
                    localized: "module.temperature.trendDown",
                    defaultValue: "降温 %.1f°C/min"
                ),
                perMin
            )
        }
        return String(localized: "module.temperature.trendStable", defaultValue: "稳定")
    }

    /// 趋势颜色:升温 → dsWarning / 降温 → dsNormal / 稳定 → 文字次色
    private var trendColor: Color {
        guard let d = disk else { return textTertiary }
        guard let slopePerSec = predictor.currentTrend(forDiskUUID: d.volumeUUID) else {
            return textTertiary
        }
        let perMin = slopePerSec * 60
        if perMin > 0.02 { return Color.dsWarning }
        if perMin < -0.02 { return Color.dsNormal }
        return textTertiary
    }

    private var selectedInterfaceSpeed: String? {
        guard let d = disk else { return nil }
        let s = d.interfaceSpeedLabel
        return s == "—" ? nil : s
    }

    private var sparklineDisplay: [Double] {
        var v = sparklineValues
        if let c = smart?.celsius, c > 0 {
            v.append(Double(c))
        }
        return v
    }

    private var sparklineMax: Double? { sparklineDisplay.max() }
    private var sparklineMin: Double? { sparklineDisplay.min() }

    private func formattedTemp(_ celsius: Double) -> String {
        let n = settings.displayTemperature(celsius: celsius)
        return String(format: "%.0f", n)
    }

    private func tempStatRow(label: String, value: String) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundStyle(.tertiary)
            Text(value)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }

    /// 显示盘名:`mountPoint` lastPathComponent → `bsdName` → modelName
    private func displayName(for disk: DiskInfo) -> String {
        if let mp = disk.mountPoint, let last = mp.split(separator: "/").last {
            return String(last)
        }
        if let model = disk.modelName, !model.isEmpty {
            return model
        }
        return disk.bsdName
    }

    // MARK: - 颜色

    private var tempColor: Color {
        // v0.9.4:3 态颜色 — 跟 tempState 对齐
        switch tempState {
        case .ok:
            let c = smart?.celsius ?? 0
            if c >= monitor.criticalTempCelsius { return Color.dsCritical }
            if c >= monitor.warningTempCelsius  { return Color.dsWarning }
            return Color.dsNormal
        case .noSensor, .usbBridge, .noData, .noDisk:
            return textTertiary
        }
    }

    /// 文字次色 `rgba(245, 242, 236, 0.55)`(暖米色)
    private var textTertiary: Color {
        Color(red: 0xF5 / 255, green: 0xF2 / 255, blue: 0xEC / 255).opacity(0.55)
    }

    // MARK: - Sparkline 数据(24h 选 disk)

    /// SwiftData 拉选中盘 24h 分钟桶温度(celsius);失败 → 空数组(SparklineView 自动隐藏)
    private func fetchSparkline() async {
        // sparkline 用 selected disk(用户当前选定的),与"hottest"未必一致
        // —— 主人审美:hottest 数字会跳,sparkline 应该稳定;否则视觉割裂
        guard let uuid = monitor.selectedDisk?.volumeUUID else {
            sparklineValues = []
            return
        }
        let now = Date()
        let start = now.addingTimeInterval(-24 * 3600)
        let minuteGranularity = SmartSnapshot.granularityMinute
        let descriptor = FetchDescriptor<SmartSnapshot>(
            predicate: #Predicate<SmartSnapshot> { s in
                s.diskUUID == uuid
                && s.granularity == minuteGranularity
                && s.timestamp >= start
                && s.timestamp <= now
            },
            sortBy: [SortDescriptor(\.timestamp, order: .forward)]
        )
        let snaps = (try? modelContext.fetch(descriptor)) ?? []
        var vals = snaps.map { Double($0.celsius) }.filter { $0 > 0 }
        if let live = smart?.celsius, live > 0 {
            vals.append(Double(live))
        }
        sparklineValues = vals
    }
}
