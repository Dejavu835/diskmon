import XCTest
import DiskMonCore

final class HealthPolicyTests: XCTestCase {
    func testUsesCallerThresholdsNotHardcoded7085() {
        let cool = HealthPolicy.grade(
            celsius: 72,
            percentageUsed: 0,
            mediaErrors: 0,
            criticalWarningRaw: 0,
            warningTemp: 80,
            criticalTemp: 90
        )
        XCTAssertEqual(cool, .normal)

        let warn = HealthPolicy.grade(
            celsius: 72,
            percentageUsed: 0,
            mediaErrors: 0,
            criticalWarningRaw: 0,
            warningTemp: 70,
            criticalTemp: 80
        )
        XCTAssertEqual(warn, .warning)
    }

    func testMediaErrorsAndBitsAreDanger() {
        XCTAssertEqual(
            HealthPolicy.grade(
                celsius: 30, percentageUsed: 0, mediaErrors: 1,
                criticalWarningRaw: 0, warningTemp: 70, criticalTemp: 80
            ),
            .danger
        )
        XCTAssertEqual(
            HealthPolicy.grade(
                celsius: 30, percentageUsed: 0, mediaErrors: 0,
                criticalWarningRaw: 0x01, warningTemp: 70, criticalTemp: 80
            ),
            .danger
        )
        XCTAssertEqual(
            HealthPolicy.grade(
                celsius: 30, percentageUsed: 0, mediaErrors: 0,
                criticalWarningRaw: 0x10, warningTemp: 70, criticalTemp: 80
            ),
            .danger
        )
    }

    func testSelfTestAndFSFailedAreDangerEvenIfCool() {
        XCTAssertEqual(
            HealthPolicy.grade(
                celsius: 30, percentageUsed: 0, mediaErrors: 0,
                criticalWarningRaw: 0, warningTemp: 70, criticalTemp: 80,
                selfTestFailed: true
            ),
            .danger
        )
        XCTAssertEqual(
            HealthPolicy.grade(
                celsius: 30, percentageUsed: 0, mediaErrors: 0,
                criticalWarningRaw: 0, warningTemp: 70, criticalTemp: 80,
                fsFailed: true
            ),
            .danger
        )
    }

    func testNilFieldsDoNotInventDanger() {
        XCTAssertEqual(
            HealthPolicy.grade(
                celsius: nil, percentageUsed: nil, mediaErrors: nil,
                criticalWarningRaw: nil, warningTemp: 70, criticalTemp: 80
            ),
            .normal
        )
    }

    func testAvailableSpareMatchesPredictorThresholds() {
        XCTAssertEqual(
            HealthPolicy.grade(
                celsius: 30, percentageUsed: 0, mediaErrors: 0,
                criticalWarningRaw: 0, availableSpare: 9,
                warningTemp: 70, criticalTemp: 80
            ),
            .critical
        )
        XCTAssertEqual(
            HealthPolicy.grade(
                celsius: 30, percentageUsed: 0, mediaErrors: 0,
                criticalWarningRaw: 0, availableSpare: 20,
                warningTemp: 70, criticalTemp: 80
            ),
            .warning
        )
        XCTAssertEqual(
            HealthPolicy.grade(
                celsius: 30, percentageUsed: 0, mediaErrors: 0,
                criticalWarningRaw: 0, availableSpare: 100,
                warningTemp: 70, criticalTemp: 80
            ),
            .normal
        )
    }

    func testBit3ReadOnlyIsDanger() {
        XCTAssertEqual(
            HealthPolicy.grade(
                celsius: 30, percentageUsed: 0, mediaErrors: 0,
                criticalWarningRaw: 0x08, warningTemp: 70, criticalTemp: 80
            ),
            .danger
        )
    }

    func testNilCelsiusDoesNotInventTemperatureWarning() {
        XCTAssertEqual(
            HealthPolicy.grade(
                celsius: nil, percentageUsed: 0, mediaErrors: 0,
                criticalWarningRaw: 0, warningTemp: 70, criticalTemp: 80
            ),
            .normal
        )
    }

    func testBit2ReliabilityIsDangerBit1TemperatureIsNot() {
        XCTAssertEqual(
            HealthPolicy.grade(
                celsius: 30, percentageUsed: 0, mediaErrors: 0,
                criticalWarningRaw: 0x04, warningTemp: 70, criticalTemp: 80
            ),
            .danger
        )
        XCTAssertEqual(
            HealthPolicy.grade(
                celsius: 30, percentageUsed: 0, mediaErrors: 0,
                criticalWarningRaw: 0x02, warningTemp: 70, criticalTemp: 80
            ),
            .normal
        )
    }

    func testPercentageUsed95IsDanger() {
        XCTAssertEqual(
            HealthPolicy.grade(
                celsius: 30, percentageUsed: 95, mediaErrors: 0,
                criticalWarningRaw: 0, warningTemp: 70, criticalTemp: 80
            ),
            .danger
        )
        XCTAssertEqual(
            HealthPolicy.grade(
                celsius: 30, percentageUsed: 90, mediaErrors: 0,
                criticalWarningRaw: 0, warningTemp: 70, criticalTemp: 80
            ),
            .critical
        )
    }
}
