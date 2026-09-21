import SwiftUI
import DiskMonCore

/// 实时功耗模块 v0.4.0 wave-4b(高级交互规范版)
/// wave-4F:尺寸 220×120 → 220×180(适配 PopoverView 控制中心多卡网格格点)
/// v0.6.1 polish-G:副标加 1 行 "健康度 X/100" Fraunces 14pt 琥珀
/// v0.7 polish-K:用真 smartctl NVMe Supported Power States(W)替代 powermetrics 估算(更准确)
///
/// 单一职责:接收一块盘 + PowerService → 渲染 220×180 玻璃卡内的"实时功耗(W)" + 健康度
/// 数据来源(v0.7 polish-K 优先级):
///   1) smartctl 真实 per-disk:`monitor.currentByUUID[uuid]?.powerConsumptionWatts`
///      (NVMe Supported Power States 第一行 max watt,SmartctlService.parse 解析)
///      — 真实硬件功耗,SmartData 字段,nil = 未解析到
///   2) powermetrics 系统估算:`PowerService.currentWatts` — 系统 SoC 总功耗代理
///      (因外接盘 TB4/USB 桥接功耗在 Apple Silicon 上无法从系统总功耗里拆分;
///      详见 PowerService.swift docstring)
///      — 5s 缓存,失败 / 权限不足 / 解析失败 → nil
///   3) 两路都 nil → "—" 文字次色
/// 优先级:smartctl 真值 > powermetrics 估算(HealthMonitor.pollOnce 写入 SmartSnapshot 已对齐此优先级)
/// 副标文案:smartctl 有值 → "smartctl power state" / powermetrics fallback → "system estimated" /
///          两路都 nil → "Not available"
///
/// v0.7 polish-K 任务硬规则(主人口气):
///   - 旧版"系统估算"被主人批"凑合",显 5.2W 但实际可能 0.1W(差 50x)
///   - 真值:NVMe spec 必报的 Supported Power States 状态 0 max watt(WD SN570 实测 4.20W)
///   - powermetrics 保留兜底(macOS 内部盘没 NVMe 协议时仍可用)
///
/// - 健康度(v0.6.1):从 `diskBSDName` 反查 volumeUUID → `HealthPredictor.warning(forDiskUUID:)`
///   → healthScore 0-100(任务硬规则:琥珀 14pt 琥珀)
///   BSD → UUID 反查走 `monitor.watchedDisks.first(where: { $0.bsdName == diskBSDName })`
///
/// === 设计选择(高级交互规范) ===
/// - **玻璃卡规范**(任务硬规则):真液态玻璃(macOS 26+ `backgroundExtensionEffect()`)
///   + 1px `rgba(255,255,255,0.08)` 边 + 顶边高光 LinearGradient(0.06 → clear)1px inset
///   + 阴影 `0 24px 48px rgba(0,0,0,0.4)` + 20px 圆角 + 35mm 噪点 PNG
///   全部走 `Views/Preferences/GlassBackground.swift` 的 `.glass(withNoise: true)` 统一接口
/// - **大数字**:Fraunces 56pt em italic,琥珀(主) / 红(critical)— **不引入绿**(主人审美)
///   - 数字滚动:`.contentTransition(.numericText(value:))` + `withAnimation(.easeInOut(duration: 0.3))`
/// - **小标签 "Power"**:11px uppercase letter-spacing 0.08em 文字次色 `rgba(245,242,236,0.55)`
/// - **单位 "W"**:SF Mono 14pt 文字次色
/// - **副标**:smartctl → "smartctl power state" / powermetrics → "system estimated" /
///             都 nil → "Not available"
/// - **v0.6.1 polish-G 健康度副标**:在主副标下方加 1 行 "健康度 75/100" Fraunces 14pt italic
///   - 数字按 HealthWarning 等级着色(danger 暗红 / critical 红 / warning 琥珀深 / none 琥珀)
///   - 没匹配到盘(empty 状态) → 不显示
/// - **hover 交互**:
///   - 玻璃卡边缘高光"内移" 1-2px(`padding` 0→1.5,模拟光带向中心位移,0.3s `cubic-bezier(0.2, 0.8, 0.2, 1)`)
///   - 大数字 1.02 放大 + 琥珀色更亮(`Color.dsNormal.opacity(1.0)` → 显式 `Color.dsNormal`)
///   - 副标从次色 → 主题前景
/// - **焦点环**:琥珀 2px stroke(`focusable() + focusEffectDisabled() + @FocusState` + 自绘,关掉系统默认)
/// - **按下态**:`LongPressGesture(minimumDuration: 0)` 追踪 press → 下沉 1px + scale 0.99 + 阴影收缩
/// - **nil 数据**:"—" 56pt 文字次色 + 副标 "Not available"(11px 文字次色)
/// - **尺寸**:220×180 固定(wave-4F 适配 PopoverView 多卡网格)
/// - **采样触发**:`task(id: diskBSDName)` 在 diskBSDName 变化 / View appear 时跑一次
/// - **5s 缓存**:`task` 内部走 `PowerService.sample()` 自身的 5s TTL,View 层不重复判
///
/// === 不做 ===
/// - 不在 UI 直接跑 powermetrics(只读 `PowerService.currentWatts`)
/// - 不 mock 数据(nil → "—" + "Not available")
/// - 不写 SwiftData(纯展示;SmartSnapshot.powerConsumptionWatts 由 HealthMonitor 写)
/// - 不动 `GlassBackground.swift` / `AppSettings.swift` / 5 Preferences 子 View
///   / `Localizable.strings`(任务硬规则)
/// - 不引入绿(主人审美:健康态用琥珀)
struct PowerModule: View {
    /// v0.4.0 polish-D:tab 切换标识(功耗 tab)
    enum Detail { case overview, temperature, capacity, power, smart }
    static let moduleTab: Detail = .power

