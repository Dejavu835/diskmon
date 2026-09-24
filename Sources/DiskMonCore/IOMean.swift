import Foundation

public struct IOBucket: Equatable, Sendable, Codable {
    public var at: Date
    public var readBps: Double
    public var writeBps: Double

    public init(at: Date, readBps: Double, writeBps: Double) {
        self.at = at
        self.readBps = readBps
        self.writeBps = writeBps
    }
}

public enum IOWindow: String, Equatable, Sendable, CaseIterable {
    case h1, h24, d7

    public var seconds: TimeInterval {
        switch self {
        case .h1: return 3600
        case .h24: return 86_400
        case .d7: return 7 * 86_400
        }
    }
}

public enum IOMean {
    /// Mean of samples inside `now - window`. Empty window → nils. Does not invent rates.
    public static func mean(
        samples: [IOBucket],
        window: IOWindow,
        now: Date
    ) -> (read: Double?, write: Double?) {
        let start = now.addingTimeInterval(-window.seconds)
        let slice = samples.filter { $0.at >= start && $0.at <= now }
        guard !slice.isEmpty else { return (nil, nil) }
        let n = Double(slice.count)
        let read = slice.reduce(0.0) { $0 + $1.readBps } / n
        let write = slice.reduce(0.0) { $0 + $1.writeBps } / n
        return (read, write)
    }

    /// 24h / 7d mean: completed hour buckets plus **one** fold of the live 2s ring.
    /// Never concatenates raw 2s points with hour buckets — an unweighted mean of
    /// ~1800 live points plus ~24 hour buckets collapses the window to the last hour.
    /// Live points at or before the newest hour bucket are already in that bucket.
    public static func mix(
        hours: [IOBucket],
        live: [IOBucket],
        window: IOWindow,
        now: Date
    ) -> (read: Double?, write: Double?) {
        if window == .h1 {
            return mean(samples: live, window: window, now: now)
        }
        let start = now.addingTimeInterval(-window.seconds)
        let lastHourAt = hours.map(\.at).max()
        let liveStart = lastHourAt.map { max(start, $0) } ?? start
        let liveFresh = live.filter { $0.at > liveStart && $0.at <= now }
        var samples = hours
        if let folded = fold(samples: liveFresh, now: now) {
            samples.append(folded)
        }
        return mean(samples: samples, window: window, now: now)
    }

    /// Mean of a short run of samples (e.g. last 60s of 2s points) as one bucket.
    public static func fold(samples: [IOBucket], now: Date) -> IOBucket? {
        guard !samples.isEmpty else { return nil }
        let n = Double(samples.count)
        let read = samples.reduce(0.0) { $0 + $1.readBps } / n
        let write = samples.reduce(0.0) { $0 + $1.writeBps } / n
        return IOBucket(at: now, readBps: read, writeBps: write)
    }

    /// Append a minute bucket; when 60 minutes or an hour elapsed, emit one hour bucket.
    public static func rollHour(
        minutes: [IOBucket],
        newMinute: IOBucket,
        now: Date,
        maxHours: Int = 168
    ) -> (minutes: [IOBucket], hoursToAppend: IOBucket?) {
        var mins = minutes
        mins.append(newMinute)
        let oldest = mins.first?.at ?? now
        let hourElapsed = now.timeIntervalSince(oldest) >= 3600
        if mins.count >= 60 || hourElapsed {
            if let hour = fold(samples: mins, now: now) {
                return ([], hour)
            }
        }
        if mins.count > 90 { mins = Array(mins.suffix(60)) }
        return (mins, nil)
    }

    public static func cappedHours(_ hours: [IOBucket], now: Date, maxHours: Int = 168) -> [IOBucket] {
        let start = now.addingTimeInterval(-Double(maxHours) * 3600)
        return hours.filter { $0.at >= start }
    }

    /// Drop stale disks and keep the persisted blob small. UserDefaults was holding every UUID forever.
    public static func cappedStore(
        _ store: [String: [IOBucket]],
        now: Date,
        maxHours: Int = 168,
        maxDisks: Int = 8
    ) -> [String: [IOBucket]] {
        let trimmed = store.compactMapValues { buckets -> [IOBucket]? in
            let kept = cappedHours(buckets, now: now, maxHours: maxHours)
            return kept.isEmpty ? nil : kept
        }
        if trimmed.count <= maxDisks { return trimmed }
        let ranked = trimmed.sorted { lhs, rhs in
            (lhs.value.last?.at ?? .distantPast) > (rhs.value.last?.at ?? .distantPast)
        }
        return Dictionary(uniqueKeysWithValues: ranked.prefix(maxDisks).map { ($0.key, $0.value) })
    }

    public static func formatMBps(_ bps: Double) -> String {
        let mb = bps / 1_000_000.0
        if mb < 0.05 { return "0" }
        if mb < 10 { return String(format: "%.1f", mb) }
        return String(format: "%.0f", mb)
    }
}
