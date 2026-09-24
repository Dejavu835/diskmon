import Foundation

/// Detect NTFSKit as a diskutil filesystem personality (FSKit appex enabled).
/// Format still works via bundled mkntfs when the personality is absent.
public enum NTFSKitProbe {
    public static func personalities(from listFilesystemsOutput: String) -> [String] {
        let text = listFilesystemsOutput
        if text.contains("<plist") || text.contains("<?xml") {
            return personalitiesFromPlistXML(text)
        }
        return personalitiesFromTextTable(text)
    }

    public static func isNTFSKitAvailable(personalities: [String]) -> Bool {
        ntfsKitPersonality(in: personalities) != nil
    }

    public static func ntfsKitPersonality(in personalities: [String]) -> String? {
        personalities.first { name in
            let compact = name.uppercased().replacingOccurrences(of: " ", with: "")
                .replacingOccurrences(of: "_", with: "")
                .replacingOccurrences(of: "-", with: "")
            return compact.contains("NTFSKIT")
        }
    }

    public static func personalitiesFromTextTable(_ text: String) -> [String] {
        var names: [String] = []
        for raw in text.split(whereSeparator: { $0.isNewline }) {
            let line = String(raw)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            if trimmed.hasPrefix("-") { continue }
            if trimmed.hasPrefix("PERSONALITY") { continue }
            if trimmed.lowercased().hasPrefix("formattable") { continue }
            if trimmed.lowercased().hasPrefix("these file") { continue }
            if trimmed.lowercased().hasPrefix("when specifying") { continue }
            if trimmed.hasPrefix("(") { continue }
            let cols = trimmed.split(whereSeparator: { $0.isWhitespace })
            guard let first = cols.first else { continue }
            let token = String(first)
            if token == "(or)" {
                if cols.count >= 2 {
                    names.append(String(cols[1]))
                }
                continue
            }
            if token.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "+" || $0 == "-" || $0 == "_" }) {
                names.append(token)
            }
        }
        return names
    }

    public static func personalitiesFromPlistXML(_ xml: String) -> [String] {
        var names: [String] = []
        // diskutil listFilesystems -plist: array of dicts with "Personality" / "Personalities"
        let pattern = "<key>Personality</key>\\s*<string>([^<]+)</string>"
        if let regex = try? NSRegularExpression(pattern: pattern, options: []) {
            let range = NSRange(xml.startIndex..<xml.endIndex, in: xml)
            regex.enumerateMatches(in: xml, options: [], range: range) { match, _, _ in
                guard let match, match.numberOfRanges >= 2,
                      let r = Range(match.range(at: 1), in: xml) else { return }
                names.append(String(xml[r]))
            }
        }
        let alias = "<key>PersonalityAlias</key>\\s*<string>([^<]+)</string>"
        if let regex = try? NSRegularExpression(pattern: alias, options: []) {
            let range = NSRange(xml.startIndex..<xml.endIndex, in: xml)
            regex.enumerateMatches(in: xml, options: [], range: range) { match, _, _ in
                guard let match, match.numberOfRanges >= 2,
                      let r = Range(match.range(at: 1), in: xml) else { return }
                names.append(String(xml[r]))
            }
        }
        return names
    }
}
