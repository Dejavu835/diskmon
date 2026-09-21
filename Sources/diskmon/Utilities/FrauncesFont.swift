import SwiftUI
import CoreText

/// Fraunces 字体 helper(v0.6.1 polish-F 字体根因修复版)
///
/// 嵌入两个 TTF(都登记到 `Info.plist` `ATSApplicationFontsPath = Fonts`):
///   - `Fraunces-Variable.ttf` (360K)  variable 字体,weight 100-900 + optical size + softness + wonky 轴
///   - `Fraunces-Italic.ttf`   (414K)  italic variable 字体
///
/// === 加载链路(polish-F 真根因修复) ===
/// Fraunces 真加载必须 3 步都对:
///   1. `Info.plist` `ATSApplicationFontsPath = Fonts` (✓ 已经在 v0.6.0)
///   2. `build_app.sh` 把 TTF 拷到 `diskmon.app/Contents/Resources/Fonts/`
///      (v0.6.0 漏了,SPM .process 把 TTF 抽到 bundle root 然后 cp -R 平铺,
///       v0.6.1 polish-F 显式 mkdir Fonts/ + mv TTF)
///   3. SwiftUI `Font.custom("Fraunces", size:)` 走 family 名查找 (✓ 已经在 v0.6.0)
/// 缺任一步 → ATS 不注册字体 → SwiftUI 走 SF Pro / New York 系统 fallback,
/// 主人看到的是系统字体不是 Fraunces(2026-09-02 polish-F 根因)。
///
/// 验证脚本(.app 跑前手动验):
///   `ls /Volumes/applelog/diskmon/dist/diskmon.app/Contents/Resources/Fonts/`
///   必须看到 `Fraunces-Variable.ttf` + `Fraunces-Italic.ttf`。
/// 运行时验:`Font.isFrauncesLoaded()` 返回 true。
///
/// TTF 真实 PostScript / Family 名(已用 CoreText `CTFontManagerCreateFontDescriptorsFromURL` 确认):
///   - Variable: family = "Fraunces"        PS = "Fraunces-9ptBlack"
///   - Italic:   family = "Fraunces"        PS = "Fraunces-9ptBlackItalic"
///
/// 走 family 名 + `.weight()` / `.italic()` 修饰,CoreText 会在 family 内选最匹配的实例。
/// 不直接写 PS 名("Fraunces-9ptBlack" / "Fraunces-9ptBlackItalic")是因为 variable 字体
/// 的 PS 名指向一个具体 instance(Black, 9pt),SwiftUI 再用 `.weight(.regular)` 也只能
/// 在该 instance 的 weight 轴内插值;走 family 名更安全,SwiftUI 会拿到整套 master。
///
/// === Weight 100-900 完整映射 ===
/// SwiftUI `Font.Weight` enum 9 个 case 完整对应 CSS wght 100-900:
/// ```
///   .ultraLight → 100   .thin → 200      .light → 300
///   .regular    → 400   .medium → 500    .semibold → 600
///   .bold       → 700   .heavy → 800     .black → 900
/// ```
/// Fraunces variable font 的 `wght` 轴支持 100-900 全范围,`Font.custom("Fraunces", size:).weight(.X)`
/// 实际通过 CoreText 把目标 weight 写到 `wght` 变体轴,字体引擎在 master 之间插值。
/// 因此 `weight` 参数是 9 档 enum,而不是 CGFloat — 不存在"任意 weight"的需求。
///
/// === Italic 走 Fraunces-Italic.ttf ===
/// `italic: true` → base font 之后调用 `.italic()`,SwiftUI/CoreText 会切换到
/// family 内的 italic master(对应 `Fraunces-Italic.ttf` 注册的 instance,wght 100-900 全范围)。
/// 验证:在 family 内 grep 6 个 master 都有 italic 对应("Fraunces-ThinItalic" / ... /
/// "Fraunces-9ptBlackItalic"),所以 italic 切换不依赖额外 PS name 解析。
///
/// === 中文字符 fallback 链(系统级,无需代码) ===
///   - macOS SF Pro / SF Mono → PingFang SC(自动)
///   - Fraunces 缺中文 → 系统 fallback 链(SwiftUI 自动处理)
///   - **不要**用 `Font.custom("Fraunces", ...) + 中文` 之后手动包 .system() — SwiftUI
///     会在 glyph missing 时自动走 fallback 链,代码层不需要二次兜底
///
/// === 用法规范(v0.6.0 polish-E 主人硬要求) ===
/// ```swift
/// // 1. 关键数字(主菜单温度 56pt / 详情 hero 80pt)— 不用 italic(数据/计量)
/// Text("56")
///     .font(.frauncesNumber(size: 56))
///
/// // 2. 模块标题 / 卡片小标题(14-18pt)— em italic(Fraunces italic 强调品牌)
/// Text("温度".uppercased())
///     .font(.frauncesTitle(size: 14, weight: .medium))
///     .tracking(0.08 * 14)  // em 字距
///
/// // 3. 偏好设置 Tab 标题(22-42pt)— em italic
/// Text("Settings")
///     .font(.frauncesTitle(size: 22))
///
/// // 4. 详情页大标题(36-44pt)— 非 italic
/// Text("WD Blue SN570")
///     .font(.frauncesNumber(size: 36, weight: .regular))
///
/// // 5. 正文(中英文混排)— 走 .system 拿 PingFang SC 自动 fallback
/// Text("外接盘已连接")
///     .font(.system(size: 12, weight: .regular, design: .default))
/// ```
extension Font {
    // MARK: - 字体身份

