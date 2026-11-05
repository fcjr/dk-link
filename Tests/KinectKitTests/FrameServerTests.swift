import XCTest
@testable import KinectKit
import KinectCore

final class FrameServerTests: XCTestCase {
    func tempSocket() -> String { NSTemporaryDirectory() + "kinect-test-\(UUID().uuidString).sock" }

    func makeImage(_ kind: FrameKind, _ w: Int, _ h: Int, _ fmt: FramePixelFormat, _ frame: UInt64, seed: UInt8) -> FrameImage {
        var bytes = [UInt8](repeating: 0, count: w * h * fmt.bytesPerPixel)
        for i in bytes.indices { bytes[i] = UInt8((Int(seed) + i) & 0xFF) }
        return FrameImage(kind: kind, width: Int32(w), height: Int32(h), pixelFormat: fmt, frameID: frame, deviceTimestampMicroseconds: frame * 33000, bytes: bytes)
    }

    func makeBody(_ id: Int32) -> FrameBody {
        var b = FrameBody(); b.id = id; b.pose = true; b.bbox = SIMD4(10, 20, 30, 40)
        for i in 0..<32 { var j = FrameJoint(); j.x = Float(i); j.y = Float(i) * 2; j.z = 2.5; j.pixelX = Float(i) * 3; j.pixelY = Float(i) * 4; j.confidence = 0.9; j.valid = i % 2 == 0; b.joints[i] = j }
        return b
    }

    func testImagesBodiesAndConfigRoundTrip() throws {
        let path = tempSocket()
        let server = FrameServer(path: path)
        let requested = NSMutableArray()
        server.onConfigRequest = { req in requested.add(req) }
        server.start()
        defer { server.stop() }
        server.updateStatus("Streaming from TESTSERIAL", serial: "TESTSERIAL")

        let client = FrameClient(path: path)
        let gotImage = expectation(description: "image")
        let gotBodies = expectation(description: "bodies")
        let gotStatus = expectation(description: "status")
        let imageBox = NSMutableArray(); let bodyBox = NSMutableArray(); let statusBox = NSMutableArray()
        client.onImage = { img in imageBox.add(img); if imageBox.count == 1 { gotImage.fulfill() } }
        client.onBodies = { bodies in bodyBox.add(bodies); if bodyBox.count == 1 { gotBodies.fulfill() } }
        client.onStatus = { s in statusBox.add(s); if s.contains("TESTSERIAL") { gotStatus.fulfill() } }
        XCTAssertTrue(client.connect(), "client should connect")
        XCTAssertEqual(client.serial, "TESTSERIAL")
        wait(for: [gotStatus], timeout: 2)

        var sub = FrameProtocol.Subscription()
        sub.kinds = [.depth, .color]
        sub.bodies = true
        sub.config = FrameProtocol.SessionRequest(depthMode: .wfovBinned, colorResolution: .p1080, frameRate: .fps15, bodyTracking: true, deviceIndex: 2, active: true)
        client.subscribe(sub)

        // The config request must reach the server.
        var waited = 0
        while requested.count == 0 && waited < 50 { Thread.sleep(forTimeInterval: 0.02); waited += 1 }
        let req = try XCTUnwrap(requested.firstObject as? FrameProtocol.SessionRequest)
        XCTAssertEqual(req.depthMode, .wfovBinned)
        XCTAssertEqual(req.colorResolution, .p1080)
        XCTAssertEqual(req.frameRate, .fps15)
        XCTAssertTrue(req.bodyTracking)
        XCTAssertEqual(req.deviceIndex, 2)

        let depth = makeImage(.depth, 640, 576, .r32f, 7, seed: 11)
        let color = makeImage(.color, 64, 48, .bgra8, 7, seed: 200)
        let ir = makeImage(.ir, 64, 48, .r32f, 7, seed: 5)   // not subscribed; must not arrive
        server.publish(images: [depth, color, ir], bodies: [makeBody(3)], stats: [30, 1.2, 31.5, 0, 1, 1])
        wait(for: [gotImage, gotBodies], timeout: 2)

        // Depth bytes must be identical end to end.
        let received = imageBox.compactMap { $0 as? FrameImage }
        let depthBack = try XCTUnwrap(received.first { $0.kind == .depth })
        XCTAssertEqual(depthBack.width, 640); XCTAssertEqual(depthBack.height, 576)
        XCTAssertEqual(depthBack.pixelFormat, .r32f)
        XCTAssertEqual(depthBack.bytes, depth.bytes)
        XCTAssertFalse(received.contains { $0.kind == .ir }, "IR was not subscribed")

        let bodies = try XCTUnwrap(bodyBox.firstObject as? [FrameBody])
        XCTAssertEqual(bodies.count, 1)
        XCTAssertEqual(bodies[0], makeBody(3))

        client.close()
    }

    func testSlowClientDropsRatherThanQueues() throws {
        // Publishing many frames to a connected-but-not-reading client must not
        // block the publisher or grow unbounded.
        let path = tempSocket()
        let server = FrameServer(path: path)
        server.start(); defer { server.stop() }
        let client = FrameClient(path: path)
        XCTAssertTrue(client.connect())
        var sub = FrameProtocol.Subscription(); sub.kinds = [.depth]; client.subscribe(sub)
        Thread.sleep(forTimeInterval: 0.1)
        let big = makeImage(.depth, 1024, 1024, .r16, 1, seed: 1)
        let start = Date()
        for f in 0..<200 { var img = big; img.frameID = UInt64(f); server.publish(images: [img], bodies: [], stats: Array(repeating: 0, count: 6)) }
        XCTAssertLessThan(Date().timeIntervalSince(start), 2.0, "publish must not block on a slow client")
        client.close()
    }

    func testProducerBytesMatchDirectConversion() throws {
        // The producer's depth bytes equal a straight uint16->float conversion,
        // so local mode and the socket carry the same numbers.
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal") }
        _ = device
        let depth = PipelineTests.fixtureDepth()
        let json = PipelineTests.fixture("calibration.json")
        var text = [CChar](repeating: 0, count: json.count + 1)
        json.withUnsafeBytes { b in for i in 0..<json.count { text[i] = CChar(bitPattern: b[i]) } }
        var calibration = k4a_calibration_t()
        _ = k4a_calibration_get_from_raw(&text, text.count, K4A_DEPTH_MODE_NFOV_UNBINNED, K4A_COLOR_RESOLUTION_720P, &calibration)
        let producer = FrameProducer(calibration: calibration, transformation: MetalTransformation(calibration: calibration))
        var handle: k4a_capture_t?
        _ = k4a_capture_create(&handle)
        k4a_capture_set_depth_image(handle, depth.handle)
        let capture = KinectCapture(handle: handle!, sequence: 1)
        k4a_capture_release(handle)
        let images = producer.images(from: capture, kinds: [.depth, .depthMillimetres], bodies: [], frameID: 1)
        let depthF = try XCTUnwrap(images.first { $0.kind == .depth })
        XCTAssertEqual(depthF.bytes.count, depth.width * depth.height * 4)
        depthF.bytes.withUnsafeBytes { raw in
            let f = raw.bindMemory(to: Float.self)
            depth.withUInt16 { v in
                for i in stride(from: 0, to: v.count, by: 997) {
                    XCTAssertEqual(f[i], Float(v[i]) * 0.001, accuracy: 1e-4)
                }
            }
        }
    }
}
