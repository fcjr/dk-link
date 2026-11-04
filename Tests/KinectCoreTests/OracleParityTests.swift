import XCTest
@testable import KinectCore

/// Our decode against Microsoft's depth engine run on the same frames of the
/// same camera (oracle/run.sh with the depth camera calibration, as the SDK
/// hands it to the engine; outputs under Fixtures/oracle). The bounds are what
/// the fit reached with a margin; see docs/calibration-block.md. The NFOV
/// unbinned fixture is a cold frame (25 C); the fitted laser-temperature
/// residual (OPENK4A_FITTED_RESIDUAL_*, see the doc) brings it to the same
/// sub-millimetre agreement as the warm frames.
final class OracleParityTests: XCTestCase {
    struct Agreement {
        var bias: Double, rms: Double, precision: Double, recall: Double, irRatio: Double
    }

    static func fixture(_ name: String, _ sub: String = "Fixtures") -> Data {
        let url = Bundle.module.url(forResource: name, withExtension: nil, subdirectory: sub)!
        return try! Data(contentsOf: url)
    }

    static func oracle(_ name: String) -> [UInt16] {
        let data = fixture(name, "Fixtures/oracle")
        return data.withUnsafeBytes { Array($0.bindMemory(to: UInt16.self)) }
    }

    static func decode(mode: k4a_depth_mode_t, raw: Data, metal: UnsafeMutableRawPointer?) -> (depth: [UInt16], ir: [UInt16], source: String) {
        let block = [UInt8](fixture("calibration_block.bin"))
        let json = fixture("calibration.json")
        var calibration = openk4a_calibration_t()
        XCTAssertTrue(json.withUnsafeBytes { openk4a_calibration_parse($0.bindMemory(to: CChar.self).baseAddress, json.count, &calibration) })
        var source = [CChar](repeating: 0, count: 128)
        let model = block.withUnsafeBufferPointer { openk4a_depth_model_open(mode, $0.baseAddress, $0.count, &calibration, &source, source.count) }!
        let info = openk4a_mode_of(mode)!.pointee
        let n = Int(info.width) * Int(info.height)
        var depth = [UInt16](repeating: 0, count: n)
        var ir = [UInt16](repeating: 0, count: n)
        raw.withUnsafeBytes { bytes in
            let p = bytes.bindMemory(to: UInt8.self).baseAddress
            if let metal {
                XCTAssertTrue(openk4a_metal_decode(metal, model, p, raw.count, &depth, &ir))
            } else {
                openk4a_depth_decode_full(model, p, raw.count, &depth, &ir, nil)
            }
        }
        openk4a_depth_model_free(model)
        openk4a_calibration_free(&calibration)
        return (depth, ir, String(cString: source))
    }

    static func agreement(_ ours: [UInt16], _ oracle: [UInt16], ourIR: [UInt16], oracleIR: [UInt16]) -> Agreement {
        var both = 0, onlyOurs = 0, onlyOracle = 0
        var sum = 0.0, sumSq = 0.0
        var ratios: [Double] = []
        for i in 0..<ours.count {
            let a = ours[i], b = oracle[i]
            if a != 0 && b != 0 {
                both += 1
                let d = Double(a) - Double(b)
                sum += d; sumSq += d * d
                if i % 7 == 0, ourIR[i] != 0, oracleIR[i] != 0 { ratios.append(Double(ourIR[i]) / Double(oracleIR[i])) }
            } else if a != 0 { onlyOurs += 1 } else if b != 0 { onlyOracle += 1 }
        }
        ratios.sort()
        return Agreement(bias: sum / Double(both), rms: (sumSq / Double(both)).squareRoot(),
                         precision: Double(both) / Double(both + onlyOurs), recall: Double(both) / Double(both + onlyOracle),
                         irRatio: ratios[ratios.count / 2])
    }

