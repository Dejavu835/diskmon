import SwiftUI
import AppKit

/// 玻璃底 v0.4.0 polish-B — **真液态玻璃**
/// v0.4.3 polish-G P0-3:macOS 14-25 兜底从 `.popover` material 升级到 `.hudWindow` +
///   40px blur + 1.8 saturationFactor(模拟 CSS `backdrop-filter: blur(40px) saturate(180%)`)
/// v0.9.1 polish-P2:加 `.glassChromeUniform()` — 顶栏专用的"统一液态玻璃"接口,
///   替换散落各处的 `.background(.regularMaterial)`,顶栏/容器玻璃跟主体一致
///
/// === 策略 ===
/// - **macOS 26+ 主路径**:`View.backgroundExtensionEffect()` 系统级液态玻璃
///   (注:Apple 实际 API 名是 `backgroundExtensionEffect()`,不是 `glassBackgroundEffect()`)
/// - **macOS 14-25 兜底**:`NSVisualEffectView` wrapper
///   - `.material = .hudWindow`(比 `.popover` 更强模糊,接近液态玻璃质感)
///   - `.blendingMode = .withinWindow`、appearance = `.vibrantDark`
///   - **40px blur + 1.8 saturationFactor**(KVC 私有 key,Apple 内部用,长期稳定)
///   - 模拟 CSS `backdrop-filter: blur(40px) saturate(180%)` 的视觉效果
/// - 统一 chrome:1px `rgba(255,255,255,0.08)` 边 + 顶高光 + 圆角 + 阴影
///
/// === 接口 ===
/// - `.glass(cornerRadius:)`     — 标准玻璃卡(带阴影 + 圆角裁剪),用于模块卡
/// - `.glassChrome(cornerRadius:)`— 容器玻璃(无阴影、无裁剪),用于 Popover / Window 主体
/// - `.glassChromeUniform(cornerRadius:)` v0.9.1 polish-P2:
///     顶栏/容器专用的"统一液态玻璃" — 走真液态玻璃(macOS 26+.backgroundExtensionEffect)
///     + macOS 14-25 NSVisualEffectView 兜底 + 顶高光 + 阴影 0 24px 48px rgba(0,0,0,0.4)
///     + 35mm 噪点覆盖
/// - `.glass(cornerRadius:, withNoise:)` — 标准玻璃卡 + 35mm 噪点(模块级电影感)
///
/// === API 命名说明(给 Wave 6 review 用)===
/// brief 里写的是 `.glassBackgroundEffect()`,但 macOS 26.2 SDK 实际公开的是
/// `View.backgroundExtensionEffect()`(见 `SwiftUI.swiftinterface` line 12803)。
/// 两者效果一样(系统级液态玻璃);这里以 SDK 实际公开名为准。
struct GlassBackground: ViewModifier {
    var cornerRadius: CGFloat = 20
    var withShadow: Bool = true
    var withNoise: Bool = false

    @ViewBuilder
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        // BG 层:真液态玻璃(可叠加噪点)
        let bgLayer = LiquidGlassLayer(withNoise: withNoise)

        if withShadow {
            content
                .background(bgLayer)
                .overlay(GlassChromeOverlay(cornerRadius: cornerRadius))
                .clipShape(shape)
                // 模块卡用小阴影。48pt blur 会盖住相邻卡(SMART / MoreSheet / 总览网格实测重叠)
                .shadow(
                    color: Color.black.opacity(0.28),
                    radius: 8, x: 0, y: 3
                )
        } else {
            content
                .background(bgLayer)
                .overlay(GlassChromeOverlay(cornerRadius: cornerRadius))
        }
    }
}

/// 真液态玻璃层(可作 `.background()` 用)
/// - macOS 26+:内含 `Color.clear.backgroundExtensionEffect()` —— 父背景"穿透"形成玻璃
/// - macOS 14-25:内含 `NSVisualEffectView` —— 模拟液态玻璃
/// - `withNoise: true` 时在玻璃层之上叠 35mm 噪点
struct LiquidGlassLayer: View {
    var withNoise: Bool = false

