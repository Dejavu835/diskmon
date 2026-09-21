import SwiftUI

/// 35mm 胶片噪点 + vignette overlay
/// fire 5:真 PNG `35mm.png`(256x256,256 阶灰度,sigma=35 → stdev 35,真胶片颗粒)
///        + RadialGradient 暗色专属 vignette(SOP §5.3 12% 暗)
///        + 亮 / 暗色都自然(.blendMode(.overlay))
/// v0.4.3 polish-I P2-4:design 永远显 vignette — polish-G 改成暗色方案后
///   light colorScheme 不会出现,删 `if colorScheme == .dark` 条件;保留 env 注入以备未来亮色再开
struct NoiseOverlay: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            // 1) 35mm 噪点 PNG — Assets.xcassets/Noise.imageset/35mm.png
            //    .resizable(resizingMode: .tile) 平铺,opacity 0.04 + .blendMode(.overlay)
            Image("35mm")
                .resizable(resizingMode: .tile)
                .opacity(0.04)
                .blendMode(.overlay)
                .allowsHitTesting(false)

            // 2) Vignette — 永远显,边缘 12% 暗(SOP §5.3)
            //    P2-4 polish-I:删 `if colorScheme == .dark` 条件,暗色方案下自动正确
            RadialGradient(
                colors: [Color.clear, Color.black.opacity(0.12)],
                center: .center,
                startRadius: 100,
                endRadius: 320
            )
            .blendMode(.multiply)
            .allowsHitTesting(false)
        }
        .accessibilityHidden(true)
    }
}
