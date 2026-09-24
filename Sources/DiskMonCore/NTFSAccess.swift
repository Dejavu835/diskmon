import Foundation

/// Honest NTFS write state. Never claims writable just because the FSKit extension exists.
public enum NTFSAccess: Equatable, Sendable {
    case notNTFS
    case unmounted
    case extensionOff
    case needsRemount
    case writable

    public static func state(
        isNTFS: Bool,
        mounted: Bool,
        extensionOn: Bool,
        volumeWritable: Bool?
    ) -> NTFSAccess {
        guard isNTFS else { return .notNTFS }
        if !mounted { return .unmounted }
        if volumeWritable == true { return .writable }
        if extensionOn { return .needsRemount }
        return .extensionOff
    }

    /// BitLocker stays locked on macOS. Do not offer a fake unlock.
    public static func isBitLocker(_ filesystem: String?) -> Bool {
        let compact = (filesystem ?? "")
            .lowercased()
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "-", with: "")
        return compact.contains("bitlocker")
    }
}
