import SwiftUI

/// 容量饼图模块 v0.4.2(高级交互规范版)
/// v0.6.1 polish-G:加 mini health bar(0-100 健康度 + 进度条)
///
/// 单一职责:接收一块盘 → 渲染 220×180 玻璃卡内的"已用百分比"饼图 + 0-100 健康度 bar
/// 数据来源:
///   - 饼图:`DiskInfo.usedBytes` / `freeBytes` / `totalBytes`,由 `HealthMonitor.refreshCapacityOnce` 写回;
///     真实 `/usr/sbin/diskutil info -plist <mountPoint>` → `CapacityInUse` / `APFSContainerFree` / `Size`
///     60s TTL 缓存,失败字段留 nil(不凑合,主人硬规则)
///   - 健康度(v0.6.1):`HealthPredictor.warning(forDiskUUID:)` → healthScore 0-100
///
/// 设计选择(高级交互规范):
/// - **SVG 自绘饼图** — 不用 Swift Charts,直接 `Path` + arc;`@State hoveredSegment` 驱动
///   扇区外扩 4px + 阴影增强 + 其他段 30% 透明,带浮动玻璃 tooltip
/// - **3 段**(色值硬规则):已用(琥珀 `#C8956C`) / 系统预留(玻璃黑) / 空闲(米白 `rgba(245,242,236,0.3)`)
/// - **玻璃卡规范**(任务硬规则):真液态玻璃(macOS 26+ `backgroundExtensionEffect()`)
///   + 1px `rgba(255,255,255,0.08)` 边 + 顶边高光 LinearGradient
///   + `0 24px 48px rgba(0,0,0,0.4)` 阴影 + 20px 圆角 + 35mm 噪点 PNG + vignette
///   全部走 `Views/Preferences/GlassBackground.swift` 的 `.glass(withNoise: true)` 统一接口
/// - **hover 交互**:
///   - 玻璃卡边缘高光"内移" 1-2px(`padding` 0→2,模拟光带向中心位移,0.3s cubic-bezier)
///   - 中心数字放大 1.02(snappy 0.25s)
///   - 扇区外扩 4px + 阴影增强 8px,其他段 → 0.3 opacity
/// - **焦点环**:琥珀 2px stroke(`.focusable()` + `@FocusState` + 自绘,关掉系统默认)
/// - **按下态**:`LongPressGesture(minimumDuration: 0)` 追踪 press → 下沉 1px + scale 0.99
/// - **中心数字**:`Fraunces 36pt` 琥珀 + `.contentTransition(.numericText())` + 0.3s ease
/// - **副标(2 行)** v0.4.2:
///   - Line 1: "Used 117 GB / 500 GB"(已用 / 总;totalBytes 优先,sizeBytes 兜底)
///   - Line 2: "Free 381 GB"(磁盘空闲字节数;APFSContainerFree;fallback sizeBytes - usedBytes)
/// - **nil 数据**:"—" 圆圈 + 副标 "Not available"(不画 0/0 假饼图,主人硬规则)
/// - **v0.6.1 polish-G mini health bar**:饼图下方 1 行
///   - 左:数字 0-100(Fraunces 14pt italic,按等级着色)
///   - 右:迷你进度条(8px 高,按 0-100 比例填充)
///
/// 不做:
/// - 不在 UI 直接跑 `diskutil`(只读 `DiskInfo.*` 字段,由 HealthMonitor 调度)
/// - 不 mock 数据(nil → "—" + "Not available")
/// - 不写 SwiftData(纯展示)
struct CapacityModule: View {
    /// v0.4.0 polish-D:tab 切换标识(容量 tab)
    enum Detail { case overview, temperature, capacity, power, smart }
    static let moduleTab: Detail = .capacity

    let disk: DiskInfo

    // MARK: - 交互状态

    /// 当前 hover 的扇区(nil = 没 hover)
    @State private var hoveredSegment: CapacitySegment?
    /// 玻璃卡整体 hover
    @State private var isCardHovered: Bool = false
    /// 焦点(Tab 键)
    @FocusState private var isFocused: Bool
    /// 按下态
    @State private var isPressed: Bool = false
    /// v0.6.1 polish-G:接 HealthPredictor
    @Environment(HealthPredictor.self) private var predictor

