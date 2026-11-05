import XCTest
@testable import DKCore

/// Tests that need no camera: the raw frame format, the companding table, the
/// mode table, the calibration document and the depth pass over a recorded
/// frame. Fixtures were captured from an Azure Kinect DK (serial
/// 000146321712) through this tree's own transport on macOS.
final class FrameTests: XCTestCase {
    static func fixture(_ name: String) -> Data {
        let url = Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures")!
        return try! Data(contentsOf: url)
    }

    static func readPGM(_ data: Data) -> (width: Int, height: Int, pixels: [UInt16]) {
        // P5\n<w> <h>\n65535\n<big-endian 16-bit>
        var cursor = 0
        func token() -> String {
            while data[cursor] == 0x0A || data[cursor] == 0x20 { cursor += 1 }
            var end = cursor
            while data[end] != 0x0A && data[end] != 0x20 { end += 1 }
            let text = String(decoding: data[cursor..<end], as: UTF8.self)
            cursor = end
            return text
        }
        XCTAssertEqual(token(), "P5")
        let width = Int(token())!
        let height = Int(token())!
        XCTAssertEqual(token(), "65535")
        cursor += 1
        var pixels = [UInt16](repeating: 0, count: width * height)
        data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            for i in 0..<(width * height) {
                pixels[i] = UInt16(bytes[cursor + 2 * i]) << 8 | UInt16(bytes[cursor + 2 * i + 1])
            }
        }
        return (width, height, pixels)
    }

    /// A short description of how two planes differ, or "" when they do not.
    static func mismatches(_ a: [UInt16], _ b: [UInt16]) -> String {
        guard a.count == b.count else { return "sizes \(a.count) vs \(b.count)" }
        var count = 0
        var first = -1
        var worst = 0
        for i in 0..<a.count where a[i] != b[i] {
            count += 1
            if first < 0 { first = i }
            worst = max(worst, abs(Int(a[i]) - Int(b[i])))
        }
        return count == 0 ? "" : "\(count) pixels differ, first at \(first) (\(a[first]) vs \(b[first])), worst by \(worst)"
    }

    func testModeTable() {
        let mode = openk4a_mode_of(K4A_DEPTH_MODE_NFOV_UNBINNED)!
        XCTAssertEqual(mode.pointee.width, 640)
        XCTAssertEqual(mode.pointee.height, 576)
        XCTAssertEqual(mode.pointee.frame_bytes, 5_310_760)
        XCTAssertEqual(mode.pointee.payload_bytes, 5_311_488)
        XCTAssertTrue(mode.pointee.has_depth)
        XCTAssertTrue(mode.pointee.nine_taps)
        XCTAssertEqual(mode.pointee.binning, 1)

        let wide = openk4a_mode_of(K4A_DEPTH_MODE_WFOV_UNBINNED)!
        XCTAssertEqual(wide.pointee.width, 1024)
        XCTAssertEqual(wide.pointee.frame_bytes, 9_438_664)
        XCTAssertEqual(openk4a_mode_max_fps(wide), 15)

        let passive = openk4a_mode_of(K4A_DEPTH_MODE_PASSIVE_IR)!
        XCTAssertFalse(passive.pointee.has_depth)
        XCTAssertEqual(openk4a_mode_max_fps(passive), 60)
        XCTAssertNil(openk4a_mode_of(K4A_DEPTH_MODE_OFF))
        XCTAssertEqual(String(cString: openk4a_mode_name(K4A_DEPTH_MODE_WFOV_2X2BINNED)), "WFOV_2X2BINNED")
        XCTAssertEqual(openk4a_mode_by_name("nfov_unbinned")?.pointee.mode, K4A_DEPTH_MODE_NFOV_UNBINNED)
    }

    func testCompandingTable() {
        // Linear below 256.
        XCTAssertEqual(openk4a_code_value(0), 0)
        XCTAssertEqual(openk4a_code_value(1), 1)
        XCTAssertEqual(openk4a_code_value(255), 255)
        // Above it: exponent = code >> 7, mantissa = 128 + 16 * ((code >> 4) & 7) + (code & 15),
        // value = mantissa << (exponent - 1).
        XCTAssertEqual(openk4a_code_value(256), 256)   // 128 << 1
        XCTAssertEqual(openk4a_code_value(257), 258)   // 129 << 1
        XCTAssertEqual(openk4a_code_value(511), 1020)  // 255 << 2
        XCTAssertEqual(openk4a_code_value(512), 1024)  // 128 << 3
        XCTAssertEqual(openk4a_code_value(1023), 16320) // 255 << 6: the largest code an active frame carries
        // Monotonic over the ten bits the device actually sends, and clamped above.
        var last: UInt16 = 0
        for code in UInt32(0)..<1024 {
            let value = openk4a_code_value(code)
            XCTAssertGreaterThanOrEqual(value, last, "code \(code)")
            last = value
        }
        XCTAssertEqual(openk4a_code_value(4095), 65535)
        XCTAssertEqual(openk4a_code_value(3328), 65535) // exponent 26: must not overflow to zero
        // Masked to twelve bits.
        XCTAssertEqual(openk4a_code_value(0x1000 | 300), openk4a_code_value(300))
    }

    func testFrameInfoRejectsGarbage() {
        var info = openk4a_frame_info_t()
        var zeros = [UInt8](repeating: 0, count: 1000)
        XCTAssertFalse(openk4a_frame_info(&zeros, zeros.count, &info))
        XCTAssertFalse(info.valid)
        XCTAssertFalse(openk4a_frame_info(nil, 0, &info))
    }

    func testFrameInfoFromFixture() {
        let raw = Self.fixture("nfov_unbinned.raw")
        XCTAssertEqual(raw.count, 5_310_760)
        var info = openk4a_frame_info_t()
        let ok = raw.withUnsafeBytes { bytes in
            openk4a_frame_info(bytes.bindMemory(to: UInt8.self).baseAddress, raw.count, &info)
        }
        XCTAssertTrue(ok)
        XCTAssertTrue(info.valid)
        XCTAssertGreaterThan(info.exposure_ticks, 0)
        XCTAssertGreaterThan(info.sensor_temp_c, 10)
        XCTAssertLessThan(info.sensor_temp_c, 70)
        XCTAssertGreaterThan(info.laser_temp_c.0, 0)
        // The footer is tagged MRMF.
        XCTAssertEqual(Array(raw.suffix(40).prefix(4)), Array("MRMF".utf8))
    }

    func testCalibrationDocumentParses() {
        let json = Self.fixture("calibration.json")
        var calibration = openk4a_calibration_t()
        let ok = json.withUnsafeBytes { bytes in
            openk4a_calibration_parse(bytes.bindMemory(to: CChar.self).baseAddress, json.count, &calibration)
        }
        XCTAssertTrue(ok)
        XCTAssertTrue(calibration.valid)
        XCTAssertEqual(calibration.depth.resolution_width, 1024)
        XCTAssertEqual(calibration.depth.resolution_height, 1024)
        XCTAssertEqual(calibration.color.resolution_width, 4096)
        XCTAssertEqual(calibration.color.resolution_height, 3072)
        XCTAssertEqual(calibration.depth.intrinsics.parameter_count, 14)
        XCTAssertGreaterThan(calibration.accel.temperature_in_c + calibration.gyro.temperature_in_c, -100)
        openk4a_calibration_free(&calibration)

        // And through the public API, denormalized to a mode.
        var mutable = [CChar](repeating: 0, count: json.count + 1)
        json.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            for i in 0..<json.count { mutable[i] = CChar(bitPattern: bytes[i]) }
        }
        var k4a = k4a_calibration_t()
        XCTAssertEqual(k4a_calibration_get_from_raw(&mutable, mutable.count, K4A_DEPTH_MODE_NFOV_UNBINNED,
                                                    K4A_COLOR_RESOLUTION_720P, &k4a), K4A_RESULT_SUCCEEDED)
        XCTAssertEqual(k4a.depth_camera_calibration.resolution_width, 640)
        XCTAssertEqual(k4a.depth_camera_calibration.resolution_height, 576)
        XCTAssertEqual(k4a.color_camera_calibration.resolution_width, 1280)
        XCTAssertEqual(k4a.color_camera_calibration.resolution_height, 720)

        // A pixel at 1 m projects back onto itself.
        let pixel = k4a_float2_t(xy: .init(x: 320, y: 288))
        var point = k4a_float3_t()
        var valid: Int32 = 0
        var copy = pixel
        XCTAssertEqual(k4a_calibration_2d_to_3d(&k4a, &copy, 1000, K4A_CALIBRATION_TYPE_DEPTH, K4A_CALIBRATION_TYPE_DEPTH, &point, &valid), K4A_RESULT_SUCCEEDED)
        XCTAssertEqual(valid, 1)
        XCTAssertEqual(point.xyz.z, 1000, accuracy: 0.01)
        var back = k4a_float2_t()
        XCTAssertEqual(k4a_calibration_3d_to_2d(&k4a, &point, K4A_CALIBRATION_TYPE_DEPTH, K4A_CALIBRATION_TYPE_DEPTH, &back, &valid), K4A_RESULT_SUCCEEDED)
        XCTAssertEqual(back.xy.x, 320, accuracy: 0.05)
        XCTAssertEqual(back.xy.y, 288, accuracy: 0.05)

        // The colour camera sees the same point somewhere inside its frame.
        var colorPixel = k4a_float2_t()
        XCTAssertEqual(k4a_calibration_3d_to_2d(&k4a, &point, K4A_CALIBRATION_TYPE_DEPTH, K4A_CALIBRATION_TYPE_COLOR, &colorPixel, &valid), K4A_RESULT_SUCCEEDED)
        XCTAssertEqual(valid, 1)
        XCTAssertGreaterThan(colorPixel.xy.x, 0)
        XCTAssertLessThan(colorPixel.xy.x, 1280)
    }

    func testDepthDecodeMatchesGolden() {
        let raw = Self.fixture("nfov_unbinned.raw")
        let golden = Self.readPGM(Self.fixture("nfov_unbinned.depth.pgm"))
        let goldenIR = Self.readPGM(Self.fixture("nfov_unbinned.ir.pgm"))
        XCTAssertEqual(golden.width, 640)
        XCTAssertEqual(golden.height, 576)

        var source = [CChar](repeating: 0, count: 128)
        let model = openk4a_depth_model_open(K4A_DEPTH_MODE_NFOV_UNBINNED, nil, 0, nil, &source, source.count)
        XCTAssertNotNil(model)
        XCTAssertTrue(openk4a_depth_model_valid(model))

        var depth = [UInt16](repeating: 0, count: 640 * 576)
        var ir = [UInt16](repeating: 0, count: 640 * 576)
        raw.withUnsafeBytes { bytes in
            openk4a_depth_decode_full(model, bytes.bindMemory(to: UInt8.self).baseAddress, raw.count, &depth, &ir, nil)
        }
        XCTAssertEqual(Self.mismatches(depth, golden.pixels), "", "the depth pass changed its answer on the recorded frame")
        XCTAssertEqual(Self.mismatches(ir, goldenIR.pixels), "", "the IR pass changed its answer on the recorded frame")
        XCTAssertGreaterThan(depth.filter { $0 != 0 }.count, 100_000, "the recorded scene has depth over most of the frame")

        // The reference pass agrees with the fast one, on a fresh model so the
        // temperature state is the same as the fast pass started with.
        var reference = [UInt16](repeating: 0, count: 640 * 576)
        let fresh = openk4a_depth_model_open(K4A_DEPTH_MODE_NFOV_UNBINNED, nil, 0, nil, &source, source.count)
        raw.withUnsafeBytes { bytes in
            openk4a_depth_decode_reference(fresh, bytes.bindMemory(to: UInt8.self).baseAddress, raw.count, &reference, nil)
        }
        XCTAssertEqual(Self.mismatches(reference, golden.pixels), "", "the reference pass and the fast pass disagree")
        openk4a_depth_model_free(fresh)
        openk4a_depth_model_free(model)
    }

    /// The Metal pass gives the CPU pass's answer on the recorded frame.
    func testMetalDecodeMatchesCPU() throws {
        guard let decoder = openk4a_metal_decoder_create() else { throw XCTSkip("no Metal device") }
        defer { openk4a_metal_decoder_destroy(decoder) }
        let raw = Self.fixture("nfov_unbinned.raw")
        let golden = Self.readPGM(Self.fixture("nfov_unbinned.depth.pgm"))
        let goldenIR = Self.readPGM(Self.fixture("nfov_unbinned.ir.pgm"))
        var source = [CChar](repeating: 0, count: 128)
        let model = openk4a_depth_model_open(K4A_DEPTH_MODE_NFOV_UNBINNED, nil, 0, nil, &source, source.count)
        var depth = [UInt16](repeating: 0, count: 640 * 576)
        var ir = [UInt16](repeating: 0, count: 640 * 576)
        let ok = raw.withUnsafeBytes { bytes in
            openk4a_metal_decode(decoder, model, bytes.bindMemory(to: UInt8.self).baseAddress, raw.count, &depth, &ir)
        }
        XCTAssertTrue(ok)
        XCTAssertEqual(Self.mismatches(ir, goldenIR.pixels), "", "Metal IR differs from the CPU pass")
        XCTAssertEqual(Self.mismatches(depth, golden.pixels), "", "Metal depth differs from the CPU pass")
        // And again, to cover the cached buffers and the rotation upload path.
        var again = [UInt16](repeating: 0, count: 640 * 576)
        _ = raw.withUnsafeBytes { bytes in
            openk4a_metal_decode(decoder, model, bytes.bindMemory(to: UInt8.self).baseAddress, raw.count, &again, nil)
        }
        XCTAssertEqual(again, depth)
        openk4a_depth_model_free(model)
    }

    func testDecodePerformance() {
        let raw = Self.fixture("nfov_unbinned.raw")
        var source = [CChar](repeating: 0, count: 128)
        let model = openk4a_depth_model_open(K4A_DEPTH_MODE_NFOV_UNBINNED, nil, 0, nil, &source, source.count)
        var depth = [UInt16](repeating: 0, count: 640 * 576)
        measure {
            raw.withUnsafeBytes { bytes in
                openk4a_depth_decode(model, bytes.bindMemory(to: UInt8.self).baseAddress, raw.count, &depth)
            }
        }
        openk4a_depth_model_free(model)
    }
}
