import SwiftUI
import SwiftData

/// FSIntegrityModule v0.8 polish-M
/// 220x180 玻璃卡,显示每盘 IntegrityStatus(verified / warning / failed / verifying)+ 时间戳
///
/// === 数据源 ===
/// `@Environment(FSIntegrityService.self)` 读 results[key: mountPoint]
/// - results 字典在用户点 "Verify" 按钮后被填充
/// - key = mountPoint("/Volumes/applelog"),value = IntegrityResult
/// - 缺数据 → "—"(不假数据)
///
/// === 高级交互规范(主人硬规则) ===
/// - 大数字:IntegrityStatus 文字("OK" / "WARN" / "FAIL" / "...")+ 状态颜色
///   (Fraunces 28pt italic)+ 数字滚动 .contentTransition(.numericText())
/// - 副标:last verified time + reason(如有)
/// - hover 玻璃卡边缘高光内移 1-2px(走 .glass() 统一接口)
/// - hover 大数字 1.02 放大
/// - 焦点环:琥珀 2px stroke
/// - 按下态:下沉 1px + scale 0.99
/// - 状态颜色:.verified → dsNormal 琥珀(任务硬规则:不引入绿)/ .warning → dsWarning /
///   .failed → dsDanger / .verifying → dsWarning + spinner
/// - 不 loop 动画 / 不弹跳 / 不 mock / nil → "—"
/// - 35mm 噪点(走 .glass() withNoise: true)
///
/// === 设计选择 ===
/// - 220x180(跟其他 Module 一致)
/// - 卡片右上角小图标:SF Symbol `checkmark.seal.fill`(完整性 / 印章)
/// - 顶标 "FS" 12pt secondary
/// - 主显示:主盘 IntegrityStatus 文字(简化 4 字母)
/// - 副标:last verified timestamp(SF Mono 11pt)
/// - 副标 2:.failed / .warning 时显示 reason
/// - 按钮:"Verify"(琥珀主调,主盘默认)
/// - in-flight → 显示 ProgressView(防双击)
struct FSIntegrityModule: View {
    /// v0.4.0 polish-D + v0.8 polish-M:tab 切换标识(FS tab)
    /// 标识本模块属于"FS"分类,PopoverView 切换 tab 时按此过滤显示
    enum Detail { case overview, temperature, capacity, power, smart, link, test, bench, fs }
    static let moduleTab: Detail = .fs

    @Environment(HealthMonitor.self) private var monitor
    @Environment(FSIntegrityService.self) private var fsIntegrity

    // MARK: - 交互状态

