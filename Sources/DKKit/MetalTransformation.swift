import Foundation
import Metal
import DKCore

/// The transformation engine on the GPU: depth into the colour camera's
/// geometry (drawn as a mesh with a z-test, as the SDK does), colour into the
/// depth camera's (bilinear), and the point cloud. The same calibration math
/// as the CPU engine in openk4a_transform.c: the depth camera's rays are
/// unprojected once on the CPU, the colour camera's Brown-Conrady projection
/// runs in the kernels. Shaders compile from source on first use.
public final class MetalTransformation: @unchecked Sendable {
    public let device: MTLDevice
    public let calibration: k4a_calibration_t
    public let depthWidth: Int
    public let depthHeight: Int
    public let colorWidth: Int
    public let colorHeight: Int

    private let queue: MTLCommandQueue
    private let verticesPipeline: MTLComputePipelineState
    private let rasterizePipeline: MTLComputePipelineState
    private let resolvePipeline: MTLComputePipelineState
    private let colorToDepthPipeline: MTLComputePipelineState
    private let pointCloudPipeline: MTLComputePipelineState
    private let packPipeline: MTLComputePipelineState
    private let lock = NSLock()

    private let xyTable: MTLBuffer       // float2 per depth pixel: x/z, y/z
    private let rayValid: MTLBuffer      // uchar per depth pixel
    private let params: MTLBuffer
    private let depthIn: MTLBuffer       // ushort per depth pixel
    private let vertices: MTLBuffer      // float4 per depth pixel: u, v, z, valid
    private let raster: MTLBuffer        // uint per colour pixel, atomic min
    private let depthOut: MTLBuffer      // ushort per colour pixel
    private let depthOutTexture: MTLTexture   // r16Uint, colour resolution
    private let packedTexture: MTLTexture     // bgra8, colour resolution
    private var colorIn: MTLBuffer?      // bgra bytes, colour resolution
    private let colorOutTexture: MTLTexture   // bgra8, depth resolution
    private let colorOut: MTLBuffer      // bgra bytes, depth resolution (readback)
    private let pointCloudBuffer: MTLBuffer   // int16 xyz per depth pixel
    private let pointCloudTexture: MTLTexture // rgba32Float, depth resolution

    public struct Timings: Sendable, Equatable {
        public var depthToColorMilliseconds: Double = 0
        public var colorToDepthMilliseconds: Double = 0
        public var pointCloudMilliseconds: Double = 0
    }
    public private(set) var timings = Timings()

    struct Params {
        var depthWidth: UInt32, depthHeight: UInt32, colorWidth: UInt32, colorHeight: UInt32
        var r0: Float, r1: Float, r2: Float, r3: Float, r4: Float, r5: Float, r6: Float, r7: Float, r8: Float
        var t0: Float, t1: Float, t2: Float
        var cx: Float, cy: Float, fx: Float, fy: Float
        var k1: Float, k2: Float, k3: Float, k4: Float, k5: Float, k6: Float
        var codx: Float, cody: Float, p1: Float, p2: Float
        var maxRadius: Float
        var rational: UInt32
        var previewRange: Float
        var pad: UInt32
    }

