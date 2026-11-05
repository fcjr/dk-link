import Foundation
import Metal
import simd
import Accelerate
import KinectCore
import KinectKit
import CKinectTD

/// The process-wide camera session behind the TouchDesigner operators. Every
/// operator instance holds a reference; the first configure starts the camera,
/// the last release stops it. All work runs off the caller's thread: the
/// operators only ever copy the newest buffers under a lock.
final class TDSession: @unchecked Sendable {
    static let shared = TDSession()

    private let lock = NSLock()
    private let control = DispatchQueue(label: "kinecttd.control")
    private var references = 0

    // Desired state (set by configure) and what is running.
    private var desired: ktd_config?
    private var active = false
    private var running: ktd_config?

    private var device: KinectDevice?
    private var session: KinectSession?
    private var transformation: MetalTransformation?
    private var tracker: BodyTracker?
    private var calibration: k4a_calibration_t?
    private var colorRays: [SIMD2<Float>] = []   // unit rays per colour pixel (x/z, y/z)
    private var buildingRays = false
    private var readbackQueue: MTLCommandQueue?

    private var status = "No Kinect connected"
    private var serial = ""
    private var calibrationJSON = ""
    private var statistics = KinectSessionStatistics()
    private var processingMilliseconds = 0.0

    // Images: one slot per kind.
    struct Slot { var info: ktd_image_info; var bytes: [UInt8] }
    private var slots: [Slot?] = Array(repeating: nil, count: Int(KTD_IMAGE_COUNT.rawValue))
    private var interest: [UInt64] = Array(repeating: 0, count: Int(KTD_IMAGE_COUNT.rawValue)) // uptime ns of last request
    private var frameID: UInt64 = 0

    // Bodies.
    private var bodies: [Body] = []
    private var bodiesFrame: UInt64 = 0

    // MARK: references

    func acquire() { lock.lock(); references += 1; lock.unlock() }

    func release() {
        lock.lock()
        references = max(0, references - 1)
        let last = references == 0
        lock.unlock()
        if last {
            control.async { [self] in
                lock.lock(); active = false; desired = nil; lock.unlock()
                stopLocked()
            }
        }
    }

    // MARK: configuration

    func configure(_ config: ktd_config, active: Bool) -> Int32 {
        if active && config.depth_mode == KTD_DEPTH_OFF && config.color_resolution == KTD_COLOR_OFF {
            lock.lock(); status = "Pick a depth mode or a colour resolution"; lock.unlock()
            return 1
        }
        lock.lock()
        desired = config
        self.active = active
        lock.unlock()
        control.async { [self] in apply() }
        return 0
    }

    private func apply() {
        lock.lock()
        let wanted = desired
        let active = self.active
        let current = running
        lock.unlock()
        let same = current.map { c in wanted.map { w in c.depth_mode == w.depth_mode && c.color_resolution == w.color_resolution && c.fps == w.fps && c.device_index == w.device_index } ?? false } ?? false
        if session != nil && (!active || !same) {
            stopLocked()
        }
        if let wanted, active, session == nil {
            start(wanted)
        } else if let wanted, active, session != nil {
            lock.lock(); running = wanted; lock.unlock()  // only body tracking toggled
        }
    }

    private func stopLocked() {
        session?.stop()
        session = nil
        tracker = nil
        transformation = nil
        device = nil
        lock.lock()
        running = nil
        slots = Array(repeating: nil, count: slots.count)
        bodies = []
        if status.hasPrefix("Streaming") || status == "Starting" { status = "Stopped" }
        lock.unlock()
    }

