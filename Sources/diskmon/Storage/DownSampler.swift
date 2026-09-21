import Foundation
import SwiftData
import DiskMonCore

/// 三级降采样:1s raw → 1min mean/min/max → 1hour mean/min/max
/// 保留期:raw 7 天 / minute 30 天 / hour 1 年
/// 由 HealthMonitor 每 60s 调一次 runScheduled()
struct DownSampler {
    /// 聚合窗口长度
    static let minuteBucketSeconds: TimeInterval = 60
    static let hourBucketSeconds: TimeInterval = 3600
    /// 保留期
    static let rawRetention: TimeInterval = 7 * 86400      // 7 天（可被设置覆盖）
    static let minuteRetention: TimeInterval = 30 * 86400   // 30 天
    static let hourRetention: TimeInterval = 365 * 86400    // 1 年

    /// 跑三级聚合 + 清理过期数据
    /// - Parameters:
    ///   - context: SwiftData ModelContext
    ///   - now: 锚点时间(测 / 模拟用)
    ///   - rawDays: raw 保留天数（来自 AppSettings，nil → 默认 7）
    @MainActor
    static func runScheduled(
        context: ModelContext,
        now: Date = .now,
        rawDays: Int? = nil
    ) {
        upsertMinuteBuckets(context: context, now: now)
        upsertHourBuckets(context: context, now: now)
        let rawKeep: TimeInterval
        if let rawDays, rawDays > 0 {
            rawKeep = TimeInterval(rawDays) * 86400
        } else {
            rawKeep = rawRetention
        }
        pruneOldData(context: context, now: now, rawRetentionOverride: rawKeep)
        try? context.save()
    }

    // MARK: - raw → minute

