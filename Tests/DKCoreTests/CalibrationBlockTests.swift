import XCTest
@testable import DKCore

/// The IR sensor's calibration block, as recorded from the fixture camera.
final class CalibrationBlockTests: XCTestCase {
    func testBlockParsesAndTiles() {
        let block = FrameTests.fixture("calibration_block.bin")
        var info = openk4a_calblock_info_t()
        var why = [CChar](repeating: 0, count: 160)
        let ok = block.withUnsafeBytes { bytes in
            openk4a_calblock_parse(bytes.bindMemory(to: UInt8.self).baseAddress, block.count, &info, &why, why.count)
        }
        XCTAssertTrue(ok, String(cString: why))
        XCTAssertEqual(info.file_size, UInt32(block.count))
        XCTAssertEqual(info.record_count, 99)
        XCTAssertEqual(info.records_found, 99)
        XCTAssertEqual(info.sensor_rows, 1024)
        XCTAssertEqual(info.sensor_cols, 1024)
        XCTAssertEqual(info.p0_records, 16)
        XCTAssertEqual(withUnsafePointer(to: info.config_version) { String(cString: UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self)) }, "6109.11")
        XCTAssertEqual(withUnsafePointer(to: info.serial) { String(cString: UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self)) }, "2141-7700031")

        // A truncated block is refused, and says why.
        let truncated = block.prefix(block.count - 1000)
        let refused = truncated.withUnsafeBytes { bytes in
            openk4a_calblock_parse(bytes.bindMemory(to: UInt8.self).baseAddress, truncated.count, &info, &why, why.count)
        }
        XCTAssertFalse(refused)
        XCTAssertTrue(String(cString: why).contains("bytes"))
    }

    func testP0RecordsForEveryDepthMode() {
        let block = FrameTests.fixture("calibration_block.bin")
        block.withUnsafeBytes { bytes in
            let base = bytes.bindMemory(to: UInt8.self).baseAddress
            for (mode, rows, cols, offsetRows, offsetCols) in [(UInt8(4), 576, 640, 180, 192), (5, 1024, 1024, 0, 0), (7, 512, 512, 0, 0)] {
                for (index, frequency) in [(UInt8(1), 19800), (2, 18900), (3, 5400)] {
                    var p0 = openk4a_calblock_p0_t()
                    XCTAssertTrue(openk4a_calblock_find_p0(base, block.count, mode, index, &p0), "mode \(mode) freq \(index)")
                    XCTAssertEqual(Int(p0.freq_10khz), frequency)
                    XCTAssertEqual(Int(p0.rows), rows)
                    XCTAssertEqual(Int(p0.cols), cols)
                    XCTAssertEqual(Int(p0.offset_rows), offsetRows)
                    XCTAssertEqual(Int(p0.offset_cols), offsetCols)
                    XCTAssertEqual(p0.row_coeff_count, 1)
                    XCTAssertEqual(p0.col_coeff_count, 3)
                    // The profiles are smooth: neighbouring entries differ by a fraction of a radian.
                    for row in 1..<rows {
                        XCTAssertLessThan(abs(openk4a_calblock_row_coeff(&p0, Int32(row), 0) - openk4a_calblock_row_coeff(&p0, Int32(row - 1), 0)), 0.2)
                    }
                    for col in 1..<cols {
                        XCTAssertLessThan(abs(openk4a_calblock_col_coeff(&p0, Int32(col), 2) - openk4a_calblock_col_coeff(&p0, Int32(col - 1), 2)), 0.2)
                        XCTAssertEqual(openk4a_calblock_col_coeff(&p0, Int32(col), 0), 0)
                        XCTAssertEqual(openk4a_calblock_col_coeff(&p0, Int32(col), 1), 0)
                    }
                }
            }
            var missing = openk4a_calblock_p0_t()
            XCTAssertFalse(openk4a_calblock_find_p0(base, block.count, 4, 4, &missing))
        }
    }

    /// The phase-to-millimetre constants come from the block's modulation
    /// frequencies and the engine's speed of light, not from a fitted scale.
    func testRangeConstantsDeriveFromTheModulationFrequencies() {
        let block = FrameTests.fixture("calibration_block.bin")
        let json = FrameTests.fixture("calibration.json")
        var calibration = openk4a_calibration_t()
        XCTAssertTrue(json.withUnsafeBytes { bytes in
            openk4a_calibration_parse(bytes.bindMemory(to: CChar.self).baseAddress, json.count, &calibration)
        })
        defer { openk4a_calibration_free(&calibration) }
        for mode in [K4A_DEPTH_MODE_NFOV_UNBINNED, K4A_DEPTH_MODE_WFOV_2X2BINNED, K4A_DEPTH_MODE_WFOV_UNBINNED] {
            var source = [CChar](repeating: 0, count: 128)
            let model = block.withUnsafeBytes { bytes in
                openk4a_depth_model_open(mode, bytes.bindMemory(to: UInt8.self).baseAddress, block.count, &calibration, &source, source.count)
            }
            var tables = openk4a_depth_model_tables_t()
            XCTAssertTrue(openk4a_depth_model_tables(model, &tables))
            // 198, 189 and 54 MHz: M = 22, 21, 6 over f_base 9 MHz; c = 299,714,130 m/s,
            // the speed of light in air the engine's own Alpha constants imply.
            let m: [Double] = [22, 21, 6]
            let sumSq = m.reduce(0) { $0 + $1 * $1 }
            let expected = m.map { $0 * 2.9971413e11 / (2.0 * 9.0e6 * sumSq) }
            XCTAssertEqual(Double(tables.alpha.0), expected[0], accuracy: 0.001)
            XCTAssertEqual(Double(tables.alpha.1), expected[1], accuracy: 0.001)
            XCTAssertEqual(Double(tables.alpha.2), expected[2], accuracy: 0.001)
            XCTAssertEqual(tables.c_m.0, 22); XCTAssertEqual(tables.c_m.1, 21); XCTAssertEqual(tables.c_m.2, 6)
            XCTAssertEqual(Double(tables.c_md.0), 22 / sumSq, accuracy: 1e-7)
            XCTAssertEqual(Double(tables.c_md.2), 6 / sumSq, accuracy: 1e-7)
            // 381.183, 363.857, 103.959 mm per turn: the engine's own Alpha, recovered from the frequencies and c.
            XCTAssertEqual(tables.alpha.0, 381.183, accuracy: 0.01)
            XCTAssertEqual(tables.alpha.1, 363.857, accuracy: 0.01)
            XCTAssertEqual(tables.alpha.2, 103.959, accuracy: 0.01)
            openk4a_depth_model_free(model)
        }
    }

    func testModelComesFromTheDeviceBlock() {
        let block = FrameTests.fixture("calibration_block.bin")
        let json = FrameTests.fixture("calibration.json")
        var calibration = openk4a_calibration_t()
        XCTAssertTrue(json.withUnsafeBytes { bytes in
            openk4a_calibration_parse(bytes.bindMemory(to: CChar.self).baseAddress, json.count, &calibration)
        })
        defer { openk4a_calibration_free(&calibration) }
        for mode in [K4A_DEPTH_MODE_NFOV_UNBINNED, K4A_DEPTH_MODE_NFOV_2X2BINNED, K4A_DEPTH_MODE_WFOV_2X2BINNED, K4A_DEPTH_MODE_WFOV_UNBINNED] {
            var source = [CChar](repeating: 0, count: 128)
            let model = block.withUnsafeBytes { bytes in
                openk4a_depth_model_open(mode, bytes.bindMemory(to: UInt8.self).baseAddress, block.count, &calibration, &source, source.count)
            }
            XCTAssertNotNil(model, "\(mode)")
            XCTAssertEqual(String(cString: source), "the device's own calibration", "\(mode)")
            openk4a_depth_model_free(model)
        }
        // Without the camera calibration there is no radialToZ, and the compiled-in tables are the fallback.
        var source = [CChar](repeating: 0, count: 128)
        let fallback = block.withUnsafeBytes { bytes in
            openk4a_depth_model_open(K4A_DEPTH_MODE_NFOV_UNBINNED, bytes.bindMemory(to: UInt8.self).baseAddress, block.count, nil, &source, source.count)
        }
        XCTAssertNotNil(fallback)
        XCTAssertEqual(String(cString: source), "compiled in")
        openk4a_depth_model_free(fallback)
    }

    func testDeviceTablesDecodeTheFixtureCloseToBuiltin() {
        let raw = FrameTests.fixture("nfov_unbinned.raw")
        let block = FrameTests.fixture("calibration_block.bin")
        let json = FrameTests.fixture("calibration.json")
        var calibration = openk4a_calibration_t()
        _ = json.withUnsafeBytes { bytes in openk4a_calibration_parse(bytes.bindMemory(to: CChar.self).baseAddress, json.count, &calibration) }
        defer { openk4a_calibration_free(&calibration) }
        var source = [CChar](repeating: 0, count: 128)
        let device = block.withUnsafeBytes { bytes in
            openk4a_depth_model_open(K4A_DEPTH_MODE_NFOV_UNBINNED, bytes.bindMemory(to: UInt8.self).baseAddress, block.count, &calibration, &source, source.count)
        }
        let builtin = openk4a_depth_model_open(K4A_DEPTH_MODE_NFOV_UNBINNED, nil, 0, nil, &source, source.count)
        var fromDevice = [UInt16](repeating: 0, count: 640 * 576)
        var fromBuiltin = [UInt16](repeating: 0, count: 640 * 576)
        raw.withUnsafeBytes { bytes in
            let base = bytes.bindMemory(to: UInt8.self).baseAddress
            openk4a_depth_decode(device, base, raw.count, &fromDevice)
            openk4a_depth_decode(builtin, base, raw.count, &fromBuiltin)
        }
        openk4a_depth_model_free(device)
        openk4a_depth_model_free(builtin)
        let validDevice = fromDevice.filter { $0 != 0 }.count
        let validBuiltin = fromBuiltin.filter { $0 != 0 }.count
        // The block path also applies the engine's own invalidations (the
        // illumination mask and the saturation code), which take about a
        // fifth of the builtin's pixels on this frame; the engine agrees, see
        // OracleParityTests.
        XCTAssertGreaterThan(validDevice, validBuiltin * 75 / 100)
        var sum = 0.0, count = 0, within = 0
        for i in 0..<fromDevice.count where fromDevice[i] != 0 && fromBuiltin[i] != 0 {
            let d = Double(fromDevice[i]) - Double(fromBuiltin[i])
            sum += d * d; count += 1
            if abs(d) <= 20 { within += 1 }
        }
        let rms = (sum / Double(count)).squareRoot()
        XCTAssertLessThan(rms, 15, "the two calibrations should agree to a centimetre or so, rms \(rms)")
        XCTAssertGreaterThan(Double(within) / Double(count), 0.99)
    }
}

