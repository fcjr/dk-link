import Foundation
import Metal
import DKCore

/// Turns captures into Metal textures, and packs 16-bit planes into the 8-bit
/// BGRA Syphon carries. Shaders are compiled from source on first use so the
/// app needs no metallib and no Metal toolchain to build.
public final class FrameTextures {
    public let device: MTLDevice
    public let queue: MTLCommandQueue
    private let packDepth: MTLComputePipelineState
    private let packIR: MTLComputePipelineState
    private let colorizeDepth: MTLComputePipelineState
    private var cache: [String: MTLTexture] = [:]

    public struct Packing: Sendable, Equatable {
        /// Millimetres at which the preview/8-bit channel reaches full white.
        public var previewRangeMillimetres: Float = 5000
        public init() {}
    }

    public init?(device: MTLDevice? = MTLCreateSystemDefaultDevice()) {
        guard let device, let queue = device.makeCommandQueue() else { return nil }
        self.device = device
        self.queue = queue
        let options = MTLCompileOptions()
        options.fastMathEnabled = false
        guard let library = try? device.makeLibrary(source: FrameTextures.shaderSource, options: options),
              let packDepthFunction = library.makeFunction(name: "pack_depth16"),
              let packIRFunction = library.makeFunction(name: "pack_ir16"),
              let colorizeFunction = library.makeFunction(name: "colorize_depth16"),
              let packDepth = try? device.makeComputePipelineState(function: packDepthFunction),
              let packIR = try? device.makeComputePipelineState(function: packIRFunction),
              let colorizeDepth = try? device.makeComputePipelineState(function: colorizeFunction) else { return nil }
        self.packDepth = packDepth
        self.packIR = packIR
        self.colorizeDepth = colorizeDepth
    }

