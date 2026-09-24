import XCTest
import DiskMonCore

final class FormatPlanTests: XCTestCase {
    private func external(
        personality: FormatPersonality,
        confirm: String = "ssd512",
        ntfs: Bool = false,
        internalDisk: Bool = false,
        mount: String? = "/Volumes/ssd512",
        bsd: String = "disk4",
        display: String = "ssd512",
        volume: String = "ssd512"
    ) -> FormatRequest {
        FormatRequest(
            bsdName: bsd,
            displayName: display,
            mountPoint: mount,
            isInternal: internalDisk,
            volumeName: volume,
            personality: personality,
            confirmToken: confirm,
            ntfsKitAvailable: ntfs
        )
    }

    func testExternalAPFSEraseUsesDiskutilEraseDisk() {
        let out = FormatPlan.planEraseDisk(external(personality: .apfs))
        guard case .command(let argv) = out else {
            return XCTFail("expected command, got \(out)")
        }
        XCTAssertEqual(argv.first, FormatPlan.diskutil)
        XCTAssertTrue(argv.contains("eraseDisk"))
        XCTAssertTrue(argv.contains("APFS"))
        XCTAssertTrue(argv.contains("disk4"))
        XCTAssertTrue(argv.contains("GPTFormat"))
        XCTAssertFalse(argv.contains("Macintosh HD"))
    }

    func testExternalExFATEraseUsesPersonality() {
        let out = FormatPlan.planEraseDisk(external(personality: .exfat))
        guard case .command(let argv) = out else {
            return XCTFail("expected command, got \(out)")
        }
        XCTAssertTrue(argv.contains("eraseDisk"))
        XCTAssertTrue(argv.contains("ExFAT"))
        XCTAssertTrue(argv.contains("disk4"))
    }

    func testFAT32UsesMBR() {
        let out = FormatPlan.planEraseDisk(external(personality: .fat32, volume: "MYDISK"))
        guard case .command(let argv) = out else {
            return XCTFail("expected command, got \(out)")
        }
        XCTAssertTrue(argv.contains("FAT32"))
        XCTAssertTrue(argv.contains("MBRFormat"))
    }

    func testInternalDiskRefusedNoEraseArgv() {
        let out = FormatPlan.planEraseDisk(external(
            personality: .apfs,
            confirm: "Macintosh HD",
            internalDisk: true,
            mount: "/",
            bsd: "disk0",
            display: "Macintosh HD",
            volume: "Macintosh HD"
        ))
        guard case .refused(let reason) = out else {
            return XCTFail("expected refuse, got \(out)")
        }
        XCTAssertTrue(reason.lowercased().contains("internal") || reason.lowercased().contains("macintosh"))
    }

    func testRootMountRefused() {
        let out = FormatPlan.planEraseDisk(external(
            personality: .exfat,
            confirm: "Data",
            mount: "/",
            bsd: "disk3",
            display: "Data",
            volume: "Data"
        ))
        guard case .refused = out else {
            return XCTFail("expected refuse for /, got \(out)")
        }
    }

    func testMacintoshHDNameRefused() {
        let out = FormatPlan.planEraseDisk(external(
            personality: .apfs,
            confirm: "Macintosh HD",
            mount: "/Volumes/Macintosh HD",
            bsd: "disk3s1",
            display: "Macintosh HD",
            volume: "Macintosh HD"
        ))
        guard case .refused = out else {
            return XCTFail("expected refuse Macintosh HD, got \(out)")
        }
    }

    func testConfirmMismatchRefused() {
        let out = FormatPlan.planEraseDisk(external(
            personality: .apfs,
            confirm: "wrong"
        ))
        guard case .refused(let reason) = out else {
            return XCTFail("expected refuse, got \(out)")
        }
        XCTAssertTrue(reason.contains("confirm"))
    }

