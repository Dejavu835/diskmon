import Foundation

/// Parse `smartctl -l selftest` for ATA (`# 1  Short offline …`) and NVMe log 0x06.
public enum SelfTestLogParser {
    public enum Kind: Equatable, Sendable { case short, long }

    public enum Result: Equatable, Sendable {
        case idle
        case running(Double)
        case passed
        case failed(String)
        case aborted
    }

    public static func parse(_ stdout: String) -> (short: Result, long: Result) {
        var short: Result = .idle
        var long: Result = .idle
        var shortSeen = false
        var longSeen = false

        for raw in stdout.split(whereSeparator: { $0.isNewline }) {
            let s = String(raw).trimmingCharacters(in: .whitespaces)
            if s.lowercased().hasPrefix("self-test status:") {
                let lower = s.lowercased()
                if lower.contains("in progress") {
                    let p = progress(from: s) ?? 0.05
                    if lower.contains("short") { short = .running(p); shortSeen = true }
                    else if lower.contains("extend") || lower.contains("long") {
                        long = .running(p); longSeen = true
                    }
                }
                continue
            }
            let kind: Kind?
            if isDataRow(s) {
                let lower = s.lowercased()
                if lower.contains("short") { kind = .short }
                else if lower.contains("long") || lower.contains("extend") { kind = .long }
                else { kind = nil }
            } else {
                kind = nil
            }
            guard let kind else { continue }
            let parsed = parseLine(s)
            switch kind {
            case .short:
                if !shortSeen { short = parsed; shortSeen = true }
            case .long:
                if !longSeen { long = parsed; longSeen = true }
            }
        }
        return (short, long)
    }

    private static func isDataRow(_ s: String) -> Bool {
        if s.hasPrefix("#") { return true }
        // NVMe: "0   Short             Completed without error"
        guard let first = s.first, first.isNumber else { return false }
        let lower = s.lowercased()
        return lower.contains("short") || lower.contains("long") || lower.contains("extend")
    }

    private static func parseLine(_ s: String) -> Result {
        let lower = s.lowercased()
        if lower.contains("completed without error") || lower.contains("completed without failure") {
            return .passed
        }
        if lower.contains("aborted") { return .aborted }
        if lower.contains("in progress") {
            return .running(progress(from: s) ?? 0.05)
        }
        if lower.contains("completed") || lower.contains("fail") {
            return .failed(compactReason(s))
        }
        return .idle
    }

    private static func progress(from s: String) -> Double? {
        let remaining = s.lowercased().contains("remaining")
        guard let pct = percent(in: s) else { return nil }
        let p = pct / 100.0
        return remaining ? max(0, min(1, 1 - p)) : p
    }

    private static func percent(in s: String) -> Double? {
        var n = ""
        for ch in s {
            if ch.isNumber { n.append(ch) }
            else if ch == "%" && !n.isEmpty { return Double(n) }
            else { n = "" }
        }
        return nil
    }

    private static func compactReason(_ s: String) -> String {
        if let r = s.range(of: "Completed:") {
            return String(s[r.upperBound...]).trimmingCharacters(in: .whitespaces).prefix(80).description
        }
        return "failed"
    }
}
