import SwiftUI

/// 多盘选择器(顶栏用,Menu 形态)
/// fire 4:列出 watchedDisks,选中态高亮,点击切换 monitor.selectedDiskUUID
///         每行显示:Volume 名 / 当前温度 / 健康度 badge
/// v0.9.1 polish-O2:接 `disk: DiskInfo?` 参数(由 PopoverView 显式注入
/// `monitor.selectedDisk ?? monitor.watchedDisks.first`),按钮 label 直接用传入 disk
/// 派生 — 让"切盘概念"在 PopoverView 主屏统一(避免 DiskPickerView 内部再走 monitor 派生
/// 跟外部 9 tab Content 选盘分裂)
/// - 弹窗内容仍走 monitor.watchedDisks / monitor.selectedDisk(实时刷新)
/// - 按钮 label 显示走 `disk` 参数(单一来源,跟 9 tab Content 一致)
struct DiskPickerView: View {
    /// v0.9.1 polish-O2:由 PopoverView 显式传入的"当前选中盘"
    /// - 通常是 `monitor.selectedDisk ?? monitor.watchedDisks.first`
    /// - 兜底:无盘 → nil,按钮 label 显 "No disk" + 灰 secondary
    let disk: DiskInfo?

    @Environment(HealthMonitor.self) private var monitor
    @State private var isOpen: Bool = false

    var body: some View {
        Button {
            isOpen.toggle()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: diskIcon)
                    .font(.system(size: 11))
                    .foregroundStyle(monitor.healthLevel.color)
                Text(currentDiskName)
                    .font(.fraunces(size: 12, weight: .medium, italic: true))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Image(systemName: isOpen ? "chevron.up" : "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .frame(maxWidth: 148)
            .background(
                Capsule(style: .continuous)
                    .fill(Color.primary.opacity(0.06))
            )
        }
        .buttonStyle(.plain)
        .popover(isPresented: $isOpen, arrowEdge: .bottom) {
            diskList
        }
    }

    // MARK: - 当前盘显示

    /// v0.9.1 polish-O2:用传入的 `disk` 参数派生按钮 label(单一来源)
    /// - 优先用 `disk`,没有时再走 monitor(防御性,理论上 caller 总会传)
    /// - 无盘 → "No disk" 占位
    private var currentDiskName: String {
        if let d = disk ?? monitor.selectedDisk {
            return d.displayName
        }
        return String(localized: "disk.noDisk", defaultValue: "No disk")
    }

    private var diskIcon: String {
        // v0.9.1 polish-O2:用 disk 参数判断是否有盘,跟 label 来源一致
        (disk ?? monitor.selectedDisk) == nil ? "externaldrive.badge.questionmark" : "externaldrive.fill"
    }

    // MARK: - 弹出列表

    private var diskList: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(String(localized: "disk.watched", defaultValue: "WATCHED DISKS").uppercased())
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .tracking(0.8)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.top, 8)
                .padding(.bottom, 4)

            if monitor.watchedDisks.isEmpty {
                Text(String(localized: "disk.empty", defaultValue: "No external disks — they will appear here when connected"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 2) {
                        ForEach(monitor.watchedDisks, id: \.volumeUUID) { disk in
                            diskRow(disk)
                        }
                    }
                }
            }
        }
        .padding(.bottom, 8)
        .frame(width: 312)
        .frame(maxHeight: 420)
        .background(.regularMaterial)
    }

    private func diskRow(_ disk: DiskInfo) -> some View {
        let isSelected = monitor.selectedDisk?.volumeUUID == disk.volumeUUID
        let temp = monitor.currentByUUID[disk.volumeUUID]?.celsius
        return Button {
            monitor.selectedDiskUUID = disk.volumeUUID
            isOpen = false
        } label: {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 12))
                    .foregroundStyle(isSelected ? Color.dsNormal : .secondary)
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(disk.displayName)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        if disk.mediaKind != .unknown {
                            mediaChip(disk.mediaKind)
                        }
                    }
                    Text(disk.capacityFootnote)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        Text(diskRowSubtitle(disk))
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        if let temp, temp > 0 {
                            Text("\(temp)°")
                                .font(.system(size: 10, weight: .medium, design: .monospaced))
                                .monospacedDigit()
                                .foregroundStyle(Color.dsNormal)
                        }
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isSelected ? Color.dsNormal.opacity(0.10) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func mediaChip(_ kind: DiskInfo.MediaKind) -> some View {
        let ssd = kind == .ssd
        return Text(ssd
            ? String(localized: "disk.kind.ssd", defaultValue: "SSD")
            : String(localized: "disk.kind.hdd", defaultValue: "HDD"))
            .font(.system(size: 8, weight: .semibold, design: .monospaced))
            .tracking(0.4)
            .foregroundStyle(ssd ? Color.dsNormal : Color.secondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(
                Capsule(style: .continuous)
                    .fill(ssd ? Color.dsNormal.opacity(0.16) : Color.white.opacity(0.06))
            )
            .overlay(
                Capsule(style: .continuous)
                    .stroke(ssd ? Color.dsNormal.opacity(0.28) : Color.white.opacity(0.10), lineWidth: 0.5)
            )
    }

    // MARK: - helpers

    private func diskRowSubtitle(_ disk: DiskInfo) -> String {
        let speed = disk.interfaceSpeedLabel
        if speed != "—" { return "\(disk.bsdName)  ·  \(speed)" }
        return disk.bsdName
    }

    /// "/Volumes/applelog" → "applelog"
    private func shortenVolumeName(_ path: String) -> String {
        if let last = path.split(separator: "/").last {
            return String(last)
        }
        return path
    }
}
