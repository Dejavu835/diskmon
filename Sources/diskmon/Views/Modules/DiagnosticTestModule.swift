import SwiftUI
import SwiftData
import AppKit  // v0.9.1 polish-Q:NSWorkspace.shared.open for FDA Settings deep link

/// DiagnosticTestModule v0.8 polish-L
/// 220x180 玻璃卡,显示每盘最后 self-test 结果 + 时间戳 + Run Short / Run Long 按钮
///
/// === 数据源 ===
/// `@Environment(DiagnosticTestService.self)` 读 snapshots[key: bsdName]
/// - snapshots 由 HealthMonitor.pollOnce 末尾 fetchLastResult 写回
/// - key = bsdName("disk5"),value = TestSnapshot
/// - 缺数据 → "—"(不假数据)
///
/// === 高级交互规范(主人硬规则) ===
/// - 大数字:lastTest pass/fail 状态(Fraunces 28pt italic)+ 数字滚动
/// - 副标:lastTest timestamp + test type(SF Mono 11pt)
/// - 按钮:Run Short / Run Long(2 个并排小按钮,玻璃风)
/// - hover 玻璃卡边缘高光内移 1-2px
/// - 焦点环:琥珀 2px stroke
/// - 按下态:下沉 1px + scale 0.99
/// - 不 loop 动画 / 不弹跳 / 不 mock / nil → "—"
/// - 35mm 噪点(走 .glass() withNoise: true)
///
/// === 设计选择 ===
/// - 220x180(跟其他 Module 一致)
/// - 卡片右上角小图标:SF Symbol `checkmark.shield.fill`(SMART self-test 语义)
/// - 顶标 "TEST" 12pt secondary
/// - 主显示:主盘 lastShortTest status(简化只显示 short 状态)
/// - 副标:lastLongTest status(一行)+ 时间
/// - 2 按钮:Run Short(琥珀主调) / Run Long(secondary 调)
///   - hover → 数字滚动 + 0.15s 反馈
///   - press → 下沉 1px + scale 0.98
struct OpenTestAction {
    let handler: () -> Void
    func callAsFunction() { handler() }
}

private enum OpenTestKey: EnvironmentKey {
    static let defaultValue = OpenTestAction(handler: {})
}

extension EnvironmentValues {
    var openTest: OpenTestAction {
        get { self[OpenTestKey.self] }
        set { self[OpenTestKey.self] = newValue }
    }
}

struct DiagnosticTestModule: View {
    enum Role { case entry, panel }
    var role: Role = .entry

    /// v0.4.0 polish-D:tab 切换标识(本 Module 跟 Test tab 配对)
    enum Detail { case overview, temperature, capacity, power, smart, link, test }
    static let moduleTab: Detail = .test

    @Environment(HealthMonitor.self) private var monitor
    @Environment(DiagnosticTestService.self) private var diagnostic
    @Environment(AppSettings.self) private var settings
    @Environment(\.openTest) private var openTest

    // MARK: - 交互状态

