import Foundation

/// Pure format/unmount/eject argv planner. Never spawns diskutil.
public enum FormatPersonality: String, Equatable, Sendable, CaseIterable {
    case apfs = "APFS"
    case exfat = "ExFAT"
    case fat32 = "FAT32"
    case ntfsKit = "NTFSKit"
}

public struct FormatRequest: Equatable, Sendable {
    public var bsdName: String
    public var displayName: String
    public var mountPoint: String?
    public var isInternal: Bool
    public var volumeName: String
    public var personality: FormatPersonality
    /// User must type displayName or bsdName to confirm erase.
    public var confirmToken: String
    public var ntfsKitAvailable: Bool
    /// Detected diskutil personality string when NTFSKit is present (may differ from "NTFSKit").
    public var ntfsKitPersonality: String
    /// Bundled mkntfs (GPL) for in-app NTFS format when diskutil personality is missing.
    public var mkntfsPath: String
    /// Partition node for mkntfs (e.g. disk4s1). Falls back to bsdName.
    public var partitionBSDName: String

    public init(
        bsdName: String,
        displayName: String,
        mountPoint: String? = nil,
        isInternal: Bool,
        volumeName: String,
        personality: FormatPersonality,
        confirmToken: String,
        ntfsKitAvailable: Bool,
        ntfsKitPersonality: String = "NTFSKit",
        mkntfsPath: String = "",
        partitionBSDName: String = ""
    ) {
        self.bsdName = bsdName
        self.displayName = displayName
        self.mountPoint = mountPoint
        self.isInternal = isInternal
        self.volumeName = volumeName
        self.personality = personality
        self.confirmToken = confirmToken
        self.ntfsKitAvailable = ntfsKitAvailable
        self.ntfsKitPersonality = ntfsKitPersonality
        self.mkntfsPath = mkntfsPath
        self.partitionBSDName = partitionBSDName
    }
}

public enum FormatPlan {
    public enum Outcome: Equatable, Sendable {
        case command(argv: [String])
        case refused(reason: String)
    }

    public static let diskutil = "/usr/sbin/diskutil"

    public static func planEraseDisk(_ req: FormatRequest) -> Outcome {
        if let reason = refuseTarget(req, requireConfirm: true) {
            return .refused(reason: reason)
        }
        if req.volumeName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .refused(reason: "volume name is empty")
        }
        let vol = sanitizedVolumeName(req.volumeName, personality: req.personality)
        switch req.personality {
        case .ntfsKit:
            if req.ntfsKitAvailable {
                let name = req.ntfsKitPersonality.trimmingCharacters(in: .whitespacesAndNewlines)
                let fs = name.isEmpty ? "NTFSKit" : name
                return .command(argv: [diskutil, "eraseDisk", fs, vol, "GPTFormat", req.bsdName])
            }
            let mk = req.mkntfsPath.trimmingCharacters(in: .whitespacesAndNewlines)
            if mk.isEmpty {
                return .refused(reason: "NTFS write/format unavailable (NTFSKit not installed)")
            }
            var part = req.partitionBSDName.trimmingCharacters(in: .whitespacesAndNewlines)
            if part.isEmpty { part = req.bsdName }
            let dev = part.hasPrefix("/dev/") ? part : "/dev/\(part)"
            // mkntfs wants the buffered node, not rdisk.
            let buffered = dev.replacingOccurrences(of: "/dev/rdisk", with: "/dev/disk")
            return .command(argv: [mk, "--force", "--fast", "-L", vol, "--", buffered])
        case .apfs, .exfat, .fat32:
            break
        }
        let fs: String
        switch req.personality {
        case .apfs: fs = "APFS"
        case .exfat: fs = "ExFAT"
        case .fat32: fs = "FAT32"
        case .ntfsKit: fs = "NTFSKit"
        }
        let scheme = (req.personality == .fat32) ? "MBRFormat" : "GPTFormat"
        return .command(argv: [diskutil, "eraseDisk", fs, vol, scheme, req.bsdName])
    }

    public static func planUnmountDisk(_ req: FormatRequest) -> Outcome {
        if let reason = refuseTarget(req, requireConfirm: false) {
            return .refused(reason: reason)
        }
        return .command(argv: [diskutil, "unmountDisk", req.bsdName])
    }

    public static func planEject(_ req: FormatRequest) -> Outcome {
        if let reason = refuseTarget(req, requireConfirm: false) {
            return .refused(reason: reason)
        }
        return .command(argv: [diskutil, "eject", req.bsdName])
    }

    public static func planMountDisk(_ req: FormatRequest) -> Outcome {
        if let reason = refuseTarget(req, requireConfirm: false) {
            return .refused(reason: reason)
        }
        // Always diskutil mountDisk. Never /sbin/mount -t ntfs -o rw.
        return .command(argv: [diskutil, "mountDisk", req.bsdName])
    }

    /// Unmount then mount so FSKit (NTFSKit) can take over a stale read-only mount.
    /// Both steps are diskutil. Never `mount -t ntfs`.
    public static func planRemount(_ req: FormatRequest) -> [Outcome] {
        [planUnmountDisk(req), planMountDisk(req)]
    }

    public static func planRename(_ req: FormatRequest) -> Outcome {
        if let reason = refuseTarget(req, requireConfirm: false) {
            return .refused(reason: reason)
        }
        let name = req.volumeName.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { return .refused(reason: "volume name is empty") }
        guard let mp = req.mountPoint, !mp.isEmpty else {
            return .refused(reason: "not mounted")
        }
        return .command(argv: [diskutil, "rename", mp, name])
    }

    public static func refuseTarget(_ req: FormatRequest, requireConfirm: Bool) -> String? {
        let bsd = req.bsdName.trimmingCharacters(in: .whitespacesAndNewlines)
        if bsd.isEmpty { return "missing disk identifier" }
        if req.isInternal { return "refused: internal system disk" }
        if bsd == "disk0" { return "refused: internal system disk" }
        if let mp = req.mountPoint {
            if mp == "/" || mp.hasPrefix("/System/") {
                return "refused: Macintosh HD / system volume"
            }
        }
        let name = req.displayName.lowercased()
        if name.contains("macintosh hd") || name == "macintoshhd" {
            return "refused: Macintosh HD / system volume"
        }
        if requireConfirm {
            let token = req.confirmToken.trimmingCharacters(in: .whitespacesAndNewlines)
            let display = req.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            if token.isEmpty { return "confirm the target disk name" }
            if token != display && token != bsd {
                return "confirm token does not match disk name or BSD"
            }
        }
        return nil
    }

    public static func sanitizedVolumeName(_ raw: String, personality: FormatPersonality) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if personality == .fat32 {
            let ascii = trimmed.uppercased().filter { $0.isLetter || $0.isNumber || $0 == "_" }
            let clipped = String(ascii.prefix(11))
            return clipped.isEmpty ? "DISK" : clipped
        }
        return trimmed
    }
}