    public init?(device: MTLDevice? = MTLCreateSystemDefaultDevice(), calibration: k4a_calibration_t) {
        guard let device, let queue = device.makeCommandQueue() else { return nil }
        let depthWidth = Int(calibration.depth_camera_calibration.resolution_width)
        let depthHeight = Int(calibration.depth_camera_calibration.resolution_height)
        let colorWidth = Int(calibration.color_camera_calibration.resolution_width)
        let colorHeight = Int(calibration.color_camera_calibration.resolution_height)
        guard depthWidth > 1, depthHeight > 1, colorWidth > 1, colorHeight > 1 else { return nil }
        self.device = device
        self.queue = queue
        self.calibration = calibration
        self.depthWidth = depthWidth
        self.depthHeight = depthHeight
        self.colorWidth = colorWidth
        self.colorHeight = colorHeight

        let options = MTLCompileOptions()
        options.fastMathEnabled = false
        let library: MTLLibrary
        do {
            library = try device.makeLibrary(source: MetalTransformation.shaderSource, options: options)
        } catch {
            NSLog("MetalTransformation: shaders would not compile: %@", "\(error)")
            return nil
        }
        func pipeline(_ name: String) -> MTLComputePipelineState? {
            guard let function = library.makeFunction(name: name) else { NSLog("MetalTransformation: no kernel %@", name); return nil }
            do { return try device.makeComputePipelineState(function: function) } catch {
                NSLog("MetalTransformation: kernel %@ would not build: %@", name, "\(error)")
                return nil
            }
        }
        guard let verticesPipeline = pipeline("transform_vertices"),
              let rasterizePipeline = pipeline("transform_rasterize"),
              let resolvePipeline = pipeline("transform_resolve"),
              let colorToDepthPipeline = pipeline("transform_color_to_depth"),
              let pointCloudPipeline = pipeline("transform_point_cloud"),
              let packPipeline = pipeline("transform_pack") else { return nil }
        self.verticesPipeline = verticesPipeline
        self.rasterizePipeline = rasterizePipeline
        self.resolvePipeline = resolvePipeline
        self.colorToDepthPipeline = colorToDepthPipeline
        self.pointCloudPipeline = pointCloudPipeline
        self.packPipeline = packPipeline

        let depthPixels = depthWidth * depthHeight
        let colorPixels = colorWidth * colorHeight
        // The depth camera's rays, once: the same unprojection the CPU engine uses.
        var table = [SIMD2<Float>](repeating: SIMD2(Float.nan, Float.nan), count: depthPixels)
        var valid = [UInt8](repeating: 0, count: depthPixels)
        var depthCamera = calibration.depth_camera_calibration
        for row in 0..<depthHeight {
            for column in 0..<depthWidth {
                let point2d: [Float] = [Float(column), Float(row)]
                var point3d: [Float] = [0, 0, 0]
                var ok: Int32 = 0
                let result = point2d.withUnsafeBufferPointer { p2 in
                    point3d.withUnsafeMutableBufferPointer { p3 in
                        openk4a_calibration_unproject(&depthCamera, p2.baseAddress, 1.0, p3.baseAddress, &ok)
                    }
                }
                if result, ok != 0, point3d[2] > 0 {
                    table[row * depthWidth + column] = SIMD2(point3d[0] / point3d[2], point3d[1] / point3d[2])
                    valid[row * depthWidth + column] = 1
                }
            }
        }
        guard let xyTable = device.makeBuffer(bytes: table, length: depthPixels * MemoryLayout<SIMD2<Float>>.stride, options: .storageModeShared),
              let rayValid = device.makeBuffer(bytes: valid, length: depthPixels, options: .storageModeShared),
              let params = device.makeBuffer(length: MemoryLayout<Params>.stride, options: .storageModeShared),
              let depthIn = device.makeBuffer(length: depthPixels * 2, options: .storageModeShared),
              let vertices = device.makeBuffer(length: depthPixels * 16, options: .storageModePrivate),
              let raster = device.makeBuffer(length: colorPixels * 4, options: .storageModePrivate),
              let depthOut = device.makeBuffer(length: colorPixels * 2, options: .storageModeShared),
              let colorOut = device.makeBuffer(length: depthPixels * 4, options: .storageModeShared),
              let pointCloudBuffer = device.makeBuffer(length: depthPixels * 6, options: .storageModeShared) else { return nil }
        self.xyTable = xyTable
        self.rayValid = rayValid
        self.params = params
        self.depthIn = depthIn
        self.vertices = vertices
        self.raster = raster
        self.depthOut = depthOut
        self.colorOut = colorOut
        self.pointCloudBuffer = pointCloudBuffer

        func texture(_ format: MTLPixelFormat, _ width: Int, _ height: Int) -> MTLTexture? {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: width, height: height, mipmapped: false)
            descriptor.usage = [.shaderRead, .shaderWrite]
            descriptor.storageMode = .shared
            return device.makeTexture(descriptor: descriptor)
        }
        guard let depthOutTexture = texture(.r16Uint, colorWidth, colorHeight),
              let packedTexture = texture(.bgra8Unorm, colorWidth, colorHeight),
              let colorOutTexture = texture(.bgra8Unorm, depthWidth, depthHeight),
              let pointCloudTexture = texture(.rgba32Float, depthWidth, depthHeight) else { return nil }
        self.depthOutTexture = depthOutTexture
        self.packedTexture = packedTexture
        self.colorOutTexture = colorOutTexture
        self.pointCloudTexture = pointCloudTexture