    var body: some View {
        ZStack {
            cardBody
            // 浮动 tooltip(玻璃卡外置,避免被 card 边裁切)
            if let seg = hoveredSegment, let tip = tooltipData(for: seg) {
                CapacityTooltip(segment: seg, data: tip)
                    .offset(y: -4)
                    .transition(.opacity.combined(with: .scale(scale: 0.95, anchor: .bottom)))
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        // v0.4.0 polish-C:自适应 min/ideal/max(配合 PopoverView LazyVGrid adaptive)
        .frame(minWidth: 180, idealWidth: 220, maxWidth: 280,
               minHeight: 140, idealHeight: 180, maxHeight: .infinity)
        .animation(.timingCurve(0.2, 0.8, 0.2, 1, duration: 0.3), value: isCardHovered)
        .animation(.easeInOut(duration: 0.3), value: hoveredSegment?.id)
        .animation(.easeOut(duration: 0.15), value: isFocused)
        .animation(.easeInOut(duration: 0.12), value: isPressed)
    }

    // MARK: - 卡片本体

    private var cardBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            // === 标签 "CAPACITY" ===
            Text(labelText)
                .font(.system(size: 11, weight: .medium, design: .default))
                .tracking(0.6)  // ≈ letter-spacing 0.08em at 11pt
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .padding(.horizontal, 14)
                .padding(.top, 12)

            // === 饼图 + 中心数字(overlay) ===
            ZStack {
                pieView
                centerNumberView
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            // === v0.6.1 polish-G:mini health bar(0-100 健康度) ===
            // - 左:数字(Fraunces 14pt italic,按等级色)
            // - 右:迷你进度条(8px 高,按 0-100 比例填充)
            // - 派生于 HealthPredictor.warning(forDiskUUID: disk.volumeUUID)
            // - empty 盘(disk.volumeUUID == "empty")不显示
            if disk.volumeUUID != "empty" {
                healthBar
                    .padding(.horizontal, 14)
                    .padding(.bottom, 8)
            }

            // === 副标(2 行 v0.4.2):"Used X / Y" + "Free Z" ===
            // - 失败字段退化为 "—"(不凑合假数据)
            // - 全部 nil 时合并成单行 "Not available"
            VStack(spacing: 1) {
                Text(subtitleUsedText)
                    .font(.system(size: 11, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(subtitleFreeText)
                    .font(.system(size: 11, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.horizontal, 14)
            .padding(.bottom, 12)
        }
        // v0.4.0 polish-C:外层 frame 已设;内层卡片填满父容器(用 maxWidth/Height 撑开)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // v0.4.0 polish-B:真液态玻璃 + 35mm 噪点(走 `.glass(withNoise: true)` 统一接口)
        // - macOS 26+ 走 `backgroundExtensionEffect()`(系统级液态玻璃)
        // - macOS 14-25 走 NSVisualEffectView(`.popover` + `vibrantDark`)兜底
        // - 1px 边 + 顶高光 + 阴影都在 modifier 里
        .glass(cornerRadius: 20, withNoise: true)
        .onHover { isCardHovered = $0 }
        // 焦点(任务:焦点环琥珀 2px)
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
    }

    // MARK: - 饼图(SVG 自绘)

    @ViewBuilder
    private var pieView: some View {
        let segs = buildSegments()
        if segs.isEmpty {
            // nil 数据 → 全灰环 + "—" 占位
            emptyPieView
        } else {
            CapacityPieView(
                segments: segs,
                hovered: $hoveredSegment
            )
            .frame(width: 100, height: 100)
        }
    }

    /// nil 占位饼图:全灰环(系统预留色)
    private var emptyPieView: some View {
        ZStack {
            PieSegmentShape(
                startDeg: 0, endDeg: 360,
                outerR: 45, innerR: 28,
                expanded: false
            )
            .fill(Color.black.opacity(0.35))
            .opacity(0.18)
        }
        .frame(width: 100, height: 100)
    }

    // MARK: - 中心数字

    @ViewBuilder
    private var centerNumberView: some View {
        VStack(spacing: 0) {
            Text(centerText)
                .font(.fraunces(size: 36, weight: .regular, italic: true))
                .foregroundStyle(centerColor)
                .monospacedDigit()
                .contentTransition(.numericText())
                .animation(.easeInOut(duration: 0.3), value: centerText)
                // hover 放大 1.02(任务:玻璃卡 hover 时中心数字轻微放大)
                .scaleEffect(isCardHovered ? 1.02 : 1.0)
                .animation(.timingCurve(0.2, 0.8, 0.2, 1, duration: 0.25), value: isCardHovered)
            if hasData {
                Text(String(localized: "capacity.used", defaultValue: "USED"))
                    .font(.system(size: 11, weight: .medium, design: .default))
                    .tracking(0.8)
                    .foregroundStyle(.tertiary)
                    .padding(.top, 1)
            }
        }
    }

    // MARK: - v0.6.1 polish-G:mini health bar

    /// mini health bar — Fraunces 14pt italic 数字 + 8px 进度条
    /// - 数据:`HealthPredictor.warning(forDiskUUID:)` → healthScore 0-100
    /// - 配色:按 HealthWarning 等级(danger 暗红 / critical 红 / warning 琥珀 / none 琥珀 normal)
    /// - 跟饼图/中心数字共享 hover 1.02 放大效果
    private var healthBar: some View {
        let warning = predictor.warning(forDiskUUID: disk.volumeUUID)
        let score = warning.healthScore
        return HStack(spacing: 8) {
            // 左:健康度数字 + /100
            HStack(alignment: .firstTextBaseline, spacing: 1) {
                Text("\(score)")
                    .font(.fraunces(size: 14, weight: .regular, italic: true))
                    .foregroundStyle(warning.color)
                    .monospacedDigit()
                    .contentTransition(.numericText(value: Double(score)))
                    .animation(.easeInOut(duration: 0.3), value: score)
                Text("/100")
                    .font(.system(size: 9, weight: .regular, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
            .scaleEffect(isCardHovered ? 1.02 : 1.0)

            // 右:迷你进度条(8px 高)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    // 背景轨道(米色低透明)
                    Capsule()
                        .fill(Color.white.opacity(0.08))
                    // 填充(按 0-100 比例,按等级色)
                    Capsule()
                        .fill(warning.color)
                        .frame(width: max(2, geo.size.width * Double(score) / 100.0))
                        .animation(.easeInOut(duration: 0.3), value: score)
                }
            }
            .frame(height: 6)
        }
    }

    // MARK: - 文本

    private var labelText: String {
        String(localized: "card.capacity", defaultValue: "Capacity")
    }

    /// 中心 "X%" 或 "—"
    /// v0.4.2:百分比基于 `usedBytes / totalBytes`(优先)或 `usedBytes / sizeBytes`(兜底)
    private var centerText: String {
        guard let used = disk.usedBytes else { return "—" }
        let totalD = Double(effectiveTotal)
        let usedD = Double(used)
        let ratio: Double = totalD > 0 ? (usedD / totalD) : 0.0
        let pct = Int((ratio * 100.0).rounded())
        return "\(pct)%"
    }

    /// 中心颜色:有数据 → 琥珀 `#C8956C`;N/A → 三级灰
    /// 主人硬规则:琥珀硬编码 #C8956C(任务规范,不用 `Color.dsNormal = #D97706` 替代)
    private var centerColor: Color {
        hasData ? Color.capacityAmber : Color.secondary
    }

    /// 是否有用于饼图的数据
    /// v0.4.2:需要 usedBytes + 真实 total(sizeBytes / totalBytes 任一)
    private var hasData: Bool {
        guard let used = disk.usedBytes, used > 0 else { return false }
        return effectiveTotal > 0
    }

    /// v0.4.2:真实总字节(优先 totalBytes,fallback sizeBytes)
    private var effectiveTotal: Int64 {
        if let t = disk.totalBytes, t > 0 { return Int64(t) }
        return disk.sizeBytes
    }

    /// v0.4.2:真实空闲字节(优先 freeBytes,fallback total - used)
    private var effectiveFree: UInt64? {
        if let f = disk.freeBytes { return f }
        if let used = disk.usedBytes, effectiveTotal > 0, effectiveTotal >= Int64(used) {
            return UInt64(effectiveTotal - Int64(used))
        }
        return nil
    }

    /// 副标第 1 行:"Used X GB / Y GB" 或 "Not available"
    /// - 用 `String(localized:)` + defaultValue(避免改 Localizable.strings)
    private var subtitleUsedText: String {
        guard hasData, let used = disk.usedBytes else {
            return String(localized: "capacity.notAvailable", defaultValue: "Not available")
        }
        let usedStr = ByteFormatter.bytes(Int64(used))
        let totalStr = ByteFormatter.bytes(effectiveTotal)
        return String(
            format: String(localized: "capacity.usedOfTotal", defaultValue: "Used %@ / %@"),
            usedStr, totalStr
        )
    }

    /// 副标第 2 行(v0.4.2 新):"Free Z GB" 或 "—"
    /// - freeBytes 真实有 → 显
    /// - freeBytes nil 但有 used+total → fallback total - used(逻辑空闲,可能跟物理差几个 MB 元数据)
    /// - 全 nil → "—"(不假数据)
    private var subtitleFreeText: String {
        guard let f = effectiveFree else {
            return String(localized: "capacity.freeNA", defaultValue: "Free —")
        }
        let freeStr = ByteFormatter.bytes(Int64(f))
        return String(
            format: String(localized: "capacity.freeValue", defaultValue: "Free %@"),
            freeStr
        )
    }

    // MARK: - 段构建(3 段)

    /// 任务色值(硬规则,自写常量)
    private static let amberHex: Color = Color(red: 0xC8/255, green: 0x95/255, blue: 0x6C/255) // #C8956C
    private static let freeHex: Color  = Color(red: 0xF5/255, green: 0xF2/255, blue: 0xEC/255).opacity(0.3) // rgba(245,242,236,0.3)
    // P1-3 polish-H:design 方案A line 639-640 sysRes = amber-deep #A87148
    // 旧 Color.black.opacity(0.4) 偏冷黑,跟 amber(#C8956C)+ 米白(free)接不上
    // amber-deep 跟 amber 同色系(更深 1 档)→ 3 段饼图渐变 amber→amber-deep→free,色相统一
    private static let sysResHex: Color = Color(red: 0xA8/255, green: 0x71/255, blue: 0x48/255) // #A87148 amber-deep

    /// 算 3 段角度(已用 + 系统预留 + 空闲)
    /// v0.4.2:空闲段用真实 `APFSContainerFree` 字节(diskutil info 实读)
    /// 系统预留 = `max(0, total - used - free)`,自动消化 APFS 元数据差(约 100-300MB)
    /// 旧 v0.4.0 wave-4c:`free = total - used`(逻辑空闲,APFS 元数据不算进来,饼图虚高)
    /// 新版用真物理空闲,饼图 3 段和 = total,显示更准
    private func buildSegments() -> [CapacitySegment] {
        guard hasData, let used = disk.usedBytes else { return [] }
        let totalD = Double(effectiveTotal)
        let usedD = Double(used)
        // 真实空闲(优先 freeBytes,fallback total - used)
        let freeD: Double
        if let f = disk.freeBytes {
            freeD = Double(f)
        } else {
            freeD = max(0, totalD - usedD)
        }
        // 系统预留 = total - used - free(消化 APFS 元数据/其他开销;APFS 单纯卷一般 ≈ 0)
        let sysResD = max(0.0, totalD - usedD - freeD)
        let sumBytes = usedD + sysResD + freeD
        guard sumBytes > 0 else { return [] }

        let usedFrac = usedD / sumBytes
        let sysFrac  = sysResD / sumBytes
        let freeFrac = freeD / sumBytes

        let usedDeg = usedFrac * 360
        let sysDeg  = sysFrac * 360
        let freeDeg = freeFrac * 360

        // 0° = 12 点钟;按 已用 → 系统预留 → 空闲 顺序顺时针排
        var out: [CapacitySegment] = []
        var cursor: Double = 0
        // 已用
        if usedDeg > 0.1 {
            out.append(CapacitySegment(
                id: "used",
                kind: .used,
                color: Self.amberHex,
                startDeg: cursor,
                endDeg: cursor + usedDeg,
                bytes: UInt64(usedD),
                label: String(localized: "capacity.used", defaultValue: "Used")
            ))
            cursor += usedDeg
        }
        // 系统预留(APFS 元数据差,通常很小但不一定是 0)
        if sysDeg > 0.1 {
            out.append(CapacitySegment(
                id: "system",
                kind: .system,
                color: Self.sysResHex,
                startDeg: cursor,
                endDeg: cursor + sysDeg,
                bytes: UInt64(sysResD),
                label: String(localized: "capacity.system", defaultValue: "System")
            ))
            cursor += sysDeg
        }
        // 空闲
        if freeDeg > 0.1 {
            out.append(CapacitySegment(
                id: "free",
                kind: .free,
                color: Self.freeHex,
                startDeg: cursor,
                endDeg: cursor + freeDeg,
                bytes: UInt64(freeD),
                label: String(localized: "capacity.free", defaultValue: "Free")
            ))
            cursor += freeDeg
        }
        return out
    }

    // MARK: - Tooltip

    /// 浮动玻璃 tooltip 数据
    private func tooltipData(for seg: CapacitySegment) -> CapacityTooltipData? {
        let total = effectiveTotal
        guard total > 0 else { return nil }
        let pct = Int(round(Double(seg.bytes) / Double(total) * 100))
        return CapacityTooltipData(
            primary: "\(seg.label) \(ByteFormatter.bytes(Int64(seg.bytes)))",
            secondary: "\(pct)%"
        )
    }
}

// MARK: - CapacitySegment 模型

/// 单段饼图数据
struct CapacitySegment: Identifiable, Equatable {
    enum Kind { case used, system, free }
    let id: String
    let kind: Kind
    let color: Color
    /// 起始角度(度数,0 = 12 点钟,顺时针为正)
    let startDeg: Double
    /// 结束角度(度数)
    let endDeg: Double
    let bytes: UInt64
    let label: String
}

struct CapacityTooltipData: Equatable {
    let primary: String    // "Used 108 GB"
    let secondary: String  // "23%"
}

// MARK: - 玻璃卡背景(私有,不动 GlassBackground)

// v0.4.0 polish-B:`CapacityGlassBackground` 已删除,统一走 `Views/Preferences/GlassBackground.swift` 的 `.glass()` 接口
// 旧"hover 时高光位移 1-2px"在统一接口里不保留(用户硬规则:同一接口,不加 hover state 参数)

// MARK: - 饼图 SVG 自绘(单段 Shape)

/// 单段饼图 Path
/// - 0° = 12 点钟方向(向上)
/// - 顺时针为正
struct PieSegmentShape: Shape {
    let startDeg: Double
    let endDeg: Double
    var outerR: CGFloat
    var innerR: CGFloat
    /// hover 时外扩 4px(任务规范)
    var expanded: Bool

    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let r: CGFloat = expanded ? outerR + 4 : outerR
        // 转数学角度(0 = +X,即 3 点钟);0° = 12 点钟 → -90°
        let startRad: Double = (startDeg - 90) * .pi / 180
        let endRad: Double   = (endDeg   - 90) * .pi / 180
        // 显式 Double → CGFloat(避免 cos / * 模糊)
        func pt(radius: CGFloat, rad: Double) -> CGPoint {
            CGPoint(
                x: center.x + CGFloat(Double(radius) * cos(rad)),
                y: center.y + CGFloat(Double(radius) * sin(rad))
            )
        }
        let startPt     = pt(radius: r,        rad: startRad)

        // 处理 360° 整圈(addArc 360° 会被 SwiftUI 优化为 0,需拆 2 段)
        let sweep: Double = endDeg - startDeg
        var p = Path()
        p.move(to: startPt)
        if sweep >= 359.99 {
            // 整圈:拆 2 段 180° 弧
            let midRad: Double = (startRad + endRad) / 2
            p.addArc(center: center, radius: r,
                     startAngle: .radians(startRad), endAngle: .radians(midRad),
                     clockwise: false)
            p.addArc(center: center, radius: r,
                     startAngle: .radians(midRad), endAngle: .radians(endRad),
                     clockwise: false)
            p.addLine(to: pt(radius: innerR, rad: endRad))
            p.addArc(center: center, radius: innerR,
                     startAngle: .radians(midRad), endAngle: .radians(endRad),
                     clockwise: true)
            p.addLine(to: pt(radius: innerR, rad: midRad))
            p.addArc(center: center, radius: innerR,
                     startAngle: .radians(startRad), endAngle: .radians(midRad),
                     clockwise: true)
            p.closeSubpath()
        } else {
            p.addArc(center: center, radius: r,
                     startAngle: .radians(startRad), endAngle: .radians(endRad),
                     clockwise: false)
            p.addLine(to: pt(radius: innerR, rad: endRad))
            p.addArc(center: center, radius: innerR,
                     startAngle: .radians(endRad), endAngle: .radians(startRad),
                     clockwise: true)
            p.closeSubpath()
        }
        return p
    }
}

// MARK: - 饼图容器(管理 hover)

/// 饼图整体,3 段 ZStack,自己接管 onContinuousHover 决定 hover 段
struct CapacityPieView: View {
    let segments: [CapacitySegment]
    @Binding var hovered: CapacitySegment?

    private let frame: CGFloat = 100
    private let outerR: CGFloat = 45
    private let innerR: CGFloat = 28

    var body: some View {
        ZStack {
            // 各段
            ForEach(segments) { seg in
                PieSegmentShape(
                    startDeg: seg.startDeg,
                    endDeg: seg.endDeg,
                    outerR: outerR,
                    innerR: innerR,
                    expanded: hovered?.id == seg.id
                )
                .fill(seg.color)
                .opacity(hovered != nil && hovered?.id != seg.id ? 0.3 : 1.0)
                .shadow(
                    color: hovered?.id == seg.id ? seg.color.opacity(0.55) : .clear,
                    radius: hovered?.id == seg.id ? 8 : 0,
                    x: 0, y: hovered?.id == seg.id ? 2 : 0
                )
                .animation(.timingCurve(0.2, 0.8, 0.2, 1, duration: 0.3), value: hovered?.id)
            }
        }
        .frame(width: frame, height: frame)
        .contentShape(Rectangle())
        .onContinuousHover { phase in
            switch phase {
            case .active(let localPoint):
                updateHover(at: localPoint)
            case .ended:
                hovered = nil
            }
        }
    }

    /// 极坐标 → 段判定
    private func updateHover(at p: CGPoint) {
        // 中心 50,50
        let cx = frame / 2
        let cy = frame / 2
        let dx = p.x - cx
        let dy = p.y - cy
        let r = sqrt(dx * dx + dy * dy)
        // 内外半径(考虑 hover 外扩)
        let innerHit: CGFloat = innerR - 2
        let outerHit: CGFloat = outerR + 6  // 容差
        guard r >= innerHit, r <= outerHit else {
            hovered = nil
            return
        }
        // atan2(dx, -dy):12 点钟为 0°,顺时针为正
        var deg = atan2(dx, -dy) * 180 / .pi
        if deg < 0 { deg += 360 }
        if let hit = segments.first(where: { deg >= $0.startDeg && deg < $0.endDeg }) {
            hovered = hit
        } else if let last = segments.last, deg >= last.endDeg - 0.5 {
            // 边界 360° 兜底
            hovered = last
        } else {
            hovered = nil
        }
    }
}

// MARK: - 浮动玻璃 Tooltip

/// 浮动玻璃卡 tooltip(任务规范)
struct CapacityTooltip: View {
    let segment: CapacitySegment
    let data: CapacityTooltipData

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(segment.color)
                .frame(width: 6, height: 6)
            VStack(alignment: .leading, spacing: 1) {
                Text(data.primary)
                    .font(.system(size: 11, weight: .medium, design: .default))
                    .tracking(0.3)
                    .foregroundStyle(.primary)
                Text(data.secondary)
                    .font(.fraunces(size: 13, weight: .regular, italic: true))
                    .foregroundStyle(.primary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.white.opacity(0.10), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.3), radius: 8, x: 0, y: 4)
    }
}

// MARK: - 颜色 Token(任务硬规则,单独列出)

extension Color {
    /// v0.4.0 wave-4c:容量饼图已用段琥珀 `#C8956C`
    /// (任务硬规则色值,跟 `dsNormal = #D97706` 略不同 — 后者偏橙,前者偏暖肉色,容量场景更柔和)
    static let capacityAmber = Color(red: 0xC8/255, green: 0x95/255, blue: 0x6C/255)
}

// MARK: - Preview

#Preview("Capacity · with data") {
    CapacityModule(disk: DiskInfo(
        bsdName: "disk5",
        volumeUUID: "ABC-123",
        mountPoint: "/Volumes/applelog",
        isInternal: false,
        sizeBytes: 499_963_456_000,
        modelName: "WD Blue SN570 1TB",
        usedBytes: 116_056_907_776,
        freeBytes: 381_918_441_472,
        totalBytes: 499_963_456_000
    ))
    .padding(20)
    .background(Color.themeBgDark)
}

#Preview("Capacity · nil data") {
    CapacityModule(disk: DiskInfo(
        bsdName: "disk5",
        volumeUUID: "ABC-123",
        mountPoint: "/Volumes/applelog",
        isInternal: false,
        sizeBytes: 499_963_456_000,
        modelName: "WD Blue SN570 1TB",
        usedBytes: nil,
        freeBytes: nil,
        totalBytes: nil
    ))
    .padding(20)
    .background(Color.themeBgDark)
}

#Preview("Capacity · partial data (used only)") {
    CapacityModule(disk: DiskInfo(
        bsdName: "disk5",
        volumeUUID: "ABC-123",
        mountPoint: "/Volumes/applelog",
        isInternal: false,
        sizeBytes: 499_963_456_000,
        modelName: "WD Blue SN570 1TB",
        usedBytes: 116_056_907_776,
        freeBytes: nil,
        totalBytes: 499_963_456_000
    ))
    .padding(20)
    .background(Color.themeBgDark)
}
