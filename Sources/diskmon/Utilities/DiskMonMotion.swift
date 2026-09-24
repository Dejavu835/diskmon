import SwiftUI

/// 统一动效。液态玻璃：短、有阻尼、不弹跳循环。
enum DiskMonMotion {
    /// 顶栏选中胶囊滑动、tab 切换
    static let tab: Animation = .spring(response: 0.38, dampingFraction: 0.84)
    /// 模块出现 / 插拔行
    static let appear: Animation = .spring(response: 0.46, dampingFraction: 0.88)
    /// 内容淡入（克制）
    static let content: Animation = .timingCurve(0.22, 0.86, 0.22, 1, duration: 0.32)
    /// hover / press
    static let hover: Animation = .easeOut(duration: 0.16)
    /// 数字滚动
    static let number: Animation = .easeInOut(duration: 0.22)

    static var tabInsert: AnyTransition {
        .asymmetric(
            insertion: .opacity.combined(with: .offset(y: 8)),
            removal: .opacity.combined(with: .offset(y: -6))
        )
    }

    static var rowInsert: AnyTransition {
        .asymmetric(
            insertion: .opacity.combined(with: .offset(y: 6)),
            removal: .opacity
        )
    }
}
