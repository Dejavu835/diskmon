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
                            Text(L10n.t("manage.ntfs.remount", zh: "重新挂载", en: "Remount", language: lang))
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(Color.dsNormal)
                        }
                        .buttonStyle(.plain)
                        .disabled(busy)
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
            return L10n.t("manage.ntfs.body.rw", zh: "文件系统扩展已打开。外接 NTFS 可以读写。", en: "The File System Extension is on. External NTFS is writable.", language: lang)
        case .needsRemount:
            return L10n.t("manage.ntfs.body.remount", zh: "打开扩展不会自动换驱动。推出再挂上，访达才能写入。不会用 mount -t ntfs。", en: "Enabling the extension does not switch the driver. Unmount and mount again so Finder can write. Never uses mount -t ntfs.", language: lang)
        case .unmounted:
            return L10n.t("manage.ntfs.body.unmounted", zh: "挂载后才会出现在访达。扩展打开后挂载即可写入。", en: "Mount it to see it in Finder. With the extension on, a mount is writable.", language: lang)
        case .extensionOff:
            return L10n.t("manage.ntfs.body.fmt", zh: "要在访达里写入，请打开本 App 的文件系统扩展，然后重新挂载这块盘。", en: "To write in Finder, enable this app’s File System Extension, then remount the disk.", language: lang)
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
            return L10n.t("manage.hint.apfs", zh: "Mac 原生。快照、克隆、加密。", en: "Native on Mac. Snapshots, clones, encryption.", language: lang)
        case .exfat:
            return L10n.t("manage.hint.exfat", zh: "Mac / Windows / 相机通用，适合大文件。", en: "Works on Mac, Windows, and cameras. Large files OK.", language: lang)
        case .fat32:
            return L10n.t("manage.hint.fat32", zh: "旧设备兼容。单文件不能超过 4 GB。", en: "Legacy devices. Files cannot exceed 4 GB.", language: lang)
        case .ntfsKit:
            return L10n.t("manage.hint.ntfs", zh: "Windows 常用。写入需要打开本 App 的文件系统扩展，格式化后重新挂载。", en: "Common on Windows. Writing needs this app’s File System Extension, then a remount.", language: lang)
        }
    }
}
