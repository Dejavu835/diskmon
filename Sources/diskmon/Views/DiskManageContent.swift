import SwiftUI
import DiskMonCore
import AppKit

/// Work-area disk management. One outer ScrollView. No TopBar changes.
struct DiskManageContent: View {
    let monitor: HealthMonitor
    let selectedDisk: DiskInfo?

    @Environment(DiskFormatService.self) private var formatter
    @Environment(AppSettings.self) private var settings
    @Environment(FSIntegrityService.self) private var fsIntegrity

    @State private var personality: FormatPersonality = .exfat
    @State private var volumeName: String = ""
    @State private var confirm: String = ""
    @State private var renameName: String = ""
    @State private var log: String = ""
    @State private var targetUUID: String?
    @State private var introStep: Int = 0
    @State private var showGuide: Bool = false

    private var lang: String { settings.language }

    private var disks: [DiskInfo] {
        monitor.watchedDisks.filter { !$0.isInternal }
    }

    private var target: DiskInfo? {
        if let uuid = targetUUID {
            return disks.first(where: { $0.volumeUUID == uuid }) ?? selectedDisk.filterExternal
        }
        return selectedDisk.filterExternal ?? disks.first
    }

    private var confirmOK: Bool {
        guard let disk = target else { return false }
        let token = confirm.trimmingCharacters(in: .whitespacesAndNewlines)
        return token == disk.displayName || token == disk.bsdName
    }

