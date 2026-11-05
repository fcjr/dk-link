import XCTest
@testable import DKCore

/// The firmware package parser, against the vendored 1.6.110080014 package
/// when it is on disk, and against synthetic corruption.
final class FirmwareTests: XCTestCase {
    static let packagePath = "/Users/fcjr/git/dk-mac/vendor/microsoft/windows/AzureKinectDK_Fw_1.6.110080014.bin"

    func testVendoredPackageParses() throws {
        guard let data = FileManager.default.contents(atPath: Self.packagePath) else {
            throw XCTSkip("vendored firmware package not present")
        }
        let bytes = [UInt8](data)
        var package = openk4a_firmware_package_t()
        XCTAssertTrue(openk4a_firmware_parse_package(bytes, bytes.count, &package))
        XCTAssertTrue(package.package_valid)
        XCTAssertTrue(package.crc_valid)
        XCTAssertEqual(package.rgb.major, 1); XCTAssertEqual(package.rgb.minor, 6); XCTAssertEqual(package.rgb.iteration, 110)
        XCTAssertEqual(package.depth.major, 1); XCTAssertEqual(package.depth.minor, 6); XCTAssertEqual(package.depth.iteration, 80)
        XCTAssertEqual(package.audio.major, 1); XCTAssertEqual(package.audio.minor, 6); XCTAssertEqual(package.audio.iteration, 14)
        XCTAssertEqual(package.depth_config_count, 2)
        XCTAssertEqual(package.depth_config.0.major, 6109); XCTAssertEqual(package.depth_config.0.minor, 7)
        XCTAssertEqual(package.depth_config.1.major, 5006); XCTAssertEqual(package.depth_config.1.minor, 27)
        XCTAssertEqual(package.build_config, K4A_FIRMWARE_BUILD_RELEASE)
        XCTAssertEqual(package.signature_type, K4A_FIRMWARE_SIGNATURE_MSFT)
        XCTAssertEqual(package.certificate_type, K4A_FIRMWARE_SIGNATURE_MSFT)

        // A flipped byte breaks the CRC and the package is refused.
        var damaged = bytes
        damaged[1000] ^= 0x55
        var broken = openk4a_firmware_package_t()
        XCTAssertFalse(openk4a_firmware_parse_package(damaged, damaged.count, &broken))
        XCTAssertFalse(broken.crc_valid)
        XCTAssertFalse(broken.package_valid)
    }

    func testTruncatedPackageIsRefused() {
        let tiny = [UInt8](repeating: 0, count: 16)
        var package = openk4a_firmware_package_t()
        XCTAssertFalse(openk4a_firmware_parse_package(tiny, tiny.count, &package))
        XCTAssertFalse(package.package_valid)
        XCTAssertFalse(openk4a_firmware_parse_package(nil, 0, &package))
    }

    func testStatusBitsDecode() {
        // overall in bits 14-15, write 8-9, erase 6-7, transfer 4-5, auth 2-3, version 0-1
        var c = openk4a_firmware_component_status_t()
        c.overall = OPENK4A_FIRMWARE_OPERATION_SUCCEEDED
        XCTAssertEqual(openk4a_firmware_component_result(&c), OPENK4A_FIRMWARE_OPERATION_SUCCEEDED)
        c.overall = OPENK4A_FIRMWARE_OPERATION_INPROGRESS
        XCTAssertEqual(openk4a_firmware_component_result(&c), OPENK4A_FIRMWARE_OPERATION_INPROGRESS)
        c.overall = OPENK4A_FIRMWARE_OPERATION_FAILED
        XCTAssertEqual(openk4a_firmware_component_result(&c), OPENK4A_FIRMWARE_OPERATION_FAILED)
        XCTAssertEqual(String(cString: openk4a_firmware_operation_name(OPENK4A_FIRMWARE_OPERATION_SUCCEEDED)), "succeeded")
    }
}
