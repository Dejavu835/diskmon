import SwiftUI

/// 总览双宽模块：所有外接盘实时读写。
/// 一眼看完每块盘在不在干活，点一行切当前盘。
struct AllDisksIOModule: View {
    @Environment(HealthMonitor.self) private var monitor
    @Environment(AppSettings.self) private var settings

    @State private var hoveredUUID: String?

    var body: some View {
        let _ = monitor.ioGeneration
        VStack(alignment: .leading, spacing: 10) {
            header
            if monitor.watchedDisks.isEmpty {
                emptyState
            } else {
                diskStack
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 10)
        .frame(
            minWidth: 240, idealWidth: 520, maxWidth: .infinity,
            minHeight: 168, idealHeight: fittedHeight, maxHeight: fittedHeight,
            alignment: .topLeading
        )
        .glass(cornerRadius: 20, withNoise: true)
        .animation(DiskMonMotion.appear, value: diskIDs)
    }

    private var diskIDs: String {
        monitor.watchedDisks.map(\.volumeUUID).joined(separator: ",")
    }

    /// ScrollView 给 unbounded 高度时会落到 idealHeight；以前锁 240 会裁掉第 4 台。
    private var fittedHeight: CGFloat {
        let n = monitor.watchedDisks.count
        if n == 0 { return 200 }
        let header: CGFloat = 34
        let pad: CGFloat = 22
        let row: CGFloat = n >= 4 ? 58 : 66
        let shown = min(max(n, 1), 6)
        return min(520, max(168, header + pad + CGFloat(shown) * row))
    }

    private var compactRows: Bool { monitor.watchedDisks.count >= 4 }

    private var header: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(Color.dsNormal)
                .frame(width: 6, height: 6)
            Text(L10n.t(
                "module.allio.title",
                zh: "全部磁盘 · 实时读写",
                en: "All Disks · Live I/O",
                language: settings.language
            ))
            .font(.system(size: 11, weight: .medium, design: .monospaced))
            .tracking(0.5)
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
            .lineLimit(1)
            Spacer(minLength: 8)
            Text(countLabel)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(.tertiary)
                .monospacedDigit()
            Text("R")
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundStyle(Color.dsNormal)
            Text("W")
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundStyle(.secondary)
        }
    }

    private var countLabel: String {
        let n = monitor.watchedDisks.count
        if settings.language == "en" {
            return n == 1 ? "1 disk" : "\(n) disks"
        }
        return "\(n) 台"
    }

    private var emptyState: some View {
        Text(L10n.t(
            "module.allio.empty",
            zh: "等待外接磁盘…",
            en: "Waiting for external disks…",
            language: settings.language
        ))
        .font(.system(size: 12))
        .foregroundStyle(.tertiary)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    @ViewBuilder
    private var diskStack: some View {
        let disks = monitor.watchedDisks
        let rows = VStack(spacing: 0) {
            ForEach(Array(disks.enumerated()), id: \.element.volumeUUID) { index, disk in
                diskRow(disk)
                    .transition(DiskMonMotion.rowInsert)
                if index < disks.count - 1 {
                    Rectangle()
                        .fill(Color.white.opacity(0.06))
                        .frame(height: 1)
                }
            }
        }
        if disks.count > 6 {
            ScrollView(.vertical, showsIndicators: false) {
                rows
            }
        } else {
            rows
        }
    }

    private func diskRow(_ disk: DiskInfo) -> some View {
        let uuid = disk.volumeUUID
        let selected = monitor.selectedDiskUUID == uuid
            || (monitor.selectedDiskUUID == nil && monitor.watchedDisks.first?.volumeUUID == uuid)
        // 跟折线右端同一点：history 最后两点取峰值，避免 contentTransition 卡在 "0"
        let live = monitor.ioLiveSample(for: uuid)
        let history = monitor.ioHistoryByUUID[uuid] ?? []
        let hovered = hoveredUUID == uuid
        let readBps = live?.readBps ?? 0
        let writeBps = live?.writeBps ?? 0
        return HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(disk.displayName)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.themeFgDark)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Text(rowSubtitle(disk))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                .frame(minWidth: 72, idealWidth: 120, maxWidth: 140, alignment: .leading)

                DualIOChart(history: history, showsAxes: true)
                    .frame(
                        maxWidth: .infinity,
                        minHeight: compactRows ? 34 : 40,
                        idealHeight: compactRows ? 40 : 46,
                        maxHeight: compactRows ? 44 : 52
                    )

                VStack(alignment: .trailing, spacing: 2) {
                    rateLine(
                        label: L10n.t("module.disk.io.read", zh: "读", en: "R", language: settings.language),
                        bps: readBps
                    )
                    rateLine(
                        label: L10n.t("module.disk.io.write", zh: "写", en: "W", language: settings.language),
                        bps: writeBps
                    )
                }
                // 只按 uuid 定身份；速率靠 @Observable 刷新，避免 ioGeneration 每 2s 整行重建
                .id(uuid)
                .fixedSize(horizontal: true, vertical: false)
            }
            .padding(.vertical, compactRows ? 6 : 8)
            .padding(.horizontal, 8)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(rowFill(selected: selected, hovered: hovered))
            )
            .overlay(alignment: .leading) {
                if selected {
                    RoundedRectangle(cornerRadius: 1, style: .continuous)
                        .fill(Color.dsNormal)
                        .frame(width: 2, height: 28)
                        .padding(.leading, 2)
                }
            }
            .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(DiskMonMotion.hover) {
                monitor.selectedDiskUUID = uuid
            }
        }
        .onHover { hovering in
            withAnimation(DiskMonMotion.hover) {
                hoveredUUID = hovering ? uuid : nil
            }
        }
    }

    private func rowSubtitle(_ disk: DiskInfo) -> String {
        let speed = disk.interfaceSpeedLabel
        if speed != "—" { return speed }
        return disk.bsdName
    }

    private func rowFill(selected: Bool, hovered: Bool) -> Color {
        if selected { return Color.dsNormal.opacity(0.10) }
        if hovered { return Color.white.opacity(0.05) }
        return .clear
    }

    private func rateLine(label: String, bps: Double) -> some View {
        let active = bps > 512
        return HStack(spacing: 4) {
            Text(label)
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundStyle(.tertiary)
            Text(ByteFormatter.bps(bps))
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(active ? Color.themeFgDark : .secondary)
                .monospacedDigit()
                .animation(DiskMonMotion.number, value: bps)
        }
    }
}
