import XCTest
import Metal
@testable import DKKit
import DKCore

/// The GPU transformation engine against the CPU one, on the recorded frame.
final class MetalTransformationTests: XCTestCase {
    static func calibration(_ resolution: k4a_color_resolution_t) -> k4a_calibration_t {
        let json = PipelineTests.fixture("calibration.json")
        var text = [CChar](repeating: 0, count: json.count + 1)
        json.withUnsafeBytes { bytes in for i in 0..<json.count { text[i] = CChar(bitPattern: bytes[i]) } }
        var calibration = k4a_calibration_t()
        XCTAssertEqual(k4a_calibration_get_from_raw(&text, text.count, K4A_DEPTH_MODE_NFOV_UNBINNED, resolution, &calibration), K4A_RESULT_SUCCEEDED)
        return calibration
    }

    static func gradient(width: Int, height: Int) -> DKImage {
        let image = DKImage.allocate(format: K4A_IMAGE_FORMAT_COLOR_BGRA32, width: width, height: height, strideBytes: width * 4)!
        let bytes = image.bytes
        for y in 0..<height {
            for x in 0..<width {
                let i = (y * width + x) * 4
                bytes[i] = UInt8(x * 255 / max(width - 1, 1))
                bytes[i + 1] = UInt8(y * 255 / max(height - 1, 1))
                bytes[i + 2] = UInt8((x + y) % 256)
                bytes[i + 3] = 255
            }
        }
        return image
    }

    func testPointCloudMatchesCPU() throws {
        let calibration = Self.calibration(K4A_COLOR_RESOLUTION_720P)
        guard let metal = MetalTransformation(calibration: calibration) else { throw XCTSkip("no Metal device") }
        let cpu = try XCTUnwrap(DKTransformation(calibration: calibration))
        let depth = PipelineTests.fixtureDepth()
        let reference = try XCTUnwrap(cpu.pointCloud(from: depth))
        let (texture, image) = try XCTUnwrap(metal.pointCloud(depth))
        XCTAssertEqual(texture.width, 640)
        var worst = 0
        var count = 0
        reference.bytes.withMemoryRebound(to: Int16.self) { a in
            image.bytes.withMemoryRebound(to: Int16.self) { b in
                for i in 0..<(640 * 576 * 3) {
                    worst = max(worst, abs(Int(a[i]) - Int(b[i])))
                    if a[i] != b[i] { count += 1 }
                }
            }
        }
        XCTAssertLessThanOrEqual(worst, 1, "point cloud differs by more than 1 mm")
        XCTAssertLessThan(count, 640 * 576 * 3 / 100, "\(count) components differ")
        print("point cloud: \(count) components differ by up to \(worst) mm; metal \(String(format: "%.2f", metal.timings.pointCloudMilliseconds)) ms")
    }

    func testDepthToColorMatchesCPU() throws {
        let calibration = Self.calibration(K4A_COLOR_RESOLUTION_720P)
        guard let metal = MetalTransformation(calibration: calibration) else { throw XCTSkip("no Metal device") }
        let cpu = try XCTUnwrap(DKTransformation(calibration: calibration))
        let depth = PipelineTests.fixtureDepth()
        let started = DispatchTime.now().uptimeNanoseconds
        let reference = try XCTUnwrap(cpu.depthToColorCamera(depth))
        let cpuMs = Double(DispatchTime.now().uptimeNanoseconds - started) / 1e6
        let image = try XCTUnwrap(metal.depthToColorCameraImage(depth))
        XCTAssertEqual(image.width, 1280)
        XCTAssertEqual(image.height, 720)
        var both = 0, agree = 0, onlyCPU = 0, onlyMetal = 0, worst = 0
        reference.withUInt16 { a in
            image.withUInt16 { b in
                for i in 0..<a.count {
                    if a[i] != 0 && b[i] != 0 {
                        both += 1
                        let d = abs(Int(a[i]) - Int(b[i]))
                        if d <= 2 { agree += 1 }
                        worst = max(worst, d)
                    } else if a[i] != 0 { onlyCPU += 1 } else if b[i] != 0 { onlyMetal += 1 }
                }
            }
        }
        let total = 1280 * 720
        print("depth->colour 720p: both \(both), within 2 mm \(agree) (\(100 * agree / max(both, 1))%), only cpu \(onlyCPU), only metal \(onlyMetal), worst \(worst) mm; cpu \(String(format: "%.1f", cpuMs)) ms, metal \(String(format: "%.2f", metal.timings.depthToColorMilliseconds)) ms")
        XCTAssertGreaterThan(both, 100_000)
        XCTAssertGreaterThanOrEqual(Double(agree) / Double(max(both, 1)), 0.95)
        XCTAssertLessThan(Double(onlyCPU + onlyMetal) / Double(total), 0.03)
    }

