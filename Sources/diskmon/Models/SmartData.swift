import Foundation
import SwiftUI  // v0.9.3:HealthLabel.color 用 Color 类型
import DiskMonCore

/// NVMe SMART 关键字段(从 smartctl -a -d nvme 解析)
/// v0.2.0:字段扩展到 NVMe Log Page 0x02 全 16 字段,增加累计功耗估算
/// v0.7 polish-K:全部 SMART 字段改 optional,避免 partial parse 时假"健康=0"
///   - 旧版默认值都是 0/false/true,smartctl 某次解析缺字段就会显示"全 0 健康"
///   - 改 optional 后,nil = "未采集" → UI 显 "—",区分"真健康"和"不知道"
///   - powerConsumptionWatts(v0.4.0 wave-4b 已存在)改真实 NVMe Supported Power States 解析
///   - 删累计功耗估算(5W × hours 估算,主人 grok 调研:不是真值,改 nil 拒绝展示假数据)
///   字段集对齐 fire 1 RESEARCH §4
struct SmartData: Equatable, Codable {
    // MARK: - 基础信息

    var modelNumber: String = ""
    var serialNumber: String = ""
    var firmwareVersion: String = ""

    // MARK: - 温度 / 健康度

    /// 当前温度(℃)— nil = 未采集
    var celsius: Int? = nil
    /// SMART overall-health self-assessment test result — nil = 未采集
    /// (空输出或解析失败时不应假定 "PASSED=true" 健康)
    var healthPassed: Bool? = nil

    // MARK: - NVMe 关键字段(13 项)— 全部 optional,partial parse 友好

    /// Critical Warning(0x02 byte 0,NVMe Log Page 0x02 offset 0)— nil = 未采集
    var criticalWarningRaw: Int? = nil
    /// 寿命(Percentage Used,NVMe 0x02 byte 3) — 0 = 新,100 = 命终
    /// 实际寿命% = 100 - percentageUsed — nil = 未采集
    var percentageUsed: Int? = nil
    /// 备块(NVMe 0x02 byte 4)— nil = 未采集
    var availableSpare: Int? = nil
    /// 介质错误(NVMe 0x02 byte 11..12)— nil = 未采集
    var mediaErrors: Int? = nil
    /// 异常断电(NVMe 0x07)— nil = 未采集
    var unsafeShutdowns: Int? = nil
    /// 上电小时(NVMe 0x09)— nil = 未采集
    var powerOnHours: Int? = nil
    /// 上电循环(NVMe 0x0C)— nil = 未采集
    var powerCycles: Int? = nil
    /// 数据读取(NVMe 0x06,单位 TB,已 / 2^20 转)— nil = 未采集
    var dataUnitsReadTB: Double? = nil
    /// 数据写入(NVMe 0x06,单位 TB,已 / 2^20 转)— nil = 未采集
    var dataUnitsWrittenTB: Double? = nil
    /// 警告温度持续时间(NVMe 0xC8,单位 min)— nil = 未采集
    var warningCompTempTime: Int? = nil
    /// 严重温度持续时间(NVMe 0xC9,单位 min)— nil = 未采集
    var criticalCompTempTime: Int? = nil

    // MARK: - v0.4.0 wave-4b + v0.7 polish-K:真实 per-disk 功耗

    /// Rated peak watts (max operational NVMe power state). Not live draw.
    var nvmePowerStates: [NVMePowerState] = []

    /// 额定峰值功耗(瓦特)— NVMe Supported Power States 工作态 max 的最大值。不是实时功率。
    /// v0.4.0 wave-4b 原值是 powermetrics 系统 SoC 估算(由 PowerService 运行时回填)
    /// v0.7 polish-K 改:smartctl parse 时从 "Supported Power States" 块第一状态行拿 max watt
    ///   - 真实 per-disk 硬件功耗(NVMe spec 标准字段,smartctl 7.5 实测存在)
    ///   - 失败 / 无 Supported Power States 块 → nil
    ///   - 该字段既走 smartctl 解析(填真实值),也兼容 PowerService 运行时回填
    ///   - SwiftData 不持久化(SmartSnapshot 单独存 SmartSnapshot.powerConsumptionWatts)
    var powerConsumptionWatts: Double? = nil

