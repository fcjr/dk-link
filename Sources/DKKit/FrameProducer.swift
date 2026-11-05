import Foundation
import Metal
import Accelerate
import DKCore

/// The images a consumer (the TouchDesigner operators, local or over the
/// socket) can ask for. Raw values match the C `ktd_image_kind` so the two
/// sides agree without a translation table.
public enum FrameKind: Int32, CaseIterable, Sendable {
    case color = 0
    case depth            // R32F metres
    case depthMillimetres // R16
    case ir               // R32F, IR/65535
    case pointCloud       // RGBA32F metres, a = valid
    case colorPointCloud  // RGBA32F metres in the colour frame
    case depthInColor     // R32F metres, colour resolution
    case colorInDepth     // BGRA8, depth resolution
    case playerIndex      // R8 body id
}

public enum FramePixelFormat: Int32, Sendable {
    case bgra8 = 0, r16, r32f, rgba32f, r8
    public var bytesPerPixel: Int { switch self { case .bgra8, .r32f: return 4; case .r16: return 2; case .rgba32f: return 16; case .r8: return 1 } }
}

/// One image: a small descriptor and tightly packed bytes (top row first).
public struct FrameImage: Sendable {
    public var kind: FrameKind
    public var width: Int32
    public var height: Int32
    public var pixelFormat: FramePixelFormat
    public var frameID: UInt64
    public var deviceTimestampMicroseconds: UInt64
    public var bytes: [UInt8]
    public init(kind: FrameKind, width: Int32, height: Int32, pixelFormat: FramePixelFormat, frameID: UInt64, deviceTimestampMicroseconds: UInt64, bytes: [UInt8]) {
        self.kind = kind; self.width = width; self.height = height; self.pixelFormat = pixelFormat
        self.frameID = frameID; self.deviceTimestampMicroseconds = deviceTimestampMicroseconds; self.bytes = bytes
    }
}

/// One tracked body, already in k4abt joint order (32 joints), so local mode
/// and the socket client build the same `ktd_body`.
public struct FrameJoint: Sendable, Equatable {
    public var x: Float = 0, y: Float = 0, z: Float = 0      // metres
    public var pixelX: Float = 0, pixelY: Float = 0           // colour pixels
    public var confidence: Float = 0
    public var valid: Bool = false
    public init() {}
}

public struct FrameBody: Sendable, Equatable {
    public var id: Int32 = 0
    public var pose: Bool = false
    public var bbox: SIMD4<Float> = .zero
    public var joints: [FrameJoint] = Array(repeating: FrameJoint(), count: 32)
    public init() {}

    public static let jointNames: [String] = [
        "pelvis", "spine_navel", "spine_chest", "neck", "clavicle_left", "shoulder_left", "elbow_left", "wrist_left",
        "hand_left", "handtip_left", "thumb_left", "clavicle_right", "shoulder_right", "elbow_right", "wrist_right",
        "hand_right", "handtip_right", "thumb_right", "hip_left", "knee_left", "ankle_left", "foot_left", "hip_right",
        "knee_right", "ankle_right", "foot_right", "head", "nose", "eye_left", "ear_left", "eye_right", "ear_right",
    ]

