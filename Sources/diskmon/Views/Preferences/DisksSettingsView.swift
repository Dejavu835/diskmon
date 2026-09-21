import SwiftUI
import DiskMonCore

/// Disks 偏好 Tab
/// v0.2.0 接管原 PreferencesView.disksTab:
///   - 列出 HealthMonitor.watchedDisks(通过 @Environment 注入,非单例)
///   - 每行 1 张玻璃卡(macOS 控制中心风:左大标题 / 右小副)
///   - 底部"+" / "-" 工具栏(Wave 2 接 toggleWatch;v0.2.0 仅占位 + 注释)
///   - 空态:暖米底 + 克制文案,主人审美"零摩擦"——连接外接盘即自动开始
struct DisksSettingsView: View {
    @Environment(HealthMonitor.self) private var monitor
    @Environment(AppSettings.self) private var settings
    @Environment(DiskFormatService.self) private var formatter

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                headerCard
                if listedDisks.isEmpty {
                    emptyCard
                } else {
                    diskList
                }
                detailListCard
                manageCard
                dropCard
            }
            .padding(28)
        }
        .background(Color.themeBgDark.opacity(0.4))
    }

    // MARK: - Header

    private var headerCard: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 4) {
                Text(String(
                    localized: "settings.disks.watched",
                    defaultValue: "Watched Disks"
                ))
                .font(.fraunces(size: 22, weight: .regular, italic: true))
                .foregroundStyle(Color.themeFgDark)
                Text(headerSubtitle)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            }
            Spacer()
            Text("\(monitor.watchedDisks.count)")
                .font(.system(size: 28, weight: .light, design: .rounded))
                .foregroundStyle(Color.themeFgDarkMuted)
        }
        .padding(20)
        .glass(cornerRadius: 16)
    }

    // MARK: - 列表

    private var listedDisks: [DiskInfo] {
        var seen = Set<String>()
        var out: [DiskInfo] = []
        for d in monitor.discoveredDisks + monitor.watchedDisks {
            if seen.insert(d.volumeUUID).inserted { out.append(d) }
        }
        return out
    }

    private var headerSubtitle: String {
        let n = monitor.watchedDisks.count
        if n == 0 {
            return L10n.t("settings.disks.discover", zh: "正在发现磁盘…", en: "Discovering disks…", language: lang)
        }
        return L10n.t(
            "settings.disks.summary",
            zh: "已监控 \(n) 台",
            en: "Watching \(n)",
            language: lang
        )
    }

    private var diskList: some View {
        VStack(spacing: 10) {
            ForEach(listedDisks) { disk in
                diskRow(disk)
            }
        }
    }

    private func diskRow(_ disk: DiskInfo) -> some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: disk.isInternal ? "internaldrive" : "externaldrive")
                .font(.system(size: 18, weight: .regular))
                .foregroundStyle(.secondary)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 3) {
                Text(disk.displayName)
                    .font(.fraunces(size: 15, weight: .regular, italic: true))
                    .foregroundStyle(Color.themeFgDark)
                HStack(spacing: 8) {
                    Text(disk.bsdName)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Text("·")
                        .foregroundStyle(.secondary)
                    Text(formattedSize(disk.sizeBytes))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    if let model = disk.modelName {
                        Text("·")
                            .foregroundStyle(.secondary)
                        Text(model)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            Spacer()
            Toggle("", isOn: Binding(
                get: { monitor.isMonitoring(disk.volumeUUID) },
                set: { monitor.toggleWatch(disk: disk, on: $0) }
            ))
            .toggleStyle(.switch)
            .tint(Color.dsNormal)
            .labelsHidden()
            .help(L10n.t("settings.disks.watch", zh: "监控", en: "Watch", language: lang))
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .glass(cornerRadius: 14)
    }

    // MARK: - 空态

    private var emptyCard: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: "externaldrive.badge.questionmark")
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(.secondary)
                .frame(width: 32)
            Text(String(
                localized: "settings.disks.empty",
                defaultValue: "No disks watched yet. Connect an external drive to begin."
            ))
            .font(.fraunces(size: 14, weight: .regular, italic: true))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            // v0.6.0 polish-E:多行段落实体加 .lineSpacing(2) 提升可读性
            .lineSpacing(2)
            Spacer()
        }
        .padding(20)
        .glass(cornerRadius: 16)
    }

    private var lang: String { settings.language }

    /// IO mean window for Disk Detail sidebar. Next to manage defaults.
    private var detailListCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.t("settings.disks.detail", zh: "详情列表", en: "Detail list", language: lang))
                .font(.fraunces(size: 18, weight: .regular, italic: true))
                .foregroundStyle(Color.themeFgDark)
            Text(L10n.t(
                "settings.disks.detail.help",
                zh: "侧栏显示这段时间的平均读写。沿用现有采样，不另开轮询。",
                en: "Sidebar shows mean read/write for this window. Uses existing samples — no extra poll loop.",
                language: lang
            ))
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            Text(L10n.t("settings.disks.ioWindow", zh: "平均读写窗口", en: "Average IO window", language: lang))
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(.secondary)
            HStack(spacing: 6) {
                ForEach([("h1", "1小时", "1 hour"), ("h24", "24小时", "24 hours"), ("d7", "7天", "7 days")], id: \.0) { item in
                    let on = settings.ioMeanWindowRaw == item.0
                    Button {
                        settings.setIOMeanWindow(item.0)
                    } label: {
                        Text(lang == "en" ? item.2 : item.1)
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
        .padding(16)
        .glass(cornerRadius: 16)
    }

    /// Preferences only. Actions live in TopBar 管理 + Disk Detail.
    private var manageCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L10n.t("settings.disks.manage", zh: "磁盘管理", en: "Disk Manage", language: lang))
                .font(.fraunces(size: 18, weight: .regular, italic: true))
                .foregroundStyle(Color.themeFgDark)
            Text(L10n.t(
                "settings.disks.manage.help",
                zh: "格式化、挂载、改名在顶栏「管理」和磁盘详情。这里只改默认项。",
                en: "Format, mount, and rename live in the Manage tab and Disk Detail. These are defaults only.",
                language: lang
            ))
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 6) {
                Text(L10n.t("manage.format.fs", zh: "默认文件系统", en: "Default file system", language: lang))
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    ForEach(["ExFAT", "APFS", "FAT32", "NTFSKit"], id: \.self) { raw in
                        let on = settings.defaultFormatRaw == raw
                        let title = raw == "NTFSKit" ? "NTFS" : raw
                        Button {
                            settings.setDefaultFormat(raw)
                        } label: {
                            Text(title)
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

            Toggle(isOn: Binding(
                get: { settings.autoMountAfterFormat },
                set: { settings.setAutoMountAfterFormat($0) }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.t("settings.disks.manage.automount", zh: "格式化后自动挂载", en: "Mount after format", language: lang))
                        .font(.system(size: 12))
                        .foregroundStyle(Color.themeFgDark)
                    Text(L10n.t("settings.disks.manage.automount.help", zh: "清空完成后用 diskutil mountDisk 挂上，方便立刻打开访达。", en: "After erase, mount with diskutil mountDisk so the volume shows up in Finder.", language: lang))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.switch)
            .tint(Color.dsNormal)

            Toggle(isOn: Binding(
                get: { settings.isManageModuleVisible },
                set: { settings.setManageModuleVisible($0) }
            )) {
                Text(L10n.t("settings.disks.manage.module", zh: "在总览显示管理模块", en: "Show Manage module on Overview", language: lang))
                    .font(.system(size: 12))
                    .foregroundStyle(Color.themeFgDark)
            }
            .toggleStyle(.switch)
            .tint(Color.dsNormal)

            Divider().opacity(0.2)

            Text(L10n.t("settings.disks.ntfs", zh: "NTFS 读写", en: "NTFS read/write", language: lang))
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(.secondary)

            NTFSStatusRow(
                access: .notNTFS,
                extensionOn: formatter.ntfsKitAvailable,
                lang: lang,
                onEnable: { DiskFormatService.openFileSystemExtensions() }
            )

            Button {
                settings.setManageIntroDone(false)
            } label: {
                Text(L10n.t("settings.disks.manage.replay", zh: "重看简介", en: "Replay intro", language: lang))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(16)
        .glass(cornerRadius: 16)
        .task { await formatter.refreshProbe() }
    }

    private var dropCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.t("settings.disks.drop", zh: "掉盘检测", en: "Drop watch", language: lang))
                .font(.fraunces(size: 18, weight: .regular, italic: true))
                .foregroundStyle(Color.themeFgDark)
            Text(L10n.t(
                "settings.disks.drop.help",
                zh: "只记意外掉盘。本 App 或访达推出的不算。卡片回答三件事：现在怎样、可能原因、可以怎么做。USB 无法点名哪一根线。",
                en: "Uses existing mount notifications and the 5s discover loop — no extra poll. Distinguishes this app’s eject, unmount while the device node remains, and a vanished disk. USB drops can only hint cable/port/power/reset.",
                language: lang
            ))
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            Toggle(isOn: Binding(
                get: { settings.isDropModuleVisible },
                set: { settings.setDropModuleVisible($0) }
            )) {
                Text(L10n.t("settings.disks.drop.module", zh: "在总览显示掉盘模块", en: "Show Drop module on Overview", language: lang))
                    .font(.system(size: 12))
                    .foregroundStyle(Color.themeFgDark)
            }
            .toggleStyle(.switch)
            .tint(Color.dsNormal)

            let recent = DropStory.history(monitor.dropStore.events, limit: 5)
            if !recent.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text(L10n.t("settings.disks.drop.recent", zh: "最近记录", en: "Recent", language: lang))
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.secondary)
                    ForEach(recent) { row in
                        HStack(spacing: 6) {
                            Text(row.event.name)
                                .font(.system(size: 11))
                                .foregroundStyle(Color.themeFgDark)
                                .lineLimit(1)
                            if row.times > 1 {
                                Text("×\(row.times)")
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(Color.dsWarning)
                            }
                            Spacer(minLength: 0)
                            Text(row.event.returnedAt == nil
                                 ? L10n.t("module.drop.chip.missing", zh: "现在不在", en: "missing", language: lang)
                                 : L10n.t("module.drop.back", zh: "已回来", en: "back", language: lang))
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(row.event.returnedAt == nil ? Color.dsDanger : Color.secondary.opacity(0.7))
                        }
                    }
                }
            }
        }
        .padding(16)
        .glass(cornerRadius: 16)
    }

    // MARK: - 辅助

    private func formattedSize(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useGB, .useTB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}