    /// 传感器/寿命字段有任意一项即视为抓到了 SMART（身份字符串不算）。
    var hasSensorFields: Bool {
        celsius != nil || percentageUsed != nil || availableSpare != nil
            || powerOnHours != nil || mediaErrors != nil || healthPassed != nil
            || powerCycles != nil || unsafeShutdowns != nil
            || dataUnitsReadTB != nil || dataUnitsWrittenTB != nil
            || criticalWarningRaw != nil
    }

    /// `self` 优先（通常是 smartctl），空字段用 fallback（diskutil/IOKit）补。
    func overlaying(_ fallback: SmartData?) -> SmartData {
        guard let f = fallback else { return self }
        var out = self
        if out.celsius == nil { out.celsius = f.celsius }
        if out.healthPassed == nil { out.healthPassed = f.healthPassed }
        if out.criticalWarningRaw == nil { out.criticalWarningRaw = f.criticalWarningRaw }
        if out.percentageUsed == nil { out.percentageUsed = f.percentageUsed }
        if out.availableSpare == nil { out.availableSpare = f.availableSpare }
        if out.mediaErrors == nil { out.mediaErrors = f.mediaErrors }
        if out.unsafeShutdowns == nil { out.unsafeShutdowns = f.unsafeShutdowns }
        if out.powerOnHours == nil { out.powerOnHours = f.powerOnHours }
        if out.powerCycles == nil { out.powerCycles = f.powerCycles }
        if out.dataUnitsReadTB == nil { out.dataUnitsReadTB = f.dataUnitsReadTB }
        if out.dataUnitsWrittenTB == nil { out.dataUnitsWrittenTB = f.dataUnitsWrittenTB }
        if out.warningCompTempTime == nil { out.warningCompTempTime = f.warningCompTempTime }
        if out.criticalCompTempTime == nil { out.criticalCompTempTime = f.criticalCompTempTime }
        if out.powerConsumptionWatts == nil { out.powerConsumptionWatts = f.powerConsumptionWatts }
        if out.nvmePowerStates.isEmpty { out.nvmePowerStates = f.nvmePowerStates }
        if out.modelNumber.isEmpty { out.modelNumber = f.modelNumber }
        if out.serialNumber.isEmpty { out.serialNumber = f.serialNumber }
        if out.firmwareVersion.isEmpty { out.firmwareVersion = f.firmwareVersion }
        return out
    }
}

// grok 调研:v0.7 polish-K, 字段改 optional 防 partial parse 假健康;新增 powerConsumptionWatts 真实 per-disk 功耗
//   删 cumulativeEnergyKWh 计算属性(5W × hours 估算,主人硬规则:宁可"做不到"也不要假数据)
//   删 powerConsumptionWatts 同时也由 PowerService powermetrics 运行时回填,
//     两路并存,UI 优先级 smartctl 解析值 > powermetrics 估算
//
// v0.9.3 健康 UX 升级(grok 3 调研,DriveDx 风格):
//   - SMART 字段加 SmartFieldMetadata(人类可读名 + 描述 + 严重度)
//   - 健康度 0-100 评分 → 4 标签(GOOD / AVERAGE / LOW / BAD)
//   - 字段非零 + 严重度 .critical → 醒目 amber 边框 + "Backup now" CTA
//   - 健康度 4 标签对应 4 档 actionable 文案

// MARK: - v0.9.3:FieldSeverity 字段严重度(SMART 字段分类)

/// SMART 字段严重度等级(v0.9.3)
/// - `.info`    :只读信息(寿命、通电时间、写入量)— 无阈值,只展示
/// - `.context` :阈值上下有意义,但非危险(unsafeShutdowns、percentageUsed、availableSpare)
/// - `.warning` :接近危险线(暂时未用,留扩展位)
/// - `.critical`:危险信号,非零即需要立即备份(mediaErrors / criticalWarningRaw bit0/bit4)
enum FieldSeverity: String, Codable, CaseIterable {
    case info
    case context
    case warning
    case critical
}

// MARK: - v0.9.3:SmartFieldMetadata 字段元数据(人类可读 + 描述 + 严重度)

