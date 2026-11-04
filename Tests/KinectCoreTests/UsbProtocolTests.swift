import XCTest
@testable import KinectCore

/// The USB layer without a camera: identifiers, and that an unopened handle
/// refuses to do anything rather than crash.
final class UsbProtocolTests: XCTestCase {
    func testDeviceIdentifiers() {
        XCTAssertEqual(OPENK4A_USB_DEPTH.pid, 0x097C)
        XCTAssertEqual(OPENK4A_USB_DEPTH.interface_mi, 0)
        XCTAssertEqual(OPENK4A_USB_DEPTH.endpoint_out, 0x02)
        XCTAssertEqual(OPENK4A_USB_DEPTH.endpoint_in, 0x81)
        XCTAssertEqual(OPENK4A_USB_DEPTH.endpoint_stream, 0x83)
        XCTAssertEqual(OPENK4A_USB_COLOR.pid, 0x097D)
        XCTAssertEqual(OPENK4A_USB_COLOR.interface_mi, 2)
        XCTAssertEqual(OPENK4A_USB_COLOR.endpoint_out, 0x04)
        XCTAssertEqual(OPENK4A_USB_COLOR.endpoint_in, 0x83)
        XCTAssertEqual(OPENK4A_USB_COLOR.endpoint_stream, 0x82)
    }

    func testUnopenedHandleRefuses() {
        var usb = openk4a_usb_t()
        var read = 0
        XCTAssertFalse(openk4a_usb_command(&usb, 0x02, nil, 0, nil, 0, nil, 0, &read, nil))
        var io = openk4a_io_t()
        XCTAssertFalse(openk4a_usb_io_post(&usb, &io))
        XCTAssertEqual(openk4a_usb_io_wait(&usb, &io, 0), Int32(OPENK4A_FAILED))
        openk4a_usb_io_close(&usb, &io)
        openk4a_usb_close(&usb)
    }

    func testContextStarts() {
        XCTAssertNotNil(openk4a_usb_context())
        // Counting attached cameras must not crash with or without one.
        var depth = OPENK4A_USB_DEPTH
        _ = openk4a_usb_count(&depth)
    }

    func testOversizedCommandDataIsRefused() {
        var usb = openk4a_usb_t()
        usb.handle = nil
        let data = [UInt8](repeating: 0, count: 129)
        XCTAssertFalse(openk4a_usb_command(&usb, 0x22, data, data.count, nil, 0, nil, 0, nil, nil))
    }
}