        let color = calibration.color_camera_calibration
        let intrinsics = color.intrinsics.parameters.param
        let extrinsics = calibration.extrinsics.0.1  // depth -> colour
        let rotation = extrinsics.rotation
        let translation = extrinsics.translation
        var p = Params(depthWidth: UInt32(depthWidth), depthHeight: UInt32(depthHeight), colorWidth: UInt32(colorWidth), colorHeight: UInt32(colorHeight),
                       r0: rotation.0, r1: rotation.1, r2: rotation.2, r3: rotation.3, r4: rotation.4, r5: rotation.5, r6: rotation.6, r7: rotation.7, r8: rotation.8,
                       t0: translation.0, t1: translation.1, t2: translation.2,
                       cx: intrinsics.cx, cy: intrinsics.cy, fx: intrinsics.fx, fy: intrinsics.fy,
                       k1: intrinsics.k1, k2: intrinsics.k2, k3: intrinsics.k3, k4: intrinsics.k4, k5: intrinsics.k5, k6: intrinsics.k6,
                       codx: intrinsics.codx, cody: intrinsics.cody, p1: intrinsics.p1, p2: intrinsics.p2,
                       maxRadius: color.metric_radius,
                       rational: color.intrinsics.type == K4A_CALIBRATION_LENS_DISTORTION_MODEL_RATIONAL_6KT ? 1 : 0,
                       previewRange: 5000, pad: 0)
        memcpy(params.contents(), &p, MemoryLayout<Params>.stride)
    }

    private func setPreviewRange(_ range: Float) {
        let p = params.contents().bindMemory(to: Params.self, capacity: 1)
        p.pointee.previewRange = range
    }

    private func uploadDepth(_ depth: DKImage) -> Bool {
        guard depth.width == depthWidth, depth.height == depthHeight, depth.format == .depth16 else { return false }
        if depth.strideBytes == depthWidth * 2 {
            memcpy(depthIn.contents(), depth.bytes.baseAddress!, depthWidth * depthHeight * 2)
        } else {
            for row in 0..<depthHeight {
                memcpy(depthIn.contents() + row * depthWidth * 2, depth.bytes.baseAddress! + row * depth.strideBytes, depthWidth * 2)
            }
        }
        return true
    }

    private func dispatch(_ encoder: MTLComputeCommandEncoder, _ pipeline: MTLComputePipelineState, width: Int, height: Int) {
        encoder.setComputePipelineState(pipeline)
        let w = pipeline.threadExecutionWidth
        let h = max(1, pipeline.maxTotalThreadsPerThreadgroup / w)
        encoder.dispatchThreads(MTLSize(width: width, height: height, depth: 1), threadsPerThreadgroup: MTLSize(width: w, height: min(h, 8), depth: 1))
    }

    // MARK: depth -> colour camera

    /// The depth image drawn into the colour camera's geometry, as an R16Uint
    /// texture at colour resolution (0 = no depth). The matching bytes are
    /// available through `depthToColorCameraImage`.
    public func depthToColorCamera(_ depth: DKImage) -> MTLTexture? {
        lock.lock(); defer { lock.unlock() }
        let started = DispatchTime.now().uptimeNanoseconds
        guard uploadDepth(depth), let commandBuffer = queue.makeCommandBuffer() else { return nil }
        if let blit = commandBuffer.makeBlitCommandEncoder() {
            blit.fill(buffer: raster, range: 0..<raster.length, value: 0xFF)
            blit.endEncoding()
        }
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else { return nil }
        encoder.setBuffer(depthIn, offset: 0, index: 0)
        encoder.setBuffer(xyTable, offset: 0, index: 1)
        encoder.setBuffer(rayValid, offset: 0, index: 2)
        encoder.setBuffer(vertices, offset: 0, index: 3)
        encoder.setBuffer(params, offset: 0, index: 4)
        dispatch(encoder, verticesPipeline, width: depthWidth, height: depthHeight)
        encoder.setBuffer(vertices, offset: 0, index: 0)
        encoder.setBuffer(raster, offset: 0, index: 1)
        encoder.setBuffer(params, offset: 0, index: 2)
        dispatch(encoder, rasterizePipeline, width: depthWidth - 1, height: depthHeight - 1)
        encoder.setBuffer(raster, offset: 0, index: 0)
        encoder.setBuffer(depthOut, offset: 0, index: 1)
        encoder.setBuffer(params, offset: 0, index: 2)
        encoder.setTexture(depthOutTexture, index: 0)
        dispatch(encoder, resolvePipeline, width: colorWidth, height: colorHeight)
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        guard commandBuffer.status == .completed else { return nil }
        timings.depthToColorMilliseconds = Double(DispatchTime.now().uptimeNanoseconds - started) / 1e6
        return depthOutTexture
    }

    /// The same, as a DEPTH16 image (a copy of the GPU's result).
    public func depthToColorCameraImage(_ depth: DKImage) -> DKImage? {
        guard depthToColorCamera(depth) != nil,
              let image = DKImage.allocate(format: K4A_IMAGE_FORMAT_DEPTH16, width: colorWidth, height: colorHeight, strideBytes: colorWidth * 2) else { return nil }
        lock.lock(); defer { lock.unlock() }
        memcpy(image.bytes.baseAddress!, depthOut.contents(), colorWidth * colorHeight * 2)
        image.copyTimestamps(from: depth)
        return image
    }

    /// Depth in the colour camera packed for Syphon (R high byte, G low byte,
    /// B preview over `previewRangeMillimetres`, A = 1).
    public func packedDepthToColorCamera(_ depth: DKImage, previewRangeMillimetres: Float) -> MTLTexture? {
        guard depthToColorCamera(depth) != nil else { return nil }
        lock.lock(); defer { lock.unlock() }
        setPreviewRange(previewRangeMillimetres)
        guard let commandBuffer = queue.makeCommandBuffer(), let encoder = commandBuffer.makeComputeCommandEncoder() else { return nil }
        encoder.setBuffer(depthOut, offset: 0, index: 0)
        encoder.setBuffer(params, offset: 0, index: 1)
        encoder.setTexture(packedTexture, index: 0)
        dispatch(encoder, packPipeline, width: colorWidth, height: colorHeight)
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        return commandBuffer.status == .completed ? packedTexture : nil
    }

    // MARK: colour -> depth camera

    /// The colour image resampled into the depth camera's geometry (BGRA8, depth
    /// resolution; black where there is no depth or the point falls outside).
    public func colorToDepthCamera(depth: DKImage, color: DKImage) -> MTLTexture? {
        lock.lock(); defer { lock.unlock() }
        let started = DispatchTime.now().uptimeNanoseconds
        guard color.format == .bgra32, color.width == colorWidth, color.height == colorHeight, uploadDepth(depth) else { return nil }
        let bytes = colorWidth * colorHeight * 4
        if colorIn == nil || colorIn!.length < bytes {
            colorIn = device.makeBuffer(length: bytes, options: .storageModeShared)
        }
        guard let colorIn else { return nil }
        if color.strideBytes == colorWidth * 4 {
            memcpy(colorIn.contents(), color.bytes.baseAddress!, bytes)
        } else {
            for row in 0..<colorHeight {
                memcpy(colorIn.contents() + row * colorWidth * 4, color.bytes.baseAddress! + row * color.strideBytes, colorWidth * 4)
            }
        }
        guard let commandBuffer = queue.makeCommandBuffer(), let encoder = commandBuffer.makeComputeCommandEncoder() else { return nil }
        encoder.setBuffer(depthIn, offset: 0, index: 0)
        encoder.setBuffer(xyTable, offset: 0, index: 1)
        encoder.setBuffer(rayValid, offset: 0, index: 2)
        encoder.setBuffer(colorIn, offset: 0, index: 3)
        encoder.setBuffer(colorOut, offset: 0, index: 4)
        encoder.setBuffer(params, offset: 0, index: 5)
        encoder.setTexture(colorOutTexture, index: 0)
        dispatch(encoder, colorToDepthPipeline, width: depthWidth, height: depthHeight)
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        guard commandBuffer.status == .completed else { return nil }
        timings.colorToDepthMilliseconds = Double(DispatchTime.now().uptimeNanoseconds - started) / 1e6
        return colorOutTexture
    }

    public func colorToDepthCameraImage(depth: DKImage, color: DKImage) -> DKImage? {
        guard colorToDepthCamera(depth: depth, color: color) != nil,
              let image = DKImage.allocate(format: K4A_IMAGE_FORMAT_COLOR_BGRA32, width: depthWidth, height: depthHeight, strideBytes: depthWidth * 4) else { return nil }
        lock.lock(); defer { lock.unlock() }
        memcpy(image.bytes.baseAddress!, colorOut.contents(), depthWidth * depthHeight * 4)
        image.copyTimestamps(from: depth)
        return image
    }

    // MARK: point cloud

    /// XYZ in millimetres per depth pixel: the SDK's int16 triplets as an
    /// image, and an RGBA32F texture (x, y, z in millimetres, a = 1 where valid).
    public func pointCloud(_ depth: DKImage) -> (texture: MTLTexture, image: DKImage)? {
        lock.lock(); defer { lock.unlock() }
        let started = DispatchTime.now().uptimeNanoseconds
        guard uploadDepth(depth), let commandBuffer = queue.makeCommandBuffer(), let encoder = commandBuffer.makeComputeCommandEncoder() else { return nil }
        encoder.setBuffer(depthIn, offset: 0, index: 0)
        encoder.setBuffer(xyTable, offset: 0, index: 1)
        encoder.setBuffer(rayValid, offset: 0, index: 2)
        encoder.setBuffer(pointCloudBuffer, offset: 0, index: 3)
        encoder.setBuffer(params, offset: 0, index: 4)
        encoder.setTexture(pointCloudTexture, index: 0)
        dispatch(encoder, pointCloudPipeline, width: depthWidth, height: depthHeight)
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        guard commandBuffer.status == .completed,
              let image = DKImage.allocate(format: K4A_IMAGE_FORMAT_CUSTOM, width: depthWidth, height: depthHeight, strideBytes: depthWidth * 6) else { return nil }
        memcpy(image.bytes.baseAddress!, pointCloudBuffer.contents(), depthWidth * depthHeight * 6)
        image.copyTimestamps(from: depth)
        timings.pointCloudMilliseconds = Double(DispatchTime.now().uptimeNanoseconds - started) / 1e6
        return (pointCloudTexture, image)
    }

    static let shaderSource = """
    #include <metal_stdlib>
    #pragma METAL fp contract(off)
    using namespace metal;

    struct Params {
        uint depthWidth, depthHeight, colorWidth, colorHeight;
        float r0, r1, r2, r3, r4, r5, r6, r7, r8;
        float t0, t1, t2;
        float cx, cy, fx, fy;
        float k1, k2, k3, k4, k5, k6;
        float codx, cody, p1, p2;
        float maxRadius;
        uint rational;
        float previewRange;
        uint pad;
    };

    struct Vertex { float u; float v; float depth; bool valid; };

    // The colour camera's Brown-Conrady projection of a normalised point
    // (x/z, y/z): openk4a_calibration.c project_internal without the Jacobian.
    static bool project_color(constant Params &p, float2 xy, thread float2 &uv)
    {
        float xp = xy.x - p.codx, yp = xy.y - p.cody;
        float xp2 = xp * xp, yp2 = yp * yp, xyp = xp * yp;
        float rs = xp2 + yp2;
        if (rs > p.maxRadius * p.maxRadius) return false;
        float rss = rs * rs, rsc = rss * rs;
        float a = 1.0f + p.k1 * rs + p.k2 * rss + p.k3 * rsc;
        float b = 1.0f + p.k4 * rs + p.k5 * rss + p.k6 * rsc;
        float bi = b != 0.0f ? 1.0f / b : 1.0f;
        float d = a * bi;
        float xp_d = xp * d, yp_d = yp * d;
        float rs_2xp2 = rs + 2.0f * xp2, rs_2yp2 = rs + 2.0f * yp2;
        float tangential = p.rational != 0 ? 1.0f : 2.0f;
        xp_d += rs_2xp2 * p.p2 + tangential * xyp * p.p1;
        yp_d += rs_2yp2 * p.p1 + tangential * xyp * p.p2;
        uv = float2((xp_d + p.codx) * p.fx + p.cx, (yp_d + p.cody) * p.fy + p.cy);
        return true;
    }

    static float3 depth_to_color_3d(constant Params &p, float3 s)
    {
        return float3(p.r0 * s.x + p.r1 * s.y + p.r2 * s.z + p.t0,
                      p.r3 * s.x + p.r4 * s.y + p.r5 * s.z + p.t1,
                      p.r6 * s.x + p.r7 * s.y + p.r8 * s.z + p.t2);
    }

    // Every depth pixel's landing point in the colour image, once.
    kernel void transform_vertices(device const ushort *depth [[buffer(0)]], device const float2 *xy [[buffer(1)]],
                                   device const uchar *rayValid [[buffer(2)]], device float4 *out [[buffer(3)]],
                                   constant Params &p [[buffer(4)]], uint2 id [[thread_position_in_grid]])
    {
        if (id.x >= p.depthWidth || id.y >= p.depthHeight) return;
        uint pixel = id.y * p.depthWidth + id.x;
        float4 landing = float4(0.0f);
        ushort d = depth[pixel];
        if (d != 0 && rayValid[pixel] != 0) {
            float fd = (float)d;
            float3 point = float3(xy[pixel].x * fd, xy[pixel].y * fd, fd);
            float3 c = depth_to_color_3d(p, point);
            float2 uv;
            if (c.z > 0.0f && project_color(p, float2(c.x / c.z, c.y / c.z), uv)) {
                landing = float4(uv.x, uv.y, c.z, 1.0f);
            }
        }
        out[pixel] = landing;
    }

    static Vertex vertex_at(device const float4 *vertices, uint index)
    {
        float4 v = vertices[index];
        Vertex r; r.u = v.x; r.v = v.y; r.depth = v.z; r.valid = v.w != 0.0f;
        return r;
    }

    // openk4a_transform.c fix_corners, literally.
    static bool fix_corners(thread Vertex &tl, thread Vertex &tr, thread Vertex &br, thread Vertex &bl)
    {
        int invalid = 0;
        if (!tl.valid) { invalid++; tl.u = (tr.u + bl.u) * 0.5f; tl.v = (tr.v + bl.v) * 0.5f; tl.depth = (tr.depth + bl.depth) * 0.5f; }
        if (!tr.valid) { invalid++; tr = br; br.u = (br.u + bl.u) * 0.5f; br.v = (br.v + bl.v) * 0.5f; br.depth = (br.depth + bl.depth) * 0.5f; }
        if (!br.valid) { invalid++; br.u = (tr.u + bl.u) * 0.5f; br.v = (tr.v + bl.v) * 0.5f; br.depth = (tr.depth + bl.depth) * 0.5f; }
        if (!bl.valid) { invalid++; bl = br; br.u = (tr.u + br.u) * 0.5f; br.v = (tr.v + br.v) * 0.5f; br.depth = (tr.depth + br.depth) * 0.5f; }
        return invalid < 2;
    }

    // One 2x2 quad of depth pixels drawn as two triangles into the colour
    // image; the nearest depth wins through an atomic minimum.
    kernel void transform_rasterize(device const float4 *vertices [[buffer(0)]], device atomic_uint *raster [[buffer(1)]],
                                    constant Params &p [[buffer(2)]], uint2 id [[thread_position_in_grid]])
    {
        uint column = id.x + 1, row = id.y + 1;
        if (column >= p.depthWidth || row >= p.depthHeight) return;
        uint w = p.depthWidth;
        Vertex tl = vertex_at(vertices, (row - 1) * w + column - 1);
        Vertex tr = vertex_at(vertices, (row - 1) * w + column);
        Vertex bl = vertex_at(vertices, row * w + column - 1);
        Vertex br = vertex_at(vertices, row * w + column);
        if (!fix_corners(tl, tr, br, bl)) return;
        float lowest = tl.depth, highest = tl.depth;
        lowest = min(lowest, min(tr.depth, min(br.depth, bl.depth)));
        highest = max(highest, max(tr.depth, max(br.depth, bl.depth)));
        if (highest - lowest > 0.04693441759f * lowest) return;

        float min_u = min(min(tl.u, tr.u), min(br.u, bl.u)), max_u = max(max(tl.u, tr.u), max(br.u, bl.u));
        float min_v = min(min(tl.v, tr.v), min(br.v, bl.v)), max_v = max(max(tl.v, tr.v), max(br.v, bl.v));
        int first_row = max((int)floor(min_v), 0), last_row = min((int)ceil(max_v), (int)p.colorHeight - 1);
        int first_column = max((int)floor(min_u), 0), last_column = min((int)ceil(max_u), (int)p.colorWidth - 1);
        if (last_row - first_row > 64 || last_column - first_column > 64) return; // a quad that big is a bad vertex, not a surface

        Vertex tri[2][3] = { { tl, tr, br }, { tl, br, bl } };
        for (int y = first_row; y <= last_row; y++) {
            for (int x = first_column; x <= last_column; x++) {
                bool inside = false;
                float depth = 0.0f;
                for (int t = 0; t < 2 && !inside; t++) {
                    Vertex a = tri[t][0], b = tri[t][1], c = tri[t][2];
                    float area = (b.u - a.u) * (c.v - a.v) - (c.u - a.u) * (b.v - a.v);
                    if (area == 0.0f) continue;
                    float pu = (float)x, pv = (float)y;
                    float w0 = ((b.u - a.u) * (pv - a.v) - (pu - a.u) * (b.v - a.v)) / area;
                    float w1 = ((pu - a.u) * (c.v - a.v) - (c.u - a.u) * (pv - a.v)) / area;
                    float w2 = 1.0f - w0 - w1;
                    if (w0 < -1e-4f || w1 < -1e-4f || w2 < -1e-4f) continue;
                    inside = true;
                    depth = w2 * a.depth + w1 * b.depth + w0 * c.depth;
                }
                if (!inside) continue;
                uint value = (uint)(depth + 0.5f);
                if (value == 0) continue;
                atomic_fetch_min_explicit(&raster[(uint)y * p.colorWidth + (uint)x], value, memory_order_relaxed);
            }
        }
    }

    kernel void transform_resolve(device const uint *raster [[buffer(0)]], device ushort *depthOut [[buffer(1)]],
                                  constant Params &p [[buffer(2)]], texture2d<uint, access::write> tex [[texture(0)]],
                                  uint2 id [[thread_position_in_grid]])
    {
        if (id.x >= p.colorWidth || id.y >= p.colorHeight) return;
        uint pixel = id.y * p.colorWidth + id.x;
        uint v = raster[pixel];
        ushort d = v == 0xFFFFFFFFu ? 0 : (ushort)min(v, 65535u);
        depthOut[pixel] = d;
        tex.write(uint4(d, 0, 0, 0), id);
    }

    static uchar bilinear(device const uchar *image, uint stride, uint component, float u, float v)
    {
        int x0 = (int)floor(u), y0 = (int)floor(v);
        float fx = u - (float)x0, fy = v - (float)y0;
        device const uchar *row0 = image + (uint)y0 * stride + component;
        device const uchar *row1 = row0 + stride;
        float top = (float)row0[x0 * 4] * (1.0f - fx) + (float)row0[(x0 + 1) * 4] * fx;
        float bottom = (float)row1[x0 * 4] * (1.0f - fx) + (float)row1[(x0 + 1) * 4] * fx;
        return (uchar)(top * (1.0f - fy) + bottom * fy + 0.5f);
    }

    kernel void transform_color_to_depth(device const ushort *depth [[buffer(0)]], device const float2 *xy [[buffer(1)]],
                                         device const uchar *rayValid [[buffer(2)]], device const uchar *color [[buffer(3)]],
                                         device uchar *out [[buffer(4)]], constant Params &p [[buffer(5)]],
                                         texture2d<float, access::write> tex [[texture(0)]], uint2 id [[thread_position_in_grid]])
    {
        if (id.x >= p.depthWidth || id.y >= p.depthHeight) return;
        uint pixel = id.y * p.depthWidth + id.x;
        uchar4 result = uchar4(0);
        ushort d = depth[pixel];
        if (d != 0 && rayValid[pixel] != 0) {
            float fd = (float)d;
            float3 c = depth_to_color_3d(p, float3(xy[pixel].x * fd, xy[pixel].y * fd, fd));
            float2 uv;
            if (c.z > 0.0f && project_color(p, float2(c.x / c.z, c.y / c.z), uv) &&
                uv.x >= 0.0f && uv.y >= 0.0f && uv.x < (float)(p.colorWidth - 1) && uv.y < (float)(p.colorHeight - 1)) {
                uint stride = p.colorWidth * 4;
                result = uchar4(bilinear(color, stride, 0, uv.x, uv.y), bilinear(color, stride, 1, uv.x, uv.y),
                                bilinear(color, stride, 2, uv.x, uv.y), 255);
            }
        }
        out[pixel * 4] = result.x; out[pixel * 4 + 1] = result.y; out[pixel * 4 + 2] = result.z; out[pixel * 4 + 3] = result.w;
        // BGRA8 texture: components in memory order b, g, r, a map to .bgra when written as rgba.
        tex.write(float4(result.z, result.y, result.x, result.w) / 255.0f, id);
    }

    kernel void transform_point_cloud(device const ushort *depth [[buffer(0)]], device const float2 *xy [[buffer(1)]],
                                      device const uchar *rayValid [[buffer(2)]], device short *out [[buffer(3)]],
                                      constant Params &p [[buffer(4)]], texture2d<float, access::write> tex [[texture(0)]],
                                      uint2 id [[thread_position_in_grid]])
    {
        if (id.x >= p.depthWidth || id.y >= p.depthHeight) return;
        uint pixel = id.y * p.depthWidth + id.x;
        ushort d = depth[pixel];
        float3 point = float3(0.0f);
        bool valid = d != 0 && rayValid[pixel] != 0;
        if (valid) {
            float fd = (float)d;
            point = float3(xy[pixel].x * fd, xy[pixel].y * fd, fd);
        }
        out[pixel * 3] = (short)point.x; out[pixel * 3 + 1] = (short)point.y; out[pixel * 3 + 2] = (short)point.z;
        tex.write(float4(point, valid ? 1.0f : 0.0f), id);
    }

    kernel void transform_pack(device const ushort *depth [[buffer(0)]], constant Params &p [[buffer(1)]],
                               texture2d<float, access::write> tex [[texture(0)]], uint2 id [[thread_position_in_grid]])
    {
        if (id.x >= p.colorWidth || id.y >= p.colorHeight) return;
        uint value = depth[id.y * p.colorWidth + id.x];
        float high = float(value >> 8) / 255.0f, low = float(value & 0xFFu) / 255.0f;
        float preview = value == 0 ? 0.0f : clamp(float(value) / p.previewRange, 0.0f, 1.0f);
        tex.write(float4(high, low, preview, 1.0f), id);
    }
    """
}

extension DKImage {
    func copyTimestamps(from other: DKImage) {
        k4a_image_set_device_timestamp_usec(handle, other.deviceTimestampMicroseconds)
        k4a_image_set_system_timestamp_nsec(handle, other.systemTimestampNanoseconds)
    }
}