/// SMART 字段元数据(v0.9.3 DriveDx 风格)
/// - `humanReadableName` :普通人能看懂的字段名(取代 "Available Spare" 这种 jargon,虽然已经较 OK)
///   - 任务规范字段列表里部分有具体中文翻译(任务文档),但代码内部用英文保持 i18n 一致
/// - `description`       :1 句 actionable 描述(DriveDx 风:不是 "reallocated sectors = 5"
///   而是 "Replace disk soon. Backup data now.")
/// - `severity`          :字段严重度(配合 SMARTModule 渲染,非零 + .critical → amber 边框 + CTA)
/// - `amberTrigger`      :什么时候该 amber 边框 + "Backup now" CTA
///   - `.alwaysIfNonZero`        :非零即触发(mediaErrors)
///   - `.ifBit0Or4NonZero`       :criticalWarningRaw 特殊 — bit0 或 bit4 触发(bit1/2/3 不算)
///   - `.never`                  :不触发(info 字段 + 某些 context 字段)
struct SmartFieldMetadata {
    enum AmberTrigger {
        case alwaysIfNonZero
        case ifBit0Or4NonZero
        case never
    }

    let humanReadableName: String
    let description: String
    let severity: FieldSeverity
    let amberTrigger: AmberTrigger
}

// MARK: - v0.9.3:SmartFieldMetadata 字典(按 SMART 字段 ID 索引)

extension SmartFieldMetadata {
    /// 10 项真 NVMe SMART 字段的元数据(v0.9.3)
    /// 字段 ID 跟 SMARTModule.SMARTField.id 对齐(mediaErrors / criticalWarning / availableSpare / ...):
    /// - humanReadableName:任务规范字段名(中文翻译,但代码里用英文保持 i18n 一致)
    ///   - 注:任务给的字段名是中文,但现有 SMARTModule 用的字段名是 "Media Errors" / "Critical Warning" 等
    ///   - 任务硬规则:不改 Localizable.strings,所以 metadata 字段名直接硬编码英文
    ///     跟现有 SMARTField.name 走同一 i18n key
    /// - description:DriveDx 风 actionable 文案(非 jargon)
    /// - severity:字段严重度(决定 SMARTModule 行内颜色 + 是否触发 amber 边框)
    /// - amberTrigger:决定是否加 amber 边框 + "Backup now" CTA
    static let byID: [String: SmartFieldMetadata] = [
        "mediaErrors": SmartFieldMetadata(
            humanReadableName: "Media Errors",
            description: "Drive counted uncorrectable read errors. Replace if > 0.",
            severity: .critical,
            amberTrigger: .alwaysIfNonZero
        ),
        "criticalWarning": SmartFieldMetadata(
            // 任务规范里 bit0 + bit4 拆开说,但 metadata 是字段级,这里用统一的 critical 描述
            // 实际渲染时 SMARTModule 可针对 bit 拆分,这里保留字段级兜底
            humanReadableName: "Critical Warning",
            description: "NVMe hardware alert (spare low / backup failed). Run SMART self-test.",
            severity: .critical,
            amberTrigger: .ifBit0Or4NonZero
        ),
        "availableSpare": SmartFieldMetadata(
            humanReadableName: "Available Spare",
            description: "Lower = closer to wear-out. < 10% = replace soon.",
            severity: .context,
            amberTrigger: .never
        ),
        "percentageUsed": SmartFieldMetadata(
            humanReadableName: "Lifetime Used",
            description: "Higher = more wear. > 90% = backup + replace soon.",
            severity: .context,
            amberTrigger: .never
        ),
        "unsafeShutdowns": SmartFieldMetadata(
            humanReadableName: "Unsafe Shutdowns",
            description: "Power loss without clean unmount. Backup important data.",
            severity: .context,
            amberTrigger: .never
        ),
        "powerOnHours": SmartFieldMetadata(
            humanReadableName: "Power-On Hours",
            description: "Total hours the drive has been powered on.",
            severity: .info,
            amberTrigger: .never
        ),
        "powerCycles": SmartFieldMetadata(
            humanReadableName: "Power Cycles",
            description: "Total power-on events since manufacture.",
            severity: .info,
            amberTrigger: .never
        ),
        "dataRead": SmartFieldMetadata(
            humanReadableName: "Data Read",
            description: "Total data read since manufacture. Higher = more wear.",
            severity: .info,
            amberTrigger: .never
        ),
        "dataWritten": SmartFieldMetadata(
            humanReadableName: "Data Written",
            description: "Higher = more wear. Monitor for abnormal spikes.",
            severity: .context,
            amberTrigger: .never
        ),
        "powerConsumption": SmartFieldMetadata(
            humanReadableName: "Power Draw (max)",
            description: "Max rated watt from NVMe Supported Power States.",
            severity: .info,
            amberTrigger: .never
        )
    ]