    private func start(_ config: ktd_config) {
        lock.lock(); status = "Starting"; lock.unlock()
        do {
            let device = try KinectDevice(index: Int(config.device_index))
            var configuration = KinectConfiguration()
            configuration.depthMode = TDSession.depthMode(config.depth_mode)
            configuration.colorResolution = TDSession.colorResolution(config.color_resolution)
            configuration.frameRate = config.fps == KTD_FPS_5 ? .fps5 : config.fps == KTD_FPS_15 ? .fps15 : .fps30
            configuration.colorFormat = .bgra32
            let session = try KinectSession(device: device, configuration: configuration)
            let calibration = session.calibration
            let transformation = MetalTransformation(calibration: calibration)
            let tracker = BodyTracker(calibration: calibration)
            tracker.onBodies = { [weak self] bodies in
                guard let self else { return }
                lock.lock(); self.bodies = bodies; bodiesFrame = frameID; lock.unlock()
            }
            session.onCapture = { [weak self] capture in self?.process(capture) }
            session.onStatistics = { [weak self] stats in
                guard let self else { return }
                lock.lock(); statistics = stats; lock.unlock()
            }
            session.onError = { [weak self] error in
                guard let self else { return }
                lock.lock(); status = "\(error)"; lock.unlock()
            }
            try session.start(imu: false)
            self.device = device
            self.session = session
            self.transformation = transformation
            self.tracker = tracker
            self.readbackQueue = transformation?.device.makeCommandQueue()
            self.calibration = calibration
            lock.lock(); self.colorRays = []; self.buildingRays = false; lock.unlock()   // built on first use
            let json = device.rawCalibration.map { String(decoding: $0, as: UTF8.self) } ?? ""
            lock.lock()
            running = config
            serial = device.serialNumber
            calibrationJSON = json
            status = "Streaming from \(device.serialNumber)"
            lock.unlock()
        } catch {
            lock.lock()
            status = KinectDevice.installedCount == 0 ? "No Kinect connected" : "\(error)"
            running = nil
            lock.unlock()
            session = nil
            device = nil
        }
    }

    // MARK: per capture

    /// Has any caller asked for this kind recently? Read against
    /// the clock now, not the frame's start: a slow frame must not make
    /// interest refreshed meanwhile look like the future.
    private func wanted(_ kind: ktd_image_kind, now: UInt64) -> Bool {
        _ = now
        let current = DispatchTime.now().uptimeNanoseconds
        lock.lock(); defer { lock.unlock() }
        let last = interest[Int(kind.rawValue)]
        // Three seconds: a TouchDesigner node that is not being viewed may ask
        // only every second or two, and must still get its kind.
        return last <= current && current - last < 3_000_000_000
    }

    private func store(_ kind: ktd_image_kind, width: Int, height: Int, format: ktd_pixel_format, bytes: [UInt8], frame: UInt64, timestamp: UInt64) {
        var info = ktd_image_info()
        info.width = Int32(width)
        info.height = Int32(height)
        info.pixel_format = format
        info.bytes = bytes.count
        info.frame_id = frame
        info.device_timestamp_usec = timestamp
        lock.lock()
        slots[Int(kind.rawValue)] = Slot(info: info, bytes: bytes)
        lock.unlock()
    }

