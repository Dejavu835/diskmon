import Foundation
import SwiftData

/// 单点温度样本(SwiftData 持久化)
/// 按 diskUUID + timestamp + granularity 三元组定位
/// granularity: "raw" / "minute" / "hour"
@Model
final class TemperatureSample {
    @Attribute(.unique) var id: UUID
    var diskUUID: String
    var timestamp: Date
    var celsius: Double
    var granularity: String

    init(diskUUID: String, celsius: Double, granularity: String) {
        self.id = UUID()
        self.diskUUID = diskUUID
        self.timestamp = .now
        self.celsius = celsius
        self.granularity = granularity
    }
}