    private func texture(_ key: String, width: Int, height: Int, format: MTLPixelFormat, usage: MTLTextureUsage) -> MTLTexture? {
        if let existing = cache[key], existing.width == width, existing.height == height, existing.pixelFormat == format {
            return existing
        }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: width, height: height, mipmapped: false)
        descriptor.usage = usage
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        cache[key] = texture
        return texture
    }

    /// A 16-bit plane as an R16Uint texture (for local preview and compute).
    public func upload16(_ image: DKImage, key: String) -> MTLTexture? {
        guard let texture = texture(key, width: image.width, height: image.height, format: .r16Uint, usage: [.shaderRead]) else { return nil }
        texture.replace(region: MTLRegionMake2D(0, 0, image.width, image.height), mipmapLevel: 0,
                        withBytes: image.bytes.baseAddress!, bytesPerRow: image.strideBytes)
        return texture
    }

    /// A BGRA colour frame as a BGRA8Unorm texture.
    public func uploadBGRA(_ image: DKImage, key: String) -> MTLTexture? {
        guard image.format == .bgra32,
              let texture = texture(key, width: image.width, height: image.height, format: .bgra8Unorm, usage: [.shaderRead]) else { return nil }
        texture.replace(region: MTLRegionMake2D(0, 0, image.width, image.height), mipmapLevel: 0,
                        withBytes: image.bytes.baseAddress!, bytesPerRow: image.strideBytes)
        return texture
    }

    private func dispatch(_ pipeline: MTLComputePipelineState, source: MTLTexture, destination: MTLTexture,
                          params: inout PackParams, on commandBuffer: MTLCommandBuffer) {
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else { return }
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(source, index: 0)
        encoder.setTexture(destination, index: 1)
        encoder.setBytes(&params, length: MemoryLayout<PackParams>.stride, index: 0)
        let w = pipeline.threadExecutionWidth
        let h = max(1, pipeline.maxTotalThreadsPerThreadgroup / w)
        encoder.dispatchThreads(MTLSize(width: source.width, height: source.height, depth: 1),
                                threadsPerThreadgroup: MTLSize(width: w, height: h, depth: 1))
        encoder.endEncoding()
    }

    /// Depth packed for Syphon: R = high byte, G = low byte (so depth_mm =
    /// R*256 + G in 0..255 units), B = depth scaled to the preview range, A = 255.
    public func packedDepth(_ image: DKImage, key: String, packing: Packing, on commandBuffer: MTLCommandBuffer) -> MTLTexture? {
        guard let source = upload16(image, key: key + ".r16"),
              let destination = texture(key + ".packed", width: image.width, height: image.height, format: .bgra8Unorm, usage: [.shaderRead, .shaderWrite]) else { return nil }
        var params = PackParams(range: packing.previewRangeMillimetres)
        dispatch(packDepth, source: source, destination: destination, params: &params, on: commandBuffer)
        return destination
    }

    /// IR packed the same way, B = IR scaled over 0..range.
    public func packedIR(_ image: DKImage, key: String, range: Float = 4000, on commandBuffer: MTLCommandBuffer) -> MTLTexture? {
        guard let source = upload16(image, key: key + ".r16"),
              let destination = texture(key + ".packed", width: image.width, height: image.height, format: .bgra8Unorm, usage: [.shaderRead, .shaderWrite]) else { return nil }
        var params = PackParams(range: range)
        dispatch(packIR, source: source, destination: destination, params: &params, on: commandBuffer)
        return destination
    }

    /// Depth as a false-colour BGRA image for the preview window.
    public func colorizedDepth(_ image: DKImage, key: String, range: Float, on commandBuffer: MTLCommandBuffer) -> MTLTexture? {
        guard let source = upload16(image, key: key + ".r16"),
              let destination = texture(key + ".color", width: image.width, height: image.height, format: .bgra8Unorm, usage: [.shaderRead, .shaderWrite]) else { return nil }
        var params = PackParams(range: range)
        dispatch(colorizeDepth, source: source, destination: destination, params: &params, on: commandBuffer)
        return destination
    }

    /// The unit-ray table of the depth camera packed for Syphon: R,G = x
    /// (high, low byte), B,A = y, each mapped from [-XYTableRange, XYTableRange]
    /// onto 0..65535. A point is (x * z, y * z, z) for depth z.
    public static let xyTableRange: Float = 2.0

    public func xyTableTexture(calibration: k4a_calibration_t, key: String) -> MTLTexture? {
        let width = Int(calibration.depth_camera_calibration.resolution_width)
        let height = Int(calibration.depth_camera_calibration.resolution_height)
        guard width > 0, height > 0,
              let texture = texture(key, width: width, height: height, format: .bgra8Unorm, usage: [.shaderRead]) else { return nil }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        var copy = calibration
        let range = FrameTextures.xyTableRange
        for y in 0..<height {
            for x in 0..<width {
                var pixel = k4a_float2_t(xy: .init(x: Float(x), y: Float(y)))
                var point = k4a_float3_t()
                var valid: Int32 = 0
                var rx: Float = 0, ry: Float = 0
                if k4a_calibration_2d_to_3d(&copy, &pixel, 1000, K4A_CALIBRATION_TYPE_DEPTH, K4A_CALIBRATION_TYPE_DEPTH, &point, &valid) == K4A_RESULT_SUCCEEDED, valid == 1 {
                    rx = point.xyz.x / 1000
                    ry = point.xyz.y / 1000
                }
                func pack(_ v: Float) -> UInt16 {
                    let t = (min(max(v, -range), range) + range) / (2 * range)
                    return UInt16((t * 65535).rounded())
                }
                let px = pack(rx), py = pack(ry)
                let i = (y * width + x) * 4
                pixels[i] = UInt8(py & 0xFF)        // B = y low
                pixels[i + 1] = UInt8(px & 0xFF)    // G = x low
                pixels[i + 2] = UInt8(px >> 8)      // R = x high
                pixels[i + 3] = UInt8(py >> 8)      // A = y high
            }
        }
        texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0, withBytes: pixels, bytesPerRow: width * 4)
        return texture
    }

    struct PackParams {
        var range: Float
    }

    static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct PackParams { float range; };

    // 16-bit value split across two 8-bit channels, plus an 8-bit preview.
    kernel void pack_depth16(texture2d<uint, access::read> source [[texture(0)]],
                             texture2d<float, access::write> destination [[texture(1)]],
                             constant PackParams &params [[buffer(0)]],
                             uint2 gid [[thread_position_in_grid]])
    {
        if (gid.x >= source.get_width() || gid.y >= source.get_height()) return;
        uint value = source.read(gid).r;
        float high = float(value >> 8) / 255.0;
        float low = float(value & 0xFFu) / 255.0;
        float preview = value == 0 ? 0.0 : clamp(float(value) / params.range, 0.0, 1.0);
        // BGRA8 texture: write as (r, g, b, a).
        destination.write(float4(high, low, preview, 1.0), gid);
    }

    kernel void pack_ir16(texture2d<uint, access::read> source [[texture(0)]],
                          texture2d<float, access::write> destination [[texture(1)]],
                          constant PackParams &params [[buffer(0)]],
                          uint2 gid [[thread_position_in_grid]])
    {
        if (gid.x >= source.get_width() || gid.y >= source.get_height()) return;
        uint value = source.read(gid).r;
        float high = float(value >> 8) / 255.0;
        float low = float(value & 0xFFu) / 255.0;
        float preview = clamp(float(value) / params.range, 0.0, 1.0);
        destination.write(float4(high, low, preview, 1.0), gid);
    }

    // Near is warm, far is cool, invalid is black.
    kernel void colorize_depth16(texture2d<uint, access::read> source [[texture(0)]],
                                 texture2d<float, access::write> destination [[texture(1)]],
                                 constant PackParams &params [[buffer(0)]],
                                 uint2 gid [[thread_position_in_grid]])
    {
        if (gid.x >= source.get_width() || gid.y >= source.get_height()) return;
        uint value = source.read(gid).r;
        if (value == 0) { destination.write(float4(0, 0, 0, 1), gid); return; }
        float t = clamp(float(value) / params.range, 0.0, 1.0);
        // A short turbo-like ramp: red -> yellow -> green -> cyan -> blue.
        float r = clamp(1.5 - abs(4.0 * t - 1.0), 0.0, 1.0) * (t < 0.5 ? 1.0 : clamp(2.0 - 4.0 * t, 0.0, 1.0));
        float g = clamp(1.5 - abs(4.0 * t - 2.0), 0.0, 1.0);
        float b = clamp(1.5 - abs(4.0 * t - 3.0), 0.0, 1.0);
        destination.write(float4(r, g, b, 1.0), gid);
    }
    """
}
