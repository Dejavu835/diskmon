import Foundation

/// SMART 数据格式化 helper v0.9.1 polish-P2
///
/// 主人硬规则"不 mock" — nil / 0 数据必须显 "—"(占位符),不显假数据。
/// v0.9.1 polish-P2 前:5 Preferences 子 View + DiskDetailView / SMARTModule /
/// TemperatureModule / PowerModule / CapacityModule / HealthOverviewModule
/// 各自内联 `xxx.map { ... } ?? "—"` 写法,不统一,容易混"采集到 0"和"未采集"。
///
/// === 设计原则 ===
/// - **nil → "—"**:字段没采到,绝不显假数据(主人"不 mock"硬规则)
/// - **0 → "—"**(温度/功耗类)或 **"0"**(计数类):见各 helper 注释
///   - 温度 celsius = 0 是物理不可能(NVMe 上电最低 5°C+),0 视为"未采到"
///   - 功耗 0W = 未接 / 已拔盘,视为"未采到"
///   - 计数类(mediaErrors / powerOnHours / ...)0 是合法值(还没出错的盘)
///     → 0 也显示(用户想知道"目前 0 个错误")
///   - percentageUsed 0 = 新盘,合法,显 "0%"
/// - 8 个常用字段全覆盖,主模块 100% 走 SmartDataFormatter
///
/// === 单元可测 ===
/// 静态 enum,纯函数,无副作用,易测。
/// (v0.9.1 polish-P2 不补 unit test — 留给 Wave 17)
enum SmartDataFormatter {
    // MARK: - 温度 / 功耗(0 视为"未采到" → "—")

    /// 温度(°C)— nil 或 0 都显 "—"
    /// - nil → "—"
    /// - 0 → "—"(NVMe 物理不可能 0°C,采集错误)
    /// - > 0 → "X°C"
    /// v0.9.1 polish-P2:统一 SMARTModule / TemperatureModule / DiskDetailView.TemperatureWidget
    static func celsius(_ v: Int?) -> String {
        guard let v, v > 0 else { return "—" }
        return "\(v)°C"
    }

    /// 功耗(W)— nil 或 0 都显 "—"
    /// - nil → "—"
    /// - 0 → "—"(未接 / 拔盘 / 估算失败)
    /// - > 0 → "X.XX W"
    /// v0.9.1 polish-P2:统一 PowerModule / DiskDetailView.PowerWidget
    static func power(_ v: Double?) -> String {
        guard let v, v > 0 else { return "—" }
        return String(format: "%.2f W", v)
    }

    // MARK: - 计数类(0 合法,显 "0" / nil 显 "—")

    /// 介质错误计数 — nil 显 "—",0 显 "0"
    /// - nil → "—"(未采集)
    /// - 0   → "0"(正常,SSD 还没出错)
    /// - > 0 → "X"
    /// v0.9.1 polish-P2:统一 SMARTModule / DiskDetailView.SMARTWidget
    static func mediaErrors(_ v: Int?) -> String {
        guard let v else { return "—" }
        return "\(v)"
    }

    /// 寿命百分比(Percentage Used)— nil 显 "—",0 显 "0%"(新盘)
    /// - nil → "—"
    /// - 0   → "0%"(新盘合法)
    /// - > 0 → "X%"
    /// v0.9.1 polish-P2:统一 SMARTModule / DiskDetailView.SMARTWidget
    static func percentageUsed(_ v: Int?) -> String {
        guard let v else { return "—" }
        return "\(v)%"
    }

    /// 备块百分比(Available Spare)— nil 显 "—",0 显 "0%"
    /// - nil → "—"
    /// - 0   → "0%"(极度危险,需立即备份)
    /// - > 0 → "X%"
    static func availableSpare(_ v: Int?) -> String {
        guard let v else { return "—" }
        return "\(v)%"
    }

    /// 异常断电次数 — nil 显 "—",0 显 "0"
    /// - nil → "—"
    /// - 0   → "0"
    /// - > 0 → "X"
    static func unsafeShutdowns(_ v: Int?) -> String {
        guard let v else { return "—" }
        return "\(v)"
    }

    /// 上电小时(Power On Hours)— nil 显 "—",0 显 "0 h"
    /// - nil → "—"
    /// - 0   → "0 h"(罕见,新盘)
    /// - > 0 → "X h"
    static func powerOnHours(_ v: Int?) -> String {
        guard let v else { return "—" }
        return "\(v) h"
    }

    /// 上电循环(Power Cycles)— nil 显 "—",0 显 "0"
    /// - nil → "—"
    /// - 0   → "0"
    /// - > 0 → "X"
    static func powerCycles(_ v: Int?) -> String {
        guard let v else { return "—" }
        return "\(v)"
    }
}