    /// 字段元数据获取(找不到时兜底返回空 metadata,SMARTModule 不崩)
    /// - Parameters:
    ///   - id:SMART 字段 ID(对齐 SMARTModule.SMARTField.id)
    /// - Returns:metadata,或兜底(空描述 + .info)
    static func metadata(for id: String) -> SmartFieldMetadata {
        if let m = byID[id] { return m }
        return SmartFieldMetadata(
            humanReadableName: id,
            description: "",
            severity: .info,
            amberTrigger: .never
        )
    }

    /// Settings language, not system locale. Empty id → original English.
    static func localizedName(id: String, language: String) -> String {
        switch id {
        case "mediaErrors":
            return L10n.t("smart.mediaErrors", zh: "介质错误", en: "Media Errors", language: language)
        case "criticalWarning":
            return L10n.t("smart.criticalWarningRaw", zh: "严重告警", en: "Critical Warning", language: language)
        case "availableSpare":
            return L10n.t("smart.availableSpare", zh: "备块", en: "Available Spare", language: language)
        case "percentageUsed":
            return L10n.t("smart.percentageUsed", zh: "寿命", en: "Lifetime Used", language: language)
        case "unsafeShutdowns":
            return L10n.t("smart.unsafeShutdowns", zh: "异常断电", en: "Unsafe Shutdowns", language: language)
        case "powerOnHours":
            return L10n.t("smart.powerOnHours", zh: "上电时间", en: "Power-On Hours", language: language)
        case "powerCycles":
            return L10n.t("smart.powerCycles", zh: "上电循环", en: "Power Cycles", language: language)
        case "dataRead":
            return L10n.t("smart.dataRead", zh: "数据读取", en: "Data Read", language: language)
        case "dataWritten":
            return L10n.t("smart.dataWritten", zh: "数据写入", en: "Data Written", language: language)
        case "powerConsumption":
            return L10n.t("smart.powerDraw", zh: "功耗", en: "Power Draw (max)", language: language)
        default:
            return byID[id]?.humanReadableName ?? id
        }
    }

    static func localizedDescription(id: String, language: String) -> String {
        switch id {
        case "mediaErrors":
            return L10n.t("smart.desc.mediaErrors", zh: "盘记录了无法纠正的读错误。大于 0 应更换。", en: "Drive counted uncorrectable read errors. Replace if > 0.", language: language)
        case "criticalWarning":
            return L10n.t("smart.desc.criticalWarning", zh: "NVMe 硬件告警（备块不足 / 备份失败）。请跑 SMART 自检。", en: "NVMe hardware alert (spare low / backup failed). Run SMART self-test.", language: language)
        case "availableSpare":
            return L10n.t("smart.desc.availableSpare", zh: "越低越接近磨损。低于 10% 应尽快更换。", en: "Lower = closer to wear-out. < 10% = replace soon.", language: language)
        case "percentageUsed":
            return L10n.t("smart.desc.percentageUsed", zh: "越高磨损越多。超过 90% 请备份并准备更换。", en: "Higher = more wear. > 90% = backup + replace soon.", language: language)
        case "unsafeShutdowns":
            return L10n.t("smart.desc.unsafeShutdowns", zh: "未正常卸载就掉电。请备份重要数据。", en: "Power loss without clean unmount. Backup important data.", language: language)
        case "powerOnHours":
            return L10n.t("smart.desc.powerOnHours", zh: "磁盘累计通电时间。", en: "Total hours the drive has been powered on.", language: language)
        case "powerCycles":
            return L10n.t("smart.desc.powerCycles", zh: "出厂以来累计通电次数。", en: "Total power-on events since manufacture.", language: language)
        case "dataRead":
            return L10n.t("smart.desc.dataRead", zh: "出厂以来累计读取。越高磨损越多。", en: "Total data read since manufacture. Higher = more wear.", language: language)
        case "dataWritten":
            return L10n.t("smart.desc.dataWritten", zh: "累计写入。越高磨损越多，注意异常跳升。", en: "Higher = more wear. Monitor for abnormal spikes.", language: language)
        case "powerConsumption":
            return L10n.t("smart.desc.powerDraw", zh: "NVMe 功耗状态表给出的额定最大瓦数。", en: "Max rated watt from NVMe Supported Power States.", language: language)
        default:
            return byID[id]?.description ?? ""
        }
    }
}

