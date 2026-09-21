import Foundation

/// smartmontools drivedb 精简表：USB VID:PID → 桥芯片和 Linux 能用的透传类型。
/// Darwin 没有 SCSI passthrough，这些盘的传感器在 macOS 上读不到，但用户要的是「有没有温度」的真话。
struct USBBridgeProfile: Equatable, Sendable {
    let vid: String
    let pid: String
    let name: String
    /// Linux smartctl -d，例如 sntasmedia / sntrealtek / sat
    let linuxType: String
    /// 盘上确实有 SMART/温度，只是 macOS 不透传
    let hasSensors: Bool
}

enum USBBridgeCatalog {
    static let profiles: [USBBridgeProfile] = [
        .init(vid: "04e8", pid: "4001", name: "Samsung T7", linuxType: "sntasmedia", hasSensors: true),
        .init(vid: "04e8", pid: "61fb", name: "Samsung T7 Shield", linuxType: "sntasmedia", hasSensors: true),
        .init(vid: "04e8", pid: "61f5", name: "Samsung T5", linuxType: "sat", hasSensors: true),
        .init(vid: "0bda", pid: "9210", name: "Realtek RTL9210", linuxType: "sntrealtek", hasSensors: true),
        .init(vid: "0bda", pid: "9211", name: "Realtek RTL9211", linuxType: "sntrealtek", hasSensors: true),
        .init(vid: "0781", pid: "55ae", name: "SanDisk Extreme", linuxType: "sntasmedia", hasSensors: true),
        .init(vid: "0781", pid: "55af", name: "SanDisk Extreme Pro", linuxType: "sntasmedia", hasSensors: true),
        .init(vid: "0781", pid: "55bb", name: "SanDisk Portable SSD", linuxType: "sntasmedia", hasSensors: true),
        .init(vid: "174c", pid: "2362", name: "ASMedia ASM2362", linuxType: "sntasmedia", hasSensors: true),
        .init(vid: "174c", pid: "2364", name: "ASMedia ASM2364", linuxType: "sntasmedia", hasSensors: true),
        .init(vid: "152d", pid: "0583", name: "JMicron JMS583", linuxType: "sntjmicron", hasSensors: true),
    ]

    static func profile(vid: String?, pid: String?) -> USBBridgeProfile? {
        guard let vid, let pid else { return nil }
        let v = vid.lowercased()
        let p = pid.lowercased()
        return profiles.first { $0.vid == v && $0.pid == p }
    }

    static func profile(matchingName name: String?) -> USBBridgeProfile? {
        guard let name, !name.isEmpty else { return nil }
        let n = name.lowercased()
        if n.contains("t7 shield") { return profiles.first { $0.pid == "61fb" } }
        // 必须是独立词 T7，不能把 Dahua T70 当成三星 T7
        if n.range(of: #"\bt7(?:\s|touch|$)"#, options: .regularExpression) != nil,
           n.contains("samsung") || n.contains("pssd t7") || n.contains("portable ssd t7") {
            return profiles.first { $0.pid == "4001" }
        }
        if n.contains("rtl9210") { return profiles.first { $0.pid == "9210" } }
        return nil
    }
}