    func testNTFSWithoutKitRefused() {
        let out = FormatPlan.planEraseDisk(external(
            personality: .ntfsKit,
            ntfs: false
        ))
        guard case .refused(let reason) = out else {
            return XCTFail("expected refuse, got \(out)")
        }
        XCTAssertTrue(reason.uppercased().contains("NTFS"))
    }

    func testNTFSUsesBundledMkntfsWhenKitMissing() {
        var req = external(personality: .ntfsKit, ntfs: false)
        req.mkntfsPath = "/app/mkntfs"
        req.partitionBSDName = "disk4s1"
        let out = FormatPlan.planEraseDisk(req)
        guard case .command(let argv) = out else {
            return XCTFail("expected mkntfs command, got \(out)")
        }
        XCTAssertEqual(argv.first, "/app/mkntfs")
        XCTAssertTrue(argv.contains("--force"))
        XCTAssertTrue(argv.contains("-L"))
        XCTAssertTrue(argv.contains("/dev/disk4s1"))
        XCTAssertFalse(argv.contains("eraseDisk"))
    }

    func testPartitionEraseUsesEraseVolume() {
        var req = external(personality: .exfat)
        req.partitionBSDName = "disk4s3"
        req.eraseWholeDisk = false
        let out = FormatPlan.planEraseDisk(req)
        guard case .command(let argv) = out else {
            return XCTFail("expected command, got \(out)")
        }
        XCTAssertTrue(argv.contains("eraseVolume"))
        XCTAssertTrue(argv.contains("disk4s3"))
        XCTAssertFalse(argv.contains("eraseDisk"))
    }

    func testFilesystemMatchAfterFormat() {
        XCTAssertTrue(FormatPlan.filesystemMatches(.exfat, reported: "ExFAT"))
        XCTAssertTrue(FormatPlan.filesystemMatches(.ntfsKit, reported: "NTFS"))
        XCTAssertFalse(FormatPlan.filesystemMatches(.apfs, reported: "ExFAT"))
        XCTAssertTrue(NTFSAccess.isBitLocker("BitLocker"))
        XCTAssertFalse(NTFSAccess.isBitLocker("NTFS"))
    }

    func testNTFSWithKitEmitsEraseDiskNTFSKit() {
        let out = FormatPlan.planEraseDisk(external(
            personality: .ntfsKit,
            ntfs: true
        ))
        guard case .command(let argv) = out else {
            return XCTFail("expected command, got \(out)")
        }
        XCTAssertTrue(argv.contains("eraseDisk"))
        XCTAssertTrue(argv.contains("NTFSKit"))
        XCTAssertTrue(argv.contains("disk4"))
    }

    func testMountExternalOK() {
        let out = FormatPlan.planMountDisk(external(personality: .exfat, confirm: ""))
        guard case .command(let argv) = out else {
            return XCTFail("expected command, got \(out)")
        }
        XCTAssertEqual(argv, [FormatPlan.diskutil, "mountDisk", "disk4"])
    }

    func testRemountIsUnmountThenMountDiskNeverLegacyNTFSMount() {
        let req = external(personality: .ntfsKit, confirm: "", ntfs: true)
        let steps = FormatPlan.planRemount(req)
        XCTAssertEqual(steps.count, 2)
        guard case .command(let unmount) = steps[0] else {
            return XCTFail("expected unmount, got \(steps[0])")
        }
        guard case .command(let mount) = steps[1] else {
            return XCTFail("expected mount, got \(steps[1])")
        }
        XCTAssertEqual(unmount, [FormatPlan.diskutil, "unmountDisk", "disk4"])
        XCTAssertEqual(mount, [FormatPlan.diskutil, "mountDisk", "disk4"])
        for argv in [unmount, mount] {
            XCTAssertEqual(argv.first, FormatPlan.diskutil)
            XCTAssertFalse(argv.contains("-t"))
            XCTAssertFalse(argv.contains("-o"))
            XCTAssertFalse(argv.contains("rw"))
            XCTAssertFalse(argv.contains("ntfs"))
            XCTAssertNotEqual(argv.first, "/sbin/mount")
            XCTAssertNotEqual(argv.first, "/usr/sbin/mount")
        }
    }

