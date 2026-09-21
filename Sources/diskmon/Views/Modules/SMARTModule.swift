import SwiftUI

/// SMART 全字段模块 v0.4.0 wave-4g(高级交互规范版)
/// v0.6.1 polish-G:删 6 项 ATA "—" placeholder + 10 项真 NVMe SMART 字段
/// v0.7 polish-K:全部字段 nil-safe + cumulativeEnergyKWh(估算) 替换为 powerConsumptionWatts(真实)
/// v0.9.3 健康 UX 升级(DriveDx 风格):
///   - 字段名改走 SmartFieldMetadata(人类可读)
///   - 行下方加 description(DriveDx 风 actionable 文案)
///   - severity 决定行内颜色(不是按 SMART 阈值算,按"字段危险度"算)
///   - .critical 字段非零 → 醒目 amber 边框 + "Backup now" CTA
///
/// 单一职责:接收 SmartData → 渲染 280×220 玻璃卡内的 10 行 NVMe SMART 字段表
/// 设计选择(高级交互规范):
/// - **玻璃卡规范**(任务硬规则):真液态玻璃(macOS 26+ `backgroundExtensionEffect()`)
///   + 1px `rgba(255,255,255,0.08)` 边 + 顶边高光 LinearGradient 1px inset
///   + `0 24px 48px rgba(0,0,0,0.4)` 阴影 + 20px 圆角 + 35mm 噪点 PNG + vignette
///   全部走 `Views/Preferences/GlassBackground.swift` 的 `.glass(withNoise: true)` 统一接口
/// - **标题**:"SMART attributes" Fraunces 14pt 琥珀
/// - **10 字段表**(v0.6.1 polish-G 全换真 NVMe 字段,v0.7 polish-K 改 nil-safe):
///   - mediaErrors / criticalWarningRaw / availableSpare / percentageUsed /
///     unsafeShutdowns / powerOnHours / powerCycles / dataUnitsReadTB / dataUnitsWrittenTB /
///     powerConsumptionWatts(v0.7 新,代 cumulativeEnergyKWh 估算)/ temperature
///   - 全部从 SmartData 字段拿真值;nil → "—"(不显 "0",区别"未采集"vs"采集到 0")
/// - **配色阈值**(任务硬规则):
///   - mediaErrors:0 绿 / 1+ 红
///   - criticalWarningRaw:bit0/bit4 非 0 → "ALERT:X" 高亮
///   - availableSpare:>=25 绿 / 10-24 黄 / <10 红
///   - percentageUsed:<70 绿 / 70-89 黄 / >=90 红
///   - unsafeShutdowns:0 绿 / 1-50 黄 / >50 红
/// - **行布局**(v0.9.3 升级):
///   - 字段名(SmartFieldMetadata.humanReadableName)+ value + 状态点
///   - 行下方小字 description(DriveDx 风 actionable 翻译)
///   - severity = .critical 字段非零:加 amber 边框 + "Backup now" CTA
/// - **行 hover**:背景 `rgba(255,255,255,0.04)` 0.15s ease
/// - **数字滚动**:`.contentTransition(.numericText(value:))` + 0.3s ease(只对真值字段;nil → 静态)
/// - **焦点环**:琥珀 2px stroke(`focusable() + focusEffectDisabled() + @FocusState`)
/// - **按下态**:下沉 1px + scale 0.99
/// - **不 loop 动画** / 不弹跳 / 不 mock / nil → "—"
///
/// === 数据流 ===
/// 1. View 接受 `SmartData`(从 `HealthMonitor.currentByUUID[uuid]` 拿)
/// 2. 真值字段直接绑 SmartData;无 SMART 数据 → 显 "—"
/// 3. View 不自己跑 smartctl;数据流是单向:HealthMonitor → View
///
/// === v0.6.1 polish-G 关键决策 ===
/// - **删 6 项 ATA placeholder**:旧版 Reallocated Sectors / Current Pending Sector / Offline
///   Uncorrectable / UDMA CRC Errors / Spin Retry / Load Cycle Count 6 项 ATA 字段
///   SmartctlService 当前只解析 NVMe 协议,ATA 协议不解析
///   旧版显 "—" 是诚实但占空间 — polish-G 改直接删掉,只显示真 NVMe 字段
/// - **加 10 项真 NVMe 字段**:mediaErrors / criticalWarningRaw / availableSpare /
///   percentageUsed / unsafeShutdowns / powerOnHours / powerCycles / dataUnitsReadTB /
///   dataUnitsWrittenTB / powerConsumptionWatts + 1 项 temperature 大字 Fraunces italic
///   全部真 SMART 解析结果(SmartData 字段都已在 SmartctlService 填好)
/// - **温度字段独立**:temperature 用 Fraunces italic 28pt 大字展示(任务硬规则),
///   跟其他 9 项 SF Mono 11pt 区分
///
/// === v0.7 polish-K 关键决策 ===
/// - **全部字段 nil-safe**:`SmartData` 字段全 optional,UI 端显 "—"(区别 "未采集" vs "采集到 0")
///   颜色判断用 nil-check,nil → `.normal` 状态(因"不知道"不等于"健康")
/// - **cumulativeEnergyKWh 替换 powerConsumptionWatts**:5W × hours 估算 → NVMe Supported Power
///   States 真实 per-disk 功耗;主人硬规则"宁可做不到也不接受凑合"要求替换估算值
///
/// === v0.9.3 关键决策(健康 UX 升级)===
/// - **jargon → 人话**:字段名不再裸 "Available Spare",走 SmartFieldMetadata.humanReadableName
///   (虽然本版本英文名跟原 SMARTField.name 差不多,但 description 字段是真 DriveDx 风 actionable)
/// - **actionable 描述**:每行下方 1 行小字 description(DriveDx "Replace if > 0" 风)
/// - **amber CTA 触发条件**:
///   - 字段 severity == .critical
///   - AND 字段非零(mediaErrors > 0 / criticalWarningRaw bit0 || bit4)
///   - 触发后该行:amber 1.5px 边框 + "Backup now" SF Symbol + 字(可点)
///
/// === 不做 ===
/// - 不在 UI 直接跑 smartctl
/// - 不 mock 数据
/// - 不写 SwiftData
/// - 不动 `GlassBackground.swift` / 5 个 Preferences 子 View /
///   `AppSettings.swift` / `Localizable.strings`(任务硬规则)
struct SMARTModule: View {
    /// v0.4.0 polish-D:tab 切换标识(SMART tab)
    enum Detail { case overview, temperature, capacity, power, smart }
    static let moduleTab: Detail = .smart