    @MainActor
    private static func upsertMinuteBuckets(context: ModelContext, now: Date) {
        // 找过去 60s 的 raw(每块盘)
        let lower = now.addingTimeInterval(-minuteBucketSeconds)
        let upper = now
        let raw = SmartSnapshot.granularityRaw
        let minute = SmartSnapshot.granularityMinute
        let descriptor = FetchDescriptor<SmartSnapshot>(
            predicate: #Predicate<SmartSnapshot> { s in
                s.granularity == raw
                && s.timestamp >= lower && s.timestamp <= upper
            }
        )
        guard let samples = try? context.fetch(descriptor) else { return }
        let byUUID = Dictionary(grouping: samples, by: \.diskUUID)
        for (uuid, snaps) in byUUID {
            let cs = snaps.map(\.celsius).filter(SmartParse.isPlausibleCelsius).map(Double.init)
            guard !cs.isEmpty else { continue }
            let mean = cs.reduce(0, +) / Double(cs.count)
            let bucket = floorToBucket(now, bucket: minuteBucketSeconds)
            // 已存在 → 覆盖(后写覆盖前写)
            if let existing = findBucket(
                context: context, uuid: uuid, granularity: minute,
                bucket: bucket
            ) {
                existing.celsius = Int(mean.rounded())
                existing.mediaErrors = snaps.last?.mediaErrors ?? 0
                existing.percentageUsed = snaps.last?.percentageUsed ?? 0
                existing.timestamp = bucket
            } else {
                let snap = SmartSnapshot(
                    diskUUID: uuid, timestamp: bucket,
                    granularity: minute,
                    celsius: Int(mean.rounded()),
                    percentageUsed: snaps.last?.percentageUsed ?? 0,
                    mediaErrors: snaps.last?.mediaErrors ?? 0,
                    warningCompTempTime: snaps.last?.warningCompTempTime ?? 0,
                    criticalCompTempTime: snaps.last?.criticalCompTempTime ?? 0,
                    healthPassed: snaps.last?.healthPassed ?? true
                )
                context.insert(snap)
            }
        }
    }

    // MARK: - minute → hour

    @MainActor
    private static func upsertHourBuckets(context: ModelContext, now: Date) {
        let lower = now.addingTimeInterval(-hourBucketSeconds)
        let upper = now
        let minute = SmartSnapshot.granularityMinute
        let hour = SmartSnapshot.granularityHour
        let descriptor = FetchDescriptor<SmartSnapshot>(
            predicate: #Predicate<SmartSnapshot> { s in
                s.granularity == minute
                && s.timestamp >= lower && s.timestamp <= upper
            }
        )
        guard let samples = try? context.fetch(descriptor) else { return }
        let byUUID = Dictionary(grouping: samples, by: \.diskUUID)
        for (uuid, snaps) in byUUID {
            let cs = snaps.map(\.celsius).filter(SmartParse.isPlausibleCelsius).map(Double.init)
            guard !cs.isEmpty else { continue }
            let mean = cs.reduce(0, +) / Double(cs.count)
            let bucket = floorToBucket(now, bucket: hourBucketSeconds)
            if let existing = findBucket(
                context: context, uuid: uuid, granularity: hour,
                bucket: bucket
            ) {
                existing.celsius = Int(mean.rounded())
                existing.timestamp = bucket
            } else {
                let snap = SmartSnapshot(
                    diskUUID: uuid, timestamp: bucket,
                    granularity: hour,
                    celsius: Int(mean.rounded()),
                    warningCompTempTime: snaps.last?.warningCompTempTime ?? 0,
                    criticalCompTempTime: snaps.last?.criticalCompTempTime ?? 0,
                    healthPassed: snaps.last?.healthPassed ?? true
                )
                context.insert(snap)
            }
        }
    }

    // MARK: - 清理过期

    @MainActor
    private static func pruneOldData(
        context: ModelContext,
        now: Date,
        rawRetentionOverride: TimeInterval? = nil
    ) {
        let rawCutoff = now.addingTimeInterval(-(rawRetentionOverride ?? rawRetention))
        let minCutoff = now.addingTimeInterval(-minuteRetention)
        let hourCutoff = now.addingTimeInterval(-hourRetention)
        let raw = SmartSnapshot.granularityRaw
        let minute = SmartSnapshot.granularityMinute
        let hour = SmartSnapshot.granularityHour

        // raw
        if let olds = try? context.fetch(FetchDescriptor<SmartSnapshot>(
            predicate: #Predicate<SmartSnapshot> { s in
                s.granularity == raw
                && s.timestamp < rawCutoff
            }
        )) {
            olds.forEach { context.delete($0) }
        }
        // minute
        if let olds = try? context.fetch(FetchDescriptor<SmartSnapshot>(
            predicate: #Predicate<SmartSnapshot> { s in
                s.granularity == minute
                && s.timestamp < minCutoff
            }
        )) {
            olds.forEach { context.delete($0) }
        }
        // hour(1 年前)
        if let olds = try? context.fetch(FetchDescriptor<SmartSnapshot>(
            predicate: #Predicate<SmartSnapshot> { s in
                s.granularity == hour
                && s.timestamp < hourCutoff
            }
        )) {
            olds.forEach { context.delete($0) }
        }
    }

    // MARK: - helpers

    @MainActor
    private static func findBucket(
        context: ModelContext, uuid: String, granularity: String, bucket: Date
    ) -> SmartSnapshot? {
        let descriptor = FetchDescriptor<SmartSnapshot>(
            predicate: #Predicate<SmartSnapshot> { s in
                s.diskUUID == uuid
                && s.granularity == granularity
                && s.timestamp == bucket
            }
        )
        return (try? context.fetch(descriptor))?.first
    }

    /// 把 now 取整到 60s/3600s 桶起点
    private static func floorToBucket(_ date: Date, bucket: TimeInterval) -> Date {
        let interval = date.timeIntervalSinceReferenceDate
        let floored = (interval / bucket).rounded(.down) * bucket
        return Date(timeIntervalSinceReferenceDate: floored)
    }
}
