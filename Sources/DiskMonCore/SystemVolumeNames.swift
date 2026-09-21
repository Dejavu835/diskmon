import Foundation

/// macOS volumes that must never appear as user-watched external disks.
public enum SystemVolumeNames {
    private static let deny: Set<String> = [
        "recovery",
        "preboot",
        "update",
        "vm",
        "macintosh hd",
        "macintosh hd - data",
        "hardware",
        "xarts",
        "iscpreboot",
    ]

    public static func isSystemVolumeName(_ name: String?) -> Bool {
        guard let name, !name.isEmpty else { return false }
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return deny.contains(n)
    }
}
