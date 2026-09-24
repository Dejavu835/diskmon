import XCTest
@testable import DiskMonCore

final class SystemVolumeNamesTests: XCTestCase {
    func testDeniesAppleSystemVolumes() {
        XCTAssertTrue(SystemVolumeNames.isSystemVolumeName("Recovery"))
        XCTAssertTrue(SystemVolumeNames.isSystemVolumeName("Preboot"))
        XCTAssertTrue(SystemVolumeNames.isSystemVolumeName("Macintosh HD"))
        XCTAssertTrue(SystemVolumeNames.isSystemVolumeName("macintosh hd - data"))
        XCTAssertTrue(SystemVolumeNames.isSystemVolumeName("  VM  "))
    }

    func testAllowsUserExternalNames() {
        XCTAssertFalse(SystemVolumeNames.isSystemVolumeName("ssd 512"))
        XCTAssertFalse(SystemVolumeNames.isSystemVolumeName("海康威视c4000 2tb"))
        XCTAssertFalse(SystemVolumeNames.isSystemVolumeName("Cursor Installer"))
        XCTAssertFalse(SystemVolumeNames.isSystemVolumeName(nil))
        XCTAssertFalse(SystemVolumeNames.isSystemVolumeName(""))
    }
}