    /// Fraunces family 名(注册到 CoreText 时使用,SwiftUI Font.custom 也按此查找)
    static let frauncesFamily = "Fraunces"

    /// 设计师品牌名(comments / 报告用,代码不引用)
    static let frauncesBrand = "Fraunces Variable + Italic (Google Fonts OFL)"

    // MARK: - 基础 helper

    /// Fraunces 通用入口
    /// - Parameters:
    ///   - size: 字号(pt)
    ///   - weight: 100-900 的 weight(Fraunces variable font `wght` 轴,9 档 enum)
    ///   - italic: true → em 用 italic(Fraunces-Italic.ttf family member 或 variable italic 轴)
    static func fraunces(
        size: CGFloat,
        weight: Font.Weight = .regular,
        italic: Bool = false
    ) -> Font {
        // 走 family 名 → CoreText 在 family 内按 weight + italic 选最近 master
        // `relativeTo: .largeTitle`:polish-F 改,显式声明是"大字号"语义,
        // 之前 .body 让 56pt 数字按 body 缩放曲线,Accessibility 大字号时会跑偏
        // macOS Dynamic Type 不如 iOS 关键,但 hint 更准总比 .body 默认好
        let base = Font.custom(Font.frauncesFamily, size: size, relativeTo: .largeTitle)
        let weighted = base.weight(weight)
        return italic ? weighted.italic() : weighted
    }

    // MARK: - 运行时 sanity check(polish-F 加)

    /// 运行时验证 Fraunces 是否真的被 CoreText 注册
    /// - Returns: true → `Font.custom("Fraunces", ...)` 会拿到 Fraunces;false → 走系统 fallback(SF Pro / New York)
    /// - 用途:debug 时 log,确认 polish-F 字体路径修复有效
    /// - 实现:CoreText 全局 family 名表查找,O(n) 但只在 debug 路径调
    static func isFrauncesLoaded() -> Bool {
        guard let families = CTFontManagerCopyAvailableFontFamilyNames() as? [String] else {
            return false
        }
        return families.contains(Font.frauncesFamily)
    }

    // MARK: - 关键数字 helper(主菜单 / 详情页 hero)

    /// 关键数字(主菜单温度 56pt / 详情 hero 80pt)
    /// - 不用 italic:数据/计量场景,Fraunces 衬线 regular 才是"电影感高级"
    /// - 默认 `.regular` weight:大数字 regular 比 light 更易读,跟 MiniMax / Apple Vision Pro 一致
    /// - Examples:
    ///   - `.frauncesNumber(size: 56)` → 主菜单温度大字
    ///   - `.frauncesNumber(size: 80)` → 详情页 hero 数字
    static func frauncesNumber(
        size: CGFloat,
        weight: Font.Weight = .regular
    ) -> Font {
        fraunces(size: size, weight: weight, italic: false)
    }

    // MARK: - 标题 helper(em italic 强调)

    /// 标题 / 模块标题 / 偏好设置 Tab 标题(Fraunces em italic,主人硬规则)
    /// - italic true 强制:Fraunces italic 是主人审美签名
    /// - 默认 `.regular` weight:14-22pt 区间 regular 比 medium 更"克制",不与 56pt 数字竞争视觉
    /// - Examples:
    ///   - `.frauncesTitle(size: 14)` → 模块顶部小标题("HOTTEST" / "CAPACITY")
    ///   - `.frauncesTitle(size: 16)` → 卡片小标题
    ///   - `.frauncesTitle(size: 22)` → 偏好设置 Tab 标题
    ///   - `.frauncesTitle(size: 42, weight: .regular)` → About 页大字
    static func frauncesTitle(
        size: CGFloat,
        weight: Font.Weight = .regular
    ) -> Font {
        fraunces(size: size, weight: weight, italic: true)
    }

    // MARK: - 关键数字 italic 变体(警告 / 危险态大字)

    /// 关键数字 + em italic(警告温度大字 / 危险态 hero)
    /// - 用于 `.font(.frauncesHeroItalic(size: 56))` 跟 `tempColor` 配合
    /// - 主人审美:危险态用 italic 强调"情绪",跟 regular 数字区分配对
    static func frauncesHeroItalic(
        size: CGFloat,
        weight: Font.Weight = .regular
    ) -> Font {
        fraunces(size: size, weight: weight, italic: true)
    }
}

// MARK: - Line spacing 规范(polish-E 提升可读性)

/// 标题 / 段落 `.lineSpacing(2)` 提升可读性 — polish-E 主人硬要求
/// - 用法:`Text("...").lineSpacing(.bodyLoose)`,在多行 wrap 时 2pt 行距
/// - 单元行(lineLimit 1)的 Text 调了也无副作用(SwiftUI 内部判 no-op)
extension Text {
    /// 段落级 line spacing(2pt) — polish-E 主人审美"行间呼吸感"
    static let bodyLineSpacing: CGFloat = 2

    /// 标题 / 段落级 line spacing(3pt) — 大字号 / 长段落用
    static let titleLineSpacing: CGFloat = 3
}
