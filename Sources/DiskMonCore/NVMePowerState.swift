import Foundation

/// One row from smartctl "Supported Power States". Max watts are rated, not live draw.
public struct NVMePowerState: Equatable, Sendable, Codable, Identifiable {
    public var index: Int
    public var operational: Bool
    public var maxWatts: Double
    public var id: Int { index }

    public init(index: Int, operational: Bool, maxWatts: Double) {
        self.index = index
        self.operational = operational
        self.maxWatts = maxWatts
    }
}

public enum NVMePowerStateParser {
    /// " 0 +     6.50W    …"  /  " 3 -   0.0500W …"
    public static func parseLine(_ line: String) -> NVMePowerState? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard let first = trimmed.first, first.isNumber else { return nil }
        let parts = trimmed.split(whereSeparator: { $0 == " " || $0 == "\t" })
        guard parts.count >= 3,
              let index = Int(parts[0]) else { return nil }
        let op = String(parts[1])
        guard op == "+" || op == "-" else { return nil }
        var maxStr = String(parts[2])
        if maxStr.hasSuffix("W") { maxStr.removeLast() }
        guard let watts = Double(maxStr), watts >= 0 else { return nil }
        return NVMePowerState(index: index, operational: op == "+", maxWatts: watts)
    }

    public static func peakWatts(from states: [NVMePowerState]) -> Double? {
        let active = states.filter(\.operational)
        let pool = active.isEmpty ? states : active
        return pool.map(\.maxWatts).max()
    }

    public static func idleWatts(from states: [NVMePowerState]) -> Double? {
        states.filter { !$0.operational }.map(\.maxWatts).min()
            ?? states.map(\.maxWatts).min()
    }
}
