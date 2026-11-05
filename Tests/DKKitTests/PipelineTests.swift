import XCTest
import Metal
@testable import DKKit
import DKCore
import Syphon

final class PipelineTests: XCTestCase {
    static func fixture(_ name: String) -> Data {
        let url = Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures")!
        return try! Data(contentsOf: url)
    }

    /// A depth image decoded from the recorded frame, as a DKImage.
    static func fixtureDepth() -> DKImage {
        let raw = fixture("nfov_unbinned.raw")
        var source = [CChar](repeating: 0, count: 128)
        let model = openk4a_depth_model_open(K4A_DEPTH_MODE_NFOV_UNBINNED, nil, 0, nil, &source, source.count)!
        let image = DKImage.allocate(format: K4A_IMAGE_FORMAT_DEPTH16, width: 640, height: 576, strideBytes: 1280)!
        raw.withUnsafeBytes { bytes in
            openk4a_depth_decode(model, bytes.bindMemory(to: UInt8.self).baseAddress, raw.count,
                                 image.bytes.baseAddress!.assumingMemoryBound(to: UInt16.self))
        }
        openk4a_depth_model_free(model)
        return image
    }

    static func readBGRA(_ texture: MTLTexture) -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: texture.width * texture.height * 4)
        pixels.withUnsafeMutableBytes { bytes in
            texture.getBytes(bytes.baseAddress!, bytesPerRow: texture.width * 4,
                             from: MTLRegionMake2D(0, 0, texture.width, texture.height), mipmapLevel: 0)
        }
        return pixels
    }

    func testConfigurationRates() {
        var config = DKConfiguration(depthMode: .wfovUnbinned, colorResolution: .p720, frameRate: .fps30)
        XCTAssertEqual(config.effectiveFrameRate, .fps15, "WFOV unbinned caps the rate at 15")
        config = DKConfiguration(depthMode: .nfovUnbinned, colorResolution: .p3072, frameRate: .fps30)
        XCTAssertEqual(config.effectiveFrameRate, .fps15, "3072p caps the rate at 15")
        config = DKConfiguration(depthMode: .nfovUnbinned, colorResolution: .p720, frameRate: .fps30)
        XCTAssertEqual(config.effectiveFrameRate, .fps30)
        XCTAssertEqual(config.k4a.depth_mode, K4A_DEPTH_MODE_NFOV_UNBINNED)
        XCTAssertEqual(config.k4a.color_resolution, K4A_COLOR_RESOLUTION_720P)
        XCTAssertEqual(config.k4a.camera_fps, K4A_FRAMES_PER_SECOND_30)
        // Round-trips through JSON for the saved settings.
        let data = try! JSONEncoder().encode(config)
        XCTAssertEqual(try? JSONDecoder().decode(DKConfiguration.self, from: data), config)
    }

    func testDKImageWrapsBuffers() {
        let image = DKImage.allocate(format: K4A_IMAGE_FORMAT_DEPTH16, width: 4, height: 2, strideBytes: 8)!
        XCTAssertEqual(image.width, 4)
        XCTAssertEqual(image.height, 2)
        XCTAssertEqual(image.byteCount, 16)
        XCTAssertEqual(image.format, .depth16)
        image.bytes.storeBytes(of: UInt16(1234), toByteOffset: 2, as: UInt16.self)
        image.withUInt16 { XCTAssertEqual($0[1], 1234) }
        XCTAssertEqual(image.data.count, 16)
    }

    func testDepthPackingRoundTrips() throws {
        guard let textures = FrameTextures() else { throw XCTSkip("no Metal device") }
        let depth = Self.fixtureDepth()
        let commandBuffer = textures.queue.makeCommandBuffer()!
        var packing = FrameTextures.Packing()
        packing.previewRangeMillimetres = 4000
        let packed = try XCTUnwrap(textures.packedDepth(depth, key: "test", packing: packing, on: commandBuffer))
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        XCTAssertEqual(packed.width, 640)
        XCTAssertEqual(packed.height, 576)
        let pixels = Self.readBGRA(packed)
        var checked = 0
        depth.withUInt16 { values in
            for i in stride(from: 0, to: values.count, by: 97) {
                let b = pixels[i * 4], g = pixels[i * 4 + 1], r = pixels[i * 4 + 2], a = pixels[i * 4 + 3]
                let unpacked = UInt16(r) << 8 | UInt16(g)
                XCTAssertEqual(unpacked, values[i], "pixel \(i)")
                XCTAssertEqual(a, 255)
                let preview = values[i] == 0 ? 0 : min(255, Int(Float(values[i]) / 4000 * 255 + 0.5))
                XCTAssertLessThanOrEqual(abs(Int(b) - preview), 1, "preview pixel \(i)")
                checked += 1
            }
        }
        XCTAssertGreaterThan(checked, 3000)
    }

    func testColorizedDepthMarksInvalidBlack() throws {
        guard let textures = FrameTextures() else { throw XCTSkip("no Metal device") }
        let depth = Self.fixtureDepth()
        let commandBuffer = textures.queue.makeCommandBuffer()!
        let colorized = try XCTUnwrap(textures.colorizedDepth(depth, key: "test", range: 4000, on: commandBuffer))
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        let pixels = Self.readBGRA(colorized)
        depth.withUInt16 { values in
            for i in stride(from: 0, to: values.count, by: 131) where values[i] == 0 {
                XCTAssertEqual(pixels[i * 4], 0); XCTAssertEqual(pixels[i * 4 + 1], 0); XCTAssertEqual(pixels[i * 4 + 2], 0)
            }
            for i in stride(from: 0, to: values.count, by: 131) where values[i] != 0 {
                XCTAssertGreaterThan(Int(pixels[i * 4]) + Int(pixels[i * 4 + 1]) + Int(pixels[i * 4 + 2]), 0)
            }
        }
    }

    /// Publishes a texture on a Syphon server and reads it back through a
    /// Syphon client in the same process: the same path TouchDesigner takes.
    func testSyphonRoundTrip() throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { throw XCTSkip("no Metal device") }
        let width = 64, height = 32
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        descriptor.usage = [.shaderRead]
        let source = device.makeTexture(descriptor: descriptor)!
        var pattern = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height { for x in 0..<width {
            let i = (y * width + x) * 4
            pattern[i] = UInt8(x * 4); pattern[i + 1] = UInt8(y * 8); pattern[i + 2] = 200; pattern[i + 3] = 255
        } }
        source.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0, withBytes: pattern, bytesPerRow: width * 4)

        let output = SyphonOutput(device: device, namePrefix: "DKTest")
        defer { output.stopAll() }
        let server = try XCTUnwrap(output.server(for: .color))
        let description = server.serverDescription
        let client = try XCTUnwrap(SyphonMetalClient(serverDescription: description, device: device, options: nil, newFrameHandler: nil))
        defer { client.stop() }

        // A frame or two for the client to attach, then publish.
        var received: MTLTexture?
        for attempt in 0..<40 {
            let commandBuffer = queue.makeCommandBuffer()!
            output.publish(source, on: .color, commandBuffer: commandBuffer, flipped: false)
            commandBuffer.commit()
            commandBuffer.waitUntilCompleted()
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
            if let frame = client.newFrameImage() { received = frame; break }
            _ = attempt
        }
        let frame = try XCTUnwrap(received, "no frame came back through Syphon")
        XCTAssertEqual(frame.width, width)
        XCTAssertEqual(frame.height, height)
        let pixels = Self.readBGRA(frame)
        // The unflipped publish keeps row 0 at the top, so the patterns match row for row.
        var mismatches = 0
        for y in 0..<height { for x in 0..<width {
            let i = (y * width + x) * 4
            if pixels[i] != pattern[i] || pixels[i + 1] != pattern[i + 1] || pixels[i + 2] != pattern[i + 2] { mismatches += 1 }
        } }
        // Either orientation would be a usable stream; record which one Syphon gives so the app's default is right.
        if mismatches > 0 {
            var flippedMismatches = 0
            for y in 0..<height { for x in 0..<width {
                let i = (y * width + x) * 4, j = ((height - 1 - y) * width + x) * 4
                if pixels[i] != pattern[j] || pixels[i + 1] != pattern[j + 1] || pixels[i + 2] != pattern[j + 2] { flippedMismatches += 1 }
            } }
            XCTAssertEqual(flippedMismatches, 0, "the frame came back neither upright nor flipped (\(mismatches) upright mismatches)")
            XCTFail("Syphon returned the frame vertically flipped; the app should publish with flipped=true by default")
        }
    }
}