    @State private var isCardHovered: Bool = false
    @State private var isButtonHovered: Bool = false
    @State private var isPressed: Bool = false
    @FocusState private var isFocused: Bool
    // v0.9.3:4 态状态机
    @State private var state: FSRunState = .idle
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
    }

    // MARK: - 卡片本体

    private var cardBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            // === 顶部:小标签 "FS" ===
            HStack(spacing: 4) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(.tertiary)
                Text(String(localized: "module.fs.title", defaultValue: "FS"))
                    .font(.system(size: 11, weight: .medium, design: .default))
                    .tracking(0.6)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 2)

            Spacer(minLength: 0)

            // === 中部:状态内容(随 4 态变化)===
            stateContent

            Spacer(minLength: 0)

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
            // 跟原版一致:大数字 status + 副标 timestamp + reason
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .center, spacing: 4) {
                    Text(statusText)
                        .font(.fraunces(size: 36, weight: .regular, italic: true))
                        .foregroundStyle(statusColor)
                        .monospacedDigit()
                        .scaleEffect(isCardHovered && statusText != "—" ? 1.02 : 1.0)
                        .contentTransition(.numericText(value: statusNumericKey))
                        .lineLimit(1)
                }
                HStack(alignment: .center, spacing: 4) {
                    Text(timestampText)
                        .font(.system(size: 11, weight: .regular, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                if let reason = reasonText {
                    HStack(alignment: .center, spacing: 4) {
                        Text(reason)
                            .font(.system(size: 10, weight: .regular, design: .default))
                            .foregroundStyle(statusColor)
                            .lineLimit(2)
                            .truncationMode(.tail)
                    }
                }
            }
        case .running(let progress):
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .center, spacing: 4) {
                    Text("Verifying")
                        .font(.fraunces(size: 30, weight: .regular, italic: true))
                        .foregroundStyle(Color.dsWarning)
                        .lineLimit(1)
                    Text("\(Int(progress * 100))%")
                        .font(.system(size: 12, weight: .regular, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                        .contentTransition(.numericText(value: progress))
                }
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .tint(Color.dsWarning)
            }
        case .success(let date, let duration):
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .center, spacing: 4) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(Color.dsNormal)
                    Text("OK")
                        .font(.fraunces(size: 32, weight: .regular, italic: true))
                        .foregroundStyle(Color.dsNormal)
                        .lineLimit(1)
                }
                HStack(spacing: 4) {
                    Text(FSIntegrityModule.formatDuration(duration))
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(Color.dsNormal)
                    Text("·")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                    Text(FSIntegrityModule.formatRelativeTime(date))
                        .font(.system(size: 11, weight: .regular, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
            }
        case .failed(let date, let error):
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .center, spacing: 4) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(Color.dsDanger)
                    Text("FAIL")
                        .font(.fraunces(size: 32, weight: .regular, italic: true))
                        .foregroundStyle(Color.dsDanger)
                        .lineLimit(1)
                }
                HStack(spacing: 4) {
                    Text(FSIntegrityModule.formatRelativeTime(date))
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

    // MARK: - v0.9.3:4 态按钮(底部)

    @ViewBuilder
    private var actionButtons: some View {
        switch state {
        case .idle:
            verifyButton
        case .running:
            stopButton
        case .success:
            reVerifyButton
        case .failed:
            retryButton
        }
    }

    private var stopButton: some View {
        Button {
            cancelVerify()
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

    private var reVerifyButton: some View {
        Button {
            runVerify()
        } label: {
            Text("Re-verify")
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
            runVerify()
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

    // MARK: - 数据:主盘 integrity

    /// "主盘" = watchedDisks 里第一个有 integrity 的
    /// - 优先 selectedDisk(用户当前选中),fallback 第一个 watched
    /// - integrity 由用户点 Verify 按钮后填充(不自动跑)
    private var primaryDisk: DiskInfo? {
        if let sel = monitor.selectedDisk, let _ = sel.integrity {
            return sel
        }
        if let first = monitor.watchedDisks.first(where: { $0.integrity != nil }) {
            return first
        }
        return monitor.selectedDisk ?? monitor.watchedDisks.first
    }

    private var primaryIntegrity: FSIntegrityService.IntegrityResult? {
        primaryDisk?.integrity
    }

    // MARK: - 文本

    private var statusText: String {
        guard let integrity = primaryIntegrity else { return "—" }
        switch integrity.status {
        case .verified:    return "OK"
        case .warning:     return "WARN"
        case .failed:      return "FAIL"
        case .verifying:   return "..."
        case .unknown:     return "—"
        }
    }

    /// `contentTransition(.numericText(value:))` 触发器
    /// - 0/1/2/3/4 映射 unknown/verified/warning/failed/verifying
    private var statusNumericKey: Double {
        guard let integrity = primaryIntegrity else { return 0 }
        switch integrity.status {
        case .unknown:     return 0
        case .verified:    return 1
        case .warning:     return 2
        case .failed:      return 3
        case .verifying:   return 4
        }
    }

    private var timestampText: String {
        guard let integrity = primaryIntegrity else {
            return String(localized: "module.fs.noData", defaultValue: "Not verified")
        }
        // 简化:相对时间(分钟/小时/天前)
        let elapsed = Date().timeIntervalSince(integrity.capturedAt)
        if elapsed < 60 {
            return String(
                format: String(localized: "module.fs.justNow", defaultValue: "Just now")
            )
        } else if elapsed < 3600 {
            let minutes = Int(elapsed / 60)
            return String(
                format: String(
                    localized: "module.fs.minutesAgo",
                    defaultValue: "%d min ago"
                ),
                minutes
            )
        } else if elapsed < 86400 {
            let hours = Int(elapsed / 3600)
            return String(
                format: String(
                    localized: "module.fs.hoursAgo",
                    defaultValue: "%d hr ago"
                ),
                hours
            )
        } else {
            let days = Int(elapsed / 86400)
            return String(
                format: String(
                    localized: "module.fs.daysAgo",
                    defaultValue: "%d day ago"
                ),
                days
            )
        }
    }

    /// failed / warning 时显示 reason;否则 nil(隐藏整行)
    private var reasonText: String? {
        guard let integrity = primaryIntegrity else { return nil }
        switch integrity.status {
        case .failed(let reason):  return reason
        case .warning(let reason): return reason
        case .verified, .verifying, .unknown: return nil
        }
    }

    // MARK: - 颜色

    private var statusColor: Color {
        guard let integrity = primaryIntegrity else { return Color.secondary.opacity(0.5) }
        switch integrity.status {
        case .verified:    return Color.dsNormal    // 琥珀(主人硬规则:不引入绿)
        case .warning:     return Color.dsWarning
        case .failed:      return Color.dsDanger
        case .verifying:   return Color.dsWarning   // 跑中也是警告色(待结果)
        case .unknown:     return Color.secondary.opacity(0.5)
        }
    }

    // MARK: - 按钮

    /// Verify 按钮(高级交互规范)
    /// - 玻璃风(macOS 控制中心小按钮)
    /// - hover → 背景 opacity 提升 + scale 1.02
    /// - press → 下沉 1px + scale 0.98
    /// - v0.9.3:移除 isRunning spinner(由 4 态 running 状态接管 spinner 显示)
    private var verifyButton: some View {
        Button {
            runVerify()
        } label: {
            HStack(spacing: 4) {
                Text(String(localized: "module.fs.verify", defaultValue: "Verify"))
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
        .help(String(localized: "module.fs.verifyHelp", defaultValue: "Run diskutil verifyVolume (read-only)"))
        .onHover { isButtonHovered = $0 }
    }

    // MARK: - 动作

    /// 触发 verify(v0.9.3:4 态 + progress + cancel)
    /// - 走 FSIntegrityService.verify(mountPoint:, progress:) — diskutil verifyVolume 只读
    /// - 失败弹 alert(原版只是 NSLog,v0.9.3 升级)+ 4 态 failed
    /// - 完成后 service 写 cache → 下次 pollOnce 5s 内同步到 DiskInfo.integrity
    private func runVerify() {
        guard let disk = primaryDisk, let mountPoint = disk.mountPoint else { return }
        let startDate = Date()
        state = .running(progress: 0.0)
        runTask?.cancel()
        runTask = Task {
            do {
                let progressHandler: (Double) -> Void = { p in
                    Task { @MainActor in
                        state = .running(progress: p)
                    }
                }
                _ = try await fsIntegrity.verify(mountPoint: mountPoint, progress: progressHandler)
                let duration = Date().timeIntervalSince(startDate)
                state = .success(date: Date(), duration: duration)
                monitor.restartPolling()
            } catch is CancellationError {
                state = .idle
            } catch let err as FSIntegrityService.FSIntegrityError {
                state = .failed(
                    date: Date(),
                    error: FSIntegrityModuleHelper.errorToString(err)
                )
            } catch {
                NSLog("DiskMon: runVerify unexpected error for \(mountPoint): \(error)")
                state = .failed(date: Date(), error: String(describing: error))
            }
        }
    }

    private func cancelVerify() {
        runTask?.cancel()
        runTask = nil
    }

    // MARK: - Static helpers(v0.9.3)

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

// MARK: - FSIntegrityModuleHelper(v0.9.3 共享 error 转换)

/// FSIntegrity 共享 helpers — DiskDetailView 跟 FSIntegrityModule 共用
enum FSIntegrityModuleHelper {
    static func errorToString(_ err: FSIntegrityService.FSIntegrityError) -> String {
        switch err {
        case .mountPointMissing: return "Not mounted"
        case .fullDiskAccessRequired: return "Full Disk Access required"
        case .verifyFailed(let code, _): return "diskutil exit \(code)"
        }
    }
}

// grok 调研:v0.8 polish-M, FS 完整性玻璃卡(diskutil verifyVolume 显示)
//   关键决策:走 FSIntegrityService.results[key: mountPoint] 读,不直接 spawn diskutil
//   已知限制:USB-NVMe 桥接 verify 可能被桥接器拒绝 → .failed,UI 显 "FAIL: <reason>"
//            大盘 verify 30s+,UI 显示 "..." 状态 + spinner
//            failed / warning 也会 trigger HealthMonitor.evaluate(smart:) → .danger