    @State private var isCardHovered: Bool = false
    @State private var isPressed: Bool = false
    @State private var isRunShortHovered: Bool = false
    @State private var isRunLongHovered: Bool = false
    @FocusState private var isFocused: Bool
    // v0.9.3:4 态状态机 — short / long 独立
    @State private var shortState: SelfTestRunState = .idle
    @State private var longState: SelfTestRunState = .idle
    // v0.9.1 polish-Q:错误 alert 状态
    @State private var testError: DiagnosticTestService.SelfTestError?
    // v0.9.3:run task 引用
    @State private var runTask: Task<Void, Never>?

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
            .animation(.easeInOut(duration: 0.3), value: statusText)
            // v0.9.1 polish-Q:错误 alert
            .alert(
                L10n.t("module.test.failed", zh: "自检失败", en: "Test Failed", language: settings.language),
                isPresented: Binding(
                    get: { testError != nil },
                    set: { if !$0 { testError = nil } }
                ),
                presenting: testError
            ) { err in
                Button(L10n.t("common.ok", zh: "好", en: "OK", language: settings.language), role: .cancel) { testError = nil }
                if err.requiresOpenSettings {
                    Button(L10n.t("manage.ntfs.enable", zh: "打开系统设置", en: "Open Settings", language: settings.language)) {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
                            NSWorkspace.shared.open(url)
                        }
                        testError = nil
                    }
                }
            } message: { err in
                Text(err.errorDescription ?? "Unknown error")
            }
    }

    // MARK: - 卡片本体

    private var cardBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            // === 顶部:小标签 "TEST" ===
            HStack(spacing: 4) {
                Image(systemName: "checkmark.shield.fill")
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(.tertiary)
                Text(L10n.t("module.test.title", zh: "自检", en: "TEST", language: settings.language))
                    .font(.system(size: 11, weight: .medium, design: .default))
                    .tracking(0.6)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                if let name = primaryDisk?.displayName {
                    Text(name)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            .padding(.top, 2)

            Spacer(minLength: 0)

            // === 中部:状态文字(随 4 态变化)===
            stateContent

            Spacer(minLength: 0)

            // === 底部副标:lastTest timestamp + type ===
            Text(subtitleText)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(isCardHovered ? Color.themeFgDark : .secondary)
                .lineLimit(1)
                .truncationMode(.tail)

            // === 底部按钮区(随状态变化)===
            actionButtons
                .padding(.top, 6)
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: - v0.9.3:4 态状态内容(中部大字)

    @ViewBuilder
    private var stateContent: some View {
        // 简化:只看 short 的 4 态(主显示,跟原版一致)
        let runningState: SelfTestRunState = {
            if case .running = shortState { return shortState }
            if case .running = longState { return longState }
            return shortState
        }()
        switch runningState {
        case .idle:
            HStack(alignment: .center, spacing: 4) {
                Text("—")
                    .font(.fraunces(size: 36, weight: .regular, italic: true))
                    .foregroundStyle(Color.secondary.opacity(0.5))
                Text(L10n.t("module.test.notRun", zh: "未跑过", en: "not run", language: settings.language))
                    .font(.system(size: 12, weight: .regular, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
        case .running(let progress, let eta):
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .center, spacing: 4) {
                    Text("\(Int(progress * 100))%")
                        .font(.fraunces(size: 36, weight: .regular, italic: true))
                        .foregroundStyle(Color.dsWarning)
                        .monospacedDigit()
                        .contentTransition(.numericText(value: progress))
                        .lineLimit(1)
                    if let eta = eta {
                        Text(DiagnosticTestModule.formatETA(eta, language: settings.language))
                            .font(.system(size: 11, weight: .regular, design: .monospaced))
                            .foregroundStyle(.tertiary)
                    }
                }
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .tint(Color.dsWarning)
            }
        case .success(let date, let duration, _):
            HStack(alignment: .center, spacing: 4) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(Color.dsNormal)
                VStack(alignment: .leading, spacing: 0) {
                    Text("PASS")
                        .font(.fraunces(size: 32, weight: .regular, italic: true))
                        .foregroundStyle(Color.dsNormal)
                        .lineLimit(1)
                    Text("\(DiagnosticTestModule.formatDuration(duration)) · \(DiagnosticTestModule.formatRelativeTime(date))")
                        .font(.system(size: 10, weight: .regular, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
        case .failed(let date, let error):
            HStack(alignment: .center, spacing: 4) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(Color.dsDanger)
                VStack(alignment: .leading, spacing: 0) {
                    Text("FAIL")
                        .font(.fraunces(size: 32, weight: .regular, italic: true))
                        .foregroundStyle(Color.dsDanger)
                        .lineLimit(1)
                    Text("\(DiagnosticTestModule.formatRelativeTime(date)) · \(error)")
                        .font(.system(size: 10, weight: .regular, design: .monospaced))
                        .foregroundStyle(Color.dsDanger.opacity(0.85))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
        }
    }

    // MARK: - v0.9.3:4 态按钮(底部)

    @ViewBuilder
    private var actionButtons: some View {
        if isTestRunning {
            stopButton
        } else if role == .entry {
            Button {
                openTest()
            } label: {
                Text(L10n.t("module.test.open", zh: "打开自检", en: "Open test", language: settings.language))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.dsNormal)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.dsNormal.opacity(0.16)))
            }
            .buttonStyle(.plain)
        } else {
            switch shortState {
            case .idle:
                HStack(spacing: 6) {
                    runButton(
                        label: L10n.t("module.test.runShort", zh: "短测", en: "Short", language: settings.language),
                        isHovered: isRunShortHovered,
                        isInFlight: false,
                        action: { runShort() }
                    )
                    .onHover { isRunShortHovered = $0 }
                    runButton(
                        label: L10n.t("module.test.runLong", zh: "长测", en: "Long", language: settings.language),
                        isHovered: isRunLongHovered,
                        isInFlight: false,
                        action: { runLong() }
                    )
                    .onHover { isRunLongHovered = $0 }
                }
            case .running:
                stopButton
            case .success:
                runButton(
                    label: L10n.t("module.test.rerun", zh: "再跑", en: "Re-run", language: settings.language),
                    isHovered: isRunShortHovered,
                    isInFlight: false,
                    action: { runShort() }
                )
                .onHover { isRunShortHovered = $0 }
            case .failed:
                runButton(
                    label: L10n.t("module.test.retry", zh: "重试", en: "Retry", language: settings.language),
                    isHovered: isRunShortHovered,
                    isInFlight: false,
                    color: Color.dsDanger,
                    action: { runShort() }
                )
                .onHover { isRunShortHovered = $0 }
            }
        }
    }

    /// v0.9.3:Stop 按钮(running 状态)
    private var stopButton: some View {
        Button {
            cancelTest()
        } label: {
            HStack(spacing: 4) {
                ProgressView()
                    .controlSize(.mini)
                    .tint(Color.dsWarning)
                Text(L10n.t("module.test.abort", zh: "中止", en: "Abort", language: settings.language))
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

    // MARK: - 数据:主盘 test snapshot

    /// "主盘" = watchedDisks 里第一个有 lastTest 的
    /// - 优先 selectedDisk(用户当前选中),fallback 第一个 watched
    /// - lastTest 由 HealthMonitor.pollOnce 末尾调 fetchLastResult 填充
    private var primaryDisk: DiskInfo? {
        if let sel = monitor.selectedDisk, let _ = sel.lastTest {
            return sel
        }
        if let first = monitor.watchedDisks.first(where: { $0.lastTest != nil }) {
            return first
        }
        return monitor.selectedDisk ?? monitor.watchedDisks.first
    }

    private var primaryTest: DiagnosticTestService.TestSnapshot? {
        primaryDisk?.lastTest
    }

    // MARK: - 文本

    private var statusText: String {
        guard let test = primaryTest else { return "—" }
        switch test.lastShortTest {
        case .passed:  return "PASS"
        case .failed:  return "FAIL"
        case .running: return "RUN"
        case .aborted: return "ABORT"
        case .idle:    return "—"
        }
    }

    /// `contentTransition(.numericText(value:))` 触发器
    /// - 0/1/2/3/4 映射 PASS/FAIL/RUN/ABORT/IDLE,数字滚动过渡
    private var numericKey: Double {
        guard let test = primaryTest else { return 0 }
        switch test.lastShortTest {
        case .passed:  return 1
        case .failed:  return 2
        case .running: return 3
        case .aborted: return 4
        case .idle:    return 0
        }
    }

    private var currentProgress: Double? {
        guard let test = primaryTest else { return nil }
        if case .running(let p) = test.lastShortTest { return p }
        return nil
    }

    private var subtitleText: String {
        let lang = settings.language
        if let disk = primaryDisk, disk.isUSBBridgeWithoutSMART {
            return L10n.t(
                "module.test.usbNever",
                zh: "USB 桥不能跑 SMART 自检，不是按钮坏了",
                en: "USB bridge cannot run SMART self-test",
                language: lang
            )
        }
        guard let test = primaryTest else {
            return L10n.t("module.test.noData", zh: "还没有自检记录", en: "No test history", language: lang)
        }
        let short = Self.statusShort(test.lastShortTest)
        let long = Self.statusShort(test.lastLongTest)
        return "S:\(short) · L:\(long)"
    }

    /// SelfTestResult → 1 字母简写(节省空间)
    private static func statusShort(_ r: DiagnosticTestService.SelfTestResult) -> String {
        switch r {
        case .passed:  return "PASS"
        case .failed:  return "FAIL"
        case .running: return "RUN"
        case .aborted: return "ABRT"
        case .idle:    return "—"
        }
    }

    // MARK: - 颜色

    private var statusColor: Color {
        guard let test = primaryTest else { return Color.secondary.opacity(0.5) }
        switch test.lastShortTest {
        case .passed:  return Color.dsNormal
        case .failed:  return Color.dsDanger
        case .running: return Color.dsWarning
        case .aborted: return .secondary
        case .idle:    return Color.secondary.opacity(0.5)
        }
    }

    // MARK: - 按钮

    /// Run Short / Run Long 按钮(高级交互规范)
    /// - 玻璃风(macOS 控制中心小按钮)
    /// - hover → 背景 opacity 提升 + scale 1.02
    /// - press → 下沉 1px + scale 0.98
    /// - inFlight → 显示 ProgressView(防双击)
    /// - v0.9.3:加 color 参数(失败时显红 Retry)
    @ViewBuilder
    private func runButton(
        label: String,
        isHovered: Bool,
        isInFlight: Bool,
        failedFlash: Bool = false,
        color: Color = Color.dsNormal,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            action()
        } label: {
            HStack(spacing: 4) {
                if isInFlight {
                    ProgressView()
                        .controlSize(.mini)
                        .tint(color)
                } else {
                    Text(label)
                        .font(.system(size: 10, weight: .medium, design: .default))
                        .tracking(0.3)
                }
            }
            .foregroundStyle(isHovered ? color : .secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(
                        isHovered
                            ? color.opacity(0.12)
                            : Color.primary.opacity(0.04)
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    // v0.9.1 polish-Q:失败时短暂红边框 0.3s
                    .stroke(
                        failedFlash ? Color.dsDanger
                            : (isHovered ? color.opacity(0.30) : Color.white.opacity(0.08)),
                        lineWidth: failedFlash ? 1.5 : 1
                    )
            )
        }
        .buttonStyle(.plain)
        .disabled(isInFlight || primaryDisk == nil || (primaryDisk?.isUSBBridgeWithoutSMART == true))
        .help(label)
    }

    // MARK: - 动作

    private var isTestRunning: Bool {
        if case .running = shortState { return true }
        if case .running = longState { return true }
        return false
    }

    private func runShort() {
        guard let disk = primaryDisk else { return }
        runTest(type: .short, bsd: disk.bsdName)
    }

    private func runLong() {
        guard let disk = primaryDisk else { return }
        runTest(type: .long, bsd: disk.bsdName)
    }

    /// v0.9.3:统一 run 入口 — 启动 Task 跑 test + 接收 progress callback + 4 态更新
    private func runTest(type: SelfTestType, bsd: String) {
        let startDate = Date()
        let initialState = SelfTestRunState.running(progress: 0, eta: nil)
        if type == .short {
            shortState = initialState
        } else {
            longState = initialState
        }
        runTask?.cancel()
        runTask = Task {
            do {
                let progressHandler: (Double) -> Void = { p in
                    let elapsed = Date().timeIntervalSince(startDate)
                    let eta: TimeInterval? = {
                        guard p > 0.01 else {
                            return DiagnosticTestService.estimatedDuration(type: type.rawValue)
                        }
                        return elapsed * (1 - p) / p
                    }()
                    Task { @MainActor in
                        if type == .short {
                            shortState = .running(progress: p, eta: eta)
                        } else {
                            longState = .running(progress: p, eta: eta)
                        }
                    }
                }
                if type == .short {
                    try await diagnostic.runShortTest(bsdName: bsd, progress: progressHandler)
                } else {
                    try await diagnostic.runLongTest(bsdName: bsd, progress: progressHandler)
                }
                let duration = Date().timeIntervalSince(startDate)
                if type == .short {
                    shortState = .success(date: Date(), duration: duration, summary: "Test completed")
                } else {
                    longState = .success(date: Date(), duration: duration, summary: "Test completed")
                }
                monitor.restartPolling()
            } catch is CancellationError {
                await diagnostic.abortTest(bsdName: bsd)
                if type == .short { shortState = .idle } else { longState = .idle }
            } catch let err as DiagnosticTestService.SelfTestError {
                testError = err
                let errStr = SelfTestModuleHelper.errorToString(err)
                if type == .short {
                    shortState = .failed(date: Date(), error: errStr)
                } else {
                    longState = .failed(date: Date(), error: errStr)
                }
            } catch {
                NSLog("DiskMon: runTest \(type.rawValue) unexpected error for \(bsd): \(error)")
            }
        }
    }

    private func cancelTest() {
        runTask?.cancel()
        runTask = nil
        let bsd = primaryDisk?.bsdName
        shortState = .idle
        longState = .idle
        if let bsd {
            Task { await diagnostic.abortTest(bsdName: bsd) }
        }
    }

    // MARK: - Static helpers

    private static func formatDuration(_ seconds: TimeInterval) -> String {
        if seconds < 60 {
            return String(format: "%.0fs", seconds)
        } else if seconds < 3600 {
            return String(format: "%dm %ds", Int(seconds / 60), Int(seconds.truncatingRemainder(dividingBy: 60)))
        } else {
            return String(format: "%dh %dm", Int(seconds / 3600), Int((seconds.truncatingRemainder(dividingBy: 3600)) / 60))
        }
    }

    private static func formatETA(_ seconds: TimeInterval, language: String) -> String {
        if seconds < 0 || seconds > 86400 * 30 {
            return L10n.t("module.test.etaUnknown", zh: "剩余 —", en: "ETA —", language: language)
        }
        if seconds < 60 {
            return L10n.t("module.test.etaS", zh: "剩余 \(Int(seconds))秒", en: "ETA \(Int(seconds))s", language: language)
        }
        if seconds < 3600 {
            let m = Int(seconds / 60)
            let s = Int(seconds.truncatingRemainder(dividingBy: 60))
            return L10n.t("module.test.etaMS", zh: "剩余 \(m)分\(s)秒", en: "ETA \(m)m \(s)s", language: language)
        }
        let h = Int(seconds / 3600)
        let m = Int((seconds.truncatingRemainder(dividingBy: 3600)) / 60)
        return L10n.t("module.test.etaHM", zh: "剩余 \(h)时\(m)分", en: "ETA \(h)h \(m)m", language: language)
    }

    private static func formatRelativeTime(_ date: Date) -> String {
        let elapsed = Date().timeIntervalSince(date)
        if elapsed < 60 { return "just now" }
        if elapsed < 3600 { return "\(Int(elapsed / 60))m ago" }
        if elapsed < 86400 { return "\(Int(elapsed / 3600))h ago" }
        return "\(Int(elapsed / 86400))d ago"
    }
}

// MARK: - SelfTestModuleHelper(v0.9.3 共享 error 转换)

/// SelfTest 共享 helpers — DiskDetailView 跟 DiagnosticTestModule 共用
enum SelfTestModuleHelper {
    static func errorToString(_ err: DiagnosticTestService.SelfTestError) -> String {
        switch err {
        case .smartmontoolsNotFound: return "smartmontools not installed"
        case .fullDiskAccessRequired: return "Full Disk Access required"
        case .notSupported: return "Not supported on this disk"
        case .commandFailed(let code, _): return "smartctl exit \(code)"
        case .invalidBSDName: return "Invalid BSD name"
        case .timedOut: return "Timed out"
        }
    }
}

// grok 调研:v0.8 polish-L, SMART self-test 闭环 observe→predict→verify
//   关键决策:走 DiagnosticTestService.snapshots[key: bsdName] 读,不直接 spawn smartctl
//   已知限制:USB-NVMe 桥接不支持 self-test,UI 显 "FAIL"(command 失败)或 "—"(未跑)