final class XYTableTests: XCTestCase {
    func testXYTablePacksUnitRays() throws {
        guard let textures = FrameTextures() else { throw XCTSkip("no Metal device") }
        let json = PipelineTests.fixture("calibration.json")
        var text = [CChar](repeating: 0, count: json.count + 1)
        json.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in for i in 0..<json.count { text[i] = CChar(bitPattern: bytes[i]) } }
        var calibration = k4a_calibration_t()
        XCTAssertEqual(k4a_calibration_get_from_raw(&text, text.count, K4A_DEPTH_MODE_NFOV_UNBINNED, K4A_COLOR_RESOLUTION_720P, &calibration), K4A_RESULT_SUCCEEDED)
        let table = try XCTUnwrap(textures.xyTableTexture(calibration: calibration, key: "test"))
        XCTAssertEqual(table.width, 640)
        XCTAssertEqual(table.height, 576)
        let pixels = PipelineTests.readBGRA(table)
        let range = FrameTextures.xyTableRange
        func unpack(_ i: Int) -> (Float, Float) {
            let px = UInt16(pixels[i * 4 + 2]) << 8 | UInt16(pixels[i * 4 + 1])
            let py = UInt16(pixels[i * 4 + 3]) << 8 | UInt16(pixels[i * 4])
            return (Float(px) / 65535 * 2 * range - range, Float(py) / 65535 * 2 * range - range)
        }
        // The principal point's ray is (0, 0); a pixel to its right has x > 0; one below has y > 0.
        let cx = Int(calibration.depth_camera_calibration.intrinsics.parameters.param.cx.rounded())
        let cy = Int(calibration.depth_camera_calibration.intrinsics.parameters.param.cy.rounded())
        let centre = unpack(cy * 640 + cx)
        XCTAssertEqual(centre.0, 0, accuracy: 0.01)
        XCTAssertEqual(centre.1, 0, accuracy: 0.01)
        XCTAssertGreaterThan(unpack(cy * 640 + cx + 100).0, 0.1)
        XCTAssertGreaterThan(unpack((cy + 100) * 640 + cx).1, 0.1)
        // Matches the calibration's own unprojection within the 16-bit step.
        var pixel = k4a_float2_t(xy: .init(x: 100, y: 50))
        var point = k4a_float3_t()
        var valid: Int32 = 0
        XCTAssertEqual(k4a_calibration_2d_to_3d(&calibration, &pixel, 1000, K4A_CALIBRATION_TYPE_DEPTH, K4A_CALIBRATION_TYPE_DEPTH, &point, &valid), K4A_RESULT_SUCCEEDED)
        let packed = unpack(50 * 640 + 100)
        XCTAssertEqual(packed.0, point.xyz.x / 1000, accuracy: 2 * range / 65535 + 0.0001)
        XCTAssertEqual(packed.1, point.xyz.y / 1000, accuracy: 2 * range / 65535 + 0.0001)
    }
}