// MARK: - v0.9.3:HealthLabel 健康度 4 标签(DriveDx 风格)

/// v0.9.3 健康度 4 标签(DriveDx 风格:grok 3 调研 2025-09)
/// - 取代 4 段 .none/.warning/.critical/.danger 内部枚举,只暴露 4 档 DriveDx 标签
/// - 阈值(基于 0-100 评分):
///   - GOOD     :80-100(健康,琥珀色,主人审美"不引入绿")
///   - AVERAGE  :50-79(可观察,蓝色)
///   - LOW      :20-49(危险,黄色,需备份)
///   - BAD      :0-19  (立即更换,红色,马上备份)
/// - 跟 HealthPredictor.healthScore(for:) 输出对齐(0/30/60/100,4 档)
/// - UI 端只要把 0-100 分转 label,具体颜色 + 文案都在这里
enum HealthLabel: String, CaseIterable {
    case good
    case average
    case low
    case bad
    /// v0.9.4:无 SMART 数据时的"未知"标签 — 区别于 .good(避免误显 "GOOD 100/100")
    /// - 颜色次色(.secondary),不动 ds* 体系
    /// - 文案 "Unknown" + "No SMART data available"
    case unknown

    /// DriveDx 标签显示名
    var displayName: String {
        switch self {
        case .good:    "GOOD"
        case .average: "AVERAGE"
        case .low:     "LOW"
        case .bad:     "BAD"
        case .unknown: "UNKNOWN"
        }
    }

    /// DriveDx 标签颜色 token
    /// - .good    → 琥珀(Color.dsNormal)— 主人审美"不引入绿",健康用琥珀
    /// - .average → 蓝色(token: dsInfo)— DriveDx 风,新加 token
    /// - .low     → 黄色(token: dsLow)— DriveDx 风,新加 token
    /// - .bad     → 红色(token: dsDanger)— 复用已有 danger 红
    /// - .unknown → 次色(.secondary)— 主人 bug 修复:无数据时不显绿色琥珀假象
    /// - 颜色定义在 HealthLevel.swift 扩展(本文件不重复定义,跟现有 ds* 体系一致)
    var color: Color {
        switch self {
        case .good:    .dsNormal
        case .average: .dsInfo
        case .low:     .dsLow
        case .bad:     .dsDanger
        case .unknown: .secondary
        }
    }

    /// DriveDx 标签 actionable 摘要文案
    /// - 1 行讲清"现在该干什么"(grok 调研:不要 false-positive,不要 jargon dump)
    /// - good    :"Slow decline over years is normal" / "Backup monthly"
    /// - average :"Some attributes approaching limits. Monitor weekly."
    /// - low     :"Replace disk within 30 days. Backup immediately."
    /// - bad     :"Replace disk NOW. Backup data immediately. Run SMART self-test to confirm."
    /// - unknown :"No SMART data available" — 主人硬规则"不 mock"
    var actionableSummary: String {
        switch self {
        case .good:
            "Slow decline over years is normal. Backup monthly."
        case .average:
            "Some attributes approaching limits. Monitor weekly."
        case .low:
            "Replace disk within 30 days. Backup immediately."
        case .bad:
            "Replace disk NOW. Backup data immediately. Run SMART self-test to confirm."
        case .unknown:
            "No SMART data available"
        }
    }

    /// 0-100 分 → 4 标签
    /// - 阈值(任务硬规则):80+ good / 50-79 average / 20-49 low / < 20 bad
    /// - 输入 nil(无 SMART 数据)→ .unknown(v0.9.4:从 .good 改 .unknown,避免 100/100 假象)
    static func label(for score: Int?) -> HealthLabel {
        guard let s = score else { return .unknown }
        if s >= 80 { return .good }
        if s >= 50 { return .average }
        if s >= 20 { return .low }
        return .bad
    }
}