    /// 注入的 PowerService(调用点仍传;瓦数改走 SmartData 额定值)
    let power: PowerService
    /// 当前盘 BSD Name(采样入参;View 切换时自动重采)
    let diskBSDName: String

    private var powerServiceAnchor: PowerService { power }

    // MARK: - 交互状态

    /// 玻璃卡整体 hover
    @State private var isCardHovered: Bool = false
    /// 焦点(Tab 键)
    @FocusState private var isFocused: Bool
    /// 按下态
    @State private var isPressed: Bool = false
    /// v0.6.1 polish-G:接 HealthMonitor + HealthPredictor(BSD → UUID 反查 + 健康度)
    @Environment(HealthMonitor.self) private var monitor
    @Environment(HealthPredictor.self) private var predictor
    @Environment(AppSettings.self) private var settings

    var body: some View {
        ZStack {
            cardBody
        }
        // v0.4.0 polish-C:自适应 min/ideal/max(配合 PopoverView LazyVGrid adaptive)
        .frame(minWidth: 180, idealWidth: 220, maxWidth: 280,
               minHeight: 140, idealHeight: 180, maxHeight: .infinity)
        // 缓动曲线(SwiftUI 用 Animation.timingCurve,不是 .cubicBezier)
        .animation(
            .timingCurve(0.2, 0.8, 0.2, 1, duration: 0.3),
            value: isCardHovered
        )
        .animation(.easeOut(duration: 0.15), value: isFocused)
        .animation(.easeInOut(duration: 0.12), value: isPressed)
        // v0.7 polish-K:动画跟有效功耗走(smartctl 真值优先,fallback powermetrics)
        .animation(.easeInOut(duration: 0.3), value: effectiveWatts ?? 0)
    }

    // MARK: - 卡片本体

    private var cardBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            // === 顶部:小标签 "POWER" ===
            HStack(spacing: 4) {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(.tertiary)
                Text(L10n.t("module.power.title", zh: "额定峰值", en: "RATED", language: settings.language))
                    .font(.system(size: 11, weight: .medium, design: .default))
                    .tracking(0.88)  // ≈ letter-spacing 0.08em at 11pt
                    .foregroundStyle(textTertiary)
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)

            Spacer(minLength: 0)

