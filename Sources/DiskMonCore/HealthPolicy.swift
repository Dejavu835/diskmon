import Foundation

/// Single SMART+threshold grade. UI maps this onto HealthLevel.
public enum HealthGrade: String, Equatable, Sendable {
    case normal, warning, critical, danger
}

public enum HealthPolicy {
    public static func grade(
        celsius: Int?,
        percentageUsed: Int?,
        mediaErrors: Int?,
        criticalWarningRaw: Int?,
        availableSpare: Int? = nil,
        warningTemp: Int,
        criticalTemp: Int,
        selfTestFailed: Bool = false,
        fsFailed: Bool = false
    ) -> HealthGrade {
        if selfTestFailed || fsFailed { return .danger }
        let raw = criticalWarningRaw ?? 0
        // bit0 spare, bit2 reliability, bit3 read-only, bit4 backup.
        // bit1 is temperature — graded on the dwell path, not as hardware death.
        if (raw & 0x1D) != 0 { return .danger }
        if (mediaErrors ?? 0) > 0 { return .danger }
        // Missing wear is unknown, not a new disk.
        if let used = percentageUsed, used >= 95 { return .danger }
        if let celsius, celsius >= criticalTemp + 5 { return .danger }
        if let celsius, celsius >= criticalTemp { return .critical }
        if let used = percentageUsed, used >= 90 { return .critical }
        if let spare = availableSpare, spare >= 0, spare < 10 { return .critical }
        if let celsius, celsius >= warningTemp { return .warning }
        if let used = percentageUsed, used >= 70 { return .warning }
        if let spare = availableSpare, spare >= 0, spare < 25 { return .warning }
        return .normal
    }

    public static func rank(_ grade: HealthGrade) -> Int {
        switch grade {
        case .normal: return 0
        case .warning: return 1
        case .critical: return 2
        case .danger: return 3
        }
    }
}