final class OutputPipelinePreviewTests: XCTestCase {
    func testPreviewsExistWhateverTheOutputsAre() throws {
        guard let pipeline = OutputPipeline() else { throw XCTSkip("no Metal device") }
        var settings = OutputSettings()
        settings.streams = []            // nothing published on Syphon
        pipeline.settings = settings
        let depth = PipelineTests.fixtureDepth()
        let ir = DKImage.allocate(format: K4A_IMAGE_FORMAT_IR16, width: 640, height: 576, strideBytes: 1280)!
        var handle: k4a_capture_t? = nil
        XCTAssertEqual(k4a_capture_create(&handle), K4A_RESULT_SUCCEEDED)
        k4a_capture_set_depth_image(handle, depth.handle)
        k4a_capture_set_ir_image(handle, ir.handle)
        let capture = DKCapture(handle: handle!, sequence: 1)
        k4a_capture_release(handle)
        pipeline.process(capture)
        XCTAssertNotNil(pipeline.preview.texture(for: .depthPreview))
        XCTAssertNotNil(pipeline.preview.texture(for: .depth))
        XCTAssertNotNil(pipeline.preview.texture(for: .ir))
        XCTAssertTrue(pipeline.syphon.activeStreams.isEmpty)
        // The colourized preview is not black where there is depth.
        let colorized = pipeline.preview.texture(for: .depthPreview)!
        let pixels = PipelineTests.readBGRA(colorized)
        var lit = 0
        depth.withUInt16 { values in
            for i in stride(from: 0, to: values.count, by: 101) where values[i] != 0 {
                if Int(pixels[i * 4]) + Int(pixels[i * 4 + 1]) + Int(pixels[i * 4 + 2]) > 0 { lit += 1 }
            }
        }
        XCTAssertGreaterThan(lit, 1000)
        pipeline.stop()
    }
}
