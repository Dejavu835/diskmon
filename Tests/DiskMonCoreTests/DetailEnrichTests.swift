import XCTest
import DiskMonCore

final class DetailEnrichTests: XCTestCase {
    func testIdentityOmitsEmptyAndNeverInventsDie() {
        let chips = IdentityChips.chips(
            mediaKind: "SSD",
            vendor: "Western Digital",
            product: "SN570",
            firmware: "1.0",
            serial: "ABC123",
            filesystem: "APFS",
            bridgeChip: nil
        )
        XCTAssertEqual(chips, ["SSD", "Western Digital", "SN570", "FW 1.0", "ABC123", "APFS"])
        XCTAssertFalse(chips.contains { $0.uppercased().contains("NAND") })
        XCTAssertFalse(chips.contains { $0.uppercased().contains("TLC") })

        let sparse = IdentityChips.chips(
            mediaKind: "",
            vendor: "  ",
            product: nil,
            firmware: nil,
            serial: "",
            filesystem: "—",
            bridgeChip: nil
        )
        XCTAssertEqual(sparse, [])

        let hdd = IdentityChips.chips(
            mediaKind: "HDD",
            vendor: nil,
            product: nil,
            firmware: nil,
            serial: nil,
            filesystem: "ExFAT"
        )
        XCTAssertEqual(hdd, ["HDD", "ExFAT"])
    }

    func testIdentityDropsDieLikeTokensIfSomehowPassed() {
        let chips = IdentityChips.chips(
            mediaKind: "SSD",
            vendor: "TLC",
            product: "3D NAND",
            firmware: nil,
            serial: nil,
            filesystem: nil
        )
        XCTAssertEqual(chips, ["SSD"])
    }

    func testIOMeanWindowsFromFixedSamples() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        var samples: [IOBucket] = []
        // 10s cadence: 7 days of points would be huge; plant 3 clusters.
        samples.append(IOBucket(at: now.addingTimeInterval(-10), readBps: 2_000_000, writeBps: 1_000_000))
        samples.append(IOBucket(at: now.addingTimeInterval(-20), readBps: 4_000_000, writeBps: 3_000_000))
        samples.append(IOBucket(at: now.addingTimeInterval(-2 * 3600), readBps: 10_000_000, writeBps: 8_000_000))
        samples.append(IOBucket(at: now.addingTimeInterval(-3 * 86_400), readBps: 20_000_000, writeBps: 16_000_000))

        let h1 = IOMean.mean(samples: samples, window: .h1, now: now)
        XCTAssertEqual(h1.read ?? -1, 3_000_000.0, accuracy: 1)
        XCTAssertEqual(h1.write ?? -1, 2_000_000.0, accuracy: 1)

        let h24 = IOMean.mean(samples: samples, window: .h24, now: now)
        let h24Expected = (2_000_000.0 + 4_000_000.0 + 10_000_000.0) / 3.0
        XCTAssertEqual(h24.read ?? -1, h24Expected, accuracy: 1)

        let d7 = IOMean.mean(samples: samples, window: .d7, now: now)
        let d7Expected = (2_000_000.0 + 4_000_000.0 + 10_000_000.0 + 20_000_000.0) / 4.0
        XCTAssertEqual(d7.read ?? -1, d7Expected, accuracy: 1)