    var body: some View {
        ZStack {
            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 12) {
                    if let disk = target {
                        identityCard(disk)
                        diskList
                        infoCard(disk)
                        actionRow(disk)
                        renameCard(disk)
                        ntfsCard
                        formatCard(disk)
                        if !log.isEmpty { logCard }
                        guideCard
                    } else {
                        emptyCard
                        guideCard
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .padding(.bottom, 8)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if !settings.manageIntroDone {
                introOverlay
            }
        }
        .task {
            await formatter.refreshProbe()
            if let raw = FormatPersonality(rawValue: settings.defaultFormatRaw) {
                personality = raw
            }
            if volumeName.isEmpty, let d = target {
                volumeName = d.displayName
                renameName = d.displayName
            }
        }
        .onChange(of: target?.volumeUUID) { _, _ in
            if let d = target {
                volumeName = d.displayName
                renameName = d.displayName
                confirm = ""
            }
        }
    }

    // MARK: - Identity

    private func identityCard(_ disk: DiskInfo) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: disk.mediaKind == .hdd ? "externaldrive" : "externaldrive.fill")
                    .font(.system(size: 22, weight: .regular))
                    .foregroundStyle(Color.dsNormal)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(disk.displayName)
                        .font(.fraunces(size: 20, weight: .regular, italic: true))
                        .foregroundStyle(Color.themeFgDark)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("\(disk.bsdName)  ·  \(disk.capacityFootnote)")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }

            HStack(spacing: 6) {
                metaChip(disk.filesystemLabel)
                if !disk.mediaKind.label.isEmpty { metaChip(disk.mediaKind.label) }
                metaChip(disk.mountPoint == nil
                         ? L10n.t("manage.chip.unmounted", zh: "未挂载", en: "Unmounted", language: lang)
                         : L10n.t("manage.chip.mounted", zh: "已挂载", en: "Mounted", language: lang))
                writableChip(disk)
            }

            capacityBar(disk)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glass(cornerRadius: 16)
    }

    private func writableChip(_ disk: DiskInfo) -> some View {
        let access = disk.ntfsAccess(extensionOn: formatter.ntfsKitAvailable)
        let writable: Bool
        let label: String
        switch access {
        case .writable:
            writable = true
            label = L10n.t("manage.chip.rw", zh: "可写", en: "Read/Write", language: lang)
        case .needsRemount, .extensionOff:
            writable = false
            label = L10n.t("manage.chip.ro", zh: "只读", en: "Read-only", language: lang)
        case .unmounted:
            writable = false
            label = "—"
        case .notNTFS:
            if let w = disk.isVolumeWritable {
                writable = w
                label = w
                    ? L10n.t("manage.chip.rw", zh: "可写", en: "Read/Write", language: lang)
                    : L10n.t("manage.chip.ro", zh: "只读", en: "Read-only", language: lang)
            } else {
                writable = false
                label = "—"
            }
        }
        return Text(label)
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .foregroundStyle(writable ? Color.dsNormal : .secondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Capsule(style: .continuous).fill(writable ? Color.dsNormal.opacity(0.16) : Color.white.opacity(0.05)))
            .overlay(Capsule(style: .continuous).stroke(Color.white.opacity(0.08), lineWidth: 0.5))
    }

    private func metaChip(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Capsule(style: .continuous).fill(Color.white.opacity(0.05)))
            .overlay(Capsule(style: .continuous).stroke(Color.white.opacity(0.08), lineWidth: 0.5))
    }

    private func capacityBar(_ disk: DiskInfo) -> some View {
        let ratio = disk.usedRatio
        return VStack(alignment: .leading, spacing: 4) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule(style: .continuous).fill(Color.white.opacity(0.06))
                    if let ratio {
                        Capsule(style: .continuous)
                            .fill(Color.dsNormal.opacity(0.85))
                            .frame(width: max(4, geo.size.width * ratio))
                    }
                }
            }
            .frame(height: 6)
            Text(disk.capacityFootnote)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: - Disk list (no nested clip)

    private var diskList: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L10n.t("manage.target", zh: "目标盘", en: "Target", language: lang))
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(.secondary)
            VStack(spacing: 4) {
                ForEach(disks, id: \.volumeUUID) { disk in
                    Button {
                        targetUUID = disk.volumeUUID
                        volumeName = disk.displayName
                        confirm = ""
                    } label: {
                        HStack(spacing: 8) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(disk.displayName)
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(Color.themeFgDark)
                                    .lineLimit(1)
                                Text("\(disk.bsdName)  ·  \(disk.filesystemLabel)  ·  \(disk.capacityFootnote)")
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 0)
                            if target?.volumeUUID == disk.volumeUUID {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(Color.dsNormal)
                                    .font(.system(size: 12))
                            }
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(target?.volumeUUID == disk.volumeUUID
                                      ? Color.dsNormal.opacity(0.12)
                                      : Color.white.opacity(0.04))
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: - NTFS

    private var ntfsCard: some View {
        let access: NTFSAccess = {
            if let disk = target, disk.isNTFSVolume {
                return disk.ntfsAccess(extensionOn: formatter.ntfsKitAvailable)
            }
            return .notNTFS
        }()
        return NTFSStatusRow(
            access: access,
            extensionOn: formatter.ntfsKitAvailable,
            lang: lang,
            busy: formatter.isBusy,
            onEnable: { DiskFormatService.openFileSystemExtensions() },
            onRemount: {
                guard let disk = target else { return }
                Task { log = await formatter.remount(disk: disk) }
            }
        )
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glass(cornerRadius: 14)
    }

    // MARK: - Info

    private func infoCard(_ disk: DiskInfo) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.t("manage.info", zh: "信息", en: "Info", language: lang))
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(.secondary)
            infoRow(L10n.t("manage.info.mount", zh: "挂载", en: "Mount", language: lang), disk.mountPoint ?? "—")
            infoRow("BSD", disk.bsdName, copyable: true)
            infoRow("UUID", disk.volumeUUID, copyable: true)
            if let serial = disk.serialNumber, !serial.isEmpty {
                infoRow(L10n.t("manage.info.serial", zh: "序列号", en: "Serial", language: lang), serial, copyable: true)
            }
            infoRow(L10n.t("manage.info.bus", zh: "接口", en: "Bus", language: lang), disk.interfaceSpeedLabel)
            if !disk.mediaKind.label.isEmpty {
                infoRow(L10n.t("manage.info.media", zh: "介质", en: "Media", language: lang), disk.mediaKind.label)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glass(cornerRadius: 14)
    }

    private func infoRow(_ label: String, _ value: String, copyable: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 52, alignment: .leading)
            Text(value)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Color.themeFgDark)
                .lineLimit(2)
                .textSelection(.enabled)
            Spacer(minLength: 0)
            if copyable, value != "—" {
                Button {
                    formatter.copyText(value)
                    log = L10n.t("manage.copied", zh: "已复制 \(value)", en: "Copied \(value)", language: lang)
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Actions

    private func actionRow(_ disk: DiskInfo) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                ghostButton(L10n.t("manage.finder", zh: "访达", en: "Finder", language: lang), icon: "folder") {
                    log = formatter.openInFinder(disk)
                }
                .disabled(disk.mountPoint == nil)
                if disk.mountPoint == nil {
                    ghostButton(L10n.t("manage.mount", zh: "挂载", en: "Mount", language: lang), icon: "externaldrive.connected.to.line.below") {
                        Task { log = await formatter.mount(disk: disk) }
                    }
                } else {
                    ghostButton(L10n.t("manage.unmount", zh: "推出", en: "Unmount", language: lang), icon: "eject") {
                        Task { log = await formatter.unmount(disk: disk) }
                    }
                }
                ghostButton(L10n.t("manage.eject", zh: "弹出", en: "Eject", language: lang), icon: "eject.fill") {
                    Task { log = await formatter.eject(disk: disk) }
                }
                if disk.ntfsAccess(extensionOn: formatter.ntfsKitAvailable) == .needsRemount {
                    ghostButton(L10n.t("manage.ntfs.remount", zh: "重新挂载", en: "Remount", language: lang), icon: "arrow.triangle.2.circlepath") {
                        Task { log = await formatter.remount(disk: disk) }
                    }
                }
                Spacer(minLength: 0)
                if formatter.isBusy {
                    ProgressView().controlSize(.small)
                }
            }
            HStack(spacing: 8) {
                ghostButton(L10n.t("manage.firstaid", zh: "急救", en: "First Aid", language: lang), icon: "cross.case") {
                    Task {
                        guard let mp = disk.mountPoint else {
                            log = L10n.t("manage.firstaid.unmounted", zh: "未挂载，无法急救", en: "Not mounted", language: lang)
                            return
                        }
                        do {
                            let result = try await fsIntegrity.verify(mountPoint: mp)
                            switch result.status {
                            case .verified:
                                log = L10n.t("manage.firstaid.ok", zh: "急救通过", en: "First Aid passed", language: lang)
                            case .warning(let reason):
                                log = reason
                            case .failed(let reason):
                                log = reason
                            case .verifying:
                                log = L10n.t("manage.firstaid.running", zh: "急救进行中…", en: "First Aid running…", language: lang)
                            case .unknown:
                                log = "—"
                            }
                        } catch {
                            log = error.localizedDescription
                        }
                    }
                }
                .disabled(disk.mountPoint == nil)
            }
        }
    }

    private func renameCard(_ disk: DiskInfo) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.t("manage.rename", zh: "重命名", en: "Rename", language: lang))
                .font(.fraunces(size: 15, weight: .regular, italic: true))
                .foregroundStyle(Color.themeFgDark)
            Text(L10n.t("manage.rename.help", zh: "只改卷名，不清空文件。盘要先挂载。", en: "Changes the volume name only. Disk must be mounted.", language: lang))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                TextField(disk.displayName, text: $renameName)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
                Button {
                    Task { log = await formatter.rename(disk: disk, newName: renameName) }
                } label: {
                    Text(L10n.t("manage.rename.go", zh: "改名", en: "Rename", language: lang))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.dsNormal)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.dsNormal.opacity(0.16)))
                }
                .buttonStyle(.plain)
                .disabled(formatter.isBusy || disk.mountPoint == nil || renameName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glass(cornerRadius: 16)
    }

    private func ghostButton(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 10, weight: .semibold))
                Text(title).font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.white.opacity(0.04))
            )
        }
        .buttonStyle(.plain)
        .disabled(formatter.isBusy)
    }

    // MARK: - Format

    private func formatCard(_ disk: DiskInfo) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.t("manage.format.section", zh: "格式化", en: "Format", language: lang))
                .font(.fraunces(size: 16, weight: .regular, italic: true))
                .foregroundStyle(Color.themeFgDark)

            Text(L10n.t("manage.format.warn", zh: "会清空这块盘上的全部文件。只处理外接盘。", en: "Erases every file on this disk. External disks only.", language: lang))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 8) {
                Text(L10n.t("manage.format.fs", zh: "文件系统", en: "File system", language: lang))
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.secondary)
                FormatPersonalityChips(
                    personality: $personality,
                    canFormatNTFS: formatter.canFormatNTFS,
                    lang: lang
                ) { p in
                    settings.setDefaultFormat(p.rawValue)
                }
                Text(personality.hint(lang: lang))
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            labeledField(L10n.t("manage.volname", zh: "卷名", en: "Name", language: lang)) {
                TextField("", text: $volumeName)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
            }

            VStack(alignment: .leading, spacing: 6) {
                labeledField(L10n.t("manage.confirm", zh: "确认", en: "Confirm", language: lang)) {
                    TextField(disk.displayName, text: $confirm)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))
                }
                HStack(spacing: 6) {
                    Button {
                        confirm = disk.displayName
                    } label: {
                        Text(disk.displayName)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(Color.dsNormal)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Capsule(style: .continuous).fill(Color.dsNormal.opacity(0.12)))
                    }
                    .buttonStyle(.plain)
                    Button {
                        confirm = disk.bsdName
                    } label: {
                        Text(disk.bsdName)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Capsule(style: .continuous).fill(Color.white.opacity(0.05)))
                    }
                    .buttonStyle(.plain)
                    Spacer(minLength: 0)
                    if confirmOK {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(Color.dsNormal)
                            .font(.system(size: 12))
                    }
                }
                Text(confirmOK
                     ? L10n.t("manage.confirm.ok", zh: "将清空 \(disk.displayName)", en: "Will erase \(disk.displayName)", language: lang)
                     : L10n.t("manage.confirmHint", zh: "点盘名或 BSD，或手动输入以确认清空", en: "Tap the name or BSD, or type it, to confirm erase", language: lang))
                    .font(.system(size: 10))
                    .foregroundStyle(confirmOK ? AnyShapeStyle(Color.dsNormal) : AnyShapeStyle(.tertiary))
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button {
                Task {
                    log = await formatter.format(
                        disk: disk,
                        personality: personality,
                        confirm: confirm,
                        volumeName: volumeName,
                        remountAfter: settings.autoMountAfterFormat
                    )
                }
            } label: {
                Text(L10n.t("manage.format", zh: "格式化", en: "Format", language: lang))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.themeFgDark)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.dsNormal.opacity(confirmOK && !formatter.isBusy ? 0.28 : 0.10))
                    )
            }
            .buttonStyle(.plain)
            .disabled(formatter.isBusy || !confirmOK || volumeName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glass(cornerRadius: 16)
    }

    private func labeledField<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .center, spacing: 8) {
            Text(title)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 48, alignment: .leading)
            content()
        }
    }

    // MARK: - Log / empty / guide

    private var logCard: some View {
        Text(log)
            .font(.system(size: 10, design: .monospaced))
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .glass(cornerRadius: 12)
    }

    private var emptyCard: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "externaldrive.badge.questionmark")
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(.secondary)
            Text(L10n.t("manage.empty", zh: "没有外接磁盘。接上一块盘就会出现在这里。", en: "No external disks. Plug one in and it will show up here.", language: lang))
                .font(.fraunces(size: 14, weight: .regular, italic: true))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(16)
        .glass(cornerRadius: 16)
    }

    private var guideCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { showGuide.toggle() }
            } label: {
                HStack {
                    Text(L10n.t("manage.guide.title", zh: "使用说明", en: "How it works", language: lang))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.themeFgDark)
                    Spacer()
                    Image(systemName: showGuide ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            .buttonStyle(.plain)
            if showGuide {
                guideLine("1", L10n.t("manage.guide.1", zh: "只动外接盘。系统盘和 Macintosh HD 会被拒绝。", en: "External disks only. Macintosh HD and internal volumes are refused.", language: lang))
                guideLine("2", L10n.t("manage.guide.2", zh: "先看文件系统、容量、只读/可写，再决定格式化。", en: "Read the file system, capacity, and read/write state before you format.", language: lang))
                guideLine("3", L10n.t("manage.guide.3", zh: "格式化会清空全部数据。输入盘名或 BSD 才能点按钮。", en: "Format erases everything. Type the disk name or BSD before the button unlocks.", language: lang))
                guideLine("4", L10n.t("manage.guide.4", zh: "NTFS 写入要打开本 App 的文件系统扩展，再重新挂载。不会用 mount -t ntfs。", en: "NTFS write needs this app’s File System Extension, then a remount. Never uses mount -t ntfs.", language: lang))
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glass(cornerRadius: 14)
    }

    private func guideLine(_ n: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(n)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(Color.dsNormal)
                .frame(width: 14)
            Text(text)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .lineSpacing(2)
        }
    }

    // MARK: - First-run intro

    private var introOverlay: some View {
        ZStack {
            Color.black.opacity(0.45)
                .ignoresSafeArea()
            VStack(alignment: .leading, spacing: 14) {
                Text(L10n.t("manage.intro.kicker", zh: "磁盘管理", en: "Disk Manage", language: lang))
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .tracking(0.8)
                    .foregroundStyle(Color.dsNormal)
                Text(introSteps[introStep].title)
                    .font(.fraunces(size: 22, weight: .regular, italic: true))
                    .foregroundStyle(Color.themeFgDark)
                    .fixedSize(horizontal: false, vertical: true)
                Text(introSteps[introStep].body)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .lineSpacing(3)

                HStack(spacing: 5) {
                    ForEach(0..<introSteps.count, id: \.self) { i in
                        Capsule()
                            .fill(i == introStep ? Color.dsNormal : Color.white.opacity(0.12))
                            .frame(width: i == introStep ? 14 : 6, height: 6)
                    }
                }
                .padding(.top, 4)

                HStack {
                    Button {
                        settings.setManageIntroDone(true)
                    } label: {
                        Text(L10n.t("manage.intro.skip", zh: "跳过", en: "Skip", language: lang))
                            .font(.system(size: 12))
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    Spacer()
                    Button {
                        if introStep < introSteps.count - 1 {
                            withAnimation(.easeInOut(duration: 0.2)) { introStep += 1 }
                        } else {
                            settings.setManageIntroDone(true)
                        }
                    } label: {
                        Text(introStep < introSteps.count - 1
                             ? L10n.t("onboarding.next", zh: "下一步", en: "Next", language: lang)
                             : L10n.t("manage.intro.done", zh: "开始使用", en: "Get started", language: lang))
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Color.dsNormal)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(Capsule().fill(Color.dsNormal.opacity(0.18)))
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(20)
            .frame(maxWidth: 360)
            .glass(cornerRadius: 18)
            .padding(20)
        }
    }

    private var introSteps: [(title: String, body: String)] {
        [
            (
                L10n.t("manage.intro.1.title", zh: "只动外接盘", en: "External disks only", language: lang),
                L10n.t("manage.intro.1.body", zh: "系统盘和 Macintosh HD 不会出现，也不会被格式化。接上 USB / 雷电盘即可管理。", en: "Macintosh HD and internal volumes never appear here and cannot be formatted. Plug in a USB or Thunderbolt disk to manage it.", language: lang)
            ),
            (
                L10n.t("manage.intro.2.title", zh: "先看这块盘", en: "See the disk first", language: lang),
                L10n.t("manage.intro.2.body", zh: "顶部是盘名、文件系统、容量和只读/可写。确认无误再往下格式化。", en: "The top of the page shows the name, file system, capacity, and read/write state. Check those before you format.", language: lang)
            ),
            (
                L10n.t("manage.intro.3.title", zh: "格式化要确认盘名", en: "Confirm the name to format", language: lang),
                L10n.t("manage.intro.3.body", zh: "选 APFS / ExFAT / FAT32 / NTFS，输入卷名，再点盘名或 BSD。对上了，格式化按钮才会亮。", en: "Pick APFS, ExFAT, FAT32, or NTFS, type a volume name, then tap the disk name or BSD. The Format button unlocks only when they match.", language: lang)
            ),
            (
                L10n.t("manage.intro.4.title", zh: "NTFS 写入要开扩展", en: "NTFS write needs the extension", language: lang),
                L10n.t("manage.intro.4.body", zh: "要在访达里写入 NTFS，请打开 DiskMon 的文件系统扩展，再点「重新挂载」。打开扩展不会自动换驱动。", en: "To write NTFS from Finder, enable DiskMon’s File System Extension, then Remount. Turning the extension on does not switch the driver by itself.", language: lang)
            )
        ]
    }
}

private extension Optional where Wrapped == DiskInfo {
    var filterExternal: DiskInfo? {
        guard let disk = self, !disk.isInternal else { return nil }
        return disk
    }
}

extension DiskFormatService {
    static func openFileSystemExtensions() {
        let candidates = [
            "x-apple.systempreferences:com.apple.LoginItems-Settings.extension",
            "x-apple.systempreferences:com.apple.ExtensionsPreferences",
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension"
        ]
        for s in candidates {
            if let url = URL(string: s) {
                NSWorkspace.shared.open(url)
                return
            }
        }
    }
}