    private func process(_ capture: KinectCapture) {
        let started = DispatchTime.now().uptimeNanoseconds
        lock.lock()
        frameID += 1
        let frame = frameID
        let running = self.running
        lock.unlock()
        let now = started
        let timestamp = capture.deviceTimestampMicroseconds

        if let color = capture.color, color.format == .bgra32, wanted(KTD_IMAGE_COLOR, now: now) {
            store(KTD_IMAGE_COLOR, width: color.width, height: color.height, format: KTD_PIXEL_BGRA8, bytes: packed(color, bytesPerPixel: 4), frame: frame, timestamp: timestamp)
        }
        if let depth = capture.depth {
            let w = depth.width, h = depth.height
            if wanted(KTD_IMAGE_DEPTH_MM, now: now) {
                store(KTD_IMAGE_DEPTH_MM, width: w, height: h, format: KTD_PIXEL_R16, bytes: packed(depth, bytesPerPixel: 2), frame: frame, timestamp: timestamp)
            }
            if wanted(KTD_IMAGE_DEPTH, now: now) {
                store(KTD_IMAGE_DEPTH, width: w, height: h, format: KTD_PIXEL_R32F, bytes: floats(from: depth, scale: 0.001), frame: frame, timestamp: timestamp)
            }
            if let transformation {
                if wanted(KTD_IMAGE_POINT_CLOUD, now: now), let cloud = transformation.pointCloud(depth) {
                    var bytes = readback(cloud.texture, bytesPerPixel: 16)
                    scaleXYZ(&bytes)
                    store(KTD_IMAGE_POINT_CLOUD, width: w, height: h, format: KTD_PIXEL_RGBA32F, bytes: bytes, frame: frame, timestamp: timestamp)
                }
                let needDepthInColor = wanted(KTD_IMAGE_DEPTH_IN_COLOR, now: now) || wanted(KTD_IMAGE_COLOR_POINT_CLOUD, now: now)
                if needDepthInColor, let aligned = transformation.depthToColorCamera(depth) {
                    let mm = readback(aligned, bytesPerPixel: 2)
                    let cw = aligned.width, ch = aligned.height
                    if wanted(KTD_IMAGE_DEPTH_IN_COLOR, now: now) {
                        store(KTD_IMAGE_DEPTH_IN_COLOR, width: cw, height: ch, format: KTD_PIXEL_R32F, bytes: floats(fromMillimetres: mm, scale: 0.001), frame: frame, timestamp: timestamp)
                    }
                    if wanted(KTD_IMAGE_COLOR_POINT_CLOUD, now: now) {
                        lock.lock(); let rays = colorRays; let building = buildingRays; lock.unlock()
                        if rays.count == cw * ch {
                            store(KTD_IMAGE_COLOR_POINT_CLOUD, width: cw, height: ch, format: KTD_PIXEL_RGBA32F, bytes: colorPointCloud(mm, rays: rays, width: cw, height: ch), frame: frame, timestamp: timestamp)
                        } else if !building, let calibration {
                            // A second's work the first time: done off the capture thread.
                            lock.lock(); buildingRays = true; lock.unlock()
                            DispatchQueue.global(qos: .userInitiated).async { [self] in
                                let table = TDSession.colorRayTable(calibration)
                                lock.lock(); colorRays = table; buildingRays = false; lock.unlock()
                            }
                        }
                    }
                }
                if wanted(KTD_IMAGE_COLOR_IN_DEPTH, now: now), let color = capture.color, let aligned = transformation.colorToDepthCamera(depth: depth, color: color) {
                    store(KTD_IMAGE_COLOR_IN_DEPTH, width: aligned.width, height: aligned.height, format: KTD_PIXEL_BGRA8, bytes: readback(aligned, bytesPerPixel: 4), frame: frame, timestamp: timestamp)
                }
            }
            if wanted(KTD_IMAGE_PLAYER_INDEX, now: now) {
                store(KTD_IMAGE_PLAYER_INDEX, width: w, height: h, format: KTD_PIXEL_R8, bytes: playerIndex(depth: depth), frame: frame, timestamp: timestamp)
            }
        }
        if let ir = capture.ir, wanted(KTD_IMAGE_IR, now: now) {
            store(KTD_IMAGE_IR, width: ir.width, height: ir.height, format: KTD_PIXEL_R32F, bytes: floats(from: ir, scale: 1.0 / 65535.0), frame: frame, timestamp: timestamp)
        }
        if let running, running.body_tracking, let tracker {
            tracker.submit(capture)
        }
        let ms = Double(DispatchTime.now().uptimeNanoseconds - started) / 1e6
        lock.lock(); processingMilliseconds = ms; lock.unlock()
    }

    // MARK: pixel helpers

    private func packed(_ image: KinectImage, bytesPerPixel: Int) -> [UInt8] {
        let rowBytes = image.width * bytesPerPixel
        var out = [UInt8](repeating: 0, count: rowBytes * image.height)
        let src = image.bytes
        let total = rowBytes * image.height
        let stride = image.strideBytes
        let height = image.height
        out.withUnsafeMutableBytes { dst in
            if stride == rowBytes {
                dst.copyMemory(from: UnsafeRawBufferPointer(start: src.baseAddress, count: total))
            } else {
                for y in 0..<height {
                    memcpy(dst.baseAddress! + y * rowBytes, src.baseAddress! + y * stride, rowBytes)
                }
            }
        }
        return out
    }

