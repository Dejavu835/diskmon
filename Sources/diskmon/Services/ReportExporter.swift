import Foundation
import SwiftData

// grok 调研:v0.5.0 report export, CSV + JSON 双格式
//
// === 单一职责 ===
// 从 SwiftData 拉 `SmartSnapshot` 序列,按选定字段集导出到
// `~/Desktop/diskmon-export-{ISO8601 timestamp}.{csv,json}`
//
// === 真实数据源 ===
// - `ModelContainer` 来自 `SwiftDataStack.makeContainer()`(落盘路径:
//   `~/Library/Application Support/com.homecenter.diskmon/diskmon.store`,
//   `ModelConfiguration("diskmon")`,由 SwiftDataStack.swift 集中管理)
// - 拉取 `SmartSnapshot` 走 `FetchDescriptor` + `#Predicate { $0.timestamp >= cutoffDate }`
//   + `SortDescriptor(\.timestamp, order: .forward)`(按时间正序,适合折线图直接画)
//
// === 失败处理(主人硬规则:不凑合) ===
// - SwiftData fetch 失败 → throw `ExportError.fetchFailed`
// - 写文件失败 → throw `ExportError.writeFailed`
// - 容器创建失败 → throw `ExportError.contextCreationFailed`
// - 0 条快照 → 仍生成空文件(CSV 只有 header 行,JSON 是 `[]` 空数组),
//   不报"假数据",不返回 mock
//
// === 并发安全 ===
// - `actor` 隔离 export 入口,避免并发写同一时间戳文件
// - `ModelContainer` 缓存一次(actor 内部 `let`),避免每次方法调都重建容器
// - `ModelContext` 每次方法调用新建(避免 actor reentrancy 期间 context 跨方法复用)
// - `ISO8601DateFormatter` 是 thread-safe,放 `static let` 全 actor 共享
//
// === 已知限制 ===
// - `ModelContext.init(_ container:)` 在 Swift 5.9 + macOS 14 SDK 下要求 SwiftData 1.0+,
//   跟 `SmartSnapshot` 的 `@Model` macro 同一 SDK 版本,一致
// - 30 天 × 1s raw × 5 块盘理论行数 ~13M(实际:7 天 raw + 23 天 minute 降采样后约 3M 行),
//   CSV 文件可能 300-500 MB;留给 Wave 9 端到端验证
// - 文件名 timestamp 用 UTC + 毫秒精度,避免同秒内连点导致覆盖

// MARK: - 导出字段枚举

/// 导出字段集(全 17 个 SmartSnapshot 可观测字段)
/// 顺序与 SmartSnapshot 字段声明顺序一致(grep 友好)
/// v0.5.0:沿用 SmartSnapshot 完整 17 字段;`id` 不导(无业务意义,UUID 还会污染 grep)
///   `healthPassed` 不导(已经从 `criticalWarningRaw` 派生,且后者更原始)
enum ExportField: String, CaseIterable, Codable {
    case timestamp
    case diskUUID
    case granularity
    case celsius
    case availableSpare
    case percentageUsed
    case mediaErrors
    case unsafeShutdowns
    case powerOnHours
    case powerCycles
    case dataUnitsReadTB
    case dataUnitsWrittenTB
    case criticalWarningRaw
    case warningCompTempTime
    case criticalCompTempTime
    case cumulativeEnergyKWh
    case powerConsumptionWatts

    /// Default export set. `cumulativeEnergyKWh` is schema-only (always 0 after
    /// the poh×5W estimate was removed) — keep the case for old files, skip it here.
    static let all: Set<ExportField> = Set(ExportField.allCases).subtracting([.cumulativeEnergyKWh])
}

// MARK: - ReportExporter actor

