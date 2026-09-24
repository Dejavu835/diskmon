import Foundation

/// TBW / Power On Hours 格式化
/// fire 2 骨架:TB → GB 转换 + PO 小时/天 转换
enum ByteFormatter {
    /// TB → 格式化("1.23 TB" / "456 GB")
    static func tb(_ tb: Double) -> String {
        let gb = tb * 1000
        if tb >= 1 {
            return String(format: "%.2f TB", tb)
        }
        return String(format: "%.0f GB", gb)
    }

    /// 小时 → "1y 23d" / "5d 12h"
    static func powerOnHours(_ hours: Int) -> String {
        let days = hours / 24
        let years = days / 365
        let remDays = days % 365
        if years > 0 {
            return "\(years)y \(remDays)d"
        }
        return "\(days)d \(hours % 24)h"
    }

    /// 轴刻度短标签："0" / "800K" / "12M"
    static func bpsShort(_ bps: Double) -> String {
        if bps < 1024 { return "0" }
        if bps < 1024 * 1024 {
            return String(format: "%.0fK", bps / 1024)
        }
        if bps < 1024 * 1024 * 1024 {
            return String(format: "%.0fM", bps / (1024 * 1024))
        }
        return String(format: "%.1fG", bps / (1024 * 1024 * 1024))
    }

    /// 字节/秒 → "12.4 MB/s" / "800 KB/s"；低于 512 B/s 视为空闲 "0"
    static func bps(_ bps: Double?) -> String {
        guard let bps, bps > 512 else { return "0" }
        if bps < 1024 * 1024 {
            return String(format: "%.0f KB/s", bps / 1024)
        }
        if bps < 1024 * 1024 * 1024 {
            return String(format: "%.1f MB/s", bps / (1024 * 1024))
        }
        return String(format: "%.2f GB/s", bps / (1024 * 1024 * 1024))
    }

    /// 字节 → "1.00 TB" / "500 GB"
    static func bytes(_ bytes: Int64) -> String {
        let tb = Double(bytes) / 1_000_000_000_000
        if tb >= 1 {
            return String(format: "%.2f TB", tb)
        }
        let gb = Double(bytes) / 1_000_000_000
        return String(format: "%.0f GB", gb)
    }
}