    /// uint16 -> float * scale, with vDSP so a debug build keeps up too.
    private static func convert(_ values: UnsafePointer<UInt16>, count: Int, scale: Float, into out: UnsafeMutablePointer<Float>) {
        vDSP_vfltu16(values, 1, out, 1, vDSP_Length(count))
        var s = scale
        vDSP_vsmul(out, 1, &s, out, 1, vDSP_Length(count))
    }

    private func floats(from image: KinectImage, scale: Float) -> [UInt8] {
        let count = image.width * image.height
        var out = [UInt8](repeating: 0, count: count * 4)
        image.withUInt16 { values in
            out.withUnsafeMutableBytes { dst in
                TDSession.convert(values.baseAddress!, count: count, scale: scale, into: dst.bindMemory(to: Float.self).baseAddress!)
            }
        }
        return out
    }

    private func floats(fromMillimetres mm: [UInt8], scale: Float) -> [UInt8] {
        let count = mm.count / 2
        var out = [UInt8](repeating: 0, count: count * 4)
        mm.withUnsafeBytes { src in
            out.withUnsafeMutableBytes { dst in
                TDSession.convert(src.bindMemory(to: UInt16.self).baseAddress!, count: count, scale: scale, into: dst.bindMemory(to: Float.self).baseAddress!)
            }
        }
        return out
    }

    /// Millimetres to metres in place on an RGBA32F buffer; alpha untouched.
    private func scaleXYZ(_ bytes: inout [UInt8]) {
        bytes.withUnsafeMutableBytes { raw in
            let f = raw.bindMemory(to: Float.self)
            let pixels = vDSP_Length(f.count / 4)
            var s: Float = 0.001
            for channel in 0..<3 {
                vDSP_vsmul(f.baseAddress! + channel, 4, &s, f.baseAddress! + channel, 4, pixels)
            }
        }
    }

    private func colorPointCloud(_ mm: [UInt8], rays: [SIMD2<Float>], width: Int, height: Int) -> [UInt8] {
        let count = width * height
        var out = [UInt8](repeating: 0, count: count * 16)
        var z = [Float](repeating: 0, count: count)
        mm.withUnsafeBytes { src in
            TDSession.convert(src.bindMemory(to: UInt16.self).baseAddress!, count: count, scale: 0.001, into: &z)
        }
        out.withUnsafeMutableBytes { dst in
            let f = dst.bindMemory(to: Float.self).baseAddress!
            rays.withUnsafeBytes { r in
                let rf = r.bindMemory(to: Float.self).baseAddress!
                // x = ray.x * z, y = ray.y * z, written into the RGBA32F buffer with stride 4.
                vDSP_vmul(rf, 2, z, 1, f, 4, vDSP_Length(count))
                vDSP_vmul(rf + 1, 2, z, 1, f + 1, 4, vDSP_Length(count))
            }
            z.withUnsafeBufferPointer { zp in
                cblas_scopy(Int32(count), zp.baseAddress!, 1, f + 2, 4)
                // alpha = 1 where z > 0: clip z to 0..1e-9 then scale up -> exactly 0 or 1? use a threshold instead.
                var lo: Float = 0, hi: Float = 1
                vDSP_vclip(zp.baseAddress!, 1, &lo, &hi, f + 3, 4, vDSP_Length(count))   // 0..1, then any positive -> 1
                var zero: Float = 0
                var one: Float = 1
                vDSP_vthrsc(f + 3, 4, &zero, &one, f + 3, 4, vDSP_Length(count))         // > 0 -> +1, else -1
                vDSP_vthres(f + 3, 4, &zero, f + 3, 4, vDSP_Length(count))                // negatives -> 0
            }
        }
        return out
    }

