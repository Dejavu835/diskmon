import SwiftUI
import SwiftData

/// Export Report 独立窗口 v0.5.0(grok 调研设计)
///
/// 800x500 独立窗口,从 PopoverView 底部按钮 / ⌘E 触发
///
/// === 布局 ===
/// ```
/// ┌────────────────────────────────────────────┐
/// │  报告导出 · Export Report        [X]       │  ← 顶栏
/// ├────────────────────────────────────────────┤
/// │  [Total 1.2K]  [Fields 14]  [Range 7D]     │  ← 3 个 StatCard
/// ├────────────────────────────────────────────┤
/// │  Time Range: [24H | 7D | 30D | ALL]         │  ← Picker
/// │                                              │
/// │  Fields (14 selected):                      │
/// │   ☑ celsius         ☑ percentageUsed        │
/// │   ☑ availableSpare  ☑ mediaErrors           │  ← Checklist
/// │   ☑ powerOnHours    ☑ powerCycles           │  (2-3 列网格)
/// │   ...                                        │
/// │                                              │
/// │  Format:    [CSV | JSON | BOTH]              │  ← Picker
/// │                                              │
/// │              [▷ Export]                      │  ← 按钮(高级交互)
/// └────────────────────────────────────────────┘
/// ```
///
/// === 数据源 ===
/// - `@Environment(\.modelContext)`:SwiftData 查 SmartSnapshot 总数
/// - `ReportExporter` actor:exportCSV / exportJSON / exportBoth
///
/// === 高级交互规范(任务硬要求) ===
/// - 统一缓动:0.3s `Animation.timingCurve(0.2, 0.8, 0.2, 1)`
/// - 数字滚动:`.contentTransition(.numericText(value:))`
/// - hover / focus / press 跟 PopoverView 顶栏按钮一致
/// - 导出后显示成功 banner(3s 自动消失)— "已导出到 ~/Desktop/diskmon-export-XXX.csv"
///
/// === 设计选择 ===
/// - 14 个 SMART 字段全选(默认)— 跟 ReportExporter 的 ExportField.all 对齐
/// - 双格式(BOTH)默认 — 用户最常用场景
/// - 失败显错(Error banner)— 不静默
/// - 导出期间 Export 按钮 disabled + 转 ProgressView
/// - 不 mock / 不凑合 — 总数 nil → "—",失败 throw 显 localizedDescription
///
/// === 不做 ===
/// - 不 emoji
/// - 不改 ReportExporter 内部
/// - 不改 GlassBackground / 5 Preferences 子 View / AppSettings / Localizable.strings
struct ExportView: View {
    @Environment(HealthMonitor.self) private var monitor
    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    // MARK: - 选区状态

    /// 时间范围(24H / 7D / 30D / ALL)— 任务硬规则 4 个选项
    @State private var timeRange: ExportTimeRange = .d7

    /// 选中的字段集(默认全选)— Set 便于 add/remove
    @State private var selectedFields: Set<ExportField> = ExportField.all

    /// 导出格式
    @State private var format: ExportFormat = .both

    // MARK: - 导出状态

    @State private var isExporting: Bool = false
    @State private var lastResult: ExportResult? = nil
    @State private var bannerVisible: Bool = false

    // MARK: - 派生数据

    /// SwiftData 当前范围内的总记录数(随 timeRange 变化)
    private var totalCount: Int {
        let cutoff = timeRange.cutoffDate
        let descriptor = FetchDescriptor<SmartSnapshot>(
            predicate: #Predicate<SmartSnapshot> { $0.timestamp >= cutoff }
        )
        return (try? modelContext.fetchCount(descriptor)) ?? 0
    }

