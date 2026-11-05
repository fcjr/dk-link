import XCTest
@testable import KinectTD
import CKinectTD
import KinectKit

final class KinectTDTests: XCTestCase {
    func testAcquireReleaseAndStatus() {
        let a = CKinectTD.ktd_session_acquire()
        let b = CKinectTD.ktd_session_acquire()
        XCTAssertNotNil(a)
        XCTAssertEqual(a, b, "one process-wide session")
        var buffer = [CChar](repeating: 0, count: 128)
        CKinectTD.ktd_session_status(a, &buffer, buffer.count)
        XCTAssertFalse(String(cString: buffer).isEmpty)
        CKinectTD.ktd_session_release(a)
        CKinectTD.ktd_session_release(b)
        CKinectTD.ktd_session_release(nil) // must not crash
    }

    func testConfigureWithoutCameraDoesNotCrash() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["KINECT_HW_TESTS"] != "1", "a camera is attached")
        try XCTSkipIf(CKinectTD.ktd_session_stat(CKinectTD.ktd_session_acquire(), KTD_STAT_DEVICES) > 0, "a camera is attached; this is the no-camera path")
        let s = CKinectTD.ktd_session_acquire()
        var config = ktd_config(depth_mode: KTD_DEPTH_NFOV_UNBINNED, color_resolution: KTD_COLOR_720P, fps: KTD_FPS_30, body_tracking: false, device_index: 0)
        XCTAssertEqual(CKinectTD.ktd_session_configure(s, &config, true), 0)
        // The start runs on a background queue; wait for it to settle.
        var text = ""
        for _ in 0..<50 {
            Thread.sleep(forTimeInterval: 0.1)
            var buffer = [CChar](repeating: 0, count: 256)
            CKinectTD.ktd_session_status(s, &buffer, buffer.count)
            text = String(cString: buffer)
            if text != "Starting" { break }
        }
        XCTAssertNotEqual(text, "Starting")
        var info = ktd_image_info()
        XCTAssertEqual(CKinectTD.ktd_session_latest_image(s, KTD_IMAGE_DEPTH, 0, &info, nil, 0), 0)
        CKinectTD.ktd_session_release(s)
    }

    func testInvalidConfigurationIsRefused() {
        let s = CKinectTD.ktd_session_acquire()
        var config = ktd_config(depth_mode: KTD_DEPTH_OFF, color_resolution: KTD_COLOR_OFF, fps: KTD_FPS_30, body_tracking: false, device_index: 0)
        XCTAssertNotEqual(CKinectTD.ktd_session_configure(s, &config, true), 0)
        XCTAssertNotEqual(CKinectTD.ktd_session_configure(nil, &config, true), 0)
        CKinectTD.ktd_session_release(s)
    }

    func testJointNames() {
        XCTAssertEqual(String(cString: CKinectTD.ktd_joint_name(0)!), "pelvis")
        XCTAssertEqual(String(cString: CKinectTD.ktd_joint_name(3)!), "neck")
        XCTAssertEqual(String(cString: CKinectTD.ktd_joint_name(26)!), "head")
        XCTAssertEqual(String(cString: CKinectTD.ktd_joint_name(31)!), "ear_right")
        XCTAssertNil(CKinectTD.ktd_joint_name(32))
        XCTAssertNil(CKinectTD.ktd_joint_name(-1))
        XCTAssertEqual(TDSession.jointNames.count, Int(KTD_JOINT_COUNT))
        // The same pointer every call: the C side may cache it.
        XCTAssertEqual(CKinectTD.ktd_joint_name(5), CKinectTD.ktd_joint_name(5))
    }

    func testBodyConversionFollowsK4abtOrder() {
        let joints = [
            BodyJoint(name: "pelvis", confidence: 0.9, colorPixel: SIMD2(100, 400), position: SIMD3(0, 0, 2000)),
            BodyJoint(name: "neck", confidence: 0.8, colorPixel: SIMD2(100, 100), position: SIMD3(0, -600, 2000)),
            BodyJoint(name: "wrist_right", confidence: 0.7, colorPixel: SIMD2(200, 250), position: nil),
        ]
        let body = Body(index: 7, joints: joints, deviceTimestampMicroseconds: 1, boundingBox: SIMD4(10, 20, 30, 40), source: "pose")
        var converted = TDSession.convert(FrameBody.from(body))
        XCTAssertEqual(converted.id, 7)
        XCTAssertTrue(converted.pose)
        let joint = { (i: Int) -> ktd_joint in
            withUnsafePointer(to: &converted.joints) { $0.withMemoryRebound(to: ktd_joint.self, capacity: 32) { $0[i] } }
        }
        XCTAssertTrue(joint(0).valid); XCTAssertEqual(joint(0).z, 2.0, accuracy: 1e-6)   // pelvis, metres
        XCTAssertTrue(joint(3).valid); XCTAssertEqual(joint(3).y, -0.6, accuracy: 1e-6)  // neck
        XCTAssertTrue(joint(1).valid); XCTAssertEqual(joint(1).y, -0.198, accuracy: 1e-3) // spine_navel interpolated
        XCTAssertFalse(joint(14).valid); XCTAssertEqual(joint(14).pixel_x, 200)         // wrist_right: pixel but no depth
        XCTAssertFalse(joint(8).valid)                                                   // hand_left: Vision has none
        let bbox = withUnsafePointer(to: &converted.bbox) { $0.withMemoryRebound(to: Float.self, capacity: 4) { [$0[0], $0[1], $0[2], $0[3]] } }
        XCTAssertEqual(bbox, [10, 20, 30, 40])
    }

    func testStatsAndStringsWithoutCamera() {
        let s = CKinectTD.ktd_session_acquire()
        XCTAssertGreaterThanOrEqual(CKinectTD.ktd_session_stat(s, KTD_STAT_DEVICES), 0)
        XCTAssertEqual(CKinectTD.ktd_session_stat(s, KTD_STAT_BODY_COUNT), 0)
        var small = [CChar](repeating: 0x41, count: 4)
        CKinectTD.ktd_session_status(s, &small, small.count)
        XCTAssertEqual(small[3], 0, "always terminated")
        XCTAssertEqual(CKinectTD.ktd_session_calibration_json(nil, nil, 0), 0)
        CKinectTD.ktd_session_release(s)
    }
}