/// SwiftData → CSV / JSON 报告导出器
/// 用法:
/// ```swift
/// let exporter = try await ReportExporter()
/// let csvURL = try await exporter.exportCSV()            // ~/Desktop/diskmon-export-XXX.csv
/// let jsonURL = try await exporter.exportJSON()          // ~/Desktop/diskmon-export-XXX.json
/// let (csv, json) = try await exporter.exportBoth()      // 同时出 CSV + JSON
/// ```
/// 三个方法都用 `actor` 序列化,并发安全(同一 actor 不会同时跑两个 export)
actor ReportExporter {
    // MARK: - 错误

    /// export 错误(给上层 UI / 日志显错用)
    enum ExportError: Error, LocalizedError {
        /// SwiftData 容器创建失败
        case contextCreationFailed(underlying: Error)
        /// SwiftData fetch 失败
        case fetchFailed(underlying: Error)
        /// 写文件失败
        case writeFailed(path: String, underlying: Error)
        /// 用户 Desktop 不可达(罕见,网络家目录 / 权限被吊销)
        case desktopUnavailable(underlying: Error)
        /// 找不到用户 home(理论上不会发生,系统级 root 环境除外)
        case noHomeDirectory

        var errorDescription: String? {
            switch self {
            case .contextCreationFailed(let err):
                return "Failed to open SwiftData store: \(err.localizedDescription)"
            case .fetchFailed(let err):
                return "Failed to fetch SmartSnapshot: \(err.localizedDescription)"
            case .writeFailed(let path, let err):
                return "Failed to write export file at \(path): \(err.localizedDescription)"
            case .desktopUnavailable(let err):
                return "Desktop folder is unavailable: \(err.localizedDescription)"
            case .noHomeDirectory:
                return "User home directory is not available"
            }
        }
    }

    // MARK: - 私有状态

    /// SwiftData 容器(创建一次,跨方法复用)
    private let container: ModelContainer

    /// ISO 8601 时间戳(UTC),thread-safe,可放 static let 全 actor 共享
    private static let iso8601: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]   // `2026-09-02T15:37:42Z`
        return f
    }()

    // MARK: - Init

    /// 创建 exporter(同步 init,内部只是开 SQLite 句柄)
    /// - 调用方:从非 actor 上下文需 `try await ReportExporter()`(actor init 标准)
    /// - 失败:SwiftData store 不可读(权限 / 磁盘满 / schema 不兼容)→ throw
    init() throws {
        do {
            self.container = try SwiftDataStack.makeContainer()
        } catch {
            throw ExportError.contextCreationFailed(underlying: error)
        }
    }

    // MARK: - 公开 API

    /// 导出 CSV(标准 RFC 4180,UTF-8 BOM)
    /// - Parameters:
    ///   - include: 包含的字段集,默认全 17 字段
    ///   - rangeDays: 拉取最近 N 天的快照,默认 30
    /// - Returns: 写入的文件 URL
    func exportCSV(
        include: Set<ExportField> = ExportField.all,
        rangeDays: Int = 30
    ) async throws -> URL {
        let snaps = try fetchSnapshots(rangeDays: rangeDays)
        let timestamp = Self.makeTimestamp()
        let url = try Self.makeOutputURL(timestamp: timestamp, extension: "csv")
        let csv = Self.renderCSV(snaps: snaps, include: include)
        do {
            try Self.writeFile(url: url, contents: csv, withBOM: true)
        } catch {
            throw ExportError.writeFailed(path: url.path, underlying: error)
        }
        return url
    }

    /// 导出 JSON(pretty-printed,UTF-8,无 BOM)
    /// - Parameters:
    ///   - include: 包含的字段集,默认全 17 字段
    ///   - rangeDays: 拉取最近 N 天的快照,默认 30
    /// - Returns: 写入的文件 URL
    func exportJSON(
        include: Set<ExportField> = ExportField.all,
        rangeDays: Int = 30
    ) async throws -> URL {
        let snaps = try fetchSnapshots(rangeDays: rangeDays)
        let timestamp = Self.makeTimestamp()
        let url = try Self.makeOutputURL(timestamp: timestamp, extension: "json")
        let objects: [[String: Any]] = snaps.map { snap in
            Self.renderJSONObject(snap: snap, include: include)
        }
        do {
            let data = try JSONSerialization.data(
                withJSONObject: objects,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            )
            try data.write(to: url, options: .atomic)
        } catch let error as ExportError {
            throw error
        } catch {
            throw ExportError.writeFailed(path: url.path, underlying: error)
        }
        return url
    }

    /// 一次 fetch + 双格式输出(CSV + JSON 用同 timestamp,便于配对)
    /// - Returns: `(csvURL, jsonURL)` 元组
    func exportBoth() async throws -> (csv: URL, json: URL) {
        let include: Set<ExportField> = ExportField.all
        let rangeDays: Int = 30
        let snaps = try fetchSnapshots(rangeDays: rangeDays)
        // 共享 timestamp,让两个文件名能配对
        let timestamp = Self.makeTimestamp()
        let csvURL = try Self.makeOutputURL(timestamp: timestamp, extension: "csv")
        let jsonURL = try Self.makeOutputURL(timestamp: timestamp, extension: "json")
        // 1) CSV
        let csv = Self.renderCSV(snaps: snaps, include: include)
        do {
            try Self.writeFile(url: csvURL, contents: csv, withBOM: true)
        } catch {
            throw ExportError.writeFailed(path: csvURL.path, underlying: error)
        }
        // 2) JSON
        let objects: [[String: Any]] = snaps.map { snap in
            Self.renderJSONObject(snap: snap, include: include)
        }
        do {
            let data = try JSONSerialization.data(
                withJSONObject: objects,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            )
            try data.write(to: jsonURL, options: .atomic)
        } catch {
            throw ExportError.writeFailed(path: jsonURL.path, underlying: error)
        }
        return (csv: csvURL, json: jsonURL)
    }

    // MARK: - 私有:SwiftData fetch

    /// 拉取最近 N 天的 SmartSnapshot(时间正序)
    /// - 拉所有 granularity(raw / minute / hour)混合,UI 端按需过滤
    /// - 用新 context(actor reentrancy 安全)
    private func fetchSnapshots(rangeDays: Int) throws -> [SmartSnapshot] {
        let context = ModelContext(container)
        let cutoff = Date().addingTimeInterval(-Double(rangeDays) * 86400.0)
        let descriptor = FetchDescriptor<SmartSnapshot>(
            predicate: #Predicate<SmartSnapshot> { $0.timestamp >= cutoff },
            sortBy: [SortDescriptor(\.timestamp, order: .forward)]
        )
        do {
            return try context.fetch(descriptor)
        } catch {
            throw ExportError.fetchFailed(underlying: error)
        }
    }

    // MARK: - 私有:CSV 渲染

    /// 把快照序列渲染为 CSV 字符串(标准 RFC 4180)
    /// - UTF-8 BOM 由 `writeFile` 加
    /// - 行分隔符:`\r\n`(RFC 4180)
    /// - 字段包含 `,` / `"` / `\r` / `\n` → 整字段用 `"` 包,内部 `"` 双写
    private static func renderCSV(
        snaps: [SmartSnapshot],
        include: Set<ExportField>
    ) -> String {
        // 字段顺序:`ExportField.allCases` 序,UI / 二次处理都按这个序
        let orderedFields = ExportField.allCases.filter { include.contains($0) }
        var lines: [String] = []
        // 1) header
        lines.append(orderedFields.map { $0.rawValue }.joined(separator: ","))
        // 2) rows
        for s in snaps {
            let cells: [String] = orderedFields.map { field in
                Self.csvEscape(Self.stringValue(field: field, snap: s))
            }
            lines.append(cells.joined(separator: ","))
        }
        return lines.joined(separator: "\r\n")
    }

    /// 单字段 → CSV 字符串
    /// - Optional nil → 空字符串(CSV 没 null 概念)
    private static func stringValue(field: ExportField, snap: SmartSnapshot) -> String {
        switch field {
        case .timestamp:
            return iso8601.string(from: snap.timestamp)
        case .diskUUID:
            return snap.diskUUID
        case .granularity:
            return snap.granularity
        case .celsius:
            return String(snap.celsius)
        case .availableSpare:
            return String(snap.availableSpare)
        case .percentageUsed:
            return String(snap.percentageUsed)
        case .mediaErrors:
            return String(snap.mediaErrors)
        case .unsafeShutdowns:
            return String(snap.unsafeShutdowns)
        case .powerOnHours:
            return String(snap.powerOnHours)
        case .powerCycles:
            return String(snap.powerCycles)
        case .dataUnitsReadTB:
            return String(snap.dataUnitsReadTB)
        case .dataUnitsWrittenTB:
            return String(snap.dataUnitsWrittenTB)
        case .criticalWarningRaw:
            return String(snap.criticalWarningRaw)
        case .warningCompTempTime:
            return String(snap.warningCompTempTime)
        case .criticalCompTempTime:
            return String(snap.criticalCompTempTime)
        case .cumulativeEnergyKWh:
            return String(snap.cumulativeEnergyKWh)
        case .powerConsumptionWatts:
            // nil → 空字符串
            if let w = snap.powerConsumptionWatts { return String(w) }
            return ""
        }
    }

    /// RFC 4180 CSV 字段转义
    /// - 含 `,` / `"` / `\r` / `\n` → 整字段加 `"`,内部 `"` 双写
    /// - 其余原样返回
    private static func csvEscape(_ s: String) -> String {
        let needsQuoting =
            s.contains(",") || s.contains("\"") || s.contains("\n") || s.contains("\r")
        if !needsQuoting { return s }
        let escaped = s.replacingOccurrences(of: "\"", with: "\"\"")
        return "\"\(escaped)\""
    }

    // MARK: - 私有:JSON 渲染

    /// 单快照 → JSON object([String: Any])
    /// - Date → ISO 8601 字符串(JSONSerialization 不接 Date)
    /// - Optional nil → `NSNull()`(JSON 标准 null)
    /// - 字段顺序:按 `ExportField.allCases` 序,`JSONSerialization` 的 `.sortedKeys` 会重排,
    ///   但 value 内容已固定,UI 端按 key 读,不受 key 顺序影响
    private static func renderJSONObject(
        snap: SmartSnapshot,
        include: Set<ExportField>
    ) -> [String: Any] {
        var obj: [String: Any] = [:]
        for field in ExportField.allCases where include.contains(field) {
            obj[field.rawValue] = Self.jsonValue(field: field, snap: snap)
        }
        return obj
    }

    /// 单字段 → JSON 值(基础类型)
    private static func jsonValue(field: ExportField, snap: SmartSnapshot) -> Any {
        switch field {
        case .timestamp:
            return iso8601.string(from: snap.timestamp)
        case .diskUUID:
            return snap.diskUUID
        case .granularity:
            return snap.granularity
        case .celsius:
            return snap.celsius
        case .availableSpare:
            return snap.availableSpare
        case .percentageUsed:
            return snap.percentageUsed
        case .mediaErrors:
            return snap.mediaErrors
        case .unsafeShutdowns:
            return snap.unsafeShutdowns
        case .powerOnHours:
            return snap.powerOnHours
        case .powerCycles:
            return snap.powerCycles
        case .dataUnitsReadTB:
            return snap.dataUnitsReadTB
        case .dataUnitsWrittenTB:
            return snap.dataUnitsWrittenTB
        case .criticalWarningRaw:
            return snap.criticalWarningRaw
        case .warningCompTempTime:
            return snap.warningCompTempTime
        case .criticalCompTempTime:
            return snap.criticalCompTempTime
        case .cumulativeEnergyKWh:
            return snap.cumulativeEnergyKWh
        case .powerConsumptionWatts:
            // nil → NSNull(JSON 标准 null,而不是 Swift 的 nil 缺失键)
            if let w = snap.powerConsumptionWatts { return w }
            return NSNull()
        }
    }

    // MARK: - 私有:文件 IO

    /// 写文件,可选 UTF-8 BOM
    /// - 原子写(`.atomic`),失败时不会留半截文件
    private static func writeFile(url: URL, contents: String, withBOM: Bool) throws {
        var data = Data()
        if withBOM {
            // UTF-8 BOM:EF BB BF(让 Excel / Numbers 自动识别 UTF-8)
            // 显式 UInt8 字面量(避免 0xEF 被推断成 Int,Data.append 重载要 UInt8)
            let bom: [UInt8] = [0xEF, 0xBB, 0xBF]
            data.append(contentsOf: bom)
        }
        if let payload = contents.data(using: .utf8) {
            data.append(payload)
        }
        try data.write(to: url, options: .atomic)
    }

    // MARK: - 私有:路径 / 时间戳

    /// 文件名 timestamp(UTC,毫秒精度,文件系统安全字符)
    /// - 形如:`2026-09-02T15-37-42-123Z`
    /// - `:` 替 `-`(APFS 支持 `:` 但跨工具 grep / Finder 显示都不友好,主人审美一致)
    /// - 毫秒精度:避免同秒内连点两次 export 覆盖前一文件
    private static func makeTimestamp() -> String {
        // DateFormatter 不是 thread-safe,每次新建
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd'T'HH-mm-ss-SSS'Z'"
        return f.string(from: Date())
    }

    /// 拼出 `~/Desktop/diskmon-export-{timestamp}.{ext}` 完整 URL
    /// - Desktop 缺失时尝试创建(罕见;macOS 默认始终有)
    private static func makeOutputURL(timestamp: String, extension ext: String) throws -> URL {
        // `homeDirectoryForCurrentUser` 在标准 user context 下始终返回 `~/`
        // 极端 root / daemon context 返回空 URL(理论不会发生在 menu bar app)
        let home = FileManager.default.homeDirectoryForCurrentUser
        let desktop: URL
        if home.path.isEmpty {
            throw ExportError.noHomeDirectory
        } else {
            desktop = home.appendingPathComponent("Desktop", isDirectory: true)
        }
        if !FileManager.default.fileExists(atPath: desktop.path) {
            do {
                try FileManager.default.createDirectory(
                    at: desktop, withIntermediateDirectories: true
                )
            } catch {
                throw ExportError.desktopUnavailable(underlying: error)
            }
        }
        return desktop.appendingPathComponent("diskmon-export-\(timestamp).\(ext)")
    }
}
