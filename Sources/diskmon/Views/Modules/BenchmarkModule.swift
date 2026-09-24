import SwiftUI
import SwiftData
import Charts  // v0.9.3:live chart 缩略图(LineMark / AreaMark)
import AppKit  // v0.9.1 polish-Q:NSWorkspace.shared.open for FDA Settings deep link

/// BenchmarkModule v0.8 polish-M
/// 220x180 玻璃卡,显示每盘 writeMBps / readMBps 实值 + Expected 颜色对比
///
/// === 数据源 ===
/// `@Environment(BenchmarkService.self)` 读 results[key: mountPoint]
/// - results 字典在用户点 "Run Benchmark" 按钮后被填充
/// - key = mountPoint("/Volumes/applelog"),value = BenchmarkResult
/// - 缺数据 → "—"(不假数据)
///
/// === 高级交互规范(主人硬规则) ===
/// - 大数字:writeMBps 主显示(Fraunces 28pt italic)+ 数字滚动 .contentTransition(.numericText())
/// - 副标 1:readMBps + 单位 "MB/s"(SF Mono 11pt)
/// - 副标 2:expected → 实测对比(降级琥珀 / 正常米白)
/// - hover 玻璃卡边缘高光内移 1-2px(走 .glass() 统一接口)
/// - hover 大数字 1.02 放大
/// - 焦点环:琥珀 2px stroke
/// - 按下态:下沉 1px + scale 0.99
/// - 降级指示:实测 < 期望 70% → 琥珀 dsWarning / 正常米白
/// - 不 loop 动画 / 不弹跳 / 不 mock / nil → "—"
/// - 35mm 噪点(走 .glass() withNoise: true)
///
/// === 设计选择 ===
/// - 220x180(跟其他 Module 一致)
/// - 卡片右上角小图标:SF Symbol `gauge.with.dots.needle.67percent`(测速仪表盘)
/// - 顶标 "BENCH" 12pt secondary
/// - 主显示:主盘 writeMBps(大数字,实测)
/// - 副标 1:主盘 readMBps(中数字,实测)
/// - 副标 2:expected vs 实测对比
/// - 按钮:"Run Benchmark"(琥珀主调,主盘默认)
/// - in-flight → 显示 ProgressView(防双击)
struct BenchmarkModule: View {
    /// v0.4.0 polish-D + v0.8 polish-M:tab 切换标识(Bench tab)
    /// 标识本模块属于"Bench"分类,PopoverView 切换 tab 时按此过滤显示
    enum Detail { case overview, temperature, capacity, power, smart, link, test, bench, fs }
    static let moduleTab: Detail = .bench

    @Environment(HealthMonitor.self) private var monitor
    @Environment(BenchmarkService.self) private var benchmark

    // MARK: - 交互状态

    @State private var isCardHovered: Bool = false
    @State private var isButtonHovered: Bool = false
    @State private var isPressed: Bool = false
    @FocusState private var isFocused: Bool
    // v0.9.3:4 态状态机
    @State private var state: BenchmarkRunState = .idle
    // v0.9.1 polish-Q:错误 alert 状态
    @State private var benchError: BenchmarkService.BenchmarkError?
    // v0.9.3:run task 引用
    @State private var runTask: Task<Void, Never>?
    // v0.9.3:live chart ring buffer
    @State private var chartBuffer: BenchmarkLiveBuffer = BenchmarkLiveBuffer()

