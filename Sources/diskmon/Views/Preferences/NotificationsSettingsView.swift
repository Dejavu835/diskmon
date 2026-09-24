import SwiftUI
import UserNotifications

/// Notifications 偏好 Tab
/// v0.2.0 全新:
///   - 启动时启动 toggle → 走 AppSettings.setLaunchAtLogin(内部 SMAppService 真注册)
///   - 菜单栏脉冲 toggle → AppSettings.setShowMenuBarPulse
///   - "请求通知权限"按钮 → UNUserNotificationCenter 真请求,不 mock
///   - 当前温度单位只读显示
struct NotificationsSettingsView: View {
    @Bindable private var settings = AppSettings.shared
    @State private var notifStatus: NotifStatus = .unknown

    enum NotifStatus {
        case unknown, authorized, denied, requesting
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                descriptionCard
                requestPermissionCard
                recoverCard
            }
            .padding(28)
        }
        .background(Color.themeBgDark.opacity(0.4))
        .task {
            await refreshNotifStatus()
        }
    }

    // MARK: - 描述卡

    private var descriptionCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(String(
                localized: "settings.notifications.title",
                defaultValue: "Notifications"
            ))
            .font(.fraunces(size: 22, weight: .regular, italic: true))
            .foregroundStyle(Color.themeFgDark)
            Text(String(
                localized: "settings.notifications.body",
                defaultValue: "DiskMon can notify you when a disk crosses warning or critical temperature thresholds."
            ))
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            // v0.6.0 polish-E:多行段落实体加 .lineSpacing(2) 提升可读性
            .lineSpacing(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .glass(cornerRadius: 16)
    }

    private var recoverCard: some View {
        SettingsRow(
            title: L10n.t("settings.notifications.recover", zh: "恢复正常时通知", en: "Notify on recover", language: settings.language),
            help: L10n.t("settings.notifications.recover.help", zh: "盘从告警回到正常时发一条。默认开。", en: "Send a notification when a disk returns to normal. On by default.", language: settings.language),
            systemImage: "arrow.uturn.backward"
        ) {
            Toggle("", isOn: Binding(
                get: { settings.notifyOnRecover },
                set: { settings.setNotifyOnRecover($0) }
            ))
            .labelsHidden()
        }
    }

    // MARK: - 请求通知权限

    private var requestPermissionCard: some View {
        SettingsRow(
            title: buttonTitle,
            help: statusSubtitle,
            systemImage: "bell.badge",
            helpColor: statusColor
        ) {
            Button(action: requestPermission) {
                HStack(spacing: 6) {
                    if notifStatus == .requesting {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "bell")
                            .font(.system(size: 12))
                    }
                    Text(buttonLabel)
                        .font(.system(size: 12, weight: .medium))
                }
                .foregroundStyle(Color.themeFgDark)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.white.opacity(0.06))
                )
            }
            .buttonStyle(.plain)
            .disabled(notifStatus == .requesting || notifStatus == .authorized)
        }
    }

    // MARK: - 权限请求

    private func requestPermission() {
        notifStatus = .requesting
        UNUserNotificationCenter.current().requestAuthorization(
            options: [.alert, .sound, .badge]
        ) { granted, _ in
            Task { @MainActor in
                notifStatus = granted ? .authorized : .denied
            }
        }
    }

    private func refreshNotifStatus() async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        await MainActor.run {
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral: notifStatus = .authorized
            case .denied: notifStatus = .denied
            case .notDetermined: notifStatus = .unknown
            @unknown default: notifStatus = .unknown
            }
        }
    }

    // MARK: - 派生文案

    private var buttonTitle: String {
        String(localized: "settings.notifications.authorize", defaultValue: "Authorize notifications")
    }

    private var buttonLabel: String {
        switch notifStatus {
        case .authorized: return "Authorized"
        case .denied: return "Denied"
        case .requesting: return "Requesting…"
        case .unknown: return "Authorize"
        }
    }

    private var statusSubtitle: String {
        switch notifStatus {
        case .authorized:
            return String(localized: "settings.notifications.authorized", defaultValue: "Notifications authorized")
        case .denied:
            return String(localized: "settings.notifications.denied", defaultValue: "Notifications denied — enable in System Settings → Notifications → DiskMon")
        case .requesting, .unknown:
            return String(localized: "settings.notifications.body", defaultValue: "DiskMon can notify you when a disk crosses warning or critical temperature thresholds.")
        }
    }

    private var statusColor: Color {
        switch notifStatus {
        case .authorized: return Color.dsNormal
        case .denied: return Color.dsCritical
        case .requesting, .unknown: return .secondary
        }
    }
}
