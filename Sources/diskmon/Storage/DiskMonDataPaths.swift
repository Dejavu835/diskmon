import Foundation
import DiskMonCore

/// Where drop events, activity lines, and default exports live.
/// Default: ~/Library/Application Support/com.homecenter.diskmon/
/// Optional: user-chosen folder (logs only; SwiftData store stays in App Support for stability).
enum DiskMonDataPaths {
    static let bundleFolderName = "com.homecenter.diskmon"

    static var defaultDirectory: URL {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        let dir = base.appendingPathComponent(bundleFolderName, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Resolve active log directory from settings (empty path → default).
    static func logDirectory(customPath: String?) -> URL {
        guard let raw = customPath?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else {
            return defaultDirectory
        }
        let url = URL(fileURLWithPath: raw, isDirectory: true)
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
            return url
        }
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func dropEventsURL(customPath: String?) -> URL {
        logDirectory(customPath: customPath).appendingPathComponent("drop-events.json")
    }

    static func activityLogURL(customPath: String?) -> URL {
        logDirectory(customPath: customPath).appendingPathComponent("activity.log")
    }

    /// Approximate on-disk size of the log directory (bytes).
    static func directorySize(_ url: URL) -> Int64 {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]
        ) else { return 0 }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
                  values.isRegularFile == true else { continue }
            total += Int64(values.fileSize ?? 0)
        }
        return total
    }

    static func formatBytes(_ bytes: Int64) -> String {
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f.string(fromByteCount: bytes)
    }

    /// Append one activity line (best-effort, never throws into UI paths).
    static func appendActivity(_ line: String, customPath: String?) {
        let url = activityLogURL(customPath: customPath)
        let stamp = ISO8601DateFormatter().string(from: Date())
        let row = "[\(stamp)] \(line)\n"
        if let data = row.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: url.path) {
                if let handle = try? FileHandle(forWritingTo: url) {
                    defer { try? handle.close() }
                    _ = try? handle.seekToEnd()
                    try? handle.write(contentsOf: data)
                }
            } else {
                try? data.write(to: url, options: .atomic)
            }
        }
        pruneActivityLogIfNeeded(at: url, customPath: customPath)
    }

    /// Keep activity.log from growing without bound (rotate at ~2MB).
    private static func pruneActivityLogIfNeeded(at url: URL, customPath: String?) {
        let limit = 2 * 1024 * 1024
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? Int64,
              size > limit else { return }
        // Keep last ~256KB
        guard let data = try? Data(contentsOf: url), data.count > 256 * 1024 else { return }
        let tail = data.suffix(256 * 1024)
        // Align to next newline
        var slice = Data(tail)
        if let nl = slice.firstIndex(of: UInt8(ascii: "\n")), nl < slice.count - 1 {
            slice = Data(slice[(slice.index(after: nl))...])
        }
        try? slice.write(to: url, options: .atomic)
        _ = customPath
    }
}
