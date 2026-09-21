import SwiftUI
import SwiftData

/// LinkHealthModule v0.8 polish-L
/// 220x180 玻璃卡,显示每盘 Link Speed / Width + Expected vs Negotiated 颜色对比
///
/// === 数据源 ===
/// `@Environment(LinkHealthService.self)` 读 snapshots[key: mountPoint]
/// - snapshots 字典在 HealthMonitor.discoverOnce 末尾被填充
/// - key = mountPoint("/Volumes/applelog"),value = LinkSnapshot
/// - 缺数据 → "—"(不假数据)
///
/// === 高级交互规范(主人硬规则) ===
/// - 大数字:negotiated speed(Fraunces 28pt italic)+ 数字滚动 .contentTransition(.numericText())
/// - 副标:width + busProtocol(SF Mono 11pt)
/// - hover 玻璃卡边缘高光内移 1-2px(走 .glass() 统一接口)
/// - hover 大数字 1.02 放大
/// - 焦点环:琥珀 2px stroke
/// - 按下态:下沉 1px + scale 0.99
/// - 降级指示:negotiated < expected → 琥珀 dsWarning / 正常米白
/// - 不 loop 动画 / 不弹跳 / 不 mock / nil → "—"
/// - 35mm 噪点(走 .glass() withNoise: true)
///
/// === 设计选择 ===
/// - 220x180(跟其他 Module 一致)
/// - 卡片右上角小图标:SF Symbol `bolt.horizontal.fill`(TB 链路语义)
/// - 顶标 "LINK" 12pt secondary
/// - 主显示:主盘 negotiated speed(GT/s)+ width(× lanes)
/// - 副标 1:主盘 busProtocol(SF Mono 10pt tertiary)
/// - 副标 2:expected → negotiated 对比(降级琥珀 / 正常米白)
/// - 多盘(>= 2)→ 副标 2 显示 "X/Y 降级" 摘要
struct LinkHealthModule: View {
    /// v0.4.0 polish-D:tab 切换标识(本 Module 跟 Link tab 配对)
    enum Detail { case overview, temperature, capacity, power, smart, link }
    static let moduleTab: Detail = .link

    @Environment(HealthMonitor.self) private var monitor
    @Environment(LinkHealthService.self) private var linkHealth

    // MARK: - 交互状态

    @State private var isCardHovered: Bool = false
    @State private var isPressed: Bool = false
    @FocusState private var isFocused: Bool

    var body: some View {
        cardBody
            // v0.4.0 polish-C:自适应 min/ideal/max(跟其他 Module 卡保持一致)
            .frame(minWidth: 180, idealWidth: 220, maxWidth: 280,
                   minHeight: 140, idealHeight: 180, maxHeight: .infinity)
            // 玻璃底 — v0.4.0 polish-B:真液态玻璃 + 35mm 噪点(走 `.glass(withNoise: true)` 统一接口)
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
            .animation(.easeInOut(duration: 0.3), value: speedText)
    }

    // MARK: - 卡片本体

    private var cardBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            // === 顶部:小标签 "LINK" ===
            HStack(spacing: 4) {
                Image(systemName: "bolt.horizontal.fill")
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(.tertiary)
                Text(String(localized: "module.link.title", defaultValue: "LINK"))
                    .font(.system(size: 11, weight: .medium, design: .default))
                    .tracking(0.6)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 2)

            Spacer(minLength: 0)