        let empty = IOMean.mean(samples: [], window: .h1, now: now)
        XCTAssertNil(empty.read)
        XCTAssertNil(empty.write)
    }

    /// Would fail if mix concatenated raw 2s points with hour buckets:
    /// 23 hours @ 1 MB/s + 1800 live 2s @ 100 MB/s → concat ≈ 99 MB/s (last hour wins).
    func testMixHourBucketsPlusOneLiveFoldNeverRaw2s() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        var hours: [IOBucket] = []
        for i in 1...23 {
            hours.append(IOBucket(
                at: now.addingTimeInterval(-Double(i) * 3600),
                readBps: 1_000_000,
                writeBps: 1_000_000
            ))
        }
        var live: [IOBucket] = []
        live.reserveCapacity(1800)
        for i in 0..<1800 {
            live.append(IOBucket(
                at: now.addingTimeInterval(-Double(i) * 2),
                readBps: 100_000_000,
                writeBps: 100_000_000
            ))
        }

        let concat = IOMean.mean(samples: hours + live, window: .h24, now: now)
        XCTAssertGreaterThan(concat.read ?? 0, 90_000_000)

        let mixed = IOMean.mix(hours: hours, live: live, window: .h24, now: now)
        let expected = (23.0 * 1_000_000.0 + 100_000_000.0) / 24.0
        XCTAssertEqual(mixed.read ?? -1, expected, accuracy: 1)
        XCTAssertEqual(mixed.write ?? -1, expected, accuracy: 1)
        XCTAssertLessThan(mixed.read ?? 0, 10_000_000)

        let d7 = IOMean.mix(hours: hours, live: live, window: .d7, now: now)
        XCTAssertEqual(d7.read ?? -1, expected, accuracy: 1)

        let h1 = IOMean.mix(hours: hours, live: live, window: .h1, now: now)
        XCTAssertEqual(h1.read ?? -1, 100_000_000, accuracy: 1)
    }

    func testMixDoesNotDoubleCountLiveAlreadyInHourBucket() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let hours = [
            IOBucket(at: now.addingTimeInterval(-1800), readBps: 1_000_000, writeBps: 2_000_000)
        ]
        let live = [
            IOBucket(at: now.addingTimeInterval(-2000), readBps: 99_000_000, writeBps: 99_000_000),
            IOBucket(at: now.addingTimeInterval(-900), readBps: 5_000_000, writeBps: 7_000_000),
            IOBucket(at: now.addingTimeInterval(-100), readBps: 7_000_000, writeBps: 9_000_000)
        ]
        let mixed = IOMean.mix(hours: hours, live: live, window: .h24, now: now)
        // hour 1 MB/s + one fold of the two post-bucket live points (6 MB/s)
        let expectedRead = (1_000_000.0 + 6_000_000.0) / 2.0
        let expectedWrite = (2_000_000.0 + 8_000_000.0) / 2.0
        XCTAssertEqual(mixed.read ?? -1, expectedRead, accuracy: 1)
        XCTAssertEqual(mixed.write ?? -1, expectedWrite, accuracy: 1)
    }

    func testIOMeanFoldAndRollHour() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let folded = IOMean.fold(
            samples: [
                IOBucket(at: now, readBps: 2, writeBps: 4),
                IOBucket(at: now, readBps: 6, writeBps: 8)
            ],
            now: now
        )
        XCTAssertEqual(folded?.readBps, 4)
        XCTAssertEqual(folded?.writeBps, 6)

        var minutes: [IOBucket] = []
        var hours: [IOBucket] = []
        for i in 0..<60 {
            let t = now.addingTimeInterval(Double(i) * 60)
            let rolled = IOMean.rollHour(
                minutes: minutes,
                newMinute: IOBucket(at: t, readBps: 1, writeBps: 2),
                now: t
            )
            minutes = rolled.minutes
            if let h = rolled.hoursToAppend { hours.append(h) }
        }
        XCTAssertEqual(minutes.count, 0)
        XCTAssertEqual(hours.count, 1)
        XCTAssertEqual(hours[0].readBps, 1, accuracy: 0.01)
        XCTAssertEqual(hours[0].writeBps, 2, accuracy: 0.01)
    }

    func testIOMeanCappedStoreDropsStaleDisks() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let fresh = IOBucket(at: now, readBps: 1, writeBps: 1)
        let stale = IOBucket(at: now.addingTimeInterval(-200 * 3600), readBps: 9, writeBps: 9)
        var store: [String: [IOBucket]] = ["old": [stale], "new": [fresh]]
        for i in 0..<10 {
            store["d\(i)"] = [IOBucket(at: now.addingTimeInterval(Double(-i)), readBps: 1, writeBps: 1)]
        }
        let capped = IOMean.cappedStore(store, now: now, maxDisks: 8)
        XCTAssertNil(capped["old"])
        XCTAssertEqual(capped["new"]?.count, 1)
        XCTAssertLessThanOrEqual(capped.count, 8)
    }

    func testNTFSAccessHonestStates() {
        XCTAssertEqual(
            NTFSAccess.state(isNTFS: false, mounted: true, extensionOn: true, volumeWritable: true),
            .notNTFS
        )
        XCTAssertEqual(
            NTFSAccess.state(isNTFS: true, mounted: false, extensionOn: true, volumeWritable: nil),
            .unmounted
        )
        XCTAssertEqual(
            NTFSAccess.state(isNTFS: true, mounted: true, extensionOn: false, volumeWritable: false),
            .extensionOff
        )
        XCTAssertEqual(
            NTFSAccess.state(isNTFS: true, mounted: true, extensionOn: true, volumeWritable: false),
            .needsRemount
        )
        XCTAssertEqual(
            NTFSAccess.state(isNTFS: true, mounted: true, extensionOn: true, volumeWritable: true),
            .writable
        )
        // Paragon / already-writable: extension off must not hide real R/W.
        XCTAssertEqual(
            NTFSAccess.state(isNTFS: true, mounted: true, extensionOn: false, volumeWritable: true),
            .writable
        )
        // Extension on is not enough — still RO until remount.
        XCTAssertNotEqual(
            NTFSAccess.state(isNTFS: true, mounted: true, extensionOn: true, volumeWritable: false),
            .writable
        )
    }

    func testMarkStoreWriteReadByUUID() {
        var store = DiskMarkStore()
        XCTAssertEqual(store.mark(for: "aaa"), .none)
        store.set(.trouble, for: "aaa")
        XCTAssertEqual(store.mark(for: "aaa"), .trouble)
        XCTAssertEqual(store.mark(for: "bbb"), .none)
        let json = store.json()
        let loaded = DiskMarkStore.parse(json)
        XCTAssertEqual(loaded.mark(for: "aaa"), .trouble)
        var cleared = loaded
        cleared.set(.none, for: "aaa")
        XCTAssertEqual(cleared.mark(for: "aaa"), .none)
        XCTAssertEqual(DiskMarkStore.parse("not-json").raw.isEmpty, true)
    }
}