/// The temperature correction records, and the model built from them.
final class CalibrationBlockTemperatureTests: XCTestCase {
    private func withBlock<T>(_ body: (UnsafePointer<UInt8>, Int) -> T) -> T {
        let block = FrameTests.fixture("calibration_block.bin")
        return block.withUnsafeBytes { bytes in body(bytes.bindMemory(to: UInt8.self).baseAddress!, block.count) }
    }

    func testSpatialTemperatureRecords() {
        withBlock { base, size in
            for (mode, grid) in [(UInt8(4), (640, 576)), (UInt8(5), (1024, 1024)), (UInt8(7), (512, 512)), (UInt8(1), (320, 288))] {
                for freq in UInt8(0)...2 {
                    var record = openk4a_calblock_spatial_temp_t()
                    XCTAssertTrue(openk4a_calblock_find_spatial_temp(base, size, mode, freq, &record), "mode \(mode) freq \(freq)")
                    XCTAssertEqual(Int(record.cols), grid.0)
                    XCTAssertEqual(Int(record.rows), grid.1)
                    XCTAssertEqual(record.freq_10khz, [19800, 18900, 5400][Int(freq)])
                    // The same frequency the P0 record names (1-based there).
                    var p0 = openk4a_calblock_p0_t()
                    XCTAssertTrue(openk4a_calblock_find_p0(base, size, mode, freq + 1, &p0))
                    XCTAssertEqual(p0.freq_10khz, record.freq_10khz)
                    // Both coefficient sets are one set over two temperature bases, ratio -100 / base temperature.
                    let base_t = record.base_cal_temperature.0
                    XCTAssertGreaterThan(base_t, 20); XCTAssertLessThan(base_t, 35)
                    let k = -100 / base_t
                    let ctc = withUnsafeBytes(of: record.column_temp_coeff) { $0.bindMemory(to: Float.self).map { $0 } }
                    let rtc = withUnsafeBytes(of: record.row_temp_coeff) { $0.bindMemory(to: Float.self).map { $0 } }
                    for i in 0..<5 where ctc[i] != 0 {
                        XCTAssertEqual(ctc[5 + i] / ctc[i], k, accuracy: 0.002, "mode \(mode) freq \(freq) coefficient \(i)")
                    }
                    XCTAssertEqual(rtc[1] / rtc[0], k, accuracy: 0.002)
                    XCTAssertEqual(rtc[2] / rtc[0], -2, accuracy: 0.001)
                    XCTAssertNotNil(record.per_column_offsets)
                }
            }
            var missing = openk4a_calblock_spatial_temp_t()
            XCTAssertFalse(openk4a_calblock_find_spatial_temp(base, size, 4, 3, &missing))
        }
    }

