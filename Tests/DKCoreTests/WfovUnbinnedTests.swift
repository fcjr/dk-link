import XCTest
@testable import DKCore

/// The wide-field modes against Microsoft's engine (oracle/run.sh output
/// recorded under Fixtures/oracle): the 8-bit WFOV unbinned layout and code
/// law, the WFOV binned tap stride, and both modes' depth and IR agreement.
final class WfovUnbinnedTests: XCTestCase {
    static func oracleU16(_ name: String, count: Int) -> [UInt16] {
        let data = FrameTests.fixture("oracle/" + name)
        XCTAssertEqual(data.count, count * 2)
        return data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) -> [UInt16] in
            let b = bytes.bindMemory(to: UInt8.self)
            return (0..<count).map { UInt16(b[$0 * 2]) | (UInt16(b[$0 * 2 + 1]) << 8) }
        }
    }

    /// A model from the device's block and calibration for a mode.
    static func deviceModel(_ mode: k4a_depth_mode_t) -> OpaquePointer? {
        let block = [UInt8](FrameTests.fixture("calibration_block.bin"))
        let json = FrameTests.fixture("calibration.json")
        var calibration = openk4a_calibration_t()
        let parsed = json.withUnsafeBytes { bytes in
            openk4a_calibration_parse(bytes.bindMemory(to: CChar.self).baseAddress, json.count, &calibration)
        }
        XCTAssertTrue(parsed)
        var source = [CChar](repeating: 0, count: 128)
        let model = block.withUnsafeBufferPointer { openk4a_depth_model_open(mode, $0.baseAddress, $0.count, &calibration, &source, source.count) }
        openk4a_calibration_free(&calibration)
        return model
    }

    static func decode(_ mode: k4a_depth_mode_t, raw: Data, width: Int, height: Int, metal: Bool = false) -> (depth: [UInt16], ir: [UInt16])? {
        guard let model = deviceModel(mode) else { return nil }
        defer { openk4a_depth_model_free(model) }
        var depth = [UInt16](repeating: 0, count: width * height)
        var ir = [UInt16](repeating: 0, count: width * height)
        let ok: Bool = raw.withUnsafeBytes { bytes in
            let base = bytes.bindMemory(to: UInt8.self).baseAddress
            if metal {
                guard let decoder = openk4a_metal_decoder_create() else { return false }
                defer { openk4a_metal_decoder_destroy(decoder) }
                return openk4a_metal_decode(decoder, model, base, raw.count, &depth, &ir)
            }
            openk4a_depth_decode_full(model, base, raw.count, &depth, &ir, nil)
            return true
        }
        return ok ? (depth, ir) : nil
    }

    static func correlation(_ a: [Double], _ b: [Double]) -> Double {
        let ma = a.reduce(0, +) / Double(a.count), mb = b.reduce(0, +) / Double(b.count)
        var sab = 0.0, saa = 0.0, sbb = 0.0
        for i in 0..<a.count { sab += (a[i] - ma) * (b[i] - mb); saa += (a[i] - ma) * (a[i] - ma); sbb += (b[i] - mb) * (b[i] - mb) }
        return sab / (saa * sbb).squareRoot()
    }

    func testModeTableLayouts() {
        let unbinned = openk4a_mode_of(K4A_DEPTH_MODE_WFOV_UNBINNED)!.pointee
        XCTAssertEqual(unbinned.code_bits, 8)
        XCTAssertEqual(unbinned.header_bytes, 160)
        // 160 + 8 * (1024*1024 + 160) + 1024*1024 + 40 is the frame exactly.
        XCTAssertEqual(160 + 8 * (1_048_576 + 160) + 1_048_576 + 40, Int(unbinned.frame_bytes))
        let binned = openk4a_mode_of(K4A_DEPTH_MODE_WFOV_2X2BINNED)!.pointee
        XCTAssertEqual(binned.code_bits, 12)
        XCTAssertEqual(binned.tap_stride, 262_305)
        XCTAssertEqual(binned.tap_stride % 5, 0, "the group walk needs a whole number of groups between planes")
        for mode in [K4A_DEPTH_MODE_NFOV_UNBINNED, K4A_DEPTH_MODE_NFOV_2X2BINNED, K4A_DEPTH_MODE_PASSIVE_IR] {
            XCTAssertEqual(openk4a_mode_of(mode)!.pointee.code_bits, 12)
            XCTAssertEqual(openk4a_mode_of(mode)!.pointee.header_bytes, 256)
        }
    }

    func testEightBitCodeLaw() {
        XCTAssertEqual(openk4a_depth_signed_value8(0), 0)
        XCTAssertEqual(openk4a_depth_signed_value8(0x80), 0)
        var last: Float = 0
        for code in UInt32(1)...0x7F {
            let value = openk4a_depth_signed_value8(code)
            XCTAssertGreaterThan(value, last, "code \(code)")
            XCTAssertEqual(openk4a_depth_signed_value8(code | 0x80), -value, "sign bit of \(code)")
            last = value
        }
    }

    func testWfovUnbinnedDecodesAgainstOracleIR() throws {
        let raw = FrameTests.fixture("wfov_unbinned.raw")
        XCTAssertEqual(raw.count, 9_438_664)
        let decoded = try XCTUnwrap(Self.decode(K4A_DEPTH_MODE_WFOV_UNBINNED, raw: raw, width: 1024, height: 1024))
        let oracleIR = Self.oracleU16("wfov_unbinned.ir.u16", count: 1024 * 1024)
        var ours: [Double] = [], theirs: [Double] = []
        for i in stride(from: 0, to: 1024 * 1024, by: 7) where oracleIR[i] > 100 && oracleIR[i] < 20000 {
            ours.append(Double(decoded.ir[i])); theirs.append(Double(oracleIR[i]))
        }
        XCTAssertGreaterThan(ours.count, 50_000)
        let r = Self.correlation(ours, theirs)
        XCTAssertGreaterThan(r, 0.99, "IR against the engine's: correlation \(r)")

        // Depth against the engine, full resolution: the same sub-millimetre
        // agreement as the other modes (bias -0.2 mm, rms 0.5 mm, 98% of the
        // engine's valid pixels kept, 0.2% extra, on this frame).
        let oracleDepth = Self.oracleU16("wfov_unbinned.depth.u16", count: 1024 * 1024)
        var both = 0, onlyOurs = 0, onlyOracle = 0, sum = 0.0, sumSq = 0.0
        for i in 0..<(1024 * 1024) {
            let a = decoded.depth[i], b = oracleDepth[i]
            if a != 0 && b != 0 {
                let d = Double(a) - Double(b)
                both += 1; sum += d; sumSq += d * d
            } else if a != 0 { onlyOurs += 1 } else if b != 0 { onlyOracle += 1 }
        }
        XCTAssertGreaterThan(both, 330_000, "pixels both decoders call valid")
        let mean = sum / Double(both), rms = (sumSq / Double(both)).squareRoot()
        XCTAssertLessThan(abs(mean), 0.7, "mean offset against the engine (mm): \(mean)")
        XCTAssertLessThan(rms, 0.9, "rms against the engine (mm): \(rms)")
        XCTAssertGreaterThan(Double(both) / Double(both + onlyOurs), 0.99, "precision: \(onlyOurs) pixels only we keep")
        XCTAssertGreaterThan(Double(both) / Double(both + onlyOracle), 0.97, "recall: \(onlyOracle) pixels only the engine keeps")

        // The recorded answer, exactly (debug and release builds agree).
        let golden = FrameTests.readPGM(FrameTests.fixture("wfov_unbinned.depth.pgm"))
        XCTAssertEqual(FrameTests.mismatches(decoded.depth, golden.pixels), "")
        let goldenIR = FrameTests.readPGM(FrameTests.fixture("wfov_unbinned.ir.pgm"))
        XCTAssertEqual(FrameTests.mismatches(decoded.ir, goldenIR.pixels), "")
        if let metal = Self.decode(K4A_DEPTH_MODE_WFOV_UNBINNED, raw: raw, width: 1024, height: 1024, metal: true) {
            XCTAssertEqual(FrameTests.mismatches(metal.depth, decoded.depth), "", "Metal differs from the CPU pass")
            XCTAssertEqual(FrameTests.mismatches(metal.ir, decoded.ir), "")
        }
    }

    func testWfovBinnedMatchesOracle() throws {
        let raw = FrameTests.fixture("wfov_2x2binned.raw")
        let decoded = try XCTUnwrap(Self.decode(K4A_DEPTH_MODE_WFOV_2X2BINNED, raw: raw, width: 512, height: 512))
        let oracleIR = Self.oracleU16("wfov_2x2binned.ir.u16", count: 512 * 512)
        let oracleDepth = Self.oracleU16("wfov_2x2binned.depth.u16", count: 512 * 512)
        var ours: [Double] = [], theirs: [Double] = []
        for i in stride(from: 0, to: 512 * 512, by: 3) where oracleIR[i] > 100 && oracleIR[i] < 20000 {
            ours.append(Double(decoded.ir[i])); theirs.append(Double(oracleIR[i]))
        }
        XCTAssertGreaterThan(Self.correlation(ours, theirs), 0.99, "the IR should match the engine's pixel for pixel")
        var both = 0, sum = 0.0, sumSq = 0.0
        for i in 0..<(512 * 512) where decoded.depth[i] != 0 && oracleDepth[i] != 0 {
            let d = Double(decoded.depth[i]) - Double(oracleDepth[i])
            both += 1; sum += d; sumSq += d * d
        }
        XCTAssertGreaterThan(both, 70_000, "pixels both decoders call valid")
        let mean = sum / Double(both), rms = (sumSq / Double(both)).squareRoot()
        XCTAssertLessThan(abs(mean), 0.8, "mean offset against the engine (mm): \(mean)")
        XCTAssertLessThan(rms, 1.0, "rms against the engine (mm): \(rms)")
        let golden = FrameTests.readPGM(FrameTests.fixture("wfov_2x2binned.depth.pgm"))
        XCTAssertEqual(FrameTests.mismatches(decoded.depth, golden.pixels), "")
        if let metal = Self.decode(K4A_DEPTH_MODE_WFOV_2X2BINNED, raw: raw, width: 512, height: 512, metal: true) {
            XCTAssertEqual(FrameTests.mismatches(metal.depth, decoded.depth), "", "Metal differs from the CPU pass")
        }
    }
}
