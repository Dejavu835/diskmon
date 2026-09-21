import Foundation

/// 双路径探测:Apple Silicon /opt/homebrew + Intel /usr/local
enum SmartctlPathLocator {
    /// 优先 PATH 解析,再 fallback 两条常见路径
    static func resolve() -> String? {
        // 1) /opt/homebrew/bin/smartctl(Apple Silicon 默认)
        let armPath = "/opt/homebrew/bin/smartctl"
        if FileManager.default.isExecutableFile(atPath: armPath) {
            return armPath
        }
        // 2) /usr/local/bin/smartctl(Intel 默认)
        let x86Path = "/usr/local/bin/smartctl"
        if FileManager.default.isExecutableFile(atPath: x86Path) {
            return x86Path
        }
        return nil
    }
}