final class KinectTDHardwareTests: XCTestCase {
    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["KINECT_HW_TESTS"] == "1", "set KINECT_HW_TESTS=1 to run against a camera")
    }

    func testLiveImagesAndBodies() throws {
        let s = CKinectTD.ktd_session_acquire()
        defer { CKinectTD.ktd_session_release(s) }
        var config = ktd_config(depth_mode: KTD_DEPTH_NFOV_UNBINNED, color_resolution: KTD_COLOR_720P, fps: KTD_FPS_30, body_tracking: true, device_index: 0)
        XCTAssertEqual(CKinectTD.ktd_session_configure(s, &config, true), 0)
        // Register interest so the session computes every kind, then wait for frames.
        let kinds: [(ktd_image_kind, Int32, Int32, ktd_pixel_format, Int)] = [
            (KTD_IMAGE_COLOR, 1280, 720, KTD_PIXEL_BGRA8, 4), (KTD_IMAGE_DEPTH, 640, 576, KTD_PIXEL_R32F, 4),
            (KTD_IMAGE_DEPTH_MM, 640, 576, KTD_PIXEL_R16, 2), (KTD_IMAGE_IR, 640, 576, KTD_PIXEL_R32F, 4),
            (KTD_IMAGE_POINT_CLOUD, 640, 576, KTD_PIXEL_RGBA32F, 16), (KTD_IMAGE_COLOR_POINT_CLOUD, 1280, 720, KTD_PIXEL_RGBA32F, 16),
            (KTD_IMAGE_DEPTH_IN_COLOR, 1280, 720, KTD_PIXEL_R32F, 4), (KTD_IMAGE_COLOR_IN_DEPTH, 640, 576, KTD_PIXEL_BGRA8, 4),
            (KTD_IMAGE_PLAYER_INDEX, 640, 576, KTD_PIXEL_R8, 1),
        ]
        var info = ktd_image_info()
        var status = ""
        for _ in 0..<100 {
            for k in kinds { _ = CKinectTD.ktd_session_latest_image(s, k.0, 0, &info, nil, 0) }
            Thread.sleep(forTimeInterval: 0.1)
            var buffer = [CChar](repeating: 0, count: 256)
            CKinectTD.ktd_session_status(s, &buffer, buffer.count)
            status = String(cString: buffer)
            if CKinectTD.ktd_session_latest_image(s, KTD_IMAGE_COLOR_POINT_CLOUD, 0, &info, nil, 0) != 0 { break }
        }
        XCTAssertTrue(status.hasPrefix("Streaming from"), status)
        for (kind, w, h, format, bpp) in kinds {
            let id = CKinectTD.ktd_session_latest_image(s, kind, 0, &info, nil, 0)
            XCTAssertNotEqual(id, 0, "\(kind)")
            XCTAssertEqual(info.width, w, "\(kind)"); XCTAssertEqual(info.height, h, "\(kind)")
            XCTAssertEqual(info.pixel_format, format, "\(kind)")
            XCTAssertEqual(info.bytes, Int(w) * Int(h) * bpp, "\(kind)")
            var bytes = [UInt8](repeating: 0, count: info.bytes)
            XCTAssertNotEqual(CKinectTD.ktd_session_latest_image(s, kind, 0, &info, &bytes, bytes.count), 0)
            XCTAssertEqual(CKinectTD.ktd_session_latest_image(s, kind, info.frame_id, &info, &bytes, bytes.count), 0, "nothing newer than itself")
            XCTAssertEqual(CKinectTD.ktd_session_latest_image(s, kind, 0, &info, &bytes, 10), 0, "too small a buffer")
            if kind == KTD_IMAGE_DEPTH {
                let metres = bytes.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
                let valid = metres.filter { $0 > 0 }
                XCTAssertGreaterThan(valid.count, 10_000)
                XCTAssertGreaterThan(valid.min()!, 0.05); XCTAssertLessThan(valid.max()!, 15)
            }
            if kind == KTD_IMAGE_POINT_CLOUD {
                let f = bytes.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
                let valid = stride(from: 0, to: f.count, by: 4).filter { f[$0 + 3] > 0 }
                XCTAssertGreaterThan(valid.count, 10_000)
                let z = valid.map { f[$0 + 2] }
                XCTAssertGreaterThan(z.min()!, 0.05); XCTAssertLessThan(z.max()!, 15)
            }
        }
        // The session reports its rate once a second; give it a window.
        var rate = 0.0
        for _ in 0..<30 {
            rate = CKinectTD.ktd_session_stat(s, KTD_STAT_CAPTURES_PER_SECOND)
            if rate > 0 { break }
            Thread.sleep(forTimeInterval: 0.1)
        }
        XCTAssertGreaterThan(rate, 10)
        let before = info.frame_id
        Thread.sleep(forTimeInterval: 0.2)
        XCTAssertNotEqual(CKinectTD.ktd_session_latest_image(s, KTD_IMAGE_DEPTH, before, &info, nil, 0), 0, "frames keep coming")
        var json = [CChar](repeating: 0, count: 65536)
        XCTAssertGreaterThan(CKinectTD.ktd_session_calibration_json(s, &json, json.count), 1000)
        XCTAssertTrue(String(cString: json).contains("CalibrationInformation"))
        var bodies = [ktd_body](repeating: ktd_body(), count: 4)
        var frame: UInt64 = 0
        let count = CKinectTD.ktd_session_bodies(s, &bodies, 4, &frame)
        print("live: \(count) bodies at frame \(frame); captures/s \(CKinectTD.ktd_session_stat(s, KTD_STAT_CAPTURES_PER_SECOND)), decode \(CKinectTD.ktd_session_stat(s, KTD_STAT_DECODE_MILLISECONDS)) ms")
        XCTAssertEqual(CKinectTD.ktd_session_configure(s, &config, false), 0)
    }
}