    /// A tracked `Body` mapped to the 32 k4abt joints, with the chest/spine and
    /// head synthesised. The one place this mapping lives, for both modes.
    public static func from(_ body: Body) -> FrameBody {
        var out = FrameBody()
        out.id = Int32(body.index)
        out.pose = body.source == "pose"
        if let box = body.boundingBox { out.bbox = box }
        let byName = Dictionary(body.joints.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        func make(_ j: BodyJoint?) -> FrameJoint {
            var k = FrameJoint()
            guard let j else { return k }
            k.pixelX = j.colorPixel.x; k.pixelY = j.colorPixel.y; k.confidence = j.confidence
            if let p = j.position { k.x = p.x / 1000; k.y = p.y / 1000; k.z = p.z / 1000; k.valid = true }
            return k
        }
        func lerp(_ a: BodyJoint?, _ b: BodyJoint?, _ t: Float) -> FrameJoint {
            guard let a, let b else { return FrameJoint() }
            var k = FrameJoint()
            k.pixelX = a.colorPixel.x + (b.colorPixel.x - a.colorPixel.x) * t
            k.pixelY = a.colorPixel.y + (b.colorPixel.y - a.colorPixel.y) * t
            k.confidence = min(a.confidence, b.confidence)
            if let pa = a.position, let pb = b.position {
                let p = pa + (pb - pa) * t
                k.x = p.x / 1000; k.y = p.y / 1000; k.z = p.z / 1000; k.valid = true
            }
            return k
        }
        let pelvis = byName["pelvis"] ?? byName["center"]
        let neck = byName["neck"]
        var head: FrameJoint
        if let l = byName["ear_left"], let r = byName["ear_right"] { head = lerp(l, r, 0.5) } else { head = make(byName["nose"]) }
        out.joints = [
            make(pelvis), lerp(pelvis, neck, 0.33), lerp(pelvis, neck, 0.66), make(neck),
            lerp(neck, byName["shoulder_left"], 0.5), make(byName["shoulder_left"]), make(byName["elbow_left"]), make(byName["wrist_left"]),
            FrameJoint(), FrameJoint(), FrameJoint(),
            lerp(neck, byName["shoulder_right"], 0.5), make(byName["shoulder_right"]), make(byName["elbow_right"]), make(byName["wrist_right"]),
            FrameJoint(), FrameJoint(), FrameJoint(),
            make(byName["hip_left"]), make(byName["knee_left"]), make(byName["ankle_left"]), FrameJoint(),
            make(byName["hip_right"]), make(byName["knee_right"]), make(byName["ankle_right"]), FrameJoint(),
            head, make(byName["nose"]), make(byName["eye_left"]), make(byName["ear_left"]), make(byName["eye_right"]), make(byName["ear_right"]),
        ]
        return out
    }
}

/// Turns a capture into the per-kind CPU buffers, identically for the library's
/// local mode and the app's frame server. The GPU work (transforms, point
/// clouds) runs through a MetalTransformation; the colour ray table is built
/// once, off the calling thread.
public final class FrameProducer: @unchecked Sendable {
    public let calibration: k4a_calibration_t
    private let transformation: MetalTransformation?
    private let readbackQueue: MTLCommandQueue?
    private let lock = NSLock()
    private var colorRays: [SIMD2<Float>] = []
    private var buildingRays = false

    public init(calibration: k4a_calibration_t, transformation: MetalTransformation?) {
        self.calibration = calibration
        self.transformation = transformation
        self.readbackQueue = transformation?.device.makeCommandQueue()
    }

    /// Produces the images among `kinds` that this capture can supply. `bodies`
    /// (already tracked) are used for the player-index map.
    public func images(from capture: DKCapture, kinds: Set<FrameKind>, bodies: [FrameBody], frameID: UInt64) -> [FrameImage] {
        var out: [FrameImage] = []
        let timestamp = capture.deviceTimestampMicroseconds
        func emit(_ kind: FrameKind, _ w: Int, _ h: Int, _ fmt: FramePixelFormat, _ bytes: [UInt8]) {
            out.append(FrameImage(kind: kind, width: Int32(w), height: Int32(h), pixelFormat: fmt, frameID: frameID, deviceTimestampMicroseconds: timestamp, bytes: bytes))
        }
        if let color = capture.color, color.format == .bgra32, kinds.contains(.color) {
            emit(.color, color.width, color.height, .bgra8, packed(color, bytesPerPixel: 4))
        }
        if let depth = capture.depth {
            let w = depth.width, h = depth.height
            if kinds.contains(.depthMillimetres) { emit(.depthMillimetres, w, h, .r16, packed(depth, bytesPerPixel: 2)) }
            if kinds.contains(.depth) { emit(.depth, w, h, .r32f, floats(from: depth, scale: 0.001)) }
            if let transformation {
                if kinds.contains(.pointCloud), let cloud = transformation.pointCloud(depth) {
                    var bytes = readback(cloud.texture, bytesPerPixel: 16); scaleXYZ(&bytes)
                    emit(.pointCloud, w, h, .rgba32f, bytes)
                }
                let needDepthInColor = kinds.contains(.depthInColor) || kinds.contains(.colorPointCloud)
                if needDepthInColor, let aligned = transformation.depthToColorCamera(depth) {
                    let mm = readback(aligned, bytesPerPixel: 2)
                    let cw = aligned.width, ch = aligned.height
                    if kinds.contains(.depthInColor) { emit(.depthInColor, cw, ch, .r32f, floats(fromMillimetres: mm, scale: 0.001)) }
                    if kinds.contains(.colorPointCloud) {
                        lock.lock(); let rays = colorRays; let building = buildingRays; lock.unlock()
                        if rays.count == cw * ch {
                            emit(.colorPointCloud, cw, ch, .rgba32f, colorPointCloud(mm, rays: rays, width: cw, height: ch))
                        } else if !building {
                            lock.lock(); buildingRays = true; lock.unlock()
                            let calibration = self.calibration
                            DispatchQueue.global(qos: .userInitiated).async { [self] in
                                let table = FrameProducer.colorRayTable(calibration)
                                lock.lock(); colorRays = table; buildingRays = false; lock.unlock()
                            }
                        }
                    }
                }
                if kinds.contains(.colorInDepth), let color = capture.color, let aligned = transformation.colorToDepthCamera(depth: depth, color: color) {
                    emit(.colorInDepth, aligned.width, aligned.height, .bgra8, readback(aligned, bytesPerPixel: 4))
                }
            }
            if kinds.contains(.playerIndex) { emit(.playerIndex, w, h, .r8, playerIndex(depth: depth, bodies: bodies)) }
        }
        if let ir = capture.ir, kinds.contains(.ir) {
            emit(.ir, ir.width, ir.height, .r32f, floats(from: ir, scale: 1.0 / 65535.0))
        }
        return out
    }

