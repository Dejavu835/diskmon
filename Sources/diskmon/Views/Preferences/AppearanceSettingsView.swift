import SwiftUI

/// Appearance 偏好 Tab
/// v0.2.0 全新:
///   - 语言切换(走 AppSettings.setLanguage,主语言变 → 整个 UI 走新语言)
///   - 温度单位 SegmentedControl(走 AppSettings.setTemperatureUnit)
///   - 菜单栏脉冲 toggle(走 AppSettings.setShowMenuBarPulse)
/// 每条用玻璃卡,留白克制,主人审美。
struct AppearanceSettingsView: View {
    @Bindable private var settings = AppSettings.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                languageCard
                unitCard
                menuBarModeCard
                menuBarColorCard
                autoOKCard
                menuBarPulseCard
            }
            .padding(28)
        }
        .background(Color.themeBgDark.opacity(0.4))
        .id(settings.language) // 切语言时强制重建,Text 全部走新 lookup
    }

    // MARK: - 语言

    private var languageCard: some View {
        SettingsRow(
            title: String(
                localized: "settings.appearance.language",
                defaultValue: "Language"
            ),
            help: currentLanguageName,
            systemImage: "globe"
        ) {
            Picker(
                "",
                selection: Binding(
                    get: { settings.language },
                    set: { settings.setLanguage($0) }
                )
            ) {
                Text(String(
                    localized: "settings.appearance.language.en",
                    defaultValue: "English"
                ))
                .tag("en")
                Text(String(
                    localized: "settings.appearance.language.zh",
                    defaultValue: "简体中文"
                ))
                .tag("zh-Hans")
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 280)
        }
    }

    // MARK: - 温度单位

    private var unitCard: some View {
        SettingsRow(
            title: String(
                localized: "settings.unit",
                defaultValue: "Temperature unit"
            ),
            help: settings.temperatureUnitLabel,
            systemImage: "thermometer.medium"
        ) {
            Picker(
                "",
                selection: Binding(
                    get: { settings.temperatureUnit },
                    set: { settings.setTemperatureUnit($0) }
                )
            ) {
                Text(String(
                    localized: "settings.unit.celsius",
                    defaultValue: "Celsius (℃)"
                ))
                .tag("celsius")
                Text(String(
                    localized: "settings.unit.fahrenheit",
                    defaultValue: "Fahrenheit (℉)"
                ))
                .tag("fahrenheit")
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 280)
        }
    }

    private var menuBarModeCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            SettingsRow(
                title: L10n.t("settings.appearance.mode", zh: "菜单栏显示", en: "Menu bar", language: settings.language),
                help: L10n.t("settings.appearance.mode.help", zh: "温度、健康点、24h 折线，或安静的 OK 图标。", en: "Temperature, health dots, 24h sparkline, or a quiet OK glyph.", language: settings.language),
                systemImage: "menubar.rectangle"
            ) {
                EmptyView()
            }
            HStack(spacing: 6) {
                ForEach(MenuBarLabel.MenuBarMode.allCases) { m in
                    let on = settings.menuBarModeRaw == m.rawValue
                    Button {
                        settings.setMenuBarMode(m.rawValue)
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: m.systemImage)
                                .font(.system(size: 10))
                            Text(modeLabel(m))
                                .font(.system(size: 11, weight: .semibold))
                        }
                        .foregroundStyle(on ? Color.dsNormal : .secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(
                            Capsule(style: .continuous)
                                .fill(on ? Color.dsNormal.opacity(0.16) : Color.white.opacity(0.05))
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 12)
        }
        .background(Color.clear)
    }

    private func modeLabel(_ m: MenuBarLabel.MenuBarMode) -> String {
        switch m {
        case .temperature:
            return L10n.t("menubar.mode.temperature", zh: "温度", en: "Temp", language: settings.language)
        case .health:
            return L10n.t("menubar.mode.health", zh: "健康", en: "Health", language: settings.language)
        case .sparkline:
            return L10n.t("menubar.mode.sparkline", zh: "折线", en: "Spark", language: settings.language)
        case .ok:
            return L10n.t("menubar.mode.ok", zh: "OK", en: "OK", language: settings.language)
        }
    }

    private var menuBarColorCard: some View {
        SettingsRow(
            title: L10n.t("settings.appearance.colorScope", zh: "菜单栏颜色", en: "Menu bar color", language: settings.language),
            help: L10n.t("settings.appearance.colorScope.help", zh: "默认跟全盘最差。也可只跟当前选中盘。", en: "Default follows the worst disk. Or only the selected disk.", language: settings.language),
            systemImage: "paintpalette"
        ) {
            Picker("", selection: Binding(
                get: { settings.menuBarColorScopeRaw },
                set: { settings.setMenuBarColorScope($0) }
            )) {
                Text(L10n.t("settings.appearance.color.worst", zh: "全盘最差", en: "Worst", language: settings.language))
                    .tag("worst")
                Text(L10n.t("settings.appearance.color.selected", zh: "仅选中盘", en: "Selected", language: settings.language))
                    .tag("selected")
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 220)
        }
    }

    private var autoOKCard: some View {
        SettingsRow(
            title: L10n.t("settings.appearance.autoOK", zh: "全绿时自动 OK", en: "Auto OK when healthy", language: settings.language),
            help: L10n.t("settings.appearance.autoOK.help", zh: "所有盘正常时菜单栏只留安静图标；一旦告警回到所选模式。", en: "When every disk is normal, show the quiet glyph. Warning returns to the chosen mode.", language: settings.language),
            systemImage: "checkmark.circle"
        ) {
            Toggle("", isOn: Binding(
                get: { settings.autoOKWhenHealthy },
                set: { settings.setAutoOKWhenHealthy($0) }
            ))
            .labelsHidden()
        }
    }

    // MARK: - 菜单栏脉冲

    private var menuBarPulseCard: some View {
        SettingsRow(
            title: String(
                localized: "settings.appearance.menubar",
                defaultValue: "Show pulse in menu bar"
            ),
            help: String(
                localized: "settings.appearance.menubar.help",
                defaultValue: "Display a subtle pulse animation when a disk is in critical condition."
            ),
            systemImage: "waveform"
        ) {
            Toggle(
                "",
                isOn: Binding(
                    get: { settings.showMenuBarPulse },
                    set: { settings.setShowMenuBarPulse($0) }
                )
            )
            .labelsHidden()
        }
    }

    // MARK: - 派生文案

    private var currentLanguageName: String {
        switch settings.language {
        case "zh-Hans":
            return String(
                localized: "settings.appearance.language.zh",
                defaultValue: "简体中文"
            )
        default:
            return String(
                localized: "settings.appearance.language.en",
                defaultValue: "English"
            )
        }
    }
}
