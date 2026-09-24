import SwiftUI

/// HealthWarning UI 扩展 v0.5.0
/// v0.6:加 .danger case 映射(SMART 独立危险信号 — bit0/bit4 / mediaErrors / 命终前夕)
///
/// 单独成文件,grok 调研设计:
/// - 跟 HealthPredictor.swift 解耦,避免并行 worker 互相覆盖
/// - HealthPredictor 自己的状态机(warnings 字典 + dwell 计算 + formatDwell)由
///   Wave 4H parallel worker 维护 — 本文件不重复定义 formatDwell
/// - 本文件只放"展示需要的映射":颜色 / SF Symbol / 进度环百分比
/// - WarningsView 引用这些扩展,完全不碰 HealthPredictor 内部
extension HealthWarning {
    /// 颜色 token(沿用 HealthLevel 同一色板,视觉一致)
    /// - 主人审美:不引入绿;Good 走 dsNormal(琥珀 #C8956C)— 跟警告形成色阶
    /// - v0.6:.danger 走 dsDanger(#A83838)— 比 dsCritical 暗一档,跟 HealthLevel.danger 同色
    ///   配合 system symbolEffect(.pulse) 区分(critical 是 .bounce,.danger 是 .pulse)
    var color: Color {
        switch self {
        case .none:     .dsNormal
        case .warning:  .dsWarning
        case .critical: .dsCritical
        case .danger:   .dsDanger
        }
    }

    /// SF Symbol 名字
    /// - v0.6:.danger 用 `exclamationmark.octagon.fill`(NVMe spec 的 Critical Warning
    ///   字面是"octagon" 危险标识,跟 critical 区分 — critical 用 `xmark.octagon.fill`,
    ///   danger 用 `exclamationmark.octagon.fill` 表达"系统级紧急",更强烈)
    var sfSymbol: String {
        switch self {
        case .none:     "checkmark.circle.fill"
        case .warning:  "exclamationmark.triangle.fill"
        case .critical: "xmark.octagon.fill"
        case .danger:   "exclamationmark.octagon.fill"
        }
    }

    /// 健康度百分比(0..1),用于进度环
    /// - .none     → 1.0(满,代表健康)
    /// - .warning  → 0.65
    /// - .critical → 0.30
    /// - .danger   → 0.0(空,代表完全不可用 / 立即备份)— 比 critical 30% 还低
    ///   进度环空给视觉强信号:盘已经不能用了
    /// - 注:这是 UI 视觉表达,不是真实健康度指标(磁盘真实健康度由 SMART 字段决定)
    var healthPercent: Double {
        switch self {
        case .none:     1.0
        case .warning:  0.65
        case .critical: 0.30
        case .danger:   0.0
        }
    }

    /// v0.6.1 polish-G:健康度 0-100 整数评分(给 module 文字 + 进度条用)
    /// - .none     → 100
    /// - .warning  → 60
    /// - .critical → 30
    /// - .danger   → 0
    /// - 跟 HealthPredictor.healthScore(for:) 同语义,这里只 wrap 一次方便 View 链
    ///   `.color/.sfSymbol/.healthScore` 一气写完
    var healthScore: Int {
        switch self {
        case .none:     100
        case .warning:  60
        case .critical: 30
        case .danger:   0
        }
    }
}
