import SwiftUI

/// 告警等级枚举
/// fire 5 视觉校准:使用 Homecenter `FAMILY-OS-UI-PROPOSALS.md` 主人 0.5.1 定的精确米色 token
///   - 方案 B(米色 moody)是 diskmon 主推
///   - 方案 A(暗色 xAI 风)在 dark colorScheme 时启用
enum HealthLevel: String, Codable, CaseIterable {
    case normal, warning, critical, danger

    var color: Color {
        switch self {
        case .normal:   .dsNormal
        case .warning:  .dsWarning
        case .critical: .dsCritical
        case .danger:   .dsDanger
        }
    }

    /// Larger = worse. Used for “worst disk” on the menu bar / overview.
    var rank: Int {
        switch self {
        case .normal: return 0
        case .warning: return 1
        case .critical: return 2
        case .danger: return 3
        }
    }
}

/// Design Token — 米色 / 暗色两套，对齐项目 design spec
/// 方案 B(米色 moody,默认) + 方案 A(暗色 xAI,可选)
/// 主人 0.5.1 拍板 — 不要自造
/// v0.4.3 polish-G P0-1:琥珀 / 红 token 改用 design spec 精确色值
///   - dsNormal:#C8956C(warm sand,design amber)— 不是 #D97706(那个偏橙,不高级)
///   - dsWarning:#A87148(deep amber,design amber-deep)— 警告加深一档
///   - dsCritical:#C84A4A(design red,电影感深红)— 之前 #A83838 太闷
///   - dsDanger:保持 #A83838(比 critical 暗一档,系统级 symbolEffect(.pulse) 区分)
/// v0.9.3 健康 UX 升级:加 dsInfo(蓝)+ dsLow(黄)2 个 DriveDx 风格 token
///   - dsInfo 蓝:DriveDx GOOD/AVERAGE 区分(AVERAGE = 可观察,蓝色 traffic-light)
///   - dsLow  黄:DriveDx LOW 档(黄 → 红 之间,过渡色,跟 BAD 红区分)
///   - 来源:DriveDx UI traffic-light(grok 3 调研 2025-09);值取自标准"苹果风"蓝/黄
extension Color {
    /// 方案 B(米色 moody) — 暖米底 + design amber warm sand
    /// 来源:FAMILY-OS-UI-PROPOSALS.md L63-67 + polish-G P0-1 主人 v0.4.3 校色
    static let dsNormal   = Color(red: 0xC8/255, green: 0x95/255, blue: 0x6C/255) // #C8956C  warm sand,design amber(主琥珀)
    static let dsWarning  = Color(red: 0xA8/255, green: 0x71/255, blue: 0x48/255) // #A87148  deep amber,design amber-deep(警告)
    static let dsCritical = Color(red: 0xC8/255, green: 0x4A/255, blue: 0x4A/255) // #C84A4A  design red(危险告警)
    static let dsDanger   = Color(red: 0xA8/255, green: 0x38/255, blue: 0x38/255) // #A83838  比 critical 暗一档,系统级 symbolEffect(.pulse) 区分
    /// v0.9.3 DriveDx 4 标签颜色(HealthLabel.average 用)— 蓝,traffic-light
    /// - DriveDx "average" 是健康但有些属性需要观察,蓝色中性,比琥珀更"冷",提示"不是全好"
    /// - RGB 取 #6699CC(柔蓝,跟琥珀暖系搭,避免冷蓝破坏米色 moody 调)
    static let dsInfo     = Color(red: 0x66/255, green: 0x99/255, blue: 0xCC/255) // #6699CC  driveDx 蓝(average 档)
    /// v0.9.3 DriveDx 4 标签颜色(HealthLabel.low 用)— 黄
    /// - DriveDx "low" 是要换盘,黄色比 dsWarning 琥珀更"亮",跟 BAD 红过渡
    /// - RGB 取 #D4A04C(暗金黄,跟米色底搭,跟琥珀 dsNormal 区分)
    static let dsLow      = Color(red: 0xD4/255, green: 0xA0/255, blue: 0x4C/255) // #D4A04C  driveDx 黄(low 档)

    /// 方案 A(暗色 xAI) — 近黑底 + 单一暖琥珀
    /// 来源:FAMILY-OS-UI-PROPOSALS.md L21-26
    /// v0.4.3 polish-G P0-1:同样校到 design amber 调色板
    ///   - dsNormalDark / dsWarningDark:用 design amber 系列(暗色下也柔和)
    ///   - dsCriticalDark / dsDangerDark:design red 系列
    static let dsNormalDark   = Color(red: 0xC8/255, green: 0x95/255, blue: 0x6C/255) // #C8956C  design amber,暗色主强调
    static let dsWarningDark  = Color(red: 0xA8/255, green: 0x71/255, blue: 0x48/255) // #A87148  design amber-deep
    static let dsCriticalDark = Color(red: 0xC8/255, green: 0x4A/255, blue: 0x4A/255) // #C84A4A  design red
    static let dsDangerDark   = Color(red: 0xA8/255, green: 0x38/255, blue: 0x38/255) // #A83838  深一档
}

/// 主题背景色 token(供 Views 用)
extension Color {
    /// 米色 moody(亮色主题)
    static let themeBg          = Color(red: 0xF3/255, green: 0xEB/255, blue: 0xDD/255) // #F3EBDD  暖米主底
    static let themeBgElevated  = Color(red: 0xFA/255, green: 0xF6/255, blue: 0xEE/255) // #FAF6EE  卡片
    static let themeBgSunken    = Color(red: 0xE7/255, green: 0xDF/255, blue: 0xD0/255) // #E7DFD0  凹槽
    static let themeFg          = Color(red: 0x1C/255, green: 0x19/255, blue: 0x17/255) // #1C1917  墨字
    static let themeFgMuted     = Color(red: 0x78/255, green: 0x6F/255, blue: 0x60/255) // 推算自 token-fg-muted 比例

    /// 暗色 xAI(暗色主题)
    static let themeBgDark         = Color(red: 0x0A/255, green: 0x0A/255, blue: 0x0B/255) // #0A0A0B
    static let themeBgDarkElevated = Color(red: 0x12/255, green: 0x12/255, blue: 0x14/255) // #121214
    static let themeBgDarkSunken   = Color(red: 0x05/255, green: 0x05/255, blue: 0x06/255) // #050506
    static let themeFgDark         = Color(red: 0xF4/255, green: 0xF4/255, blue: 0xF5/255) // #F4F4F5
    static let themeFgDarkMuted    = Color(red: 0xA1/255, green: 0xA1/255, blue: 0xAA/255) // #A1A1AA
}