    var body: some View {
        ZStack {
            NoiseOverlay()
                .accessibilityHidden(true)

            VStack(spacing: 14) {
                topBar
                statsRow
                Divider()
                    .background(Color.white.opacity(0.08))
                configSection
                Spacer(minLength: 0)
                exportButtonRow
            }
            .padding(18)
            .overlay(alignment: .bottom) {
                if bannerVisible, let result = lastResult {
                    resultBanner(result)
                        .padding(.horizontal, 18)
                        .padding(.bottom, 80)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
        }
        .frame(minWidth: 480, idealWidth: 600, maxWidth: .infinity,
               minHeight: 320, idealHeight: 400, maxHeight: .infinity)
        .background(
            ResizableWindowConfigurator(minSize: CGSize(width: 480, height: 320))
        )
        .glassChrome(cornerRadius: 16)
    }

    // MARK: - 顶栏

    private var topBar: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "square.and.arrow.up.on.square.fill")
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(Color.dsNormal)
            VStack(alignment: .leading, spacing: 2) {
                Text("报告导出")
                    .font(.fraunces(size: 16, weight: .regular, italic: true))
                    .foregroundStyle(Color.themeFgDark)
                Text("Export Report")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .tracking(0.4)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Close")
            .onHover { hovering in
                if hovering { NSCursor.pointingHand.push() }
                else { NSCursor.pop() }
            }
        }
        .frame(height: 36)
        // v0.9.1 polish-P2:顶栏走真液态玻璃(替换 .regularMaterial,跟主体 .glassChrome 一致)
        .glassChromeUniform(cornerRadius: 12)
    }

    // MARK: - 3 个 StatCard

    private var statsRow: some View {
        let columns = [GridItem(.adaptive(minimum: 140), spacing: 12)]
        return LazyVGrid(columns: columns, spacing: 12) {
            StatCard(
                value: Double(totalCount),
                unit: "条",
                label: "TOTAL RECORDS",
                color: Color.themeFgDark
            )
            StatCard(
                value: Double(selectedFields.count),
                unit: "个",
                label: "SELECTED FIELDS",
                color: Color.dsNormal
            )
            StatCard(
                value: Double(timeRange.daysForCard),
                unit: timeRange == .all ? "ALL" : "DAYS",
                label: "TIME RANGE",
                color: Color.dsWarning
            )
        }
    }

    // MARK: - 配置区(Picker + Checklist + Format)

    private var configSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            // 1) 时间范围
            configRow(
                icon: "calendar",
                title: "时间范围",
                subtitle: "Time Range"
            ) {
                Picker("", selection: $timeRange) {
                    ForEach(ExportTimeRange.allCases) { range in
                        Text(range.label).tag(range)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 360)
            }

            // 2) 字段多选(checklist)
            fieldChecklist

            // 3) 格式
            configRow(
                icon: "doc.on.doc",
                title: "格式",
                subtitle: "Format"
            ) {
                Picker("", selection: $format) {
                    ForEach(ExportFormat.allCases) { f in
                        Text(f.label).tag(f)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 280)
            }
        }
    }

