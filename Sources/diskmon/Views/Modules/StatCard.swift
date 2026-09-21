import SwiftUI

/// 通用 StatCard v0.4.0 wave-4g(高级交互规范版,模块网格用)
///
/// 单一职责:接收 `value: Double` + 单位 + 标签 + 颜色 → 渲染模块网格中的大数字卡
///
/// === 设计选择(高级交互规范) ===
/// - **玻璃卡规范**(任务硬规则):真液态玻璃(macOS 26+ `backgroundExtensionEffect()`)
///   + 1px `rgba(255,255,255,0.08)` 边 + 顶边高光 LinearGradient 1px inset
///   + 阴影 `0 24px 48px rgba(0,0,0,0.4)` + 20px 圆角 + 35mm 噪点 + vignette
///   全部走 `Views/Preferences/GlassBackground.swift` 的 `.glass(withNoise: true)` 统一接口
/// - **大数字**:Fraunces 56pt em italic,按 `color` 着色(琥珀/红/绿/前景)
///   - 数字滚动:`.contentTransition(.numericText(value:))` + 0.3s ease
/// - **小标签**:11px uppercase tracking 0.6 文字次色
/// - **单位**:SF Mono 14pt 文字次色
/// - **hover 交互**:
///   - 大数字 1.02 放大 + 玻璃卡边缘高光内移 1-2px(0.3s `cubic-bezier(0.2, 0.8, 0.2, 1)`)
/// - **焦点环**:琥珀 2px stroke(`focusable() + focusEffectDisabled() + @FocusState`)
/// - **按下态**:下沉 1px + scale 0.99
/// - **nil 数据**:`Double.nan` 传进来 → 显 "—";不 mock 假数据
///
/// === 不做 ===
/// - 不写 SwiftData(纯展示)
/// - 不动 `GlassBackground.swift` / 5 个 Preferences 子 View /
///   `AppSettings.swift` / `Localizable.strings`(任务硬规则)
struct StatCard: View {
    /// 大数字(Double)— `nan` 显 "—"
    let value: Double
    /// 单位(SF Mono 14pt)
    var unit: String = ""
    /// 11px uppercase 标签
    var label: String = ""
    /// 大数字主色(琥珀/红/绿/前景)
    var color: Color = .primary

    // MARK: - 交互状态

    /// 玻璃卡整体 hover
    @State private var isCardHovered: Bool = false
    /// 焦点(Tab 键)
    @FocusState private var isFocused: Bool
    /// 按下态
    @State private var isPressed: Bool = false

    var body: some View {
        cardBody
            // 统一缓动 0.3s `Animation.timingCurve(0.2, 0.8, 0.2, 1)`(任务硬规则)
            .animation(
                .timingCurve(0.2, 0.8, 0.2, 1, duration: 0.3),
                value: isCardHovered
            )
            .animation(.easeOut(duration: 0.15), value: isFocused)
            .animation(.easeInOut(duration: 0.12), value: isPressed)
            .animation(.easeInOut(duration: 0.3), value: value)
    }

    // MARK: - 卡片本体

    private var cardBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            // === 顶部:小标签 ===
            Text(label.uppercased())
                .font(.system(size: 11, weight: .medium, design: .default))
                .tracking(0.6)  // ≈ letter-spacing 0.08em at 11pt
                .foregroundStyle(.secondary)
                .padding(.horizontal, 14)
                .padding(.top, 12)

            Spacer(minLength: 0)

            // === 中部:大数字 + 单位 ===
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(mainReading)
                    .font(.fraunces(size: 44, weight: .regular, italic: true))
                    .foregroundStyle(color)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .scaleEffect(isCardHovered ? 1.02 : 1.0)
                    .contentTransition(.numericText(value: value))
                    .animation(.easeInOut(duration: 0.3), value: value)
                if !unit.isEmpty {
                    Text(unit)
                        .font(.system(size: 14, weight: .regular, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .padding(.leading, 2)
                }
            }
            .padding(.horizontal, 14)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, minHeight: 96, idealHeight: 120)
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
        .onHover { isCardHovered = $0 }
    }

    // MARK: - 文本

    /// 大数字文案:`Double.nan` → "—";整数 → 整数;小数 → 1 位小数
    private var mainReading: String {
        if value.isNaN { return "—" }
        if value.truncatingRemainder(dividingBy: 1) == 0
            && abs(value) < 1e9 {
            return String(format: "%.0f", value)
        }
        return String(format: "%.1f", value)
    }
}

// MARK: - 玻璃卡背景(私有,不动 GlassBackground)

/// StatCard 专用玻璃卡背景
/// 严格按任务规范:
/// - `.regularMaterial` 兜底
// v0.4.0 polish-B:`StatCardGlassBackground` 已删除,统一走 `Views/Preferences/GlassBackground.swift` 的 `.glass()` 接口
// 旧"hover 时高光位移 1-2px"在统一接口里不保留(用户硬规则:同一接口,不加 hover state 参数)