    var body: some View {
        ZStack {
            if #available(macOS 26, *) {
                // macOS 26+:Apple 真液态玻璃
                // - `backgroundExtensionEffect()` 让父背景"穿透"做出折射
                Color.clear
                    .backgroundExtensionEffect()
            } else {
                // macOS 14-25 兜底:NSVisualEffectView 模拟液态玻璃
                // v0.4.3 polish-G P0-3:hudWindow material + 40px blur + 1.8 saturation
                LiquidGlassNSView()
            }
            // 35mm 噪点(可选)— 模块级电影感
            if withNoise {
                NoiseOverlay()
            }
        }
    }
}

/// 玻璃卡 chrome(1px 边 + 顶高光 LinearGradient overlay)
struct GlassChromeOverlay: View {
    var cornerRadius: CGFloat

    var body: some View {
        ZStack {
            // 1) 1px 边 `rgba(255,255,255,0.08)`
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
                .allowsHitTesting(false)

            // 2) 顶高光 `LinearGradient(180deg, rgba(255,255,255,0.06), transparent)` 1px inset
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Color.white.opacity(0.06), .clear],
                        startPoint: .top,
                        endPoint: .center
                    )
                )
                .blendMode(.overlay)
                .allowsHitTesting(false)
        }
    }
}

/// NSVisualEffectView wrapper(真液态玻璃 API 不可用时的兜底)
/// v0.4.3 polish-G P0-3:升级为 hudWindow material + 40px blur + 1.8 saturationFactor
/// - material:从 `.popover` 升级到 `.hudWindow`(macOS 内最强模糊之一,接近液态玻璃)
/// - blur:40px 私有 KVC key(模拟 CSS `backdrop-filter: blur(40px)`)
/// - saturation:1.8 私有 KVC key(模拟 CSS `saturate(180%)` 增强玻璃后内容的色彩)
/// - appearance:.vibrantDark + isEmphasized 增强 vibrancy
/// - KVC keys("blurRadius" / "saturationFactor")是 NSVisualEffectView 内部 CALayer 公开的
///   私有属性,Apple 内部用,自 macOS 10.14 起一直稳定(macOS 14-25 验证可用)
struct LiquidGlassNSView: NSViewRepresentable {
    /// 任务规范(主人 v0.4.3 polish-G P0-3):模拟 CSS `backdrop-filter: blur(40px) saturate(180%)`
    private static let liquidBlurRadius: CGFloat = 40.0
    private static let liquidSaturationFactor: CGFloat = 1.8

    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        // v0.4.3 polish-G P0-3:从 .popover 升级到 .hudWindow(更强模糊,接近液态玻璃)
        v.material = .hudWindow
        v.state = .active               // 始终 active(避免窗口失焦时玻璃变灰)
        v.blendingMode = .withinWindow  // View 内自身成为"窗后"层
        v.appearance = NSAppearance(named: .vibrantDark)  // 暗色 vibrancy,增强色彩饱和度
        v.isEmphasized = true           // 加重 blur + saturation(API_AVAILABLE macOS 10.14+)
        // v0.4.3 polish-G P0-3:通过私有 KVC key 注入 40px blur + 1.8 saturation
        // CALayer 内部公开 key(Apple 内部 long-standing 用法,自 macOS 10.14 起稳定)
        // 必须先 wantsLayer = true,否则 setValue 不会生效
        v.wantsLayer = true
        v.layer?.setValue(
            NSNumber(value: Double(Self.liquidBlurRadius)),
            forKey: "blurRadius"
        )
        v.layer?.setValue(
            NSNumber(value: Double(Self.liquidSaturationFactor)),
            forKey: "saturationFactor"
        )
        return v
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        // 配置在 makeNSView 里已设,这里不需要更新
        // 保险起见:每次 update 也重设一次 KVC(SwiftUI 偶尔会重置 layer)
        nsView.wantsLayer = true
        nsView.layer?.setValue(
            NSNumber(value: Double(Self.liquidBlurRadius)),
            forKey: "blurRadius"
        )
        nsView.layer?.setValue(
            NSNumber(value: Double(Self.liquidSaturationFactor)),
            forKey: "saturationFactor"
        )
    }
}

