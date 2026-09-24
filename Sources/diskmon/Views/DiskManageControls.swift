import SwiftUI
import DiskMonCore

/// Shared NTFS / format chips used by TopBar 管理, Disk Detail, and Settings.
struct NTFSStatusRow: View {
    let access: NTFSAccess
    let extensionOn: Bool
    let lang: String
    var compact: Bool = false
    var busy: Bool = false
    var onEnable: () -> Void
    var onRemount: (() -> Void)? = nil
    var onMount: (() -> Void)? = nil
    var onOpen: (() -> Void)? = nil

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: compact ? 12 : 14))
                .foregroundStyle(access == .writable ? Color.dsNormal : .secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: compact ? 11 : 12, weight: .semibold))
                    .foregroundStyle(Color.themeFgDark)
                    .fixedSize(horizontal: false, vertical: true)
                Text(bodyText)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .lineSpacing(2)
                HStack(spacing: 10) {
                    if showsEnable {
                        Button(action: onEnable) {
                            Text(L10n.t("manage.ntfs.enable", zh: "打开文件系统扩展", en: "Open File System Extensions", language: lang))
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(Color.dsNormal)
                        }
                        .buttonStyle(.plain)
                    }
                    if access == .needsRemount, let onRemount {
                        Button(action: onRemount) {
                            Text(L10n.t("manage.ntfs.remount", zh: "重新挂载以写入", en: "Remount to write", language: lang))
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(Color.dsNormal)
                        }
                        .buttonStyle(.plain)
                        .disabled(busy)
                    }
                    if access == .unmounted, let onMount {
                        Button(action: onMount) {
                            Text(L10n.t("manage.mount", zh: "挂载", en: "Mount", language: lang))
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(Color.dsNormal)
                        }
                        .buttonStyle(.plain)
                        .disabled(busy)
                    }
                    if access == .writable, let onOpen {
                        Button(action: onOpen) {
                            Text(L10n.t("manage.finder", zh: "访达", en: "Finder", language: lang))
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(Color.dsNormal)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.top, 2)
            }
            Spacer(minLength: 0)
        }
    }

    private var icon: String {
        switch access {
        case .writable: return "lock.open.fill"
        case .needsRemount: return "arrow.triangle.2.circlepath"
        case .unmounted: return "externaldrive.badge.minus"
        default: return "lock.fill"
        }
    }

    private var showsEnable: Bool {
        access == .extensionOff || (!extensionOn && access != .writable)
    }

    private var title: String {
        switch access {
        case .writable:
            return L10n.t("manage.ntfs.title.rw", zh: "NTFS 可写", en: "NTFS writable", language: lang)
        case .needsRemount:
            return L10n.t("manage.ntfs.title.remount", zh: "扩展已开，这块盘还是只读", en: "Extension on — this disk is still read-only", language: lang)
        case .unmounted:
            return L10n.t("manage.ntfs.title.unmounted", zh: "NTFS 未挂载", en: "NTFS not mounted", language: lang)
        case .extensionOff:
            return L10n.t("manage.ntfs.title.fmt", zh: "NTFS 目前只读", en: "NTFS is read-only", language: lang)
        case .notNTFS:
            return extensionOn
                ? L10n.t("manage.ntfs.title.rw", zh: "NTFS 可写已启用", en: "NTFS write enabled", language: lang)
                : L10n.t("manage.ntfs.title.fmt", zh: "NTFS 目前只读", en: "NTFS is read-only", language: lang)
        }
    }

    private var bodyText: String {
        switch access {
        case .writable:
            return L10n.t("manage.ntfs.body.rw", zh: "这块盘现在可读写。扩展只在挂载时工作，平时不占进程。", en: "This disk is writable. The extension runs only while the volume is mounted.", language: lang)
        case .needsRemount:
            return L10n.t("manage.ntfs.body.remount", zh: "点一次重新挂载，系统才改用写入扩展。不会后台重试，也不用 mount -t ntfs。", en: "Remount once so the write extension takes this volume. No background retry, and never mount -t ntfs.", language: lang)
        case .unmounted:
            return L10n.t("manage.ntfs.body.unmounted", zh: "挂载后出现在访达。扩展已开时，这次挂载即可写入。", en: "Mount it to see it in Finder. With the extension on, this mount is writable.", language: lang)
        case .extensionOff:
            return L10n.t("manage.ntfs.body.fmt", zh: "Mac 自带 NTFS 只读。打开本 App 的文件系统扩展后再重新挂载，才能写入。扩展没开时没有后台进程。", en: "macOS NTFS is read-only. Enable this app’s File System Extension, then remount, to write. Nothing runs in the background until then.", language: lang)
        case .notNTFS:
            return extensionOn
                ? L10n.t("manage.ntfs.body.rw", zh: "文件系统扩展已打开。外接 NTFS 可以读写，也可以在本页格式化。", en: "The File System Extension is on. External NTFS volumes can be read, written, and formatted here.", language: lang)
                : L10n.t("manage.ntfs.body.fmt", zh: "要在访达里写入，请在系统设置打开本 App 的文件系统扩展。", en: "To write in Finder, enable this app’s File System Extension in System Settings.", language: lang)
        }
    }
}

struct FormatPersonalityChips: View {
    @Binding var personality: FormatPersonality
    var canFormatNTFS: Bool
    var lang: String
    var onSelect: (FormatPersonality) -> Void

    private var items: [FormatPersonality] {
        var list: [FormatPersonality] = [.exfat, .apfs, .fat32]
        if canFormatNTFS { list.append(.ntfsKit) }
        return list
    }

    var body: some View {
        HStack(spacing: 6) {
            ForEach(items, id: \.self) { p in
                let on = personality == p
                Button {
                    personality = p
                    onSelect(p)
                } label: {
                    Text(p.title)
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(on ? Color.dsNormal : .secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(
                            Capsule(style: .continuous)
                                .fill(on ? Color.dsNormal.opacity(0.16) : Color.white.opacity(0.05))
                        )
                        .overlay(
                            Capsule(style: .continuous)
                                .stroke(on ? Color.dsNormal.opacity(0.35) : Color.white.opacity(0.08), lineWidth: 0.5)
                        )
                }
                .buttonStyle(.plain)
            }
        }
    }
}

extension FormatPersonality {
    var title: String {
        switch self {
        case .apfs: return "APFS"
        case .exfat: return "ExFAT"
        case .fat32: return "FAT32"
        case .ntfsKit: return "NTFS"
        }
    }

    func hint(lang: String) -> String {
        switch self {
        case .apfs:
            return L10n.t("manage.hint.apfs", zh: "只适合 Mac。", en: "Mac only.", language: lang)
        case .exfat:
            return L10n.t("manage.hint.exfat", zh: "Mac 和 Windows 都能读写。没有日志，拔盘前先推出。", en: "Mac and Windows can read and write. No journal — eject before unplugging.", language: lang)
        case .fat32:
            return L10n.t("manage.hint.fat32", zh: "旧设备兼容。单文件不能超过 4 GB。", en: "Legacy devices. A single file cannot exceed 4 GB.", language: lang)
        case .ntfsKit:
            return L10n.t("manage.hint.ntfs", zh: "只把盘格式化成 NTFS。Mac 上要能写，还得打开扩展并重新挂载。没有扩展时，格式化完仍然只读。", en: "Formats the disk as NTFS. Writing on this Mac still needs the extension and a remount. Without it, the disk stays read-only.", language: lang)
        }
    }
}
