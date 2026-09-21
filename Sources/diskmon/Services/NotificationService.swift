import Foundation
import UserNotifications
import AppKit

/// UNUserNotificationCenter 封装 + Full Disk Access 引导
/// 等级变化才发,不重复
/// Critical Warning bit 0 (available spare below threshold) / bit 4 (backup failed)
/// v0.2.0:所有文案走 String(localized:),本地化用 Localizable.strings 现有 key 集
final class NotificationService {
    static let shared = NotificationService()

    private(set) var authorized: Bool = false
    private var lastSentLevelByUUID: [String: HealthLevel] = [:]
    private var lastBit0NotifiedByUUID: [String: Bool] = [:]
    private var lastBit4NotifiedByUUID: [String: Bool] = [:]
    private var didPromptFullDiskAccess = false

    /// 启动时弹一次授权
    func requestAuthorizationIfNeeded() {
        UNUserNotificationCenter.current().requestAuthorization(
            options: [.alert, .sound]
        ) { [weak self] granted, _ in
            self?.authorized = granted
        }
    }

    /// 等级变化才调(从 normal → warning/critical/danger 等)
    func notifyIfChanged(level: HealthLevel, disk: DiskInfo, smart: SmartData, diskUUID: String? = nil, notifyRecover: Bool = true) {
        guard authorized else { return }
        let uuid = diskUUID ?? disk.volumeUUID
        let critRaw = smart.criticalWarningRaw ?? 0
        let bit0 = (critRaw & 0x01) != 0
        let bit4 = (critRaw & 0x10) != 0
        if bit0 && lastBit0NotifiedByUUID[uuid] != true {
            let title = String(
                localized: "notification.title.bit0",
                defaultValue: "DiskMon — CRITICAL WARNING bit 0"
            )
            let body = String(
                format: String(
                    localized: "notification.body.bit0",
                    defaultValue: "%@ · Available spare below threshold · Back up now"
                ),
                disk.mountPoint ?? disk.bsdName
            )
            send(title: title, body: body, level: .danger, disk: disk)
            lastBit0NotifiedByUUID[uuid] = true
        } else if !bit0 {
            lastBit0NotifiedByUUID[uuid] = false
        }
        if bit4 && lastBit4NotifiedByUUID[uuid] != true {
            let title = String(
                localized: "notification.title.bit4",
                defaultValue: "DiskMon — CRITICAL WARNING bit 4"
            )
            let body = String(
                format: String(
                    localized: "notification.body.bit4",
                    defaultValue: "%@ · Backup or redundancy failure · Inspect now"
                ),
                disk.mountPoint ?? disk.bsdName
            )
            send(title: title, body: body, level: .danger, disk: disk)
            lastBit4NotifiedByUUID[uuid] = true
        } else if !bit4 {
            lastBit4NotifiedByUUID[uuid] = false
        }
        let prev = lastSentLevelByUUID[uuid]
        guard prev != level else { return }
        lastSentLevelByUUID[uuid] = level
        if level == .normal && !notifyRecover { return }
        let title = String(
            format: String(
                localized: "notification.title.normal",
                defaultValue: "DiskMon — %@"
            ),
            level.rawValue.uppercased()
        )
        let diskName = disk.mountPoint ?? disk.bsdName
        let celsiusVal = smart.celsius ?? 0
        let tempStr = "\(celsiusVal)"
        let detail: String
        switch level {
        case .normal:
            detail = String(
                format: String(
                    localized: "notification.body.normal",
                    defaultValue: "%@ · %@° · Healthy"
                ),
                diskName, tempStr
            )
        case .warning:
            detail = String(
                format: String(
                    localized: "notification.body.warning",
                    defaultValue: "%@ · %@° · Approaching temperature or lifetime threshold"
                ),
                diskName, tempStr
            )
        case .critical:
            if celsiusVal >= 80 {
                detail = String(
                    format: String(
                        localized: "notification.body.critical.temp",
                        defaultValue: "%@ · %@° · Temperature critical"
                    ),
                    diskName, tempStr
                )
            } else {
                detail = String(
                    format: String(
                        localized: "notification.body.critical.lifetime",
                        defaultValue: "%@ · Lifetime %@%% · Nearly exhausted"
                    ),
                    diskName, "\(smart.percentageUsed ?? 0)"
                )
            }
        case .danger:
            let mediaErr = smart.mediaErrors ?? 0
            if mediaErr > 0 {
                detail = String(
                    format: String(
                        localized: "notification.body.danger.media",
                        defaultValue: "%@ · Media errors %@ · Back up now"
                    ),
                    diskName, "\(mediaErr)"
                )
            } else {
                detail = String(
                    format: String(
                        localized: "notification.body.danger.temp",
                        defaultValue: "%@ · %@° · Danger"
                    ),
                    diskName, tempStr
                )
            }
        }
        send(title: title, body: detail, level: level, disk: disk)
    }

    private func send(title: String, body: String, level: HealthLevel, disk: DiskInfo) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = level == .danger ? .defaultCritical : .default
        let req = UNNotificationRequest(
            identifier: "diskmon-\(disk.bsdName)-\(level.rawValue)-\(UUID().uuidString.prefix(8))",
            content: content, trigger: nil
        )
        UNUserNotificationCenter.current().add(req, withCompletionHandler: nil)
    }

    // MARK: - Full Disk Access 引导(退码 251)

    /// 弹 NSAlert 引导用户去 系统设置 → 隐私与安全性 → 完整磁盘访问
    func requestFullDiskAccess() {
        if didPromptFullDiskAccess { return }
        didPromptFullDiskAccess = true
        let alert = NSAlert()
        alert.messageText = String(
            localized: "alert.fda.title",
            defaultValue: "DiskMon needs Full Disk Access"
        )
        alert.informativeText = String(
            localized: "alert.fda.message",
            defaultValue: """
            smartctl reads raw /dev/diskN devices and requires Full Disk Access (TCC).\n\n\
            Please open:\n\
            System Settings → Privacy & Security → Full Disk Access\n\n\
            Enable DiskMon, then relaunch the app.
            """
        )
        alert.alertStyle = .warning
        alert.addButton(withTitle: String(
            localized: "alert.fda.openSettings", defaultValue: "Open System Settings"
        ))
        alert.addButton(withTitle: String(
            localized: "alert.fda.copyCommand", defaultValue: "Copy Command"
        ))
        alert.addButton(withTitle: String(
            localized: "alert.fda.later", defaultValue: "Later"
        ))
        let response = alert.runModal()
        switch response {
        case .alertFirstButtonReturn:
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
                NSWorkspace.shared.open(url)
            }
        case .alertSecondButtonReturn:
            let cmd = "open \"x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles\""
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(cmd, forType: .string)
        default:
            break
        }
    }
}
