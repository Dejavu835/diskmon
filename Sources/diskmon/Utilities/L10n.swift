import Foundation

/// 按 AppSettings.language 读 en / zh-Hans.lproj。
/// String(localized:) 只跟系统语言走,设置里切中文不会改模块标题。
enum L10n {
    static func t(_ key: String, zh: String, en: String, language: String) -> String {
        let code = language == "en" ? "en" : "zh-Hans"
        let fallback = language == "en" ? en : zh
        if let path = Bundle.main.path(forResource: code, ofType: "lproj"),
           let bundle = Bundle(path: path) {
            let value = bundle.localizedString(forKey: key, value: fallback, table: nil)
            return value
        }
        return fallback
    }
}
