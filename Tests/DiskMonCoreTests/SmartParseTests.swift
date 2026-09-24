import XCTest
import DiskMonCore

final class SmartParseTests: XCTestCase {
    func testBracketedTB() {
        XCTAssertEqual(SmartParse.dataUnitsToTB("25,213,506 [12.9 TB]") ?? -1, 12.9, accuracy: 0.01)
        XCTAssertEqual(SmartParse.dataUnitsToTB("1,000 [512 GB]") ?? -1, 0.512, accuracy: 0.001)
    }

    func testBareCountIsDataUnitsNotTerabytes() {
        let tb = SmartParse.dataUnitsToTB("25,213,506")
        let expected = SmartParse.nvmeDataUnitsToTB(25_213_506)
        XCTAssertEqual(tb ?? -1, expected, accuracy: 0.0001)
        XCTAssertLessThan(tb ?? 99, 20)
    }

    func testWearUsesNormalizedValueNotRaw() {
        XCTAssertEqual(SmartParse.percentageUsedFromWearValue("100"), 0)
        XCTAssertEqual(SmartParse.percentageUsedFromWearValue("050"), 50)
        XCTAssertEqual(SmartParse.percentageUsedFromWearValue("001"), 99)
        XCTAssertNil(SmartParse.percentageUsedFromWearValue("200"))
        XCTAssertEqual(SmartParse.sparePercentFromNormalizedValue("100"), 100)
        XCTAssertEqual(SmartParse.sparePercentFromNormalizedValue("010"), 10)
        XCTAssertNil(SmartParse.sparePercentFromNormalizedValue("5000"))
    }

    func testPlausibleCelsius() {
        XCTAssertTrue(SmartParse.isPlausibleCelsius(42))
        XCTAssertFalse(SmartParse.isPlausibleCelsius(-273))
        XCTAssertFalse(SmartParse.isPlausibleCelsius(0 - 1000))
    }
}