    /// A straight CPU reference: per depth pixel, the SDK's own 2D-to-2D
    /// mapping and a bilinear sample with the right 4-byte pixel stride. (The
    /// OpenK4A CPU engine's bilinear() indexes BGRA by x0 rather than x0 * 4
    /// and samples the wrong channel, so it is not the reference here.)
    static func referenceColorToDepth(calibration: k4a_calibration_t, depth: DKImage, color: DKImage) -> [UInt8] {
        var cal = calibration
        let w = depth.width, h = depth.height, cw = color.width, ch = color.height
        var out = [UInt8](repeating: 0, count: w * h * 4)
        let src = color.bytes
        depth.withUInt16 { values in
            for y in 0..<h {
                for x in 0..<w {
                    let d = values[y * w + x]
                    if d == 0 { continue }
                    var p2 = k4a_float2_t(xy: .init(x: Float(x), y: Float(y)))
                    var uv = k4a_float2_t()
                    var valid: Int32 = 0
                    guard k4a_calibration_2d_to_2d(&cal, &p2, Float(d), K4A_CALIBRATION_TYPE_DEPTH, K4A_CALIBRATION_TYPE_COLOR, &uv, &valid) == K4A_RESULT_SUCCEEDED,
                          valid == 1, uv.xy.x >= 0, uv.xy.y >= 0, uv.xy.x < Float(cw - 1), uv.xy.y < Float(ch - 1) else { continue }
                    let x0 = Int(uv.xy.x.rounded(.down)), y0 = Int(uv.xy.y.rounded(.down))
                    let fx = uv.xy.x - Float(x0), fy = uv.xy.y - Float(y0)
                    for c in 0..<3 {
                        let r0 = y0 * cw * 4 + c, r1 = r0 + cw * 4
                        let top = Float(src[r0 + x0 * 4]) * (1 - fx) + Float(src[r0 + (x0 + 1) * 4]) * fx
                        let bottom = Float(src[r1 + x0 * 4]) * (1 - fx) + Float(src[r1 + (x0 + 1) * 4]) * fx
                        out[(y * w + x) * 4 + c] = UInt8(top * (1 - fy) + bottom * fy + 0.5)
                    }
                    out[(y * w + x) * 4 + 3] = 255
                }
            }
        }
        return out
    }

    func testColorToDepthMatchesCPU() throws {
        let calibration = Self.calibration(K4A_COLOR_RESOLUTION_720P)
        guard let metal = MetalTransformation(calibration: calibration) else { throw XCTSkip("no Metal device") }
        let depth = PipelineTests.fixtureDepth()
        let color = Self.gradient(width: 1280, height: 720)
        let started = DispatchTime.now().uptimeNanoseconds
        let referenceBytes = Self.referenceColorToDepth(calibration: calibration, depth: depth, color: color)
        let cpuMs = Double(DispatchTime.now().uptimeNanoseconds - started) / 1e6
        let image = try XCTUnwrap(metal.colorToDepthCameraImage(depth: depth, color: color))
        let reference = DKImage.allocate(format: K4A_IMAGE_FORMAT_COLOR_BGRA32, width: 640, height: 576, strideBytes: 640 * 4)!
        referenceBytes.withUnsafeBytes { reference.bytes.copyMemory(from: $0) }
        var close = 0, total = 0, worst = 0
        let a = reference.bytes, b = image.bytes
        for i in 0..<(640 * 576) {
            total += 1
            var ok = true
            for c in 0..<4 {
                let d = abs(Int(a[i * 4 + c]) - Int(b[i * 4 + c]))
                worst = max(worst, d)
                if d > 2 { ok = false }
            }
            if ok { close += 1 }
        }
        print("colour->depth: \(close)/\(total) pixels within 2 levels, worst \(worst); cpu \(String(format: "%.1f", cpuMs)) ms, metal \(String(format: "%.2f", metal.timings.colorToDepthMilliseconds)) ms")
        XCTAssertGreaterThanOrEqual(Double(close) / Double(total), 0.98)
    }

    func testTimingsAt2160p() throws {
        let calibration = Self.calibration(K4A_COLOR_RESOLUTION_2160P)
        guard let metal = MetalTransformation(calibration: calibration) else { throw XCTSkip("no Metal device") }
        let cpu = try XCTUnwrap(DKTransformation(calibration: calibration))
        let depth = PipelineTests.fixtureDepth()
        let color = Self.gradient(width: 3840, height: 2160)
        _ = metal.depthToColorCamera(depth)  // warm
        var started = DispatchTime.now().uptimeNanoseconds
        let reference = try XCTUnwrap(cpu.depthToColorCamera(depth))
        let cpuD2C = Double(DispatchTime.now().uptimeNanoseconds - started) / 1e6
        let image = try XCTUnwrap(metal.depthToColorCameraImage(depth))
        var both = 0, agree = 0
        reference.withUInt16 { a in image.withUInt16 { b in
            for i in 0..<a.count where a[i] != 0 && b[i] != 0 { both += 1; if abs(Int(a[i]) - Int(b[i])) <= 2 { agree += 1 } }
        } }
        started = DispatchTime.now().uptimeNanoseconds
        _ = cpu.colorToDepthCamera(depth: depth, color: color)  // the C engine, for its timing only
        let cpuC2D = Double(DispatchTime.now().uptimeNanoseconds - started) / 1e6
        _ = metal.colorToDepthCamera(depth: depth, color: color)
        print(String(format: "2160p: depth->colour cpu %.1f ms, metal %.2f ms (agree %d/%d within 2 mm); colour->depth cpu %.1f ms, metal %.2f ms",
                     cpuD2C, metal.timings.depthToColorMilliseconds, agree, both, cpuC2D, metal.timings.colorToDepthMilliseconds))
        XCTAssertGreaterThanOrEqual(Double(agree) / Double(max(both, 1)), 0.95)
        XCTAssertLessThan(metal.timings.depthToColorMilliseconds, cpuD2C)
    }
}
