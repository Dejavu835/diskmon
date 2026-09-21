import XCTest
import DiskMonCore

final class SelfTestLogParserTests: XCTestCase {
    func testATAShortPassed() {
        let log = """
        SMART Self-test log structure revision number 1
        Num  Test_Description    Status                  Remaining  LifeTime(hours)
        # 1  Short offline       Completed without error       00%     12345
        # 2  Extended offline    Completed: read failure       90%     10000
        """
        let (short, long) = SelfTestLogParser.parse(log)
        XCTAssertEqual(short, .passed)
        if case .failed = long { } else { XCTFail("expected long failed, got \(long)") }
    }

    func testNVMeEmptyIsIdle() {
        let log = """
        Self-test Log (NVMe Log 0x06, NSID 0xffffffff)
        Self-test status: No self-test in progress
        No Self-tests Logged
        """
        let (short, long) = SelfTestLogParser.parse(log)
        XCTAssertEqual(short, .idle)
        XCTAssertEqual(long, .idle)
    }

    func testNVMeInProgressRemaining() {
        let log = """
        Self-test Log (NVMe Log 0x06)
        Self-test status: Short device self-test in progress, 40% remaining
        """
        let (short, long) = SelfTestLogParser.parse(log)
        if case .running(let p) = short {
            XCTAssertEqual(p, 0.6, accuracy: 0.01)
        } else {
            XCTFail("expected short running, got \(short)")
        }
        XCTAssertEqual(long, .idle)
    }

    func testNVMeCompletedRowWithoutHash() {
        let log = """
        Num  Test_Description  Status                       Power_on_Hours
         0   Short             Completed without error                 26
         1   Extended          Completed without error                 20
        """
        let (short, long) = SelfTestLogParser.parse(log)
        XCTAssertEqual(short, .passed)
        XCTAssertEqual(long, .passed)
    }
}
