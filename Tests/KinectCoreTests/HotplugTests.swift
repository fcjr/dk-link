import XCTest
@testable import KinectCore

/// Hotplug and pairing without assuming a camera: with one attached the
/// subscription reports it as an arrival; with none it stays quiet.
final class HotplugTests: XCTestCase {
    func testSubscriptionReportsAttachedCameras() {
        final class Box: @unchecked Sendable { var arrivals: [String] = []; let lock = NSLock() }
        let box = Box()
        let token = openk4a_hotplug_subscribe({ context, arrived, serial in
            let box = Unmanaged<Box>.fromOpaque(context!).takeUnretainedValue()
            box.lock.lock(); if arrived { box.arrivals.append(serial.map { String(cString: $0) } ?? "") }; box.lock.unlock()
        }, Unmanaged.passUnretained(box).toOpaque())
        XCTAssertNotEqual(token, 0, "libusb on macOS supports hotplug")
        let deadline = Date().addingTimeInterval(3)
        let expected = Int(openk4a_usb_camera_count())
        while Date() < deadline {
            box.lock.lock(); let count = box.arrivals.count; box.lock.unlock()
            if count >= expected { break }
            Thread.sleep(forTimeInterval: 0.05)
        }
        openk4a_hotplug_unsubscribe(token)
        box.lock.lock(); let arrivals = box.arrivals; box.lock.unlock()
        XCTAssertEqual(arrivals.count, expected, "one arrival per attached camera")
        for serial in arrivals { XCTAssertFalse(serial.isEmpty) }
        if expected > 0 {
            var serial = [CChar](repeating: 0, count: Int(OPENK4A_SERIAL_CHARS))
            XCTAssertTrue(openk4a_usb_camera_serial(0, &serial, serial.count))
            XCTAssertTrue(arrivals.contains(String(cString: serial)))
        }
    }

    func testCameraSerialIndexIsBounded() {
        var serial = [CChar](repeating: 0, count: Int(OPENK4A_SERIAL_CHARS))
        XCTAssertFalse(openk4a_usb_camera_serial(99, &serial, serial.count))
        XCTAssertEqual(serial[0], 0)
        var usb = openk4a_usb_t()
        var depth = OPENK4A_USB_DEPTH
        XCTAssertFalse(openk4a_usb_open_serial(&usb, &depth, "no-such-serial"))
        XCTAssertEqual(k4a_device_get_installed_count(), openk4a_usb_camera_count())
    }
}
