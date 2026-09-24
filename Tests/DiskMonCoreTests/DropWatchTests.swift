import XCTest
import DiskMonCore

final class DropWatchTests: XCTestCase {
    func testWholeDiskBSDStripsPartition() {
        XCTAssertEqual(DropClassifier.wholeDiskBSD("disk4s1"), "disk4")
        XCTAssertEqual(DropClassifier.wholeDiskBSD("disk12"), "disk12")
        XCTAssertEqual(DropClassifier.wholeDiskBSD("disk0s3"), "disk0")
    }

    func testUserEjectWinsOverMissingNode() {
        let ctx = DropContext(
            bsdNodeExists: false,
            recentUserEject: true,
            recentUserUnmount: false,
            isUSB: true
        )
        let (kind, hint) = DropClassifier.classify(ctx)
        XCTAssertEqual(kind, .ejected)
        XCTAssertEqual(hint, .userAction)
    }

    func testBsdStillThereIsUnmountNotDrop() {
        let ctx = DropContext(
            bsdNodeExists: true,
            recentUserEject: false,
            recentUserUnmount: false,
            isUSB: true
        )
        let (kind, hint) = DropClassifier.classify(ctx)
        XCTAssertEqual(kind, .unmounted)
        XCTAssertEqual(hint, .stillConnected)
    }

    func testUSBGoneWithoutActionIsCableOrPortHint() {
        let ctx = DropContext(
            bsdNodeExists: false,
            recentUserEject: false,
            recentUserUnmount: false,
            isUSB: true
        )
        let (kind, hint) = DropClassifier.classify(ctx)
        XCTAssertEqual(kind, .dropped)
        XCTAssertEqual(hint, .usbCableOrPort)
    }

    func testAfterSleepHint() {
        let ctx = DropContext(
            bsdNodeExists: false,
            recentUserEject: false,
            recentUserUnmount: false,
            secondsSinceSleepOrWake: 30,
            isUSB: false
        )
        let (kind, hint) = DropClassifier.classify(ctx)
        XCTAssertEqual(kind, .dropped)
        XCTAssertEqual(hint, .afterSleep)
    }

    func testFlapHintBeatsSleep() {
        let ctx = DropContext(
            bsdNodeExists: false,
            recentUserEject: false,
            recentUserUnmount: false,
            secondsSinceSleepOrWake: 10,
            secondsSincePriorDrop: 90,
            isUSB: true
        )
        let (kind, hint) = DropClassifier.classify(ctx)
        XCTAssertEqual(kind, .dropped)
        XCTAssertEqual(hint, .flap)
    }

    func testStoreRoundTripAndReturned() {
        var store = DropWatchStore()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        store.append(DropEvent(
            uuid: "aaa",
            name: "ssd 512",
            bsdName: "disk4",
            serial: "S1",
            at: now,
            kind: .dropped,
            hint: .usbCableOrPort
        ), now: now)
        XCTAssertEqual(store.drops(since: now.addingTimeInterval(-10)).count, 1)
        store.markReturned(
            matching: DropIdentity(uuid: "bbb", name: "ssd 512", serial: "S1"),
            at: now.addingTimeInterval(30)
        )
        XCTAssertNotNil(store.lastDrop(uuid: "bbb")?.returnedAt)
        let loaded = DropWatchStore.parse(store.json())
        XCTAssertEqual(loaded.events.count, 1)
        XCTAssertEqual(loaded.events[0].name, "ssd 512")
        XCTAssertEqual(loaded.events[0].hint, .usbCableOrPort)
    }

