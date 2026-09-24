import Foundation
import SwiftData

/// ModelContainer 工厂
/// 落盘路径:~/Library/Application Support/com.homecenter.diskmon/diskmon.store
/// Schema:SmartSnapshot(14 字段) + TemperatureSample(单点温度)
enum SwiftDataStack {
    static let appSupportDir: URL = {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!.appendingPathComponent("com.homecenter.diskmon", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: base, withIntermediateDirectories: true
        )
        return base
    }()

    static func makeContainer() throws -> ModelContainer {
        let schema = Schema([SmartSnapshot.self, TemperatureSample.self])
        let config = ModelConfiguration(
            "diskmon",
            schema: schema,
            isStoredInMemoryOnly: false,
            allowsSave: true,
            cloudKitDatabase: .none   // 本地,不上云
        )
        return try ModelContainer(for: schema, configurations: config)
    }
}