            // === 中部:大数字 + 单位 "W" ===
            // v0.7 polish-K:大数字用 effectiveWatts(smartctl 真值优先 → powermetrics 估算)
            let _ = monitor.ioGeneration
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(mainReading)
                        .font(.fraunces(size: 40, weight: .regular, italic: true))
                        .foregroundStyle(mainColor)
                        .monospacedDigit()
                        .scaleEffect(isCardHovered && effectiveWatts != nil ? 1.02 : 1.0)
                        .contentTransition(.numericText(value: effectiveWatts ?? 0))
                        .animation(.easeInOut(duration: 0.3), value: effectiveWatts)
                    Text(L10n.t("module.power.unitPeak", zh: "W 峰值", en: "W peak", language: settings.language))
                        .font(.system(size: 12, weight: .regular, design: .monospaced))
                        .foregroundStyle(textTertiary)
                }
                Spacer(minLength: 4)
                VStack(alignment: .trailing, spacing: 2) {
                    ioRateRow(
                        label: L10n.t("module.disk.io.read", zh: "读", en: "R", language: settings.language),
                        value: ByteFormatter.bps(ioSample?.readBps)
                    )
                    ioRateRow(
                        label: L10n.t("module.disk.io.write", zh: "写", en: "W", language: settings.language),
                        value: ByteFormatter.bps(ioSample?.writeBps)
                    )
                }
            }
            .padding(.horizontal, 14)

            DualIOChart(
                history: ioHistory,
                showsAxes: false,
                maxPoints: 90
            )
            .frame(height: 36)
            .padding(.horizontal, 14)
            .padding(.top, 4)

            if let peak = peakWatts, let idle = idleWatts, peak > idle {
                rangeBar(idle: idle, peak: peak)
                    .padding(.horizontal, 14)
                    .padding(.top, 6)
            }

            Spacer(minLength: 0)

            // === v0.6.1 polish-G:健康度副标(只在有匹配盘时显示)===
            // - 任务硬规则:Fraunces 14pt italic 琥珀(主标签)
            // - 数字按 HealthWarning 等级着色
            // - 没匹配到盘(empty / "—" BSD) → 不显示
            if let healthLine = healthSubtitle {
                HStack(spacing: 4) {
                    Text(String(localized: "module.power.healthLabel", defaultValue: "Health"))
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .tracking(0.6)
                        .foregroundStyle(.tertiary)
                    Text(healthLine)
                        .font(.fraunces(size: 14, weight: .regular, italic: true))
                        .foregroundStyle(healthSubtitleColor)
                        .monospacedDigit()
                        .lineLimit(1)
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 2)
            }

            // === 底部:副标(估算 / 不可用)===
            Text(subtitleText)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(isCardHovered ? Color.themeFgDark : textTertiary)
                .lineLimit(1)
                .padding(.horizontal, 14)
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
        // 按下态(任务:下沉 1px + scale 0.99;阴影用 .glass() 的统一标准,不再动态)
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
        .onHover { isCardHovered = $0 }
    }

    // MARK: - 文本 / 颜色

    /// 只显示 NVMe Supported Power States 额定最大瓦数。不是实时功耗，也不是系统 SoC。
    private var effectiveWatts: Double? {
        if let uuid = volumeUUID,
           let smartctlW = monitor.currentByUUID[uuid]?.powerConsumptionWatts,
           smartctlW > 0 {
            return smartctlW
        }
        return nil
    }

    private var selectedDiskInfo: DiskInfo? {
        monitor.watchedDisks.first(where: { $0.bsdName == diskBSDName })
            ?? monitor.selectedDisk
    }

    /// BSD → volumeUUID 反查(用 cached value,避免每次都重算)
    private var volumeUUID: String? {
        monitor.watchedDisks.first(where: { $0.bsdName == diskBSDName })?.volumeUUID
    }

    /// 大数字文案:有数据 → "X.X",nil → "—"
    /// v0.9.1 polish-P2:走 SmartDataFormatter.power 统一规则(nil/0 → "—",> 0 → "X.XX W")
    /// 跟 DiskDetailView.PowerWidget + SMARTModule.powerConsumption 统一,主人硬规则"不 mock"
    private var mainReading: String {
        // SmartDataFormatter.power 带 "X.XX W" 后缀,但 PowerModule mainReading 不带 "W" 单位
        // (单位 "W" 在右边单独 Text),所以这里手动走 "— / 数字" 规则
        guard let w = effectiveWatts, w > 0 else { return "—" }
        return String(format: "%.1f", w)
    }

    private var subtitleText: String {
        let lang = settings.language
        if let disk = selectedDiskInfo, disk.isUSBBridgeWithoutSMART {
            return L10n.t(
                "module.power.usbNever",
                zh: "USB 桥不提供功耗，不是还没采到",
                en: "USB bridge does not expose power",
                language: lang
            )
        }
        if effectiveWatts != nil {
            return L10n.t(
                "module.power.ratedLive",
                zh: "额定峰值。折线是实时读写，不是功耗。",
                en: "Rated peak. Sparkline is live I/O, not watts.",
                language: lang
            )
        }
        if selectedDiskInfo?.smartUnavailableKind == .pending
            || selectedDiskInfo?.nvmeSMARTCapable == true {
            return L10n.t(
                "module.power.waiting",
                zh: "额定功耗约 5 秒后出现（第一次轮询）",
                en: "Rated power in ~5s (first poll)",
                language: lang
            )
        }
        return L10n.t(
            "module.power.notAvailable",
            zh: "不可用",
            en: "Not available",
            language: lang
        )
    }

    /// Rated peak is a spec number — never paint it red at 8W.
    private var mainColor: Color {
        effectiveWatts == nil ? textTertiary : Color.dsNormal
    }

    /// 文字次色 `rgba(245, 242, 236, 0.55)`(任务硬规则:暖米色)
    private var textTertiary: Color {
        Color(red: 0xF5 / 255, green: 0xF2 / 255, blue: 0xEC / 255).opacity(0.55)
    }

    // MARK: - v0.6.1 polish-G:健康度副标

    /// 健康度副标文案:"X/100" 或 nil(empty 状态不显示)
    /// - BSD → volumeUUID 反查 `monitor.watchedDisks`
    /// - 反查到 → `predictor.warning(forDiskUUID:)` → healthScore
    /// - 没匹配到(empty / "—" / 盘已拔)→ nil
    private var healthSubtitle: String? {
        guard diskBSDName != "—" else { return nil }
        guard let volumeUUID = monitor.watchedDisks
            .first(where: { $0.bsdName == diskBSDName })?.volumeUUID else {
            return nil
        }
        let warning = predictor.warning(forDiskUUID: volumeUUID)
        return "\(warning.healthScore)/100"
    }

    /// 健康度副标颜色:按 HealthWarning 等级
    private var healthSubtitleColor: Color {
        guard diskBSDName != "—" else { return textTertiary }
        guard let volumeUUID = monitor.watchedDisks
            .first(where: { $0.bsdName == diskBSDName })?.volumeUUID else {
            return textTertiary
        }
        return predictor.warning(forDiskUUID: volumeUUID).color
    }

    private var powerStates: [NVMePowerState] {
        guard let uuid = volumeUUID else { return [] }
        return monitor.currentByUUID[uuid]?.nvmePowerStates ?? []
    }

    private var peakWatts: Double? { NVMePowerStateParser.peakWatts(from: powerStates) }
    private var idleWatts: Double? { NVMePowerStateParser.idleWatts(from: powerStates) }

    private var ioBusyInferred: Bool {
        let r = ioSample?.readBps ?? 0
        let w = ioSample?.writeBps ?? 0
        return r + w > 1_000_000
    }

    private func rangeBar(idle: Double, peak: Double) -> some View {
        let busy = ioBusyInferred
        return HStack(spacing: 6) {
            Text(String(format: "%.2f", idle))
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.tertiary)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.08))
                    Capsule()
                        .fill(Color.dsNormal.opacity(busy ? 0.55 : 0.22))
                        .frame(width: max(8, geo.size.width * (busy ? 0.85 : 0.18)))
                }
            }
            .frame(height: 5)
            Text(String(format: "%.1f", peak))
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.secondary)
            Text(busy
                 ? L10n.t("module.power.busy", zh: "忙·推断", en: "busy·inferred", language: settings.language)
                 : L10n.t("module.power.idle", zh: "闲·推断", en: "idle·inferred", language: settings.language))
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.tertiary)
        }
    }

    private var ioSample: HealthMonitor.IOSample? {
        guard let uuid = volumeUUID else { return nil }
        return monitor.ioLiveSample(for: uuid)
    }

    private var ioHistory: [HealthMonitor.IOHistoryPoint] {
        guard let uuid = volumeUUID else { return [] }
        return monitor.ioHistoryByUUID[uuid] ?? []
    }

    private func ioRateRow(label: String, value: String) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundStyle(.tertiary)
            Text(value)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .animation(DiskMonMotion.number, value: value)
        }
    }
}

// MARK: - 玻璃卡背景(私有,不动 GlassBackground)

/// 功耗模块专用玻璃卡背景
/// 严格按任务规范:
// v0.4.0 polish-B:`PowerGlassBackground` 已删除,统一走 `Views/Preferences/GlassBackground.swift` 的 `.glass()` 接口
// 旧"hover 时高光位移 1-2px / 按下时阴影收缩"在统一接口里不保留(用户硬规则:同一接口,不加 hover/press state 参数)
