import XCTest
import DiskMonCore

final class NVMePowerStateParserTests: XCTestCase {
    func testHikvisionC4000Table() {
        let lines = [
            " 0 +     6.50W       -        -    0  0  0  0        0       0",
            " 1 +     5.80W       -        -    1  1  1  1        0       0",
            " 2 +     3.60W       -        -    2  2  2  2        0       0",
            " 3 -   0.0500W       -        -    3  3  3  3     5000   10000",
            " 4 -   0.0025W       -        -    4  4  4  4     8000   45000"
        ]
        let states = lines.compactMap(NVMePowerStateParser.parseLine)
        XCTAssertEqual(states.count, 5)
        XCTAssertEqual(states[0].maxWatts, 6.5, accuracy: 0.01)
        XCTAssertTrue(states[0].operational)
        XCTAssertEqual(states[3].maxWatts, 0.05, accuracy: 0.0001)
        XCTAssertFalse(states[3].operational)
        XCTAssertEqual(NVMePowerStateParser.peakWatts(from: states) ?? -1, 6.5, accuracy: 0.01)
        XCTAssertEqual(NVMePowerStateParser.idleWatts(from: states) ?? -1, 0.0025, accuracy: 0.0001)
    }

    func testSkipsHeader() {
        XCTAssertNil(NVMePowerStateParser.parseLine("St Op     Max   Active     Idle"))
        XCTAssertNil(NVMePowerStateParser.parseLine("Supported Power States"))
    }
}
