import SwiftUI

/// 读琥珀 / 写浅色双折线。Canvas 绘制，不走 Swift Charts。
/// 悬停只改本视图 @State，不额外采样。
struct DualIOChart: View {
    struct Point: Equatable {
        var date: Date
        var read: Double
        var write: Double
    }

    let points: [Point]
    var showsAxes: Bool = false
    var maxPoints: Int = 120

    @State private var hoverX: CGFloat? = nil

    init(read: [Double], write: [Double], showsAxes: Bool = false, maxPoints: Int = 120) {
        let n = max(read.count, write.count)
        let now = Date()
        var pts: [Point] = []
        pts.reserveCapacity(n)
        for i in 0..<n {
            pts.append(Point(
                date: now,
                read: i < read.count ? read[i] : 0,
                write: i < write.count ? write[i] : 0
            ))
        }
        self.points = pts
        self.showsAxes = showsAxes
        self.maxPoints = maxPoints
    }

    init(history: [HealthMonitor.IOHistoryPoint], showsAxes: Bool = false, maxPoints: Int = 120) {
        self.points = history.suffix(maxPoints).map {
            Point(date: $0.at, read: $0.readBps, write: $0.writeBps)
        }
        self.showsAxes = showsAxes
        self.maxPoints = maxPoints
    }

    var body: some View {
        let series = Array(points.suffix(maxPoints))
        GeometryReader { geo in
            let plot = plotRect(in: geo.size)
            ZStack(alignment: .topLeading) {
                Canvas { context, size in
                    drawChart(context: context, size: size, series: series, plot: plot)
                }
                if showsAxes {
                    axisLabels(series: series, plot: plot)
                }
                if let hoverX, series.count > 1 {
                    hoverOverlay(series: series, plot: plot, hoverX: hoverX)
                }
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let loc):
                    let x = min(max(loc.x, plot.minX), plot.maxX)
                    hoverX = x
                case .ended:
                    hoverX = nil
                }
            }
        }
    }

    private func plotRect(in size: CGSize) -> CGRect {
        let left: CGFloat = showsAxes ? 26 : 0
        let bottom: CGFloat = showsAxes ? 2 : 0
        return CGRect(
            x: left,
            y: 1,
            width: max(1, size.width - left - 4),
            height: max(1, size.height - bottom - 2)
        )
    }

    private func drawChart(
        context: GraphicsContext,
        size: CGSize,
        series: [Point],
        plot: CGRect
    ) {
        if showsAxes {
            for i in 0..<3 {
                let y = plot.maxY - plot.height * CGFloat(i) / 2
                var grid = Path()
                grid.move(to: CGPoint(x: plot.minX, y: y))
                grid.addLine(to: CGPoint(x: plot.maxX, y: y))
                context.stroke(
                    grid,
                    with: .color(Color.white.opacity(i == 0 ? 0.16 : 0.07)),
                    style: StrokeStyle(lineWidth: 0.5, dash: i == 0 ? [] : [2, 2])
                )
            }
            var yAxis = Path()
            yAxis.move(to: CGPoint(x: plot.minX, y: plot.minY))
            yAxis.addLine(to: CGPoint(x: plot.minX, y: plot.maxY))
            context.stroke(yAxis, with: .color(Color.white.opacity(0.14)), lineWidth: 0.5)
        }

        guard series.count > 1 else { return }
        let maxV = max(series.map(\.read).max() ?? 0, series.map(\.write).max() ?? 0, 1)
        stroke(context: context, series: series, plot: plot, maxV: maxV, key: \.write, color: Color.white.opacity(0.30))
        stroke(context: context, series: series, plot: plot, maxV: maxV, key: \.read, color: Color.dsNormal)
    }

    private func stroke(
        context: GraphicsContext,
        series: [Point],
        plot: CGRect,
        maxV: Double,
        key: KeyPath<Point, Double>,
        color: Color
    ) {
        let dx = plot.width / CGFloat(series.count - 1)
        var path = Path()
        for (i, p) in series.enumerated() {
            let x = plot.minX + CGFloat(i) * dx
            let y = plot.maxY - CGFloat(p[keyPath: key] / maxV) * plot.height
            if i == 0 { path.move(to: CGPoint(x: x, y: y)) }
            else { path.addLine(to: CGPoint(x: x, y: y)) }
        }
        context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: 1.15, lineJoin: .round))
    }

    @ViewBuilder
    private func axisLabels(series: [Point], plot: CGRect) -> some View {
        let maxV = max(series.map(\.read).max() ?? 0, series.map(\.write).max() ?? 0, 1)
        VStack {
            Text(ByteFormatter.bpsShort(maxV))
            Spacer(minLength: 0)
            Text("0")
        }
        .font(.system(size: 8, design: .monospaced))
        .foregroundStyle(.tertiary)
        .frame(width: 24, height: plot.height, alignment: .trailing)
        .position(x: 12, y: plot.midY)
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private func hoverOverlay(series: [Point], plot: CGRect, hoverX: CGFloat) -> some View {
        let idx = index(at: hoverX, series: series, plot: plot)
        let p = series[idx]
        let dx = plot.width / CGFloat(series.count - 1)
        let x = plot.minX + CGFloat(idx) * dx
        let maxV = max(series.map(\.read).max() ?? 0, series.map(\.write).max() ?? 0, 1)
        let yR = plot.maxY - CGFloat(p.read / maxV) * plot.height
        ZStack(alignment: .topLeading) {
            Path { path in
                path.move(to: CGPoint(x: x, y: plot.minY))
                path.addLine(to: CGPoint(x: x, y: plot.maxY))
            }
            .stroke(Color.white.opacity(0.22), style: StrokeStyle(lineWidth: 0.5, dash: [2, 2]))
            Circle()
                .fill(Color.dsNormal)
                .frame(width: 5, height: 5)
                .position(x: x, y: yR)
            tooltip(for: p)
                .offset(
                    x: min(max(4, x + 8), plot.maxX - 118),
                    y: 2
                )
        }
        .allowsHitTesting(false)
    }

    private func tooltip(for p: Point) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            if p.date.timeIntervalSince1970 > 0 {
                Text(p.date.formatted(.dateTime.hour().minute().second()))
                    .foregroundStyle(.tertiary)
            }
            Text("R  \(ByteFormatter.bps(p.read))")
                .foregroundStyle(Color.dsNormal)
            Text("W  \(ByteFormatter.bps(p.write))")
                .foregroundStyle(.secondary)
        }
        .font(.system(size: 9, weight: .medium, design: .monospaced))
        .monospacedDigit()
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(.regularMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .stroke(Color.white.opacity(0.10), lineWidth: 0.5)
        )
    }

    private func index(at x: CGFloat, series: [Point], plot: CGRect) -> Int {
        guard series.count > 1, plot.width > 0 else { return 0 }
        let t = (x - plot.minX) / plot.width
        let i = Int((t * CGFloat(series.count - 1)).rounded())
        return min(max(0, i), series.count - 1)
    }
}