    // MARK: pixel helpers (byte-for-byte the library's former private copies)

    private func packed(_ image: DKImage, bytesPerPixel: Int) -> [UInt8] {
        let rowBytes = image.width * bytesPerPixel
        var out = [UInt8](repeating: 0, count: rowBytes * image.height)
        let src = image.bytes, total = rowBytes * image.height, stride = image.strideBytes, height = image.height
        out.withUnsafeMutableBytes { dst in
            if stride == rowBytes { dst.copyMemory(from: UnsafeRawBufferPointer(start: src.baseAddress, count: total)) }
            else { for y in 0..<height { memcpy(dst.baseAddress! + y * rowBytes, src.baseAddress! + y * stride, rowBytes) } }
        }
        return out
    }
    private static func convert(_ values: UnsafePointer<UInt16>, count: Int, scale: Float, into out: UnsafeMutablePointer<Float>) {
        vDSP_vfltu16(values, 1, out, 1, vDSP_Length(count)); var s = scale; vDSP_vsmul(out, 1, &s, out, 1, vDSP_Length(count))
    }
    private func floats(from image: DKImage, scale: Float) -> [UInt8] {
        let count = image.width * image.height
        var out = [UInt8](repeating: 0, count: count * 4)
        image.withUInt16 { v in out.withUnsafeMutableBytes { d in FrameProducer.convert(v.baseAddress!, count: count, scale: scale, into: d.bindMemory(to: Float.self).baseAddress!) } }
        return out
    }
    private func floats(fromMillimetres mm: [UInt8], scale: Float) -> [UInt8] {
        let count = mm.count / 2
        var out = [UInt8](repeating: 0, count: count * 4)
        mm.withUnsafeBytes { s in out.withUnsafeMutableBytes { d in FrameProducer.convert(s.bindMemory(to: UInt16.self).baseAddress!, count: count, scale: scale, into: d.bindMemory(to: Float.self).baseAddress!) } }
        return out
    }
    private func scaleXYZ(_ bytes: inout [UInt8]) {
        bytes.withUnsafeMutableBytes { raw in
            let f = raw.bindMemory(to: Float.self); let pixels = vDSP_Length(f.count / 4); var s: Float = 0.001
            for c in 0..<3 { vDSP_vsmul(f.baseAddress! + c, 4, &s, f.baseAddress! + c, 4, pixels) }
        }
    }
    private func colorPointCloud(_ mm: [UInt8], rays: [SIMD2<Float>], width: Int, height: Int) -> [UInt8] {
        let count = width * height
        var out = [UInt8](repeating: 0, count: count * 16)
        var z = [Float](repeating: 0, count: count)
        mm.withUnsafeBytes { s in FrameProducer.convert(s.bindMemory(to: UInt16.self).baseAddress!, count: count, scale: 0.001, into: &z) }
        out.withUnsafeMutableBytes { dst in
            let f = dst.bindMemory(to: Float.self).baseAddress!
            rays.withUnsafeBytes { r in
                let rf = r.bindMemory(to: Float.self).baseAddress!
                vDSP_vmul(rf, 2, z, 1, f, 4, vDSP_Length(count)); vDSP_vmul(rf + 1, 2, z, 1, f + 1, 4, vDSP_Length(count))
            }
            z.withUnsafeBufferPointer { zp in
                cblas_scopy(Int32(count), zp.baseAddress!, 1, f + 2, 4)
                var zero: Float = 0, one: Float = 1
                vDSP_vthrsc(zp.baseAddress!, 1, &zero, &one, f + 3, 4, vDSP_Length(count))
                vDSP_vthres(f + 3, 4, &zero, f + 3, 4, vDSP_Length(count))
            }
        }
        return out
    }
    private func readback(_ texture: MTLTexture, bytesPerPixel: Int) -> [UInt8] {
        let rowBytes = texture.width * bytesPerPixel, size = rowBytes * texture.height
        var out = [UInt8](repeating: 0, count: size)
        guard let queue = readbackQueue, let buffer = queue.device.makeBuffer(length: size, options: .storageModeShared),
              let command = queue.makeCommandBuffer(), let blit = command.makeBlitCommandEncoder() else { return out }
        blit.copy(from: texture, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                  sourceSize: MTLSize(width: texture.width, height: texture.height, depth: 1),
                  to: buffer, destinationOffset: 0, destinationBytesPerRow: rowBytes, destinationBytesPerImage: size)
        blit.endEncoding(); command.commit(); command.waitUntilCompleted()
        out.withUnsafeMutableBytes { $0.copyMemory(from: UnsafeRawBufferPointer(start: buffer.contents(), count: size)) }
        return out
    }
    private func playerIndex(depth: DKImage, bodies: [FrameBody]) -> [UInt8] {
        let w = depth.width, h = depth.height
        var out = [UInt8](repeating: 0, count: w * h)
        var calibration = self.calibration
        guard !bodies.isEmpty else { return out }
        depth.withUInt16 { values in
            for body in bodies {
                let zs = body.joints.filter { $0.valid }.map { $0.z * 1000 }.sorted()
                guard !zs.isEmpty else { continue }
                let z = zs[zs.count / 2]; guard z > 0 else { continue }
                var corners: [SIMD2<Float>]
                if body.bbox != .zero { corners = [SIMD2(body.bbox.x, body.bbox.y), SIMD2(body.bbox.x + body.bbox.z, body.bbox.y), SIMD2(body.bbox.x, body.bbox.y + body.bbox.w), SIMD2(body.bbox.x + body.bbox.z, body.bbox.y + body.bbox.w)] }
                else { corners = body.joints.filter { $0.confidence > 0 }.map { SIMD2($0.pixelX, $0.pixelY) } }
                var minX = Float.greatestFiniteMagnitude, minY = Float.greatestFiniteMagnitude, maxX = -Float.greatestFiniteMagnitude, maxY = -Float.greatestFiniteMagnitude
                for c in corners {
                    var source = k4a_float2_t(xy: .init(x: c.x, y: c.y)); var p3 = k4a_float3_t(); var p2 = k4a_float2_t(); var valid: Int32 = 0
                    guard k4a_calibration_2d_to_3d(&calibration, &source, z, K4A_CALIBRATION_TYPE_COLOR, K4A_CALIBRATION_TYPE_DEPTH, &p3, &valid) == K4A_RESULT_SUCCEEDED, valid == 1,
                          k4a_calibration_3d_to_2d(&calibration, &p3, K4A_CALIBRATION_TYPE_DEPTH, K4A_CALIBRATION_TYPE_DEPTH, &p2, &valid) == K4A_RESULT_SUCCEEDED, valid == 1 else { continue }
                    minX = min(minX, p2.xy.x); maxX = max(maxX, p2.xy.x); minY = min(minY, p2.xy.y); maxY = max(maxY, p2.xy.y)
                }
                guard minX < maxX, minY < maxY else { continue }
                let x0 = max(0, Int(minX)), x1 = min(w - 1, Int(maxX)), y0 = max(0, Int(minY)), y1 = min(h - 1, Int(maxY))
                guard x0 <= x1, y0 <= y1 else { continue }
                let id = UInt8(clamping: body.id), near = UInt16(max(0, z - 500)), far = UInt16(min(65535, z + 500))
                for y in y0...y1 { for x in x0...x1 { let v = values[y * w + x]; if v >= near && v <= far { out[y * w + x] = id } } }
            }
        }
        return out
    }
    public static func colorRayTable(_ calibration: k4a_calibration_t) -> [SIMD2<Float>] {
        var copy = calibration
        let w = Int(calibration.color_camera_calibration.resolution_width), h = Int(calibration.color_camera_calibration.resolution_height)
        guard w > 0, h > 0 else { return [] }
        var rays = [SIMD2<Float>](repeating: SIMD2(0, 0), count: w * h)
        for y in 0..<h { for x in 0..<w {
            var pixel = k4a_float2_t(xy: .init(x: Float(x), y: Float(y))); var point = k4a_float3_t(); var valid: Int32 = 0
            if k4a_calibration_2d_to_3d(&copy, &pixel, 1000, K4A_CALIBRATION_TYPE_COLOR, K4A_CALIBRATION_TYPE_COLOR, &point, &valid) == K4A_RESULT_SUCCEEDED, valid == 1 {
                rays[y * w + x] = SIMD2(point.xyz.x / 1000, point.xyz.y / 1000)
            }
        } }
        return rays
    }
}