            // === 中部:大数字 negotiated speed(GT/s)+ 单位 ===
            HStack(alignment: .center, spacing: 4) {
                Text(speedText)
                    .font(.fraunces(size: 48, weight: .regular, italic: true))
                    .foregroundStyle(speedColor)
                    .monospacedDigit()
                    .scaleEffect(isCardHovered && speedText != "—" ? 1.02 : 1.0)
                    .contentTransition(.numericText(value: numericKey))
                    .lineLimit(1)
                if let width = widthText {
                    Text("×\(width)")
                        .font(.system(size: 14, weight: .regular, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer(minLength: 0)

            // === 底部副标 1:busProtocol + GT/s ===
            Text(busSubtitle)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(isCardHovered ? Color.themeFgDark : .secondary)
                .lineLimit(1)
                .truncationMode(.tail)

            // === 底部副标 2:expected vs negotiated(降级琥珀 / 正常米白)===
            HStack(spacing: 4) {
                Text(comparisonText)
                    .font(.fraunces(size: 14, weight: .regular, italic: true))
                    .foregroundStyle(comparisonColor)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: - 数据:主盘 link snapshot

    /// "主盘" = watchedDisks 里第一个有 linkSnapshot 的
    /// - 跟 PopoverView.primaryDisk 选择策略不同(那是 celsius 最大)
    /// - 这里优先 link snapshot 已 ready 的盘,确保 UI 不空白
    private var primarySnapshot: (disk: DiskInfo, snap: LinkHealthService.LinkSnapshot)? {
        for d in monitor.watchedDisks {
            if let mp = d.mountPoint, let snap = linkHealth.snapshots[mp] {
                return (d, snap)
            }
        }
        return nil
    }

    /// 所有盘的 link snapshot(用于多盘统计摘要)
    private var allSnaps: [(DiskInfo, LinkHealthService.LinkSnapshot)] {
        monitor.watchedDisks.compactMap { d in
            guard let mp = d.mountPoint, let snap = linkHealth.snapshots[mp] else { return nil }
            return (d, snap)
        }
    }

    // MARK: - 文本

    private var speedText: String {
        guard let pair = primarySnapshot,
              let speed = pair.snap.negotiatedSpeedGTs else { return "—" }
        // 1 位小数(GT/s 精度)
        return String(format: "%.1f", speed)
    }

    /// `contentTransition(.numericText(value:))` 触发器
    private var numericKey: Double {
        guard let pair = primarySnapshot,
              let speed = pair.snap.negotiatedSpeedGTs else { return 0 }
        return speed
    }

    private var widthText: String? {
        guard let pair = primarySnapshot, let width = pair.snap.negotiatedWidth else { return nil }
        return "\(width)"
    }

    private var busSubtitle: String {
        guard let pair = primarySnapshot else {
            return String(localized: "module.link.noData", defaultValue: "No link data")
        }
        let protocolText = pair.snap.busProtocol
        if let expSpeed = pair.snap.expectedSpeedGTs {
            return String(
                format: String(
                    localized: "module.link.busExpected",
                    defaultValue: "%@ · exp %.0f GT/s"
                ),
                protocolText, expSpeed
            )
        }
        return protocolText
    }

    private var comparisonText: String {
        let allSnaps = self.allSnaps
        if allSnaps.isEmpty {
            return String(localized: "module.link.collecting", defaultValue: "Collecting…")
        }
        // 降级计数
        let degraded = allSnaps.filter { LinkHealthService.isDegraded($0.1) }
        if !degraded.isEmpty {
            return String(
                format: String(
                    localized: "module.link.degraded",
                    defaultValue: "%d/%d degraded"
                ),
                degraded.count, allSnaps.count
            )
        }
        // 全部 ok
        if let pair = primarySnapshot,
           let negotiated = pair.snap.negotiatedSpeedGTs,
           let expected = pair.snap.expectedSpeedGTs {
            return String(
                format: String(
                    localized: "module.link.match",
                    defaultValue: "OK · %.0f/%.0f GT/s"
                ),
                negotiated, expected
            )
        }
        return String(
            format: String(
                localized: "module.link.allOk",
                defaultValue: "%d disks OK"
            ),
            allSnaps.count
        )
    }

    // MARK: - 颜色

    private var speedColor: Color {
        guard let pair = primarySnapshot else { return Color.secondary.opacity(0.5) }
        return LinkHealthService.isDegraded(pair.snap) ? Color.dsWarning : Color.dsNormal
    }

    private var comparisonColor: Color {
        let allSnaps = self.allSnaps
        let degraded = allSnaps.filter { LinkHealthService.isDegraded($0.1) }
        if !degraded.isEmpty {
            return Color.dsWarning
        }
        return Color.dsNormal
    }
}

// grok 调研:v0.8 polish-L, macOS 链接健康(NVMe/PCIe/TB/USB4)监控玻璃卡
//   关键决策:走 LinkHealthService.snapshots[key: mountPoint] 读,不直接 spawn diskutil
//   已知限制:USB-NVMe 盒子 negotiated speed/width 都是 nil,UI 显 "—"(不假数据)