    /// Reads a texture back through a blit into shared memory, whatever its storage mode.
    private func readback(_ texture: MTLTexture, bytesPerPixel: Int) -> [UInt8] {
        let rowBytes = texture.width * bytesPerPixel
        let size = rowBytes * texture.height
        var out = [UInt8](repeating: 0, count: size)
        guard let queue = readbackQueue, let buffer = queue.device.makeBuffer(length: size, options: .storageModeShared),
              let command = queue.makeCommandBuffer(), let blit = command.makeBlitCommandEncoder() else { return out }
        blit.copy(from: texture, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                  sourceSize: MTLSize(width: texture.width, height: texture.height, depth: 1),
                  to: buffer, destinationOffset: 0, destinationBytesPerRow: rowBytes, destinationBytesPerImage: size)
        blit.endEncoding()
        command.commit()
        command.waitUntilCompleted()
        out.withUnsafeMutableBytes { $0.copyMemory(from: UnsafeRawBufferPointer(start: buffer.contents(), count: size)) }
        return out
    }

    /// R8 player map: each body's colour box, carried to the depth image at the
    /// body's own distance, painted with its id where the depth agrees.
    private func playerIndex(depth: KinectImage) -> [UInt8] {
        let w = depth.width, h = depth.height
        var out = [UInt8](repeating: 0, count: w * h)
        lock.lock(); let bodies = self.bodies; lock.unlock()
        guard var calibration, !bodies.isEmpty else { return out }
        depth.withUInt16 { values in
            for body in bodies {
                let positions = body.joints.compactMap { $0.position }
                guard !positions.isEmpty else { continue }
                let zs = positions.map { $0.z }.sorted()
                let z = zs[zs.count / 2]
                guard z > 0 else { continue }
                // The region: the colour box's corners at that distance, else the joints' spread.
                var corners: [SIMD2<Float>]
                if let box = body.boundingBox {
                    corners = [SIMD2(box.x, box.y), SIMD2(box.x + box.z, box.y), SIMD2(box.x, box.y + box.w), SIMD2(box.x + box.z, box.y + box.w)]
                } else {
                    corners = body.joints.map { $0.colorPixel }
                }
                var minX = Float.greatestFiniteMagnitude, minY = Float.greatestFiniteMagnitude, maxX = -Float.greatestFiniteMagnitude, maxY = -Float.greatestFiniteMagnitude
                for c in corners {
                    var source = k4a_float2_t(xy: .init(x: c.x, y: c.y))
                    var p3 = k4a_float3_t(), p2 = k4a_float2_t()
                    var valid: Int32 = 0
                    guard k4a_calibration_2d_to_3d(&calibration, &source, z, K4A_CALIBRATION_TYPE_COLOR, K4A_CALIBRATION_TYPE_DEPTH, &p3, &valid) == K4A_RESULT_SUCCEEDED, valid == 1,
                          k4a_calibration_3d_to_2d(&calibration, &p3, K4A_CALIBRATION_TYPE_DEPTH, K4A_CALIBRATION_TYPE_DEPTH, &p2, &valid) == K4A_RESULT_SUCCEEDED, valid == 1 else { continue }
                    minX = min(minX, p2.xy.x); maxX = max(maxX, p2.xy.x); minY = min(minY, p2.xy.y); maxY = max(maxY, p2.xy.y)
                }
                guard minX < maxX, minY < maxY else { continue }
                let x0 = max(0, Int(minX)), x1 = min(w - 1, Int(maxX)), y0 = max(0, Int(minY)), y1 = min(h - 1, Int(maxY))
                guard x0 <= x1, y0 <= y1 else { continue }
                let id = UInt8(clamping: body.index)
                let near = UInt16(max(0, z - 500)), far = UInt16(min(65535, z + 500))
                for y in y0...y1 {
                    for x in x0...x1 {
                        let v = values[y * w + x]
                        if v >= near && v <= far { out[y * w + x] = id }
                    }
                }
            }
        }
        return out
    }

    // MARK: readers