    let smart: SmartData
    @Environment(AppSettings.self) private var settings

    // MARK: - 交互状态

    /// 当前 hover 的行 ID(nil = 没 hover)
    @State private var hoveredRowID: String? = nil
    /// 焦点(Tab 键)
    @FocusState private var isFocused: Bool
    /// 按下态
    @State private var isPressed: Bool = false

    var body: some View {
        cardBody
            // v0.4.0 polish-C:自适应(跟其他 Module 卡 min/ideal/max 一致)
            .frame(minWidth: 200, idealWidth: 280, maxWidth: .infinity,
                   minHeight: 180, alignment: .topLeading)
            .animation(.easeOut(duration: 0.15), value: hoveredRowID)
            .animation(.easeOut(duration: 0.15), value: isFocused)
            .animation(.easeInOut(duration: 0.12), value: isPressed)
    }

    // MARK: - 卡片本体

    private var cardBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            // === 标题 ===
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                Text(L10n.t("card.smart.attributes", zh: "SMART 属性", en: "SMART attributes", language: settings.language))
                    .font(.fraunces(size: 14, weight: .regular, italic: true))
                    .foregroundStyle(Color.dsNormal)
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 8)

            // === 温度大字(任务硬规则)===
            // - Fraunces italic 28pt + 颜色按温度阈值
            // - 跟下面 9 字段表区分,头部是核心指标
            // v0.7 polish-K:温度 nil → "—" + .secondary(不显 "0")
            // v0.9.1 polish-P2:温度显示走 SmartDataFormatter.celsius(nil/0 → "—",不带 °C 后缀;
            //   下方独立 "°C" 单位标签)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(SmartDataFormatter.celsius(smart.celsius)
                    .replacingOccurrences(of: "°C", with: ""))
                    .font(.fraunces(size: 28, weight: .regular, italic: true))
                    .foregroundStyle(temperatureColor)
                    .monospacedDigit()
                    .lineLimit(1)
                Text("°C")
                    .font(.system(size: 14, weight: .regular, design: .monospaced))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("NVMe SMART")
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .tracking(0.6)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 10)

            Divider()
                .background(Color.white.opacity(0.05))
                .padding(.horizontal, 8)

            // === 9 字段表 ===
            VStack(spacing: 0) {
                ForEach(fields) { field in
                    fieldRow(field)
                }
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 10)
        }
        // v0.4.0 polish-C:外层 frame 已设;内层卡片填满父容器
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
        // 按下态(任务:下沉 1px)
        .scaleEffect(isPressed ? 0.99 : 1.0)
        .offset(y: isPressed ? 1 : 0)
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 0)
                .onChanged { _ in isPressed = true }
                .onEnded { _ in isPressed = false }
        )
        // v0.4.0 polish-B:真液态玻璃 + 35mm 噪点(走 `.glass(withNoise: true)` 统一接口)
        // - macOS 26+ 走 `backgroundExtensionEffect()`(系统级液态玻璃)
        // - macOS 14-25 走 NSVisualEffectView(`.popover` + `vibrantDark`)兜底
        // - 1px 边 + 顶高光 + 阴影都在 modifier 里
        .glass(cornerRadius: 20, withNoise: true)
    }

    // MARK: - 温度颜色

    /// 任务硬规则:>=85 红 / 80-84 琥珀 / 70-79 琥珀深 / <70 琥珀 normal
    /// 跟 HealthLevel / TemperatureModule 阈值保持一致
    /// v0.7 polish-K:nil → .secondary(占位色,区别于 0°C 的 .dsNormal)
    private var temperatureColor: Color {
        guard let c = smart.celsius else { return .secondary }
        if c >= 85 { return .dsDanger }
        if c >= 80 { return .dsCritical }
        if c >= 70 { return .dsWarning }
        return .dsNormal
    }

    // MARK: - 单行渲染

    /// 单行渲染(v0.9.3 升级:加 description + amber 边框 + "Backup now" CTA)
    /// 布局:
    /// ```
    /// ┌──────────────────────────────────────────────────────┐
    /// │ fieldName                  value              ●      │  11pt SF Mono
    /// │ description (small italic actionable)                │  9pt italic 次色
    /// │ [BACKUP NOW] (if severity==.critical && nonzero)    │  amber 1.5px 边框
    /// └──────────────────────────────────────────────────────┘
    /// ```
    /// - severity == .critical AND 字段非零 → 整行 amber 1.5px 边框 + "Backup now" CTA
    private func fieldRow(_ field: SMARTField) -> some View {
        let isHover = hoveredRowID == field.id
        let showAmberCTA = field.requiresAmberCTA
        return VStack(alignment: .leading, spacing: 2) {
            // === 主行:字段名 + value + 状态点 ===
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                // 字段名(SF Mono,文字次色)— v0.9.3 走 SmartFieldMetadata.humanReadableName
                Text(SmartFieldMetadata.localizedName(id: field.id, language: settings.language))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)

                // Value(SF Mono,按状态着色;真值带数字滚动)
                valueText(for: field)

                // 状态点(4px 圆,按状态着色)
                Circle()
                    .fill(field.status.color)
                    .frame(width: 4, height: 4)
            }

            // === description 行(v0.9.3 新加)===
            // - 仅在 description 非空时显示
            // - 9pt italic 次色,DriveDx "Replace if > 0" 风格 actionable 文案
            // - severity == .critical 字段 → 描述用 dsCritical 色强调(仍 italic)
            let desc = SmartFieldMetadata.localizedDescription(id: field.id, language: settings.language)
            if !desc.isEmpty {
                Text(desc)
                    .font(.system(size: 9, weight: .regular, design: .default))
                    .italic()
                    .foregroundStyle(field.requiresAmberCTA ? Color.dsCritical.opacity(0.85) : Color.secondary.opacity(0.7))
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // === amber CTA(v0.9.3 新加)— severity .critical AND 非零 ===
            // - 醒目 amber 1.5px 边框 + "Backup now" SF Symbol + 字
            // - 整行包 amber RoundedRectangle(8pt 圆角),只在 showAmberCTA 时
            // - CTA 是静态显示,不可点(任务硬规则:不写 SwiftData / 不动 state)— 只是个视觉提醒
            if showAmberCTA {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 9, weight: .semibold))
                    Text(L10n.t("smart.action.backupNow", zh: "立即备份", en: "BACKUP NOW", language: settings.language))
                        .font(.system(size: 9, weight: .heavy, design: .monospaced))
                        .tracking(0.6)
                }
                .foregroundStyle(Color.dsCritical)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .stroke(Color.dsCritical, lineWidth: 1)
                        .background(
                            RoundedRectangle(cornerRadius: 3, style: .continuous)
                                .fill(Color.dsCritical.opacity(0.12))
                        )
                )
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        // hover 背景:rgba(255,255,255,0.04) 0.15s
        .background(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(Color.white.opacity(isHover ? 0.04 : 0))
        )
        // v0.9.3:amber CTA 字段 → 整行加 amber 1.5px 边框 + 4pt 浅琥珀内底
        // - 整行(主行 + description + CTA)用 8pt 圆角 amber 边框包
        // - 边框 + 内底都只在 showAmberCTA 时出现
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(
                    showAmberCTA ? Color.dsCritical : Color.clear,
                    lineWidth: showAmberCTA ? 1.5 : 0
                )
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(showAmberCTA ? Color.dsCritical.opacity(0.06) : Color.clear)
                )
                .padding(-2)
        )
        .contentShape(Rectangle())
        .onHover { hovering in
            hoveredRowID = hovering ? field.id : (hoveredRowID == field.id ? nil : hoveredRowID)
        }
    }

    /// Value 文本:真值字段带数字滚动,—" 字段固定
    @ViewBuilder
    private func valueText(for field: SMARTField) -> some View {
        if let numeric = field.numericValue {
            Text(field.value)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(field.status.color)
                .frame(width: 110, alignment: .trailing)
                .contentTransition(.numericText(value: numeric))
                .animation(.easeInOut(duration: 0.3), value: numeric)
        } else {
            Text(field.value)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(field.status.color)
                .frame(width: 110, alignment: .trailing)
        }
    }

    // MARK: - 字段模型

    fileprivate struct SMARTField: Identifiable {
        let id: String
        let name: String
        let value: String
        /// 状态点 + value 着色
        let status: Status
        /// 真值 → 数字滚动;nil → 静态 "—"
        let numericValue: Double?
        /// v0.9.3:字段元数据(人类可读名 + description + severity)
        let metadata: SmartFieldMetadata
        /// v0.9.3:是否触发 amber CTA 边框("Backup now" + amber 1.5px 边框)
        /// - severity == .critical AND 字段非零(mediaErrors > 0 / criticalWarningRaw bit0||bit4)
        /// - 只在 .info / .context 字段 → false
        let requiresAmberCTA: Bool

        enum Status {
            case normal, warning, critical, danger

            var color: Color {
                switch self {
                case .normal:   return .dsNormal
                case .warning:  return .dsWarning
                case .critical: return .dsCritical
                case .danger:   return .dsDanger
                }
            }
        }
    }

    // MARK: - 9 字段(v0.6.1 polish-G 全换真 NVMe)

    /// 9 项真 NVMe SMART 字段(删 6 项 ATA placeholder)
    /// 阈值参考 NVMe spec + HealthPredictor:
    ///   - mediaErrors:>0 → .danger(介质错误,SSD 出这个基本废了)
    ///   - criticalWarningRaw:>0 → .danger(NVMe bit0/bit4 不可恢复)
    ///   - availableSpare:<10 → .critical / <25 → .warning / else .normal
    ///   - percentageUsed:>=90 → .critical / >=70 → .warning / else .normal
    ///   - unsafeShutdowns:>50 → .warning / else .normal
    ///   - powerOnHours / powerCycles:无阈值,.normal
    ///   - dataUnitsReadTB / WrittenTB:无阈值,.normal
    ///   - powerConsumptionWatts(v0.7 polish-K 新增,代 cumulativeEnergyKWh):
    ///     真实 NVMe Supported Power States max watt,无阈值,.normal
    /// v0.7 polish-K:全部字段 nil-safe(partial parse 友好)
    ///   - value:nil → "—"(不显 "0")
    ///   - numericValue:nil → 静态不滚动
    ///   - status:nil → .normal(无报警色,因"不知道"不等于"健康")
    private var fields: [SMARTField] {
        // 1. mediaErrors(NVMe 0x02 byte 11..12)— 介质错误计数
        //    >0 → .danger(SMART 独立危险信号)
        let mediaErrVal = smart.mediaErrors
        let mediaErrStatus: SMARTField.Status = (mediaErrVal ?? 0) > 0 ? .danger : .normal

        // 2. criticalWarningRaw(NVMe 0x02 byte 0)— Critical Warning byte
        //    >0 → .danger;显示 "ALERT:X" 高亮(任务硬规则)
        let critWarnVal = smart.criticalWarningRaw
        let critWarnStatus: SMARTField.Status = (critWarnVal ?? 0) > 0 ? .danger : .normal
        let critWarnValue: String = {
            guard let v = critWarnVal, v > 0 else { return critWarnVal == nil ? "—" : "0" }
            return "ALERT:\(v)"
        }()

        // 3. availableSpare(NVMe 0x02 byte 4)— 备块%
        //    <10 → .critical / <25 → .warning / else .normal
        let spareVal = smart.availableSpare
        let spareStatus: SMARTField.Status = {
            guard let s = spareVal else { return .normal }
            return s < 10 ? .critical : s < 25 ? .warning : .normal
        }()

        // 4. percentageUsed(NVMe 0x02 byte 3)— 寿命%(0=新,100=命终)
        //    >=90 → .critical / >=70 → .warning / else .normal
        let usedVal = smart.percentageUsed
        let usedStatus: SMARTField.Status = {
            guard let u = usedVal else { return .normal }
            return u >= 90 ? .critical : u >= 70 ? .warning : .normal
        }()

        // 5. unsafeShutdowns(NVMe 0x07)— 异常断电次数
        //    >50 → .danger / >0 → .warning / else .normal
        let unsafeVal = smart.unsafeShutdowns
        let unsafeStatus: SMARTField.Status = {
            guard let u = unsafeVal else { return .normal }
            return u > 50 ? .danger : u > 0 ? .warning : .normal
        }()

        // 6. powerOnHours(NVMe 0x09)— 上电小时
        //    任务硬规则:显示 "X days"(÷ 24);nil → "—"
        let pohVal = smart.powerOnHours
        let pohValue: String = {
            guard let h = pohVal else { return "—" }
            return "\(h / 24)d"
        }()

        // 7. powerCycles(NVMe 0x0C)— 上电循环
        let powerCyclesVal = smart.powerCycles

        // 8. dataUnitsReadTB / 9. dataUnitsWrittenTB(NVMe 0x06)
        //    ByteFormatter.tb() 已处理 "1.23 TB" / "456 GB";nil → "—"
        let readVal = smart.dataUnitsReadTB
        let writeVal = smart.dataUnitsWrittenTB
        let readValue: String = readVal.map { ByteFormatter.tb($0) } ?? "—"
        let writeValue: String = writeVal.map { ByteFormatter.tb($0) } ?? "—"

        // 10. powerConsumptionWatts(v0.7 polish-K 替换 cumulativeEnergyKWh)
        //     NVMe Supported Power States 第一状态行 max watt(真实 per-disk)
        //     任务硬规则:"X.XX W";nil → "—"
        let powerVal = smart.powerConsumptionWatts

        return [
            SMARTField(
                id: "mediaErrors",
                name: String(localized: "smart.mediaErrors", defaultValue: "Media Errors"),
                // v0.9.1 polish-P2:走 SmartDataFormatter.mediaErrors(nil → "—",0 → "0")
                value: SmartDataFormatter.mediaErrors(mediaErrVal),
                status: mediaErrStatus,
                numericValue: mediaErrVal.map(Double.init),
                // v0.9.3:SmartFieldMetadata(人类可读 + actionable description + .critical)
                metadata: SmartFieldMetadata.metadata(for: "mediaErrors"),
                // v0.9.3:.critical + 非零 → amber CTA
                requiresAmberCTA: (mediaErrVal ?? 0) > 0
            ),
            SMARTField(
                id: "criticalWarning",
                name: String(localized: "smart.criticalWarningRaw", defaultValue: "Critical Warning"),
                value: critWarnValue,
                status: critWarnStatus,
                numericValue: critWarnVal.map(Double.init),
                // v0.9.3:SmartFieldMetadata(人类可读 + actionable description + .critical)
                metadata: SmartFieldMetadata.metadata(for: "criticalWarning"),
                // v0.9.3:.critical + bit0||bit4 非零 → amber CTA(bit1/2/3 不算)
                //   NVMe spec:bit0=spare below / bit1=temperature / bit2=reliability /
                //   bit3=read-only / bit4=backup failed — 只有 bit0 + bit4 是真硬件故障
                //   bit1 走温度 dwell 路径,bit2/3 是边缘情况先不管
                requiresAmberCTA: (critWarnVal.map { ($0 & 0x01) != 0 || ($0 & 0x10) != 0 } ?? false)
            ),
            SMARTField(
                id: "availableSpare",
                name: String(localized: "smart.availableSpare", defaultValue: "Available Spare"),
                // v0.9.1 polish-P2:走 SmartDataFormatter.availableSpare(nil → "—",0 → "0%")
                value: SmartDataFormatter.availableSpare(spareVal),
                status: spareStatus,
                numericValue: spareVal.map(Double.init),
                // v0.9.3:.context severity,无 amber CTA
                metadata: SmartFieldMetadata.metadata(for: "availableSpare"),
                requiresAmberCTA: false
            ),
            SMARTField(
                id: "percentageUsed",
                name: String(localized: "smart.percentageUsed", defaultValue: "Percentage Used"),
                // v0.9.1 polish-P2:走 SmartDataFormatter.percentageUsed(nil → "—",0 → "0%")
                value: SmartDataFormatter.percentageUsed(usedVal),
                status: usedStatus,
                numericValue: usedVal.map(Double.init),
                // v0.9.3:.context severity,无 amber CTA(健康度评分里会反映)
                metadata: SmartFieldMetadata.metadata(for: "percentageUsed"),
                requiresAmberCTA: false
            ),
            SMARTField(
                id: "unsafeShutdowns",
                name: String(localized: "smart.unsafeShutdowns", defaultValue: "Unsafe Shutdowns"),
                // v0.9.1 polish-P2:走 SmartDataFormatter.unsafeShutdowns(nil → "—",0 → "0")
                value: SmartDataFormatter.unsafeShutdowns(unsafeVal),
                status: unsafeStatus,
                numericValue: unsafeVal.map(Double.init),
                // v0.9.3:.context severity,无 amber CTA
                metadata: SmartFieldMetadata.metadata(for: "unsafeShutdowns"),
                requiresAmberCTA: false
            ),
            SMARTField(
                id: "powerOnHours",
                name: String(localized: "smart.powerOnHours", defaultValue: "Power On Hours"),
                value: pohValue,
                status: .normal,
                numericValue: pohVal.map(Double.init),
                // v0.9.3:.info severity,无 amber CTA
                metadata: SmartFieldMetadata.metadata(for: "powerOnHours"),
                requiresAmberCTA: false
            ),
            SMARTField(
                id: "powerCycles",
                name: String(localized: "smart.powerCycles", defaultValue: "Power Cycles"),
                // v0.9.1 polish-P2:走 SmartDataFormatter.powerCycles(nil → "—",0 → "0")
                value: SmartDataFormatter.powerCycles(powerCyclesVal),
                status: .normal,
                numericValue: powerCyclesVal.map(Double.init),
                // v0.9.3:.info severity,无 amber CTA
                metadata: SmartFieldMetadata.metadata(for: "powerCycles"),
                requiresAmberCTA: false
            ),
            SMARTField(
                id: "dataRead",
                name: String(localized: "smart.dataUnitsReadTB", defaultValue: "Data Read"),
                value: readValue,
                status: .normal,
                numericValue: readVal,
                // v0.9.3:.info severity,无 amber CTA
                metadata: SmartFieldMetadata.metadata(for: "dataRead"),
                requiresAmberCTA: false
            ),
            SMARTField(
                id: "dataWritten",
                name: String(localized: "smart.dataUnitsWrittenTB", defaultValue: "Data Written"),
                value: writeValue,
                status: .normal,
                numericValue: writeVal,
                // v0.9.3:.context severity,无 amber CTA
                metadata: SmartFieldMetadata.metadata(for: "dataWritten"),
                requiresAmberCTA: false
            ),
            SMARTField(
                id: "powerConsumption",
                name: String(localized: "smart.powerConsumptionWatts", defaultValue: "Power Max (W)"),
                // v0.9.1 polish-P2:走 SmartDataFormatter.power(nil/0 → "—",> 0 → "X.XX W")
                value: SmartDataFormatter.power(powerVal),
                status: .normal,
                numericValue: powerVal,
                // v0.9.3:.info severity,无 amber CTA
                metadata: SmartFieldMetadata.metadata(for: "powerConsumption"),
                requiresAmberCTA: false
            ),
        ]
    }
}
