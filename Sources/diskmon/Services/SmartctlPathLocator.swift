import Foundation

/// Locate smartctl. GUI apps often have a short PATH, so Homebrew/MacPorts
/// come first; PATH is the fallback for nix / custom prefixes.
enum SmartctlPathLocator {
    static func resolve() -> String? {
        let known = [
            "/opt/homebrew/bin/smartctl",
            "/usr/local/bin/smartctl",
            "/opt/local/bin/smartctl"
        ]
        for path in known where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        return lookupInPATH()
    }

    private static func lookupInPATH() -> String? {
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        for dir in path.split(separator: ":") {
            let candidate = URL(fileURLWithPath: String(dir), isDirectory: true)
                .appendingPathComponent("smartctl").path
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }
}