    var body: some View {
        cardBody
            // v0.4.0 polish-C:自适应 min/ideal/max(跟其他 Module 卡保持一致)
            .frame(minWidth: 180, idealWidth: 220, maxWidth: 280,
                   minHeight: 140, idealHeight: 180, maxHeight: .infinity)
            // 玻璃底 — v0.4.0 polish-B:真液态玻璃 + 35mm 噪点
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
            .animation(.easeInOut(duration: 0.3), value: writeSpeedText)
            // 切盘：清掉上一块盘的 success/failed 本地状态，避免仍显示 953
            .onChange(of: monitor.selectedDisk?.volumeUUID) { _, _ in
                if case .running = state { return }
                state = .idle
                chartBuffer.clear()
            }
            // v0.9.1 polish-Q:错误 alert
            .alert(
                "Benchmark Failed",
                isPresented: Binding(
                    get: { benchError != nil },
                    set: { if !$0 { benchError = nil } }
                ),
                presenting: benchError
            ) { err in
                Button("OK", role: .cancel) { benchError = nil }
                if err.requiresOpenSettings {
                    Button("Open Settings") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
                            NSWorkspace.shared.open(url)
                        }
                        benchError = nil
                    }
                }
            } message: { err in
                Text(err.errorDescription ?? "Unknown error")
            }
    }

    // MARK: - 卡片本体

    private var cardBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            // === 顶部:小标签 BENCH + 当前目标盘 ===
            HStack(spacing: 4) {
                Image(systemName: "gauge.with.dots.needle.67percent")
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(.tertiary)
                Text(String(localized: "module.bench.title", defaultValue: "测速"))
                    .font(.system(size: 11, weight: .medium, design: .default))
                    .tracking(0.6)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                if let name = primaryDisk?.displayName {
                    Text(name)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: 110, alignment: .trailing)
                }
            }
            .padding(.top, 2)

            Spacer(minLength: 0)

            // === 中部:状态内容(随 4 态变化)===
            stateContent

            Spacer(minLength: 0)

            // === 副标:last run hero(对比 expected)— 折衷方案:只 idle/success 时显 ===
            if case .running = state {
                EmptyView()
            } else {
                HStack(spacing: 4) {
                    Text(comparisonText)
                        .font(.fraunces(size: 13, weight: .regular, italic: true))
                        .foregroundStyle(comparisonColor)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            // === 底部按钮:随 4 态变化 ===
            actionButtons
                .padding(.top, 6)
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: - v0.9.3:4 态状态内容(中部)

    @ViewBuilder
    private var stateContent: some View {
        switch state {
        case .idle:
            // 跟原版一致:大数字 writeMBps + 副标 readMBps
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .center, spacing: 4) {
                    Text(writeSpeedText)
                        .font(.fraunces(size: 32, weight: .regular, italic: true))
                        .foregroundStyle(writeSpeedColor)
                        .monospacedDigit()
                        .scaleEffect(isCardHovered && writeSpeedText != "—" ? 1.02 : 1.0)
                        .contentTransition(.numericText(value: writeNumericKey))
                        .lineLimit(1)
                    Text("MB/s")
                        .font(.system(size: 11, weight: .regular, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
                HStack(alignment: .center, spacing: 4) {
                    Text("R:")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(.tertiary)
                    Text(readSpeedText)
                        .font(.system(size: 13, weight: .regular, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .lineLimit(1)
                    Text("MB/s")
                        .font(.system(size: 10, weight: .regular, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
            }
        case .running(let phase, let progress):
            // v0.9.3:阶段 + 进度 + live chart 缩略图
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .center, spacing: 4) {
                    Text("\(Int(progress * 100))%")
                        .font(.fraunces(size: 30, weight: .regular, italic: true))
                        .foregroundStyle(Color.dsWarning)
                        .monospacedDigit()
                        .contentTransition(.numericText(value: progress))
                        .lineLimit(1)
                    Text(phase.phaseLabel)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .tint(Color.dsWarning)
                // v0.9.3:live chart 缩略图(24pt 高)
                if !chartBuffer.points.isEmpty {
                    liveChartStrip
                        .frame(height: 24)
                }
            }
        case .success(let date, let duration, let w, let r):
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .center, spacing: 4) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(Color.dsNormal)
                    Text(String(format: "%.0f", w))
                        .font(.fraunces(size: 30, weight: .regular, italic: true))
                        .foregroundStyle(writeSpeedColor)
                        .monospacedDigit()
                        .lineLimit(1)
                    Text("MB/s")
                        .font(.system(size: 11, weight: .regular, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
                HStack(spacing: 4) {
                    Text("R: \(Int(r))")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Text("·")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                    Text(BenchmarkModule.formatDuration(duration))
                        .font(.system(size: 11, weight: .regular, design: .monospaced))
                        .foregroundStyle(.tertiary)
                    Text("·")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                    Text(BenchmarkModule.formatRelativeTime(date))
                        .font(.system(size: 11, weight: .regular, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
            }
        case .failed(let date, let error):
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .center, spacing: 4) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(Color.dsDanger)
                    Text("FAIL")
                        .font(.fraunces(size: 30, weight: .regular, italic: true))
                        .foregroundStyle(Color.dsDanger)
                        .lineLimit(1)
                }
                HStack(spacing: 4) {
                    Text(BenchmarkModule.formatRelativeTime(date))
                        .font(.system(size: 11, weight: .regular, design: .monospaced))
                        .foregroundStyle(.tertiary)
                    Text("·")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                    Text(error)
                        .font(.system(size: 11, weight: .regular, design: .monospaced))
                        .foregroundStyle(Color.dsDanger.opacity(0.85))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
        }
    }

    /// v0.9.3:live chart 缩略图(LineMark + AreaMark,ring buffer 100 pts)
    private var liveChartStrip: some View {
        Chart {
            ForEach(Array(chartBuffer.points.enumerated()), id: \.offset) { idx, v in
                LineMark(
                    x: .value("t", idx),
                    y: .value("MB/s", v)
                )
                .foregroundStyle(Color.dsWarning)
                .interpolationMethod(.monotone)
                .lineStyle(StrokeStyle(lineWidth: 1.2))
                AreaMark(
                    x: .value("t", idx),
                    y: .value("MB/s", v)
                )
                .foregroundStyle(Color.dsWarning.opacity(0.20))
                .interpolationMethod(.monotone)
            }
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartLegend(.hidden)
        .chartYScale(domain: chartBuffer.yDomain)
    }

    // MARK: - v0.9.3:4 态按钮(底部)

    @ViewBuilder
    private var actionButtons: some View {
        switch state {
        case .idle:
            runButtonContent
        case .running:
            stopButton
        case .success:
            reRunButton
        case .failed:
            retryButton
        }
    }

    private var runButtonContent: some View {
        Button {
            runBenchmark()
        } label: {
            HStack(spacing: 4) {
                Text(String(localized: "module.bench.run", defaultValue: "Run Benchmark"))
                    .font(.system(size: 10, weight: .medium, design: .default))
                    .tracking(0.3)
            }
            .foregroundStyle(isButtonHovered ? Color.dsNormal : .secondary)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(
                        isButtonHovered
                            ? Color.dsNormal.opacity(0.12)
                            : Color.primary.opacity(0.04)
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .stroke(
                        isButtonHovered ? Color.dsNormal.opacity(0.30) : Color.white.opacity(0.08),
                        lineWidth: 1
                    )
            )
        }
        .buttonStyle(.plain)
        .disabled(primaryDisk?.mountPoint == nil)
        .help(String(localized: "module.bench.runHelp", defaultValue: "Run 1GB write + read benchmark"))
        .onHover { isButtonHovered = $0 }
    }

    private var stopButton: some View {
        Button {
            cancelBenchmark()
        } label: {
            HStack(spacing: 4) {
                ProgressView()
                    .controlSize(.mini)
                    .tint(Color.dsWarning)
                Text("Stop")
                    .font(.system(size: 10, weight: .medium, design: .default))
                    .tracking(0.3)
            }
            .foregroundStyle(Color.dsWarning)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color.dsWarning.opacity(0.12))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .stroke(Color.dsWarning.opacity(0.30), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private var reRunButton: some View {
        Button {
            runBenchmark()
        } label: {
            Text("Re-run")
                .font(.system(size: 10, weight: .medium, design: .default))
                .tracking(0.3)
                .foregroundStyle(Color.dsNormal)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(Color.dsNormal.opacity(0.12))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .stroke(Color.dsNormal.opacity(0.30), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .disabled(primaryDisk?.mountPoint == nil)
    }

    private var retryButton: some View {
        Button {
            runBenchmark()
        } label: {
            Text("Retry")
                .font(.system(size: 10, weight: .medium, design: .default))
                .tracking(0.3)
                .foregroundStyle(Color.dsDanger)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(Color.dsDanger.opacity(0.12))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .stroke(Color.dsDanger.opacity(0.30), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .disabled(primaryDisk?.mountPoint == nil)
    }

    // MARK: - 数据:当前选中盘

    /// 测速目标 = 用户当前选中的盘（切盘即切目标）。
    /// 不得回退到「已有跑分的盘」——否则换盘后仍显示旧盘 953，Re-run 也测错盘。
    private var primaryDisk: DiskInfo? {
        monitor.selectedDisk ?? monitor.watchedDisks.first
    }

    private var primaryBenchmark: BenchmarkService.BenchmarkResult? {
        primaryDisk?.benchmark
    }

    // MARK: - 文本

    private var writeSpeedText: String {
        guard let bench = primaryBenchmark,
              let w = bench.writeMBps else { return "—" }
        // 0 位小数(MB/s 量级 ~1000s,整数足够)
        return String(format: "%.0f", w)
    }

    private var readSpeedText: String {
        guard let bench = primaryBenchmark,
              let r = bench.readMBps else { return "—" }
        return String(format: "%.0f", r)
    }

    /// `contentTransition(.numericText(value:))` 触发器(writeMBps)
    private var writeNumericKey: Double {
        primaryBenchmark?.writeMBps ?? 0
    }

    private var comparisonText: String {
        guard let bench = primaryBenchmark,
              let write = bench.writeMBps else {
            return String(localized: "module.bench.notRun", defaultValue: "Not run")
        }
        if let expected = bench.expectedWriteMBps, expected > 0 {
            return String(
                format: String(
                    localized: "module.bench.vsExpected",
                    defaultValue: "%.0f vs %.0f MB/s"
                ),
                write, expected
            )
        }
        // 没期望值(走 BusProtocol 失败)— 只显实测
        return String(
            format: String(
                localized: "module.bench.writeOnly",
                defaultValue: "W: %.0f MB/s"
            ),
            write
        )
    }

    // MARK: - 颜色

    private var writeSpeedColor: Color {
        guard let bench = primaryBenchmark,
              let write = bench.writeMBps else { return Color.secondary.opacity(0.5) }
        if let expected = bench.expectedWriteMBps, expected > 0 {
            // 降级:实测 < 期望 70% → 琥珀警告
            return write < expected * 0.7 ? Color.dsWarning : Color.dsNormal
        }
        return Color.dsNormal
    }

    private var comparisonColor: Color {
        guard let bench = primaryBenchmark,
              let write = bench.writeMBps else { return Color.secondary.opacity(0.5) }
        if let expected = bench.expectedWriteMBps, expected > 0 {
            return write < expected * 0.7 ? Color.dsWarning : Color.dsNormal
        }
        return Color.dsNormal
    }

    // MARK: - 按钮(v0.9.3 拆分:runButtonContent / stopButton / reRunButton / retryButton 都在 actionButtons 里)

    // MARK: - 动作

    // MARK: - 动作

    /// 触发 benchmark(v0.9.3:4 态 + progress + cancel)
    /// - 走 BenchmarkService.run(mountPoint:, progress:) — 写 1 GB + 读 1 GB(默认)
    /// - 失败弹 alert + 4 态 failed
    /// - 完成后 service 写 cache → 下次 pollOnce 5s 内同步到 DiskInfo.benchmark
    private func runBenchmark() {
        guard let disk = primaryDisk, let mountPoint = disk.mountPoint else { return }
        let startDate = Date()
        chartBuffer.clear()
        state = .running(phase: .preparing, progress: 0.0)
        runTask?.cancel()
        runTask = Task {
            do {
                let progressHandler: (BenchmarkService.BenchmarkPhase, Double) -> Void = { phase, p in
                    let mbps = BenchmarkModule.estimateMBps(progress: p, start: startDate, bytes: 1 << 30)
                    Task { @MainActor in
                        state = .running(phase: phase, progress: p)
                        chartBuffer.append(value: mbps)
                    }
                }
                let result = try await benchmark.run(
                    mountPoint: mountPoint,
                    bytes: 1 << 30,
                    force: true,
                    progress: progressHandler
                )
                let duration = Date().timeIntervalSince(startDate)
                state = .success(
                    date: Date(),
                    duration: duration,
                    writeMBps: result.writeMBps ?? 0,
                    readMBps: result.readMBps ?? 0
                )
                monitor.restartPolling()
            } catch is CancellationError {
                state = .idle
                chartBuffer.clear()
            } catch let err as BenchmarkService.BenchmarkError {
                benchError = err
                state = .failed(
                    date: Date(),
                    error: BenchmarkModuleHelper.errorToString(err)
                )
                chartBuffer.clear()
            } catch {
                NSLog("DiskMon: runBenchmark unexpected error for \(mountPoint): \(error)")
                state = .failed(date: Date(), error: String(describing: error))
                chartBuffer.clear()
            }
        }
    }

    private func cancelBenchmark() {
        runTask?.cancel()
        runTask = nil
    }

    // MARK: - Static helpers(v0.9.3)

    private static func estimateMBps(
        progress: Double,
        start: Date,
        bytes: UInt64
    ) -> Double {
        let elapsed = Date().timeIntervalSince(start)
        guard elapsed > 0.05 else { return 0 }
        return (Double(bytes) * progress / 1_000_000.0) / elapsed
    }

    static func formatDuration(_ seconds: TimeInterval) -> String {
        if seconds < 60 {
            return String(format: "%.1fs", seconds)
        } else {
            return String(format: "%.0fs", seconds)
        }
    }

    static func formatRelativeTime(_ date: Date) -> String {
        let elapsed = Date().timeIntervalSince(date)
        if elapsed < 60 { return "just now" }
        if elapsed < 3600 { return "\(Int(elapsed / 60))m ago" }
        if elapsed < 86400 { return "\(Int(elapsed / 3600))h ago" }
        return "\(Int(elapsed / 86400))d ago"
    }
}

// MARK: - BenchmarkModuleHelper(v0.9.3 共享 error 转换)

/// Benchmark 共享 helpers — DiskDetailView 跟 BenchmarkModule 共用
enum BenchmarkModuleHelper {
    static func errorToString(_ err: BenchmarkService.BenchmarkError) -> String {
        switch err {
        case .mountPointMissing: return "Not mounted"
        case .fullDiskAccessRequired: return "Full Disk Access required"
        case .fileCreationFailed: return "Cannot create test file"
        case .ioFailed(let code, _): return "IO failed (\(code))"
        }
    }
}

// grok 调研:v0.8 polish-M, Benchmark 玻璃卡(custom Swift POSIX I/O 测速显示)
//   关键决策:走 BenchmarkService.results[key: mountPoint] 读,不直接 spawn POSIX
//   已知限制:实测 < 期望 70% 标琥珀警告(SSD 老化 / 桥接降级 / 温度节流)
//            没跑过 → "—",不假数据
//            写 1 GB 对消费级 SSD 寿命影响极小,但在 SSD 寿命关键时刻仍建议跳过