    private func configRow<Content: View>(
        icon: String,
        title: String,
        subtitle: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(alignment: .center, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.themeFgDark)
                    Text(subtitle)
                        .font(.system(size: 11, design: .monospaced))
                        .tracking(0.4)
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(width: 140, alignment: .leading)
            Spacer(minLength: 8)
            content()
        }
    }

    /// 字段多选 checklist(2 列网格)
    private var fieldChecklist: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "checklist")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text("字段选择")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.themeFgDark)
                    Text("Fields (\(selectedFields.count) of \(ExportField.allCases.count) selected)")
                        .font(.system(size: 11, design: .monospaced))
                        .tracking(0.4)
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                // 全选 / 全不选 快捷按钮
                Button {
                    if selectedFields.count == ExportField.allCases.count {
                        selectedFields = []
                    } else {
                        selectedFields = Set(ExportField.allCases)
                    }
                } label: {
                    Text(
                        selectedFields.count == ExportField.allCases.count
                            ? "Clear All" : "Select All"
                    )
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(Color.dsNormal)
                }
                .buttonStyle(.plain)
            }
            // 2 列字段 checklist
            let columns = [
                GridItem(.flexible(), spacing: 8),
                GridItem(.flexible(), spacing: 8)
            ]
            LazyVGrid(columns: columns, alignment: .leading, spacing: 4) {
                ForEach(ExportField.allCases, id: \.self) { field in
                    FieldToggleRow(
                        field: field,
                        isSelected: selectedFields.contains(field)
                    ) {
                        if selectedFields.contains(field) {
                            selectedFields.remove(field)
                        } else {
                            selectedFields.insert(field)
                        }
                    }
                }
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(0.02))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.white.opacity(0.06), lineWidth: 1)
            )
        }
    }

    // MARK: - Export 按钮 + 状态

    private var exportButtonRow: some View {
        HStack(alignment: .center, spacing: 12) {
            // 左:状态文案
            if isExporting {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.7)
                    Text("正在导出…")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            } else if !selectedFields.isEmpty {
                Text("将导出 \(totalCount) 条记录,\(selectedFields.count) 个字段,范围 \(timeRange.label)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            } else {
                Text("至少选择 1 个字段")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Color.dsCritical)
            }
            Spacer()
            // Export 按钮
            ExportButton(
                isExporting: isExporting,
                isEnabled: !selectedFields.isEmpty
            ) {
                runExport()
            }
        }
        .frame(height: 44)
    }

    // MARK: - 导出执行

    private func runExport() {
        guard !isExporting, !selectedFields.isEmpty else { return }
        isExporting = true
        let fields = selectedFields
        let days = timeRange.rangeDays
        let fmt = format
        Task { @MainActor in
            defer { isExporting = false }
            do {
                let exporter = try ReportExporter()
                switch fmt {
                case .csv:
                    let url = try await exporter.exportCSV(
                        include: fields,
                        rangeDays: days
                    )
                    lastResult = .success(urls: [url])
                case .json:
                    let url = try await exporter.exportJSON(
                        include: fields,
                        rangeDays: days
                    )
                    lastResult = .success(urls: [url])
                case .both:
                    // 双格式:并行跑 2 个,actor 内部序列化
                    let (csv, json) = try await exporter.exportBoth()
                    lastResult = .success(urls: [csv, json])
                }
                showBanner()
            } catch {
                lastResult = .failure(message: error.localizedDescription)
                showBanner()
            }
        }
    }

    private func showBanner() {
        withAnimation(.easeOut(duration: 0.2)) {
            bannerVisible = true
        }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            withAnimation(.easeIn(duration: 0.2)) {
                bannerVisible = false
            }
        }
    }

    // MARK: - 成功 / 失败 banner

    private func resultBanner(_ result: ExportResult) -> some View {
        HStack(spacing: 10) {
            Image(systemName: result.iconName)
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(result.iconColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(result.title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.themeFgDark)
                Text(result.detail)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    // v0.6.0 polish-E:多行段落实体加 .lineSpacing(2) 提升可读性
                    .lineSpacing(2)
            }
            Spacer()
            Button {
                withAnimation { bannerVisible = false }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(.regularMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(result.iconColor.opacity(0.3), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.3), radius: 12, y: 4)
    }
}

// MARK: - 字段 toggle 行

/// 字段 toggle 行(单字段 + checkbox)
private struct FieldToggleRow: View {
    let field: ExportField
    let isSelected: Bool
    let onTap: () -> Void

    @State private var isHovered: Bool = false

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 6) {
                Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                    .font(.system(size: 12))
                    .foregroundStyle(isSelected ? Color.dsNormal : .secondary)
                Text(field.displayName)
                    .font(.system(size: 11, weight: .regular, design: .monospaced))
                    .foregroundStyle(isSelected ? Color.themeFgDark : .secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(isHovered ? Color.white.opacity(0.05) : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.15), value: isHovered)
    }
}

// MARK: - Export 按钮(高级交互)

/// Export 按钮(高级交互规范)
private struct ExportButton: View {
    let isExporting: Bool
    let isEnabled: Bool
    let action: () -> Void

