import XCTest
@testable import KinectKit
import KinectCore

final class OSCTests: XCTestCase {
    func testMessageEncoding() {
        let packet = OSC.message("/kinect/bodies", [.int(2), .float(1.5), .string("hi")])
        // "/kinect/bodies\0\0" (16) + ",ifs\0\0\0\0" (8) + int (4) + float (4) + "hi\0\0" (4)
        XCTAssertEqual(packet.count, 36)
        XCTAssertEqual(Array(packet.prefix(14)), Array("/kinect/bodies".utf8))
        XCTAssertEqual(packet[14], 0); XCTAssertEqual(packet[15], 0)
        XCTAssertEqual(Array(packet[16..<20]), Array(",ifs".utf8))
        XCTAssertEqual(Array(packet[24..<28]), [0, 0, 0, 2])
        XCTAssertEqual(Array(packet[28..<32]), [0x3F, 0xC0, 0, 0]) // 1.5f big-endian
        XCTAssertEqual(Array(packet[32..<36]), Array("hi".utf8) + [0, 0])
    }

    func testBundleEncoding() {
        let a = OSC.message("/a", [.int(1)])
        let bundle = OSC.bundle([a, a])
        XCTAssertEqual(Array(bundle.prefix(8)), Array("#bundle".utf8) + [0])
        XCTAssertEqual(Array(bundle[8..<16]), [0, 0, 0, 0, 0, 0, 0, 1])
        XCTAssertEqual(bundle.count, 16 + 2 * (4 + a.count))
        XCTAssertEqual(Array(bundle[16..<20]), [0, 0, 0, UInt8(a.count)])
    }

    func testSenderDoesNotThrowWithoutListener() {
        let sender = OSCSender(host: "127.0.0.1", port: 65001)
        sender.send(OSC.message("/ping", []))
        sender.reconfigure(host: "127.0.0.1", port: 65002)
        sender.close()
    }
}

final class BodyTrackerTests: XCTestCase {
    func testTrackingRunsOnAFrameWithoutAPerson() throws {
        let json = PipelineTests.fixture("calibration.json")
        var text = [CChar](repeating: 0, count: json.count + 1)
        json.withUnsafeBytes { bytes in for i in 0..<json.count { text[i] = CChar(bitPattern: bytes[i]) } }
        var calibration = k4a_calibration_t()
        XCTAssertEqual(k4a_calibration_get_from_raw(&text, text.count, K4A_DEPTH_MODE_NFOV_UNBINNED, K4A_COLOR_RESOLUTION_720P, &calibration), K4A_RESULT_SUCCEEDED)
        let tracker = BodyTracker(calibration: calibration)
        // A flat grey colour frame: Vision must find nothing and not crash.
        let color = KinectImage.allocate(format: K4A_IMAGE_FORMAT_COLOR_BGRA32, width: 1280, height: 720, strideBytes: 1280 * 4)!
        memset(color.bytes.baseAddress!, 128, color.byteCount)
        let depth = PipelineTests.fixtureDepth()
        let bodies = tracker.track(color: color, depth: depth, timestamp: 1)
        XCTAssertTrue(bodies.isEmpty)
        // Lifting a colour pixel that sees valid depth yields a point with that depth.
        let lifted = tracker.lift(pixel: SIMD2(640, 360), depth: depth)
        if let lifted {
            XCTAssertGreaterThan(lifted.z, 100)
            XCTAssertLessThan(lifted.z, 10000)
        }
        let bundle = BodyTracker.oscBundle([Body(index: 0, joints: [BodyJoint(name: "nose", confidence: 0.9, colorPixel: SIMD2(1, 2), position: SIMD3(10, 20, 30))], deviceTimestampMicroseconds: 5, boundingBox: nil, source: "pose")])
        XCTAssertTrue(bundle.count > 40)
        XCTAssertEqual(Array(bundle.prefix(7)), Array("#bundle".utf8))
    }
}


final class BodyTrackerFrameTests: XCTestCase {
    /// Runs the tracker on a saved 1280x720 BGRA frame named by KINECT_BODY_FRAME, for checking detections by hand.
    func testSavedFrame() throws {
        guard let path = ProcessInfo.processInfo.environment["KINECT_BODY_FRAME"] else { throw XCTSkip("set KINECT_BODY_FRAME") }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let color = KinectImage.allocate(format: K4A_IMAGE_FORMAT_COLOR_BGRA32, width: 1280, height: 720, strideBytes: 1280 * 4)!
        data.withUnsafeBytes { memcpy(color.bytes.baseAddress!, $0.baseAddress!, min($0.count, color.byteCount)) }
        let json = PipelineTests.fixture("calibration.json")
        var text = [CChar](repeating: 0, count: json.count + 1)
        json.withUnsafeBytes { bytes in for i in 0..<json.count { text[i] = CChar(bitPattern: bytes[i]) } }
        var calibration = k4a_calibration_t()
        _ = k4a_calibration_get_from_raw(&text, text.count, K4A_DEPTH_MODE_NFOV_UNBINNED, K4A_COLOR_RESOLUTION_720P, &calibration)
        let bodies = BodyTracker(calibration: calibration).track(color: color, depth: nil, timestamp: 0)
        print("saved frame: \(bodies.count) bodies: " + bodies.map { "\($0.source) \($0.joints.count) joints box \($0.boundingBox.map { "\($0)" } ?? "-")" }.joined(separator: "; "))
        XCTAssertGreaterThan(bodies.count, 0)
    }
}