    func check(_ name: String, _ mode: k4a_depth_mode_t, biasWithin: Double, rmsBelow: Double, precisionAtLeast: Double, recallAtLeast: Double) {
        let raw = Self.fixture("\(name).raw")
        let oracleDepth = Self.oracle("\(name).depth.u16")
        let oracleIR = Self.oracle("\(name).ir.u16")
        let cpu = Self.decode(mode: mode, raw: raw, metal: nil)
        XCTAssertEqual(cpu.source, "the device's own calibration")
        let a = Self.agreement(cpu.depth, oracleDepth, ourIR: cpu.ir, oracleIR: oracleIR)
        print("oracle parity \(name): bias \(a.bias) mm, rms \(a.rms), precision \(a.precision), recall \(a.recall), IR ratio \(a.irRatio)")
        XCTAssertLessThan(abs(a.bias), biasWithin, "\(name) bias \(a.bias)")
        XCTAssertLessThan(a.rms, rmsBelow, "\(name) rms \(a.rms)")
        XCTAssertGreaterThan(a.precision, precisionAtLeast, "\(name) precision \(a.precision)")
        XCTAssertGreaterThan(a.recall, recallAtLeast, "\(name) recall \(a.recall)")
        XCTAssertEqual(a.irRatio, 1.0, accuracy: 0.015, "\(name) IR ratio \(a.irRatio)")

        if let metal = openk4a_metal_decoder_create() {
            let gpu = Self.decode(mode: mode, raw: raw, metal: metal)
            openk4a_metal_decoder_destroy(metal)
            XCTAssertEqual(gpu.depth, cpu.depth, "\(name): Metal depth differs from the CPU pass")
            XCTAssertEqual(gpu.ir, cpu.ir, "\(name): Metal IR differs from the CPU pass")
        }
    }

    func testNFOVUnbinnedMatchesEngine() {
        check("nfov_unbinned", K4A_DEPTH_MODE_NFOV_UNBINNED, biasWithin: 0.6, rmsBelow: 1.2, precisionAtLeast: 0.99, recallAtLeast: 0.975)
    }

    func testNFOVBinnedMatchesEngine() {
        check("nfov_2x2binned", K4A_DEPTH_MODE_NFOV_2X2BINNED, biasWithin: 0.6, rmsBelow: 1.0, precisionAtLeast: 0.96, recallAtLeast: 0.99)
    }

    func testWFOVBinnedMatchesEngine() {
        check("wfov_2x2binned", K4A_DEPTH_MODE_WFOV_2X2BINNED, biasWithin: 0.8, rmsBelow: 1.0, precisionAtLeast: 0.99, recallAtLeast: 0.97)
    }

    func testWFOVUnbinnedMatchesEngine() {
        check("wfov_unbinned", K4A_DEPTH_MODE_WFOV_UNBINNED, biasWithin: 0.7, rmsBelow: 0.9, precisionAtLeast: 0.99, recallAtLeast: 0.97)
    }

    func testFOIMaskRecordsTile() {
        let block = [UInt8](Self.fixture("calibration_block.bin"))
        for (mode, rows, cols) in [(UInt8(4), 576, 640), (1, 288, 320), (7, 512, 512), (5, 1024, 1024)] {
            var foi = openk4a_calblock_foi_t()
            XCTAssertTrue(block.withUnsafeBufferPointer { openk4a_calblock_find_foi($0.baseAddress, $0.count, mode, &foi) }, "mode \(mode)")
            XCTAssertEqual(Int(foi.rows), rows); XCTAssertEqual(Int(foi.cols), cols)
            var lit = 0
            for row in 0..<rows {
                var first: Int32 = 0, last: Int32 = 0
                if openk4a_calblock_foi_bounds(&foi, Int32(row), &first, &last) {
                    XCTAssertLessThanOrEqual(first, last); XCTAssertLessThan(Int(last), cols); lit += 1
                }
            }
            XCTAssertGreaterThan(lit, rows / 2, "mode \(mode) has lit rows")
        }
        // The NFOV unbinned record's middle row spans the whole width; the top row does not.
        var foi = openk4a_calblock_foi_t()
        _ = block.withUnsafeBufferPointer { openk4a_calblock_find_foi($0.baseAddress, $0.count, 4, &foi) }
        var first: Int32 = 0, last: Int32 = 0
        XCTAssertTrue(openk4a_calblock_foi_bounds(&foi, 288, &first, &last)); XCTAssertEqual(first, 0); XCTAssertEqual(last, 639)
        XCTAssertTrue(openk4a_calblock_foi_bounds(&foi, 0, &first, &last)); XCTAssertGreaterThan(first, 100); XCTAssertLessThan(last, 520)
    }
}