    func testGlobalTemperatureRecords() {
        withBlock { base, size in
            for capture in UInt8(1)...9 {
                var record = openk4a_calblock_global_temp_t()
                XCTAssertTrue(openk4a_calblock_find_global_temp(base, size, 4, capture, &record), "capture \(capture)")
                XCTAssertEqual(Int(record.freq_index), Int(capture - 1) / 3)
                XCTAssertEqual(record.laser_id, 16)
                XCTAssertNotEqual(record.amplitude_coeff.0, 0)
                XCTAssertNotEqual(record.phase_coeff.0, 0)
            }
            var missing = openk4a_calblock_global_temp_t()
            XCTAssertFalse(openk4a_calblock_find_global_temp(base, size, 4, 10, &missing))
        }
    }

    func testModelTemperatureComesFromTheBlock() {
        let json = FrameTests.fixture("calibration.json")
        var calibration = openk4a_calibration_t()
        XCTAssertTrue(json.withUnsafeBytes { bytes in
            openk4a_calibration_parse(bytes.bindMemory(to: CChar.self).baseAddress, json.count, &calibration)
        })
        defer { openk4a_calibration_free(&calibration) }
        var source = [CChar](repeating: 0, count: 128)
        let model = withBlock { base, size in
            openk4a_depth_model_open(K4A_DEPTH_MODE_NFOV_UNBINNED, base, size, &calibration, &source, source.count)
        }
        XCTAssertNotNil(model)
        var slope: Float = 0, intercept: Float = 0, fromBlock = false
        var rowCoeffs = [Float](repeating: 0, count: 3)
        XCTAssertTrue(openk4a_depth_model_temperature(model, &slope, &intercept, &rowCoeffs, &fromBlock))
        XCTAssertTrue(fromBlock)
        XCTAssertEqual(slope, 0.01, accuracy: 1e-6)
        // -BaseCalTemperature[0] / 100 for this camera.
        var record = openk4a_calblock_spatial_temp_t()
        withBlock { base, size in _ = openk4a_calblock_find_spatial_temp(base, size, 4, 0, &record) }
        XCTAssertEqual(intercept, -0.01 * record.base_cal_temperature.0, accuracy: 1e-6)
        let rtc = withUnsafeBytes(of: record.row_temp_coeff) { $0.bindMemory(to: Float.self).map { $0 } }
        XCTAssertEqual(rowCoeffs[0], rtc[3] / 640, accuracy: 1e-12)
        // The per-row term follows the column polynomial: rising across the frame, about the same size as the recorded camera's.
        let top = openk4a_depth_model_row_term(model, 0, 0), bottom = openk4a_depth_model_row_term(model, 575, 0)
        XCTAssertLessThan(top, -0.02); XCTAssertGreaterThan(bottom, 0.03)
        XCTAssertEqual(openk4a_depth_model_row_term(model, 575, 2) - openk4a_depth_model_row_term(model, 0, 2), 0.0172, accuracy: 0.002)
        openk4a_depth_model_free(model)

        // The compiled-in tables keep their own measured model.
        let builtin = openk4a_depth_model_open(K4A_DEPTH_MODE_NFOV_UNBINNED, nil, 0, nil, &source, source.count)
        XCTAssertTrue(openk4a_depth_model_temperature(builtin, &slope, &intercept, &rowCoeffs, &fromBlock))
        XCTAssertFalse(fromBlock)
        XCTAssertEqual(slope, 0.0099913086, accuracy: 1e-9)
        openk4a_depth_model_free(builtin)
    }
}
