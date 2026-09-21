import Foundation

/// Pure SMART text helpers. Kept in DiskMonCore so parse fixtures do not
/// depend on the app target.
public enum SmartParse {
    /// NVMe Data Units are 1000 × 512 bytes.
    public static func nvmeDataUnitsToTB(_ units: Double) -> Double {
        units * 512_000.0 / 1_000_000_000_000.0
    }

    /// smartctl "Data Units Read: 25,213,506 [12.9 TB]" → 12.9
    /// Bare counts are treated as NVMe data units, never as terabytes.
    public static func dataUnitsToTB(_ s: String) -> Double? {
        if let open = s.firstIndex(of: "["),
           let close = s.firstIndex(of: "]"),
           open < close {
            let inside = s[s.index(after: open)..<close]
            let parts = inside.split(separator: " ")
            if parts.count >= 2, let n = Double(parts[0]) {
                switch parts[1].uppercased() {
                case "TB": return n
                case "GB": return n / 1000.0
                case "PB": return n * 1000.0
                case "MB": return n / 1_000_000.0
                default: return n
                }
            }
        }
        let cleaned = s.replacingOccurrences(of: ",", with: "")
            .trimmingCharacters(in: .whitespaces)
        let token = cleaned.split(whereSeparator: { !$0.isNumber && $0 != "." && $0 != "-" }).first
        guard let raw = token, let n = Double(raw), n >= 0 else { return nil }
        if n >= 1000 { return nvmeDataUnitsToTB(n) }
        return n
    }

    /// ATA wear attributes: Normalized VALUE is remaining life (100…0).
    /// RAW is usually an erase count and must not be used as a percent.
    public static func percentageUsedFromWearValue(_ valueToken: String) -> Int? {
        let digits = valueToken.trimmingCharacters(in: .whitespaces)
        guard let v = Int(digits), (0...100).contains(v) else { return nil }
        return 100 - v
    }

    public static func isPlausibleCelsius(_ c: Int) -> Bool {
        (-20...120).contains(c)
    }
}
