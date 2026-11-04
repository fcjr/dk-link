import XCTest
@testable import KinectKit
import KinectCore

/// Tests that need an Azure Kinect plugged in. They run only when
/// KINECT_HW_TESTS=1 is set, so the ordinary suite stays hardware-free:
///
///     KINECT_HW_TESTS=1 swift test --filter HardwareTests
final class HardwareTests: XCTestCase {
    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["KINECT_HW_TESTS"] == "1", "set KINECT_HW_TESTS=1 to run against a camera")
        try XCTSkipUnless(KinectDevice.installedCount > 0, "no Azure Kinect attached")
    }

    func testOpenReportsIdentity() throws {
        let device = try KinectDevice()
        XCTAssertEqual(device.serialNumber.count, 12, "serial \(device.serialNumber)")
        let firmware = try XCTUnwrap(device.firmwareVersion)
        XCTAssertTrue(firmware.depth.hasPrefix("1."), firmware.description)
        let calibration = try XCTUnwrap(device.rawCalibration)
        XCTAssertTrue(String(decoding: calibration, as: UTF8.self).contains("CalibrationInformation"))
    }

    func testDepthAndColorStreamAtRate() throws {
        let device = try KinectDevice()
        let configuration = KinectConfiguration(depthMode: .nfovUnbinned, colorResolution: .p720, frameRate: .fps30)
        let session = try KinectSession(device: device, configuration: configuration)
        XCTAssertEqual(session.calibration.depth_camera_calibration.resolution_width, 640)

        let lock = NSLock()
        var captures: [KinectCapture] = []
        var imuSamples = 0
        session.onCapture = { capture in
            lock.lock(); captures.append(capture); lock.unlock()
        }
        session.onIMU = { _ in lock.lock(); imuSamples += 1; lock.unlock() }
        try session.start(imu: true)
        let deadline = Date().addingTimeInterval(4)
        while Date() < deadline {
            lock.lock(); let count = captures.count; lock.unlock()
            if count >= 45 { break }
            Thread.sleep(forTimeInterval: 0.05)
        }
        session.stop()

        lock.lock(); let got = captures; let imu = imuSamples; lock.unlock()
        XCTAssertGreaterThanOrEqual(got.count, 30, "fewer than 30 captures in 4 s")
        XCTAssertGreaterThan(imu, 500, "the IMU should run at over 1 kHz")

        // Depth frames arrive ~33 ms apart on the device clock, in order.
        var previous: Int64 = 0
        var withColor = 0
        let timestamps = got.map { Int64($0.depth?.deviceTimestampMicroseconds ?? 0) }
        for capture in got {
            let depth = try XCTUnwrap(capture.depth)
            XCTAssertEqual(depth.width, 640)
            XCTAssertEqual(depth.height, 576)
            XCTAssertNotNil(capture.ir)
            let now = Int64(depth.deviceTimestampMicroseconds)
            if previous != 0 {
                let gap = now - previous
                XCTAssertGreaterThan(gap, 25_000, "frames out of order or duplicated: \(timestamps)")
                XCTAssertLessThan(gap, 120_000, "a gap of more than three frames: \(timestamps)")
            }
            previous = now
            if let color = capture.color {
                withColor += 1
                XCTAssertEqual(color.width, 1280)
                XCTAssertEqual(color.height, 720)
                XCTAssertEqual(color.format, .bgra32)
                let skew = Int64(color.deviceTimestampMicroseconds) - Int64(depth.deviceTimestampMicroseconds)
                XCTAssertLessThan(abs(skew), 70_000, "colour paired more than two frames from depth")
            }
        }
        XCTAssertGreaterThan(withColor, got.count / 2, "most captures should carry a colour frame")
    }

    func testColorControlsRoundTrip() throws {
        let device = try KinectDevice()
        try device.start(KinectConfiguration(depthMode: .off, colorResolution: .p720, frameRate: .fps30))
        defer { device.stop() }
        let caps = try XCTUnwrap(device.capabilities(of: .brightness))
        let before = try XCTUnwrap(device.value(of: .brightness))
        let target = before.value == caps.minimum ? caps.minimum + caps.step : caps.minimum
        try device.set(.brightness, ColorControlValue(isAuto: false, value: target))
        XCTAssertEqual(device.value(of: .brightness)?.value, target)
        try device.set(.brightness, before)
        XCTAssertEqual(device.value(of: .brightness)?.value, before.value)

        let exposure = try XCTUnwrap(device.capabilities(of: .exposure))
        XCTAssertTrue(exposure.supportsAuto)
        XCTAssertGreaterThan(exposure.maximum, exposure.minimum)
    }

    func testWideFieldModes() throws {
        let device = try KinectDevice()
        for (mode, size) in [(DepthMode.wfovBinned, (512, 512)), (DepthMode.passiveIR, (1024, 1024))] {
            try device.start(KinectConfiguration(depthMode: mode, colorResolution: .off, frameRate: .fps30))
            var seen = 0
            for _ in 0..<40 {
                guard let capture = try device.capture(timeoutMilliseconds: 500) else { continue }
                let ir = try XCTUnwrap(capture.ir)
                XCTAssertEqual(ir.width, size.0)
                XCTAssertEqual(ir.height, size.1)
                if mode.hasDepth { XCTAssertNotNil(capture.depth) } else { XCTAssertNil(capture.depth) }
                seen += 1
                if seen == 5 { break }
            }
            device.stop()
            XCTAssertEqual(seen, 5, "\(mode) did not deliver frames")
        }
    }
}

final class BodyTrackingHardwareTests: XCTestCase {
    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["KINECT_HW_TESTS"] == "1", "set KINECT_HW_TESTS=1 to run against a camera")
        try XCTSkipUnless(KinectDevice.installedCount > 0, "no Azure Kinect attached")
    }

    func testTrackerRunsOnLiveCaptures() throws {
        let device = try KinectDevice()
        let configuration = KinectConfiguration(depthMode: .nfovUnbinned, colorResolution: .p720, frameRate: .fps30)
        let calibration = try device.calibration(for: configuration)
        let tracker = BodyTracker(calibration: calibration)
        try device.start(configuration)
        defer { device.stop() }
        var frames = 0, withBodies = 0, lifted = 0, joints = 0
        var totalMs = 0.0
        for _ in 0..<60 where frames < 10 {
            guard let capture = try device.capture(timeoutMilliseconds: 500), let color = capture.color, capture.depth != nil else { continue }
            frames += 1
            let started = Date()
            let bodies = tracker.track(color: color, depth: capture.depth, timestamp: capture.deviceTimestampMicroseconds)
            totalMs += Date().timeIntervalSince(started) * 1000
            if !bodies.isEmpty { withBodies += 1 }
            for body in bodies {
                for joint in body.joints {
                    joints += 1
                    XCTAssertTrue(joint.colorPixel.x >= 0 && joint.colorPixel.x <= 1280 && joint.colorPixel.y >= 0 && joint.colorPixel.y <= 720)
                    if let p = joint.position { lifted += 1; XCTAssertGreaterThan(p.z, 100); XCTAssertLessThan(p.z, 14000) }
                }
            }
        }
        XCTAssertEqual(frames, 10)
        print("body tracking: \(frames) frames, \(withBodies) with a body, \(joints) joints, \(lifted) lifted to 3D, \(totalMs / Double(frames)) ms/frame")
    }
}
