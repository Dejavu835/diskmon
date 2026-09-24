import Foundation

/// Sidebar identity tokens. Empty/nil omitted. Never invents NAND/die types.
public enum IdentityChips {
    public static func chips(
        mediaKind: String,
        vendor: String?,
        product: String?,
        firmware: String?,
        serial: String?,
        filesystem: String?,
        bridgeChip: String? = nil
    ) -> [String] {
        var out: [String] = []
        let media = mediaKind.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if media == "SSD" || media == "HDD" {
            out.append(media)
        }
        appendIfPresent(&out, vendor)
        let productTrim = trimmed(product)
        if let productTrim, productTrim.caseInsensitiveCompare(trimmed(vendor) ?? "") != .orderedSame {
            appendIfPresent(&out, productTrim)
        }
        if let fw = trimmed(firmware) {
            out.append(fw.hasPrefix("FW") ? fw : "FW \(fw)")
        }
        appendIfPresent(&out, serial)
        let fs = trimmed(filesystem)
        if let fs, fs != "—" {
            out.append(fs)
        }
        appendIfPresent(&out, bridgeChip)
        return out.filter { token in
            let u = token.uppercased()
            return u != "TLC" && u != "QLC" && u != "MLC" && u != "SLC"
                && !u.contains("NAND") && !u.contains("颗粒")
        }
    }

    private static func trimmed(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    private static func appendIfPresent(_ out: inout [String], _ raw: String?) {
        if let t = trimmed(raw) { out.append(t) }
    }
}
