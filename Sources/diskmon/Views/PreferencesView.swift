import SwiftUI

/// Preferences 窗口(Settings Scene 挂 ⌘, 菜单)
/// v0.2.0:5 Tab 重构(General / Disks / Notifications / Appearance / About)
/// 全部用 Wave 1A 子 View,外层包 GlassBackground(20pt 圆角)
/// Disks Tab 加 "Open Disk Detail…" 按钮,用 openWindow(id: "disk-detail")
struct PreferencesView: View {
    @Environment(HealthMonitor.self) private var monitor
    @Environment(\.openWindow) private var openWindow
    // grok 调研:Tab 选择持久化,reopen Settings 保留上次 tab
    // 用 @AppStorage 替代 @State,跨窗口关闭/重开 ⌘, 都保留上次选中。
    // rawValue String 持久化(enum 自身 Codable 会随版本变,rawValue 稳)。
    @AppStorage("preferences.selectedTab") private var selectedTabRaw: String = PreferencesTab.general.rawValue
    private var selectedTab: PreferencesTab {
        get { PreferencesTab(rawValue: selectedTabRaw) ?? .general }
        set { selectedTabRaw = newValue.rawValue }
    }

    enum PreferencesTab: String, CaseIterable, Identifiable {
        case general, disks, notifications, appearance, about
        var id: String { rawValue }
        var systemImage: String {
            switch self {
            case .general:      return "gearshape"
            case .disks:        return "externaldrive"
            case .notifications: return "bell"
            case .appearance:   return "paintbrush"
            case .about:        return "info.circle"
            }
        }
        var localizedLabel: String {
            switch self {
            case .general:      return String(localized: "tab.general", defaultValue: "General")
            case .disks:        return String(localized: "tab.disks", defaultValue: "Disks")
            case .notifications: return String(localized: "tab.notifications", defaultValue: "Notifications")
            case .appearance:   return String(localized: "tab.appearance", defaultValue: "Appearance")
            case .about:        return String(localized: "tab.about", defaultValue: "About")
            }
        }
    }

    var body: some View {
        // 用 HStack 模拟"左导航 + 右内容"的 macOS Settings 风
        // 不用原生 TabView,因为 TabView 在 macOS 上样式不克制
        HStack(spacing: 0) {
            // === 左:侧边栏导航 ===
            sidebar
                .frame(width: 180)
                .background(
                    Color.themeBgDarkElevated.opacity(0.5)
                )
            Divider()
            // === 右:Tab 内容 ===
            Group {
                switch selectedTab {
                case .general:       GeneralSettingsView()
                case .disks:         DisksSettingsView()
                case .notifications: NotificationsSettingsView()
                case .appearance:    AppearanceSettingsView()
                case .about:         AboutSettingsView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(
                Color.themeBgDark.opacity(0.3)
            )
        }
        .frame(minWidth: 640, idealWidth: 880, maxWidth: .infinity,
               minHeight: 420, idealHeight: 580, maxHeight: .infinity)
        // Settings scene 常丢掉 resizable,用 NSWindow 补回
        .background(
            ResizableWindowConfigurator(minSize: CGSize(width: 640, height: 420))
        )
        // 整面板包玻璃
        .background(
            RoundedRectangle(cornerRadius: 0, style: .continuous)
                .fill(.regularMaterial)
        )
    }

    // MARK: - 侧边栏

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 顶部:app name
            HStack(alignment: .center, spacing: 8) {
                Image(systemName: "circle.hexagongrid.fill")
                    .font(.system(size: 16, weight: .regular))
                    .foregroundStyle(Color.dsNormal)
                Text(String(localized: "app.name", defaultValue: "DiskMon"))
                    .font(.fraunces(size: 14, weight: .regular, italic: true))
                    .foregroundStyle(Color.themeFgDark)
            }
            .padding(.horizontal, 16)
            .padding(.top, 18)
            .padding(.bottom, 14)
            Divider()
            // Tab 列表
            VStack(alignment: .leading, spacing: 2) {
                ForEach(PreferencesTab.allCases) { tab in
                    tabButton(tab)
                }
            }
            .padding(.horizontal, 10)
            .padding(.top, 10)
            Spacer()
            // 底部:Disks Tab 时显示"Open Disk Detail…" 按钮
            if selectedTab == .disks {
                openDetailButton
                    .padding(.horizontal, 14)
                    .padding(.bottom, 14)
            } else {
                Color.clear.frame(height: 14)
            }
        }
    }

    private func tabButton(_ tab: PreferencesTab) -> some View {
        let isSelected = selectedTab == tab
        // @AppStorage 的 wrappedValue 是 nonmutating set,可在 Button action 直接赋值
        // 不能走 selectedTab computed setter(struct View self immutable)
        return Button {
            selectedTabRaw = tab.rawValue
        } label: {
            HStack(spacing: 9) {
                Image(systemName: tab.systemImage)
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(isSelected ? Color.dsNormal : .secondary)
                    .frame(width: 18)
                Text(tab.localizedLabel)
                    .font(.system(size: 12, weight: isSelected ? .medium : .regular))
                    .foregroundStyle(isSelected ? Color.themeFgDark : .secondary)
                Spacer(minLength: 4)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isSelected ? Color.dsNormal.opacity(0.10) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(isSelected ? Color.dsNormal.opacity(0.3) : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private var openDetailButton: some View {
        Button {
            openWindow(id: "disk-detail")
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "macwindow")
                    .font(.system(size: 12))
                Text(String(localized: "disks.openDetail", defaultValue: "Open Disk Detail…"))
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(Color.dsNormal)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.dsNormal.opacity(0.10))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.dsNormal.opacity(0.3), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .disabled(monitor.watchedDisks.isEmpty)
    }
}
