import Foundation
import SwiftData

/// 一次 SMART 整快照(SwiftData 持久化)
/// 按 diskUUID + timestamp 定位,可降采样(原始保留,分钟/小时聚合由 DownSampler 生成)
/// v0.2.0:字段扩展到 14 项 + cumulativeEnergyKWh 估算;min/max 复用 warningCompTempTime/criticalCompTempTime
@Model
final class SmartSnapshot {
    @Attribute(.unique) var id: UUID
    /// Volume UUID(不是 BSD Name,跨拔插稳定)
    var diskUUID: String
    var timestamp: Date

    // MARK: - 核心 13 字段(对齐 SmartData)

    var celsius: Int
    var availableSpare: Int
    var percentageUsed: Int
    var mediaErrors: Int
    var unsafeShutdowns: Int
    var powerOnHours: Int
    var powerCycles: Int
    var dataUnitsReadTB: Double
    var dataUnitsWrittenTB: Double
    var criticalWarningRaw: Int
    /// DownSampler 复用:minute / hour 桶的 min(℃)记录在 warningCompTempTime,max 在 criticalCompTempTime
    var warningCompTempTime: Int
    /// DownSampler 复用:minute / hour 桶的 max(℃)记录在 criticalCompTempTime
    var criticalCompTempTime: Int
    var healthPassed: Bool
    /// 累计功耗估算(kWh,同 SmartData.cumulativeEnergyKWh)
    /// 冗余存盘是为了 DiskDetailView 24h 折线计算增量时不用回算 powerOnHours
    var cumulativeEnergyKWh: Double
    /// 标识这次快照的 source(raw / minute / hour)
    var granularity: String

    // MARK: - v0.4.0 wave-4b:运行时功耗字段(可选,默认 nil)
    /// 实时功耗(瓦特),由 PowerService 通过 powermetrics 运行时填充
    /// v0.7 polish-K:优先级 smartctl NVMe Supported Power States 真实解析 > powermetrics 系统估算
    ///   - raw 采样点:smartctl 解析成功 → 用 smartctl 值;失败/无 Power States 块 → PowerService fallback
    ///   - 历史快照(granularity ≠ raw)不填(降采样不重采,保留 raw 原始)
    /// SwiftData 持久化(给 DiskDetailView 24h 实时功耗折线作数据点)
    /// powermetrics / smartctl 都失败 → nil(不凑合假数据)
    var powerConsumptionWatts: Double? = nil

    init(
        diskUUID: String,
        timestamp: Date = .now,
        granularity: String = SmartSnapshot.granularityRaw,
        celsius: Int = 0,
        availableSpare: Int = 100,
        percentageUsed: Int = 0,
        mediaErrors: Int = 0,
        unsafeShutdowns: Int = 0,
        powerOnHours: Int = 0,
        powerCycles: Int = 0,
        dataUnitsReadTB: Double = 0,
        dataUnitsWrittenTB: Double = 0,
        criticalWarningRaw: Int = 0,
        warningCompTempTime: Int = 0,
        criticalCompTempTime: Int = 0,
        healthPassed: Bool = true,
        cumulativeEnergyKWh: Double = 0,
        powerConsumptionWatts: Double? = nil
    ) {
        self.id = UUID()
        self.diskUUID = diskUUID
        self.timestamp = timestamp
        self.granularity = granularity
        self.celsius = celsius
        self.availableSpare = availableSpare
        self.percentageUsed = percentageUsed
        self.mediaErrors = mediaErrors
        self.unsafeShutdowns = unsafeShutdowns
        self.powerOnHours = powerOnHours
        self.powerCycles = powerCycles
        self.dataUnitsReadTB = dataUnitsReadTB
        self.dataUnitsWrittenTB = dataUnitsWrittenTB
        self.criticalWarningRaw = criticalWarningRaw
        self.warningCompTempTime = warningCompTempTime
        self.criticalCompTempTime = criticalCompTempTime
        self.healthPassed = healthPassed
        self.cumulativeEnergyKWh = cumulativeEnergyKWh
        self.powerConsumptionWatts = powerConsumptionWatts
    }

    static let granularityRaw = "raw"
    static let granularityMinute = "minute"
    static let granularityHour = "hour"
}