    func latestImage(_ kind: ktd_image_kind, since: UInt64, info: UnsafeMutablePointer<ktd_image_info>?, dst: UnsafeMutableRawPointer?, capacity: Int) -> UInt64 {
        guard kind.rawValue < KTD_IMAGE_COUNT.rawValue else { return 0 }
        lock.lock()
        interest[Int(kind.rawValue)] = DispatchTime.now().uptimeNanoseconds
        guard let slot = slots[Int(kind.rawValue)] else { lock.unlock(); return 0 }
        info?.pointee = slot.info
        if slot.info.frame_id <= since { lock.unlock(); return 0 }
        if let dst {
            guard capacity >= slot.bytes.count else { lock.unlock(); return 0 }
            slot.bytes.withUnsafeBytes { dst.copyMemory(from: $0.baseAddress!, byteCount: $0.count) }
        }
        let id = slot.info.frame_id
        lock.unlock()
        return id
    }

    static let jointNames: [String] = [
        "pelvis", "spine_navel", "spine_chest", "neck", "clavicle_left", "shoulder_left", "elbow_left", "wrist_left",
        "hand_left", "handtip_left", "thumb_left", "clavicle_right", "shoulder_right", "elbow_right", "wrist_right",
        "hand_right", "handtip_right", "thumb_right", "hip_left", "knee_left", "ankle_left", "foot_left", "hip_right",
        "knee_right", "ankle_right", "foot_right", "head", "nose", "eye_left", "ear_left", "eye_right", "ear_right",
    ]
    static let jointCStrings: [UnsafePointer<CChar>] = jointNames.map { UnsafePointer(strdup($0)!) }

    func bodies(into out: UnsafeMutablePointer<ktd_body>?, max: Int32, frame: UnsafeMutablePointer<UInt64>?) -> Int32 {
        lock.lock()
        let bodies = self.bodies
        let bodiesFrame = self.bodiesFrame
        lock.unlock()
        frame?.pointee = bodiesFrame
        guard let out, max > 0 else { return Int32(bodies.count) }
        let count = min(Int(max), bodies.count)
        for i in 0..<count {
            out[i] = TDSession.convert(bodies[i])
        }
        return Int32(count)
    }

