import Foundation

/// 节流:菜单栏刷新 / SwiftData 写盘
/// fire 2 骨架:接口,fire 3 在 HealthMonitor 用
struct Throttle {
    /// 距离上次执行 ≥ interval 才返回 true
    static func shouldFire(
        lastFired: Date?, interval: TimeInterval, now: Date = .now
    ) -> Bool {
        guard let last = lastFired else { return true }
        return now.timeIntervalSince(last) >= interval
    }
}