    @State private var isHovered: Bool = false
    @State private var isPressed: Bool = false
    @FocusState private var isFocused: Bool

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if isExporting {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.6)
                        .tint(.white)
                } else {
                    Image(systemName: "arrow.down.doc.fill")
                        .font(.system(size: 11, weight: .semibold))
                }
                Text(isExporting ? "导出中…" : "Export")
                    .font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(buttonBg)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(Color.white.opacity(0.15), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled || isExporting)
        .focusable()
        .focusEffectDisabled()
        .focused($isFocused)
        .overlay(focusRing)
        .scaleEffect(isPressed ? 0.97 : 1.0)
        .onHover { isHovered = $0 }
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 0)
                .onChanged { _ in isPressed = true }
                .onEnded { _ in isPressed = false }
        )
        .animation(.easeInOut(duration: 0.12), value: isPressed)
        .animation(
            .timingCurve(0.2, 0.8, 0.2, 1, duration: 0.3),
            value: isHovered
        )
    }

    private var buttonBg: Color {
        if !isEnabled { return Color.gray.opacity(0.3) }
        if isHovered { return Color.dsNormal.opacity(0.9) }
        return Color.dsNormal
    }

    private var focusRing: some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .strokeBorder(Color.white, lineWidth: isFocused ? 2 : 0)
            .padding(isFocused ? 2 : 0)
            .allowsHitTesting(false)
    }
}

// MARK: - 时间范围 / 格式 枚举(UI 用,不进 ReportExporter 内部)

enum ExportTimeRange: String, CaseIterable, Identifiable {
    case h24 = "24H"
    case d7  = "7D"
    case d30 = "30D"
    case all = "ALL"

    var id: String { rawValue }

    var label: String { rawValue }

    /// 截止时间(用于 SwiftData fetchCount)
    var cutoffDate: Date {
        Date().addingTimeInterval(-Double(daysForCard) * 86400.0)
    }

    /// ReportExporter 用的 rangeDays 参数
    var rangeDays: Int {
        switch self {
        case .h24: return 1
        case .d7:  return 7
        case .d30: return 30
        case .all: return 3650  // 10 年 ≈ 全部
        }
    }

    /// StatCard 显示的数字
    /// - ALL 显示 0(StatCard 用 "ALL" 单位标识)
    var daysForCard: Int {
        switch self {
        case .h24: return 1
        case .d7:  return 7
        case .d30: return 30
        case .all: return 0
        }
    }
}

enum ExportFormat: String, CaseIterable, Identifiable {
    case csv  = "CSV"
    case json = "JSON"
    case both = "BOTH"

    var id: String { rawValue }

    var label: String { rawValue }
}

// MARK: - ExportField 显示名扩展(UI 层)— 不动 ReportExporter

extension ExportField {
    /// UI 显示名(中文优先,跟主人审美一致)
    var displayName: String {
        switch self {
        case .timestamp:              return "时间戳"
        case .diskUUID:               return "盘 UUID"
        case .granularity:            return "粒度"
        case .celsius:                return "温度 (℃)"
        case .availableSpare:         return "可用备用块 (%)"
        case .percentageUsed:         return "寿命消耗 (%)"
        case .mediaErrors:            return "介质错误数"
        case .unsafeShutdowns:        return "不安全关机数"
        case .powerOnHours:           return "通电小时数"
        case .powerCycles:            return "通电循环数"
        case .dataUnitsReadTB:        return "已读数据 (TB)"
        case .dataUnitsWrittenTB:     return "已写数据 (TB)"
        case .criticalWarningRaw:     return "关键警告位"
        case .warningCompTempTime:    return "警告温度累计"
        case .criticalCompTempTime:   return "严重温度累计"
        case .cumulativeEnergyKWh:    return "累计能耗 (kWh)"
        case .powerConsumptionWatts:  return "额定峰值功耗 (W)"
        }
    }
}

// MARK: - 导出结果(给 banner 用)

enum ExportResult {
    case success(urls: [URL])
    case failure(message: String)

    var iconName: String {
        switch self {
        case .success: "checkmark.circle.fill"
        case .failure: "exclamationmark.triangle.fill"
        }
    }

    var iconColor: Color {
        switch self {
        case .success: Color.dsNormal
        case .failure: Color.dsCritical
        }
    }

    var title: String {
        switch self {
        case .success(let urls):
            return "已导出 \(urls.count) 个文件"
        case .failure:
            return "导出失败"
        }
    }

    var detail: String {
        switch self {
        case .success(let urls):
            // 展示所有 URL 路径(短)
            return urls.map { ($0.path as NSString).abbreviatingWithTildeInPath }
                .joined(separator: "\n")
        case .failure(let msg):
            return msg
        }
    }
}