    func testRemountInternalRefused() {
        let req = external(
            personality: .ntfsKit,
            confirm: "",
            ntfs: true,
            internalDisk: true,
            mount: "/",
            bsd: "disk0",
            display: "Macintosh HD"
        )
        for step in FormatPlan.planRemount(req) {
            guard case .refused = step else {
                return XCTFail("expected refuse, got \(step)")
            }
        }
    }

    func testRenameExternalUsesMountPoint() {
        let req = external(personality: .exfat, confirm: "", volume: "NewName")
        let out = FormatPlan.planRename(req)
        guard case .command(let argv) = out else {
            return XCTFail("expected command, got \(out)")
        }
        XCTAssertEqual(argv, [FormatPlan.diskutil, "rename", "/Volumes/ssd512", "NewName"])
    }

    func testUnmountExternalOK() {
        let out = FormatPlan.planUnmountDisk(external(personality: .exfat, confirm: ""))
        guard case .command(let argv) = out else {
            return XCTFail("expected command, got \(out)")
        }
        XCTAssertEqual(argv, [FormatPlan.diskutil, "unmountDisk", "disk4"])
    }

    func testUnmountInternalRefused() {
        let out = FormatPlan.planUnmountDisk(external(
            personality: .apfs,
            confirm: "",
            internalDisk: true,
            mount: "/",
            bsd: "disk0",
            display: "Macintosh HD"
        ))
        guard case .refused = out else {
            return XCTFail("expected refuse, got \(out)")
        }
    }

    func testProbeDetectsNTFSKitInTable() {
        let sample = """
        Formattable file systems
        PERSONALITY                     USER VISIBLE NAME
        APFS                            APFS
        ExFAT                           ExFAT
        FAT32                           MS-DOS (FAT32)
        NTFSKit                         NTFS (NTFSKit)
        """
        let names = NTFSKitProbe.personalities(from: sample)
        XCTAssertTrue(names.contains("APFS"))
        XCTAssertTrue(names.contains("ExFAT"))
        XCTAssertTrue(NTFSKitProbe.isNTFSKitAvailable(personalities: names))
        XCTAssertEqual(NTFSKitProbe.ntfsKitPersonality(in: names), "NTFSKit")
    }

    func testProbeAbsentWithoutNTFSKit() {
        let sample = """
        PERSONALITY                     USER VISIBLE NAME
        APFS                            APFS
        ExFAT                           ExFAT
        MS-DOS                          MS-DOS (FAT)
        FAT32                           MS-DOS (FAT32)
        """
        let names = NTFSKitProbe.personalities(from: sample)
        XCTAssertFalse(NTFSKitProbe.isNTFSKitAvailable(personalities: names))
        XCTAssertNil(NTFSKitProbe.ntfsKitPersonality(in: names))
    }

    func testLiveListFilesystemsProbeDoesNotCrash() throws {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
        proc.arguments = ["listFilesystems"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        try proc.run()
        proc.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let text = String(data: data, encoding: .utf8) ?? ""
        let names = NTFSKitProbe.personalities(from: text)
        let available = NTFSKitProbe.isNTFSKitAvailable(personalities: names)
        XCTAssertFalse(text.isEmpty)
        // Boolean result is the contract; NTFSKit need not be installed.
        _ = available
        print("NTFSKIT_AVAILABLE=\(available)")
        print("PERSONALITIES=\(names.joined(separator: ","))")
    }

    func testProbePlistPersonality() {
        let xml = """
        <?xml version="1.0"?>
        <plist><array>
        <dict><key>Personality</key><string>APFS</string></dict>
        <dict><key>Personality</key><string>NTFSKit</string></dict>
        </array></plist>
        """
        let names = NTFSKitProbe.personalities(from: xml)
        XCTAssertTrue(NTFSKitProbe.isNTFSKitAvailable(personalities: names))
    }
}