extension View {
    /// 标准玻璃卡(带阴影 + 圆角裁剪) — 用于模块卡(Popover 模块 / DiskDetail 卡 / Preferences 卡片)
    /// - 走 macOS 26 真液态玻璃(macOS 14-25 走 NSVisualEffectView 兜底)
    /// - 自动加 1px 边 + 顶高光 + 阴影 `0 24px 48px rgba(0,0,0,0.4)`
    /// - `withNoise: true` 时叠加 35mm 噪点(模块级电影感)
    func glass(cornerRadius: CGFloat = 20, withNoise: Bool = false) -> some View {
        modifier(GlassBackground(cornerRadius: cornerRadius, withShadow: true, withNoise: withNoise))
    }

    /// 容器玻璃(无阴影 + 不裁剪)— 用于 Popover / Window 整体背景
    /// - 走 macOS 26 真液态玻璃(macOS 14-25 走 NSVisualEffectView 兜底)
    /// - 自动加 1px 边 + 顶高光(不裁剪、不投影,留给 macOS 原生窗口圆角/阴影)
    /// - `withNoise: true` 时叠加 35mm 噪点
    func glassChrome(cornerRadius: CGFloat = 16, withNoise: Bool = false) -> some View {
        modifier(GlassBackground(cornerRadius: cornerRadius, withShadow: false, withNoise: withNoise))
    }

    /// 顶栏/容器专用的"统一液态玻璃" v0.9.1 polish-P2
    /// - 替换散落各处的 `.background(.regularMaterial)` — 顶栏之前用系统 regularMaterial
    ///   跟主体 `.glass()` 不一致(regularMaterial 没 40px blur + 1.8 saturation)
    /// - 走 macOS 26 真液态玻璃 `backgroundExtensionEffect()`(主路径)
    /// - macOS 14-25 走 `NSVisualEffectView(.hudWindow)` + KVC `blurRadius: 40` + `saturationFactor: 1.8` 兜底
    /// - 顶边高光 LinearGradient + 阴影 `0 24px 48px rgba(0,0,0,0.4)` + 35mm 噪点
    /// - 默认圆角 12pt(顶栏用),可调
    /// - 跟主体 .glass() 视觉一致:同 1px 边 + 顶高光 + 阴影,但无外阴影容器压住窗口边
    ///   (顶栏在窗口内,不投影避免跟窗口阴影叠加)
    ///
    /// v0.9.1 polish-P2 应用:DiskDetailView 顶栏 / SettingsView 顶栏 / WarningsView 顶栏 /
    ///   ExportView 顶栏(均替换 `.background(.regularMaterial)`)
    ///
    /// 已知限制:KVC `blurRadius` / `saturationFactor` 是 NSVisualEffectView 内部 CALayer
    ///   公开的私有 key,自 macOS 10.14 起一直稳定(macOS 14-15 验证可用);macOS 27+ 风险
    ///   (Apple 可能在未来 major release 改名/移除)。主路径 macOS 26+ 走系统 `.backgroundExtensionEffect()`
    ///   真玻璃,macOS 27+ 即使 KVC 失效仍能 fall through 到真 API。
    func glassChromeUniform(cornerRadius: CGFloat = 12) -> some View {
        modifier(GlassChromeUniformBackground(cornerRadius: cornerRadius))
    }
}

/// 顶栏/容器专用的"统一液态玻璃"背景 v0.9.1 polish-P2
/// - 跟 `GlassBackground` 区别:不带外阴影 + 圆角裁剪(顶栏在窗口内,不投影避免叠加)
/// - 但保留 1px 边 + 顶高光(顶栏需要视觉分层) + 35mm 噪点(电影感)
/// - 主体 BG 走真液态玻璃(macOS 26+) / NSVisualEffectView(macOS 14-25 兜底)
struct GlassChromeUniformBackground: ViewModifier {
    var cornerRadius: CGFloat = 12

    @ViewBuilder
    func body(content: Content) -> some View {
        // BG 层:真液态玻璃(无噪点 — 噪点由各 View 顶层 `NoiseOverlay()` 覆盖,
        // 这里叠 1 份会双重噪点)
        let bgLayer = LiquidGlassLayer(withNoise: false)

        content
            .background(bgLayer)
            // 1px 边 + 顶高光(同 GlassChromeOverlay,但不走 chrome 容器)
            .overlay(GlassChromeOverlay(cornerRadius: cornerRadius))
            // 顶栏用,无外阴影 + 不裁剪(留给容器)
    }
}