final class KinectTDClientModeTests: XCTestCase {
    /// With the app's frame server running, the library connects as a client,
    /// reports "via Kinect for Mac" and delivers the server's bytes.
    func testClientModeDeliversServerFrames() throws {
        let path = NSTemporaryDirectory() + "kinect-td-\(UUID().uuidString).sock"
        setenv("KINECT_SOCKET", path, 1)
        defer { unsetenv("KINECT_SOCKET") }
        let server = FrameServer(path: path)
        var adopted: FrameProtocol.SessionRequest?
        server.onConfigRequest = { adopted = $0 }
        server.start(); defer { server.stop() }
        server.updateStatus("Streaming from FAKESERIAL", serial: "FAKESERIAL")

        let s = CKinectTD.ktd_session_acquire()
        defer { CKinectTD.ktd_session_release(s) }
        var config = ktd_config(depth_mode: KTD_DEPTH_NFOV_UNBINNED, color_resolution: KTD_COLOR_720P, fps: KTD_FPS_30, body_tracking: true, device_index: 0)
        XCTAssertEqual(CKinectTD.ktd_session_configure(s, &config, true), 0)

        // Wait for the client to connect and report the via-app status.
        var status = ""
        for _ in 0..<100 {
            Thread.sleep(forTimeInterval: 0.03)
            var buf = [CChar](repeating: 0, count: 256)
            CKinectTD.ktd_session_status(s, &buf, buf.count)
            status = String(cString: buf)
            if status.contains("via Kinect for Mac") { break }
        }
        XCTAssertTrue(status.contains("via Kinect for Mac"), "status was \(status)")

        // Ask for depth so the library subscribes, then the server publishes it.
        var info = ktd_image_info()
        _ = CKinectTD.ktd_session_latest_image(s, KTD_IMAGE_DEPTH, 0, &info, nil, 0)
        var sent = [UInt8](repeating: 0, count: 8 * 6 * 4)
        for i in sent.indices { sent[i] = UInt8((i * 7) & 0xFF) }
        // Publish until the subscription (sent on the control queue) has landed.
        var got: UInt64 = 0
        for _ in 0..<100 {
            server.publish(images: [FrameImage(kind: .depth, width: 8, height: 6, pixelFormat: .r32f, frameID: 42, deviceTimestampMicroseconds: 99, bytes: sent)],
                           bodies: [], stats: [30, 1, 31, 0, 0, 1])
            Thread.sleep(forTimeInterval: 0.03)
            got = CKinectTD.ktd_session_latest_image(s, KTD_IMAGE_DEPTH, 0, &info, nil, 0)
            if got != 0 { break }
        }
        XCTAssertEqual(got, 42)
        XCTAssertEqual(info.width, 8); XCTAssertEqual(info.height, 6)
        var dst = [UInt8](repeating: 0, count: Int(info.bytes))
        let id = dst.withUnsafeMutableBytes { CKinectTD.ktd_session_latest_image(s, KTD_IMAGE_DEPTH, 0, &info, $0.baseAddress, $0.count) }
        XCTAssertEqual(id, 42)
        XCTAssertEqual(dst, sent, "the plugin receives the server's exact bytes")
        XCTAssertEqual(adopted?.depthMode, .nfovUnbinned)
        XCTAssertTrue(adopted?.bodyTracking ?? false)
    }
}
