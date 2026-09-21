import SwiftUI

struct OpenDiskManageAction {
    let handler: () -> Void
    func callAsFunction() { handler() }
}

private enum OpenDiskManageKey: EnvironmentKey {
    static let defaultValue = OpenDiskManageAction(handler: {})
}

extension EnvironmentValues {
    var openDiskManage: OpenDiskManageAction {
        get { self[OpenDiskManageKey.self] }
        set { self[OpenDiskManageKey.self] = newValue }
    }
}

/// Overview quick-access card for Disk Manage. Same 220×180 glass as other modules.
struct DiskManageModule: View {
    @Environment(HealthMonitor.self) private var monitor
    @Environment(DiskFormatService.self) private var formatter
    @Environment(AppSettings.self) private var settings
    @Environment(\.openDiskManage) private var openDiskManage

    @State private var isCardHovered = false
    @State private var isPressed = false
    @FocusState private var isFocused: Bool

    private var lang: String { settings.language }

    private var disk: DiskInfo? {
        let selected = monitor.selectedDisk ?? monitor.watchedDisks.first
        if let selected, !selected.isInternal { return selected }
        return monitor.watchedDisks.first(where: { !$0.isInternal })
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
            .task { await formatter.refreshProbe() }
    }

    private var cardBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                Image(systemName: "wrench.and.screwdriver")
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(.tertiary)
                Text(L10n.t("module.manage.title", zh: "管理", en: "MANAGE", language: lang))
                    .font(.system(size: 11, weight: .medium))
                    .tracking(0.6)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                if !settings.manageIntroDone {
                    Text(L10n.t("module.manage.new", zh: "新", en: "NEW", language: lang))
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Color.dsNormal)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.dsNormal.opacity(0.16)))
                }
            }
            .padding(.top, 2)

            Spacer(minLength: 4)

            if let disk {
                Text(disk.displayName)
                    .font(.fraunces(size: 22, weight: .regular, italic: true))
                    .foregroundStyle(Color.themeFgDark)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                HStack(spacing: 6) {
                    Text(disk.filesystemLabel)
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Color.dsNormal)
                    Text("·")
                        .foregroundStyle(.tertiary)
                    Text(rwLabel(disk))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                if let ratio = disk.usedRatio {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.white.opacity(0.08))
                            Capsule().fill(Color.dsNormal.opacity(0.85))
                                .frame(width: max(3, geo.size.width * ratio))
                        }
                    }
                    .frame(height: 5)
                    .padding(.top, 4)
                }
            } else {
                Text("—")
                    .font(.fraunces(size: 28, weight: .regular, italic: true))
                    .foregroundStyle(.tertiary)
                Text(L10n.t("manage.empty", zh: "没有外接磁盘", en: "No external disks", language: lang))
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
            }

            Spacer(minLength: 0)

            Button {
                openDiskManage()
            } label: {
                Text(L10n.t("module.manage.open", zh: "打开管理", en: "Open manage", language: lang))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.dsNormal)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.dsNormal.opacity(0.16)))
            }
            .buttonStyle(.plain)
            .padding(.top, 6)
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .contentShape(Rectangle())
        .onTapGesture { openDiskManage() }
    }

    private func rwLabel(_ disk: DiskInfo) -> String {
        switch disk.ntfsAccess(extensionOn: formatter.ntfsKitAvailable) {
        case .writable:
            return L10n.t("manage.chip.rw", zh: "可写", en: "R/W", language: lang)
        case .needsRemount:
            return L10n.t("manage.chip.remount", zh: "待重挂", en: "Remount", language: lang)
        case .extensionOff:
            return L10n.t("manage.chip.ro", zh: "只读", en: "R/O", language: lang)
        case .unmounted:
            return L10n.t("manage.chip.unmounted", zh: "未挂载", en: "Unmounted", language: lang)
        case .notNTFS:
            if disk.isVolumeWritable == true {
                return L10n.t("manage.chip.rw", zh: "可写", en: "R/W", language: lang)
            }
            if disk.isVolumeWritable == false {
                return L10n.t("manage.chip.ro", zh: "只读", en: "R/O", language: lang)
            }
            return "—"
        }
    }
}
