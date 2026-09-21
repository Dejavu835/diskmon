import SwiftUI
import AppKit

/// General 偏好 Tab
/// v0.2.0 接管原 PreferencesView.generalTab:
///   - GlassBackground 整体 + 4 张玻璃卡(轮询 / 警告阈值 / 严重阈值 / 温度单位)
///   - 用 @Bindable + 显式 Binding 包到 AppSettings setter(走真持久化 + didChange 通知)
///   - 留白克制,主人审美:电影感 + Fraunces italic 标题
struct GeneralSettingsView: View {
    @Bindable private var settings = AppSettings.shared
    @State private var folderSizeLabel: String = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                pollCard
                warningCard
                criticalCard
                launchAtLoginCard
                storageCard
            }
            .padding(28)
        }
        .background(Color.themeBgDark.opacity(0.4))
        .task { refreshFolderSize() }
    }

    // MARK: - 日志文件夹与缓存

    private var storageCard: some View {
        SettingCard(
            title: L10n.t(
                "settings.storage.title",
                zh: "日志与缓存",
                en: "Logs & Cache",
                language: settings.language
            ),
            help: L10n.t(
                "settings.storage.help",
                zh: "活动日志、掉盘记录与导出默认位置。采样缓存超限时自动清理最旧数据。测速历史库仍在系统应用支持目录，以保证稳定。",
                en: "Folder for activity log, drop records, and default exports. When cache exceeds the limit, oldest samples are pruned. The measurement store stays in Application Support for stability.",
                language: settings.language
            ),
            systemImage: "folder.badge.gearshape"
        ) {
            VStack(alignment: .leading, spacing: 12) {
                // 当前路径
                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.t(
                        "settings.storage.folder",
                        zh: "日志文件夹",
                        en: "Log folder",
                        language: settings.language
                    ))
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.secondary)
                    Text(settings.resolvedLogDirectory.path)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Color.themeFgDark)
                        .lineLimit(2)
                        .textSelection(.enabled)
                    if !folderSizeLabel.isEmpty {
                        Text(folderSizeLabel)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.tertiary)
                    }
                }

                HStack(spacing: 8) {
                    Button {
                        pickFolder()
                    } label: {
                        Text(L10n.t(
                            "settings.storage.choose",
                            zh: "选择文件夹…",
                            en: "Choose Folder…",
                            language: settings.language
                        ))
                        .font(.system(size: 12, weight: .medium))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(Color.dsNormal.opacity(0.12))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(Color.dsNormal.opacity(0.3), lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)

                    Button {
                        settings.setLogDirectoryPath("")
                        DiskMonDataPaths.appendActivity(
                            "log directory reset to default",
                            customPath: ""
                        )
                        refreshFolderSize()
                    } label: {
                        Text(L10n.t(
                            "settings.storage.reset",
                            zh: "恢复默认",
                            en: "Reset",
                            language: settings.language
                        ))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                    }
                    .buttonStyle(.plain)

                    Button {
                        NSWorkspace.shared.open(settings.resolvedLogDirectory)
                    } label: {
                        Text(L10n.t(
                            "settings.storage.open",
                            zh: "在访达打开",
                            en: "Open in Finder",
                            language: settings.language
                        ))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                    }
                    .buttonStyle(.plain)
                }

                Divider().opacity(0.25)

                // 缓存上限
                HStack(spacing: 10) {
                    Text(L10n.t(
                        "settings.storage.cacheLimit",
                        zh: "缓存上限",
                        en: "Cache limit",
                        language: settings.language
                    ))
                    .font(.system(size: 12))
                    .foregroundStyle(Color.themeFgDark)
                    Text(settings.cacheLimitMB == 0
                         ? L10n.t("settings.storage.cacheUnlimited", zh: "不限制", en: "Off", language: settings.language)
                         : "\(settings.cacheLimitMB) MB")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    Slider(
                        value: Binding(
                            get: { Double(settings.cacheLimitMB) },
                            set: { settings.setCacheLimitMB(Int($0)) }
                        ),
                        in: 0...4096,
                        step: 128
                    )
                    .frame(maxWidth: 220)
                }

                // raw 保留天数
                HStack(spacing: 10) {
                    Text(L10n.t(
                        "settings.storage.rawDays",
                        zh: "明细保留天数",
                        en: "Detail retention",
                        language: settings.language
                    ))
                    .font(.system(size: 12))
                    .foregroundStyle(Color.themeFgDark)
                    Text("\(settings.rawHistoryDays)")
                        .font(.fraunces(size: 16, weight: .regular, italic: true))
                        .foregroundStyle(Color.themeFgDark)
                        .monospacedDigit()
                    Text(L10n.t("settings.storage.days", zh: "天", en: "days", language: settings.language))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Slider(
                        value: Binding(
                            get: { Double(settings.rawHistoryDays) },
                            set: { settings.setRawHistoryDays(Int($0)) }
                        ),
                        in: 1...90,
                        step: 1
                    )
                    .frame(maxWidth: 220)
                }
            }
        }
    }

    private func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = L10n.t(
            "settings.storage.choose",
            zh: "选择文件夹",
            en: "Choose Folder",
            language: settings.language
        )
        panel.begin { resp in
            guard resp == .OK, let url = panel.url else { return }
            settings.setLogDirectoryPath(url.path)
            DiskMonDataPaths.appendActivity("log folder selected: \(url.path)", customPath: url.path)
            refreshFolderSize()
        }
    }

    private func refreshFolderSize() {
        let size = DiskMonDataPaths.directorySize(settings.resolvedLogDirectory)
        let sz = DiskMonDataPaths.formatBytes(size)
        folderSizeLabel = L10n.t(
            "settings.storage.size",
            zh: "当前占用 %@",
            en: "Current size %@",
            language: settings.language
        ).replacingOccurrences(of: "%@", with: sz)
    }

    // MARK: - 轮询间隔

    private var pollCard: some View {
        SettingCard(
            title: String(localized: "settings.interval", defaultValue: "Monitor interval"),
            help: String(
                localized: "monitor.interval.help",
                defaultValue: "How often to query smartctl (1-60 seconds)"
            ),
            systemImage: "timer"
        ) {
            HStack(spacing: 10) {
                Text("\(Int(settings.pollIntervalSeconds))")
                    .font(.fraunces(size: 22, weight: .regular, italic: true))
                    .foregroundStyle(Color.themeFgDark)
                    .frame(minWidth: 36, alignment: .trailing)
                Text(unitSeconds)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Slider(
                    value: Binding(
                        get: { settings.pollIntervalSeconds },
                        set: { settings.setPollInterval($0) }
                    ),
                    in: 1...60,
                    step: 1
                )
                .frame(maxWidth: 220)
            }
        }
    }

    // MARK: - 警告温度

    private var warningCard: some View {
        SettingCard(
            title: String(localized: "settings.warning", defaultValue: "Warning temperature"),
            help: String(
                localized: "warning.temperature.help",
                defaultValue: "Yellow alert when disk exceeds this temperature"
            ),
            systemImage: "thermometer.sun"
        ) {
            HStack(spacing: 10) {
                Text("\(settings.warningTempCelsius)°")
                    .font(.fraunces(size: 22, weight: .regular, italic: true))
                    .foregroundStyle(Color.dsWarning)
                    .frame(minWidth: 36, alignment: .trailing)
                Text(settings.temperatureUnitSymbol)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Stepper(
                    value: Binding(
                        get: { settings.warningTempCelsius },
                        set: { settings.setWarning($0) }
                    ),
                    in: 50...95
                ) {
                    EmptyView()
                }
                .labelsHidden()
            }
        }
    }

    // MARK: - 严重温度

    private var criticalCard: some View {
        SettingCard(
            title: String(localized: "settings.critical", defaultValue: "Critical temperature"),
            help: String(
                localized: "critical.temperature.help",
                defaultValue: "Red alert when disk exceeds this temperature"
            ),
            systemImage: "thermometer.high"
        ) {
            HStack(spacing: 10) {
                Text("\(settings.criticalTempCelsius)°")
                    .font(.fraunces(size: 22, weight: .regular, italic: true))
                    .foregroundStyle(Color.dsCritical)
                    .frame(minWidth: 36, alignment: .trailing)
                Text(settings.temperatureUnitSymbol)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Stepper(
                    value: Binding(
                        get: { settings.criticalTempCelsius },
                        set: { settings.setCritical($0) }
                    ),
                    in: 50...100
                ) {
                    EmptyView()
                }
                .labelsHidden()
            }
        }
    }

    private var launchAtLoginCard: some View {
        SettingCard(
            title: L10n.t("settings.notifications.launch", zh: "登录时启动", en: "Launch at login", language: settings.language),
            help: L10n.t("settings.notifications.launch.help", zh: "登录后自动打开 DiskMon。", en: "Automatically start DiskMon when you sign in.", language: settings.language),
            systemImage: "power"
        ) {
            Toggle("", isOn: Binding(
                get: { settings.launchAtLogin },
                set: { settings.setLaunchAtLogin($0) }
            ))
            .labelsHidden()
        }
    }

    // MARK: - 副文案

    private var unitSeconds: String {
        String(localized: "seconds", defaultValue: "seconds")
    }
}

// MARK: - 玻璃卡(本文件内复用)

/// 单条设置项:标题 + 副标题 + 右侧控件
/// 用 .glass() 套,圆角 16pt(比 Settings 整体 20pt 略小,层级)
private struct SettingCard<Content: View>: View {
    let title: String
    let help: String?
    let systemImage: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: systemImage)
                    .font(.system(size: 16, weight: .regular))
                    .foregroundStyle(.secondary)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.fraunces(size: 16, weight: .regular, italic: true))
                        .foregroundStyle(Color.themeFgDark)
                        .fixedSize(horizontal: false, vertical: true)
                    if let help {
                        Text(help)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .lineSpacing(2)
                    }
                }
                Spacer(minLength: 0)
            }
            content
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glass(cornerRadius: 16)
    }
}
