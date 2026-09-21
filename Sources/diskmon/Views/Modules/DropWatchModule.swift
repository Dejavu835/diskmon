import SwiftUI
import DiskMonCore

/// Overview card: unexpected disconnect vs our own eject/unmount. Honest hints only.
struct DropWatchModule: View {
    @Environment(HealthMonitor.self) private var monitor
    @Environment(AppSettings.self) private var settings

    @State private var isCardHovered = false
    @State private var isPressed = false
    @FocusState private var isFocused: Bool

    private var lang: String { settings.language }

    private var now: Date { Date() }

    private var story: DropNowState {
        monitor.dropStory()
    }

    var body: some View {
        cardBody
            .frame(minWidth: 180, idealWidth: 220, maxWidth: 280,
                   minHeight: 140, idealHeight: 180, maxHeight: .infinity)
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
            .animation(.timingCurve(0.2, 0.8, 0.2, 1, duration: 0.3), value: isCardHovered)
            .animation(.easeOut(duration: 0.15), value: isFocused)
            .animation(.easeInOut(duration: 0.12), value: isPressed)
    }

    private var cardBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                Image(systemName: "externaldrive.badge.xmark")
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(.tertiary)
                Text(L10n.t("module.drop.title", zh: "连接", en: "Connection", language: lang))
                    .font(.system(size: 11, weight: .medium))
                    .tracking(0.6)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Text(statusChip)
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundStyle(statusColor)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(statusColor.opacity(0.16)))
            }
            .padding(.top, 2)

            Spacer(minLength: 4)

            Text(headline)
                .font(.fraunces(size: 28, weight: .regular, italic: true))
                .foregroundStyle(statusColor == .secondary ? Color.themeFgDark : statusColor)
                .lineLimit(1)
                .minimumScaleFactor(0.7)

            if let line = subjectLine {
                Text(line)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.themeFgDark)
                    .lineLimit(1)
                    .padding(.top, 4)
            }

            Spacer(minLength: 4)

            Text(meaning)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .lineLimit(2)

            Text(action)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(isCardHovered ? Color.themeFgDark : Color.dsNormal)
                .fixedSize(horizontal: false, vertical: true)
                .lineLimit(2)
                .padding(.top, 4)
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .contentShape(Rectangle())
    }

    private var statusChip: String {
        switch story {
        case .steady:
            return L10n.t("module.drop.chip.ok", zh: "正常", en: "OK", language: lang)
        case .expectedGone:
            return L10n.t("module.drop.chip.ejected", zh: "已推出", en: "Ejected", language: lang)
        case .missing:
            return L10n.t("module.drop.chip.missing", zh: "已中断", en: "Lost", language: lang)
        case .flap:
            return L10n.t("module.drop.chip.flap", zh: "不稳", en: "Unstable", language: lang)
        }
    }

    private var statusColor: Color {
        switch story {
        case .steady, .expectedGone: return .secondary
        case .missing: return Color.dsDanger
        case .flap: return Color.dsWarning
        }
    }

    private var headline: String {
        switch story {
        case .steady:
            return L10n.t("module.drop.steady", zh: "连接稳定", en: "Steady", language: lang)
        case .expectedGone:
            return L10n.t("module.drop.ejected", zh: "已安全推出", en: "Ejected", language: lang)
        case .missing:
            return L10n.t("module.drop.gone", zh: "连接中断", en: "Disconnected", language: lang)
        case .flap(let n, _):
            return L10n.t("module.drop.flapHeadline", zh: "接触不稳", en: "Unstable", language: lang)
                + " · \(n)×"
        }
    }

    private var subjectLine: String? {
        switch story {
        case .steady:
            return nil
        case .expectedGone(let ev):
            return "\(ev.name) · \(relative(ev.at))"
        case .missing(let ev):
            return "\(ev.name) · \(relative(ev.at))"
        case .flap(let n, let ev):
            return L10n.t(
                "module.drop.flap.sub",
                zh: "\(ev.name) · 24h 内 \(n) 次，已回来",
                en: "\(ev.name) · \(n)× in 24h, back",
                language: lang
            )
        }
    }

    private var focusHint: DropHint? {
        switch story {
        case .steady: return nil
        case .expectedGone: return .userAction
        case .missing(let ev): return ev.hint
        case .flap(_, let ev): return ev.hint
        }
    }

    private var meaning: String {
        guard let hint = focusHint else {
            return L10n.t(
                "module.drop.meaning.ok",
                zh: "最近没有意外中断。",
                en: "No unexpected disconnects lately.",
                language: lang
            )
        }
        switch hint {
        case .afterSleep:
            return L10n.t("module.drop.meaning.sleep", zh: "可能发生在睡眠或唤醒时。", en: "May have happened around sleep or wake.", language: lang)
        case .flap:
            return L10n.t("module.drop.meaning.flap", zh: "短时间断开又连上，多半是线或接口。", en: "Dropped and came back quickly — often cable or port.", language: lang)
        case .usbCableOrPort:
            return L10n.t("module.drop.meaning.usb", zh: "硬盘从列表里消失了。", en: "The disk disappeared from the list.", language: lang)
        case .unknown:
            return L10n.t("module.drop.meaning.unknown", zh: "不是在本应用里推出的。", en: "Not ejected from this app.", language: lang)
        case .userAction, .stillConnected:
            return L10n.t("module.drop.meaning.ok", zh: "没有意外中断。", en: "No unexpected disconnect.", language: lang)
        }
    }

    private var action: String {
        guard let hint = focusHint else {
            return L10n.t("module.drop.action.ok", zh: "不用处理。", en: "Nothing to do.", language: lang)
        }
        switch hint {
        case .afterSleep:
            return L10n.t("module.drop.action.sleep", zh: "唤醒后看看是否已重新出现。", en: "After wake, check whether it reappeared.", language: lang)
        case .flap:
            return L10n.t("module.drop.action.flap", zh: "换一个接口直连试试。", en: "Try another port, plug in directly.", language: lang)
        case .usbCableOrPort, .unknown:
            return L10n.t("module.drop.action.usb", zh: "重新插一次，或换个接口。", en: "Replug once, or try another port.", language: lang)
        case .userAction, .stillConnected:
            return L10n.t("module.drop.action.ok", zh: "不用处理。", en: "Nothing to do.", language: lang)
        }
    }

    private func relative(_ date: Date) -> String {
        let s = now.timeIntervalSince(date)
        if s < 60 { return L10n.t("module.drop.just", zh: "刚刚", en: "just now", language: lang) }
        if s < 3600 { return "\(Int(s / 60))m" }
        if s < 86_400 { return "\(Int(s / 3600))h" }
        return "\(Int(s / 86_400))d"
    }
}