    static func convert(_ body: Body) -> ktd_body {
        var result = ktd_body()
        result.id = Int32(body.index)
        result.pose = body.source == "pose"
        let box = body.boundingBox ?? SIMD4<Float>(0, 0, 0, 0)
        withUnsafeMutablePointer(to: &result.bbox) { p in
            p.withMemoryRebound(to: Float.self, capacity: 4) { f in f[0] = box.x; f[1] = box.y; f[2] = box.z; f[3] = box.w }
        }
        let byName = Dictionary(body.joints.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        func make(_ j: BodyJoint?) -> ktd_joint {
            var k = ktd_joint()
            guard let j else { return k }
            k.pixel_x = j.colorPixel.x; k.pixel_y = j.colorPixel.y
            k.confidence = j.confidence
            if let p = j.position {
                k.x = p.x / 1000; k.y = p.y / 1000; k.z = p.z / 1000
                k.valid = true
            }
            return k
        }
        func lerp(_ a: BodyJoint?, _ b: BodyJoint?, _ t: Float) -> ktd_joint {
            guard let a, let b else { return ktd_joint() }
            var k = ktd_joint()
            k.pixel_x = a.colorPixel.x + (b.colorPixel.x - a.colorPixel.x) * t
            k.pixel_y = a.colorPixel.y + (b.colorPixel.y - a.colorPixel.y) * t
            k.confidence = min(a.confidence, b.confidence)
            if let pa = a.position, let pb = b.position {
                let p = pa + (pb - pa) * t
                k.x = p.x / 1000; k.y = p.y / 1000; k.z = p.z / 1000
                k.valid = true
            }
            return k
        }
        let centre = byName["center"]
        let pelvis = byName["pelvis"] ?? centre
        let neck = byName["neck"]
        // Head: between the ears when both are there, else the nose.
        var head: ktd_joint
        if let l = byName["ear_left"], let r = byName["ear_right"] { head = lerp(l, r, 0.5) } else { head = make(byName["nose"]) }
        let table: [ktd_joint] = [
            make(pelvis), lerp(pelvis, neck, 0.33), lerp(pelvis, neck, 0.66), make(neck),
            lerp(neck, byName["shoulder_left"], 0.5), make(byName["shoulder_left"]), make(byName["elbow_left"]), make(byName["wrist_left"]),
            ktd_joint(), ktd_joint(), ktd_joint(),
            lerp(neck, byName["shoulder_right"], 0.5), make(byName["shoulder_right"]), make(byName["elbow_right"]), make(byName["wrist_right"]),
            ktd_joint(), ktd_joint(), ktd_joint(),
            make(byName["hip_left"]), make(byName["knee_left"]), make(byName["ankle_left"]), ktd_joint(),
            make(byName["hip_right"]), make(byName["knee_right"]), make(byName["ankle_right"]), ktd_joint(),
            head, make(byName["nose"]), make(byName["eye_left"]), make(byName["ear_left"]), make(byName["eye_right"]), make(byName["ear_right"]),
        ]
        withUnsafeMutablePointer(to: &result.joints) { p in
            p.withMemoryRebound(to: ktd_joint.self, capacity: Int(KTD_JOINT_COUNT)) { j in
                for i in 0..<Int(KTD_JOINT_COUNT) { j[i] = table[i] }
            }
        }
        return result
    }

    func stat(_ stat: ktd_stat) -> Double {
        lock.lock(); defer { lock.unlock() }
        switch stat {
        case KTD_STAT_CAPTURES_PER_SECOND: return statistics.capturesPerSecond
        case KTD_STAT_DECODE_MILLISECONDS: return processingMilliseconds
        case KTD_STAT_SENSOR_TEMPERATURE_C: return Double(statistics.sensorTemperatureCelsius)
        case KTD_STAT_BODY_MILLISECONDS: return tracker?.lastProcessingMilliseconds ?? 0
        case KTD_STAT_BODY_COUNT: return Double(bodies.count)
        case KTD_STAT_DEVICES: return Double(KinectDevice.installedCount)
        default: return 0
        }
    }

    func copyString(_ text: String, to out: UnsafeMutablePointer<CChar>?, capacity: Int) -> Int {
        guard let out, capacity > 0 else { return text.utf8.count }
        let bytes = Array(text.utf8)
        let n = min(bytes.count, capacity - 1)
        bytes.withUnsafeBufferPointer { src in
            out.withMemoryRebound(to: UInt8.self, capacity: capacity) { dst in
                for i in 0..<n { dst[i] = src[i] }
            }
        }
        out[n] = 0
        return bytes.count
    }

    var currentStatus: String { lock.lock(); defer { lock.unlock() }; return status }
    var currentSerial: String { lock.lock(); defer { lock.unlock() }; return serial }
    var currentCalibrationJSON: String { lock.lock(); defer { lock.unlock() }; return calibrationJSON }

    // MARK: mappings

    static func depthMode(_ mode: ktd_depth_mode) -> DepthMode {
        switch mode {
        case KTD_DEPTH_NFOV_2X2BINNED: return .nfovBinned
        case KTD_DEPTH_NFOV_UNBINNED: return .nfovUnbinned
        case KTD_DEPTH_WFOV_2X2BINNED: return .wfovBinned
        case KTD_DEPTH_WFOV_UNBINNED: return .wfovUnbinned
        case KTD_DEPTH_PASSIVE_IR: return .passiveIR
        default: return .off
        }
    }

    static func colorResolution(_ resolution: ktd_color_resolution) -> ColorResolution {
        switch resolution {
        case KTD_COLOR_720P: return .p720
        case KTD_COLOR_1080P: return .p1080
        case KTD_COLOR_1440P: return .p1440
        case KTD_COLOR_1536P: return .p1536
        case KTD_COLOR_2160P: return .p2160
        case KTD_COLOR_3072P: return .p3072
        default: return .off
        }
    }

    /// Unit rays (x/z, y/z) for every colour pixel, from the colour camera's model.
    static func colorRayTable(_ calibration: k4a_calibration_t) -> [SIMD2<Float>] {
        var copy = calibration
        let w = Int(calibration.color_camera_calibration.resolution_width)
        let h = Int(calibration.color_camera_calibration.resolution_height)
        guard w > 0, h > 0 else { return [] }
        var rays = [SIMD2<Float>](repeating: SIMD2(0, 0), count: w * h)
        for y in 0..<h {
            for x in 0..<w {
                var pixel = k4a_float2_t(xy: .init(x: Float(x), y: Float(y)))
                var point = k4a_float3_t()
                var valid: Int32 = 0
                if k4a_calibration_2d_to_3d(&copy, &pixel, 1000, K4A_CALIBRATION_TYPE_COLOR, K4A_CALIBRATION_TYPE_COLOR, &point, &valid) == K4A_RESULT_SUCCEEDED, valid == 1 {
                    rays[y * w + x] = SIMD2(point.xyz.x / 1000, point.xyz.y / 1000)
                }
            }
        }
        return rays
    }
}

// MARK: - C exports

private func session(_ pointer: OpaquePointer?) -> TDSession? {
    guard let pointer else { return nil }
    return Unmanaged<TDSession>.fromOpaque(UnsafeRawPointer(pointer)).takeUnretainedValue()
}

@_cdecl("ktd_session_acquire")
public func ktd_session_acquire() -> OpaquePointer? {
    TDSession.shared.acquire()
    return OpaquePointer(Unmanaged.passUnretained(TDSession.shared).toOpaque())
}

@_cdecl("ktd_session_release")
public func ktd_session_release(_ pointer: OpaquePointer?) {
    session(pointer)?.release()
}

@_cdecl("ktd_session_configure")
public func ktd_session_configure(_ pointer: OpaquePointer?, _ config: UnsafePointer<ktd_config>?, _ active: Bool) -> Int32 {
    guard let s = session(pointer), let config else { return 2 }
    return s.configure(config.pointee, active: active)
}

@_cdecl("ktd_session_latest_image")
public func ktd_session_latest_image(_ pointer: OpaquePointer?, _ kind: ktd_image_kind, _ since: UInt64,
                                     _ info: UnsafeMutablePointer<ktd_image_info>?, _ dst: UnsafeMutableRawPointer?, _ capacity: Int) -> UInt64 {
    guard let s = session(pointer) else { return 0 }
    return s.latestImage(kind, since: since, info: info, dst: dst, capacity: capacity)
}

@_cdecl("ktd_session_bodies")
public func ktd_session_bodies(_ pointer: OpaquePointer?, _ out: UnsafeMutablePointer<ktd_body>?, _ max: Int32, _ frame: UnsafeMutablePointer<UInt64>?) -> Int32 {
    guard let s = session(pointer) else { return 0 }
    return s.bodies(into: out, max: max, frame: frame)
}

@_cdecl("ktd_joint_name")
public func ktd_joint_name(_ index: Int32) -> UnsafePointer<CChar>? {
    guard index >= 0, Int(index) < TDSession.jointCStrings.count else { return nil }
    return TDSession.jointCStrings[Int(index)]
}

@_cdecl("ktd_session_stat")
public func ktd_session_stat(_ pointer: OpaquePointer?, _ stat: ktd_stat) -> Double {
    session(pointer)?.stat(stat) ?? 0
}

@_cdecl("ktd_session_status")
public func ktd_session_status(_ pointer: OpaquePointer?, _ out: UnsafeMutablePointer<CChar>?, _ capacity: Int) {
    let text = session(pointer)?.currentStatus ?? "No session"
    _ = TDSession.shared.copyString(text, to: out, capacity: capacity)
}

@_cdecl("ktd_session_serial")
public func ktd_session_serial(_ pointer: OpaquePointer?, _ out: UnsafeMutablePointer<CChar>?, _ capacity: Int) {
    _ = TDSession.shared.copyString(session(pointer)?.currentSerial ?? "", to: out, capacity: capacity)
}

@_cdecl("ktd_session_calibration_json")
public func ktd_session_calibration_json(_ pointer: OpaquePointer?, _ out: UnsafeMutablePointer<CChar>?, _ capacity: Int) -> Int {
    TDSession.shared.copyString(session(pointer)?.currentCalibrationJSON ?? "", to: out, capacity: capacity)
}
