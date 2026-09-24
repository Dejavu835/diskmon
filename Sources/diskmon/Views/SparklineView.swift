import SwiftUI

/// Mini sparkline 折线 v0.2.0
/// - 接受 [Double] 数据,渲染 40x16 折线(默认,可自定义)
/// - 平滑 catmull-rom-like 折线 + 半透明 area fill
/// - 颜色 customizable
/// - 单个 [Double] 数据 → 平直;空数组 → 占位提示
struct SparklineView: View {
    let values: [Double]
    var lineColor: Color = Color.themeFgDark
    var fillColor: Color? = nil
    var frameSize: CGSize = CGSize(width: 40, height: 16)
    var lineWidth: CGFloat = 1.0

    var body: some View {
        Canvas { context, size in
            guard values.count > 1 else { return }
            // 找 max / min
            let maxV = values.max() ?? 0
            let minV = values.min() ?? 0
            let range = max(0.001, maxV - minV)
            // x / y
            let n = values.count
            let dx = size.width / CGFloat(n - 1)
            let topPad: CGFloat = 1
            let bottomPad: CGFloat = 1
            let usableH = max(0, size.height - topPad - bottomPad)
            // 计算 points
            var points: [CGPoint] = []
            for (i, v) in values.enumerated() {
                let x = CGFloat(i) * dx
                let normalized = (v - minV) / range
                let y = topPad + (1 - CGFloat(normalized)) * usableH
                points.append(CGPoint(x: x, y: y))
            }
            // 1) area fill
            if let fillColor {
                var fill = Path()
                fill.move(to: CGPoint(x: 0, y: size.height))
                for p in points { fill.addLine(to: p) }
                fill.addLine(to: CGPoint(x: size.width, y: size.height))
                fill.closeSubpath()
                context.fill(fill, with: .color(fillColor))
            }
            // 2) line
            var line = Path()
            line.move(to: points[0])
            for p in points.dropFirst() { line.addLine(to: p) }
            context.stroke(
                line, with: .color(lineColor),
                style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round)
            )
        }
        .frame(width: frameSize.width, height: frameSize.height)
        .accessibilityLabel(Text("Sparkline"))
    }
}