    func testReplugWithNewUUIDClearsMissing() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let gone = DropEvent(
            uuid: "old-uuid", name: "海康威视 c4000 2tb", bsdName: "disk4",
            serial: "SN1", at: now.addingTimeInterval(-120),
            kind: .dropped, hint: .usbCableOrPort
        )
        XCTAssertEqual(DropStory.now([gone], at: now), .missing(gone))
        let online = [DropIdentity(uuid: "new-uuid", name: "海康威视 c4000 2tb", serial: "SN1")]
        XCTAssertEqual(DropStory.now([gone], online: online, at: now), .steady)
    }

    func testDiskImageVanishIsNotDrop() {
        let ctx = DropContext(
            bsdNodeExists: false,
            recentUserEject: false,
            recentUserUnmount: false,
            isDiskImage: true,
            isUSB: false
        )
        let (kind, hint) = DropClassifier.classify(ctx)
        XCTAssertEqual(kind, .ejected)
        XCTAssertEqual(hint, .userAction)
    }

    func testHistoricalDiskImageNeverShowsMissing() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let dmg = DropEvent(
            uuid: "img-1",
            name: "Cursor Installer",
            bsdName: "disk10",
            bus: "Disk Image",
            at: now.addingTimeInterval(-86_400),
            kind: .dropped,
            hint: .unknown
        )
        XCTAssertEqual(DropStory.now([dmg], online: [], at: now), .steady)
        XCTAssertTrue(DropStory.history([dmg]).isEmpty)
    }

    func testFinderUnmountIsNotDrop() {
        let ctx = DropContext(
            bsdNodeExists: false,
            recentUserEject: false,
            recentUserUnmount: false,
            recentWorkspaceUnmount: true,
            isUSB: true
        )
        let (kind, hint) = DropClassifier.classify(ctx)
        XCTAssertEqual(kind, .unmounted)
        XCTAssertEqual(hint, .userAction)
    }

    func testExpectedGoneWhenEjected() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let ev = DropEvent(
            uuid: "a", name: "ssd 512", bsdName: "disk4", at: now,
            kind: .ejected, hint: .userAction
        )
        let state = DropStory.now([], online: [], expectedGone: ev, at: now)
        guard case .expectedGone = state else {
            return XCTFail("expectedGone, got \(state)")
        }
        let back = DropStory.now(
            [],
            online: [DropIdentity(uuid: "a", name: "ssd 512")],
            expectedGone: ev,
            at: now
        )
        XCTAssertEqual(back, .steady)
    }

    func testNowStateIgnoresUnmountAndPrefersOpenDrop() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let unmount = DropEvent(
            uuid: "a", name: "ssd", bsdName: "disk4", at: now.addingTimeInterval(-10),
            kind: .unmounted, hint: .stillConnected, returnedAt: now
        )
        XCTAssertEqual(DropStory.now([unmount], at: now), .steady)

        let missing = DropEvent(
            uuid: "b", name: "T70", bsdName: "disk5", at: now.addingTimeInterval(-30),
            kind: .dropped, hint: .usbCableOrPort
        )
        let state = DropStory.now([unmount, missing], at: now)
        guard case .missing(let ev) = state else {
            return XCTFail("expected missing, got \(state)")
        }
        XCTAssertEqual(ev.uuid, "b")
    }

    func testHistoryCollapsesSameDiskWithinHourAndDropsUnmounts() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let a1 = DropEvent(uuid: "a", name: "T70", bsdName: "disk5", at: now.addingTimeInterval(-100), kind: .dropped, hint: .usbCableOrPort)
        let a2 = DropEvent(uuid: "a", name: "T70", bsdName: "disk5", at: now.addingTimeInterval(-20), kind: .dropped, hint: .flap, returnedAt: now)
        let unmount = DropEvent(uuid: "a", name: "T70", bsdName: "disk5", at: now.addingTimeInterval(-10), kind: .unmounted, hint: .userAction, returnedAt: now)
        let rows = DropStory.history([a1, a2, unmount], limit: 3)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].times, 2)
        XCTAssertEqual(rows[0].event.hint, .flap)
    }

    func testNeverInventCauseForBareDrop() {
        let ctx = DropContext(
            bsdNodeExists: false,
            recentUserEject: false,
            recentUserUnmount: false,
            isUSB: false
        )
        let (_, hint) = DropClassifier.classify(ctx)
        XCTAssertEqual(hint, .unknown)
    }
}
