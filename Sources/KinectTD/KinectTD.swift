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
    private var producer: FrameProducer?
    private var tracker: BodyTracker?
    private var calibration: k4a_calibration_t?

    // Client mode: frames come from the app's frame server over the socket.
    private enum Mode { case local, client }
    private var mode: Mode = .local
    private var client: FrameClient?
    private var clientStats: [Double] = Array(repeating: 0, count: 6)
    private var lastSubscriptionMask: UInt32 = .max

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

    // Bodies, already in k4abt order.
    private var bodies: [FrameBody] = []
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
        client?.close()
        client = nil
        session?.stop()
        session = nil
        tracker = nil
        transformation = nil
        producer = nil
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
        // Prefer the app's frame server when it is running: one camera, shared.
        if startClient(config) { return }
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
            let producer = FrameProducer(calibration: calibration, transformation: transformation)
            let tracker = BodyTracker(calibration: calibration)
            tracker.onBodies = { [weak self] bodies in
                guard let self else { return }
                let frames = bodies.map(FrameBody.from)
                lock.lock(); self.bodies = frames; bodiesFrame = frameID; lock.unlock()
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
            self.mode = .local
            self.device = device
            self.session = session
            self.transformation = transformation
            self.producer = producer
            self.tracker = tracker
            self.calibration = calibration
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
        let bodies = self.bodies
        lock.unlock()

        if let running, running.body_tracking, let tracker { tracker.submit(capture) }

        guard let producer else { return }
        let kinds = wantedKinds()
        if !kinds.isEmpty {
            let images = producer.images(from: capture, kinds: kinds, bodies: bodies, frameID: frame)
            for image in images { store(image) }
        }
        let ms = Double(DispatchTime.now().uptimeNanoseconds - started) / 1e6
        lock.lock(); processingMilliseconds = ms; lock.unlock()
    }

    /// The image kinds any reader has asked for recently, as FrameKinds.
    private func wantedKinds() -> Set<FrameKind> {
        let current = DispatchTime.now().uptimeNanoseconds
        lock.lock(); defer { lock.unlock() }
        var kinds = Set<FrameKind>()
        for raw in 0..<interest.count {
            let last = interest[raw]
            if last <= current, current - last < 3_000_000_000, let kind = FrameKind(rawValue: Int32(raw)) { kinds.insert(kind) }
        }
        return kinds
    }

    private func store(_ image: FrameImage) {
        var info = ktd_image_info()
        info.width = image.width
        info.height = image.height
        info.pixel_format = ktd_pixel_format(UInt32(image.pixelFormat.rawValue))
        info.bytes = image.bytes.count
        info.frame_id = image.frameID
        info.device_timestamp_usec = image.deviceTimestampMicroseconds
        lock.lock()
        slots[Int(image.kind.rawValue)] = Slot(info: info, bytes: image.bytes)
        lock.unlock()
    }

    // MARK: client mode

    /// Connects to the app's frame server; returns true when it took over.
    private func startClient(_ config: ktd_config) -> Bool {
        let client = FrameClient()
        guard client.connect() else { return false }
        client.onImage = { [weak self] image in self?.store(image) }
        client.onBodies = { [weak self] bodies in
            guard let self else { return }
            lock.lock(); self.bodies = bodies; frameID += 1; bodiesFrame = frameID; lock.unlock()
        }
        client.onStatus = { [weak self] text in
            guard let self else { return }
            lock.lock(); status = text.hasPrefix("Streaming from ") ? text + " via Kinect for Mac" : text; lock.unlock()
        }
        client.onStats = { [weak self] stats in
            guard let self else { return }
            lock.lock(); clientStats = stats; lock.unlock()
        }
        client.onDisconnect = { [weak self] in
            guard let self else { return }
            lock.lock(); let wasClient = mode == .client; if wasClient { status = "Disconnected from Kinect for Mac" }; lock.unlock()
        }
        self.client = client
        self.mode = .client
        self.serial = client.serial
        lock.lock()
        status = client.serial.isEmpty ? "Connected to Kinect for Mac" : "Streaming from \(client.serial) via Kinect for Mac"
        running = config
        lock.unlock()
        sendSubscription(config, force: true)
        return true
    }

    /// Tells the server which kinds and config this process wants.
    private func sendSubscription(_ config: ktd_config, force: Bool) {
        guard let client else { return }
        let kinds = wantedKinds()
        var mask: UInt32 = 0
        for kind in kinds { mask |= 1 << UInt32(kind.rawValue) }
        lock.lock(); let changed = force || mask != lastSubscriptionMask; lastSubscriptionMask = mask; lock.unlock()
        guard changed else { return }
        var sub = FrameProtocol.Subscription()
        sub.kinds = kinds
        sub.bodies = config.body_tracking
        sub.config = FrameProtocol.SessionRequest(
            depthMode: TDSession.depthMode(config.depth_mode),
            colorResolution: TDSession.colorResolution(config.color_resolution),
            frameRate: config.fps == KTD_FPS_5 ? .fps5 : config.fps == KTD_FPS_15 ? .fps15 : .fps30,
            bodyTracking: config.body_tracking, deviceIndex: config.device_index, active: true)
        client.subscribe(sub)
    }

    // MARK: readers

    func latestImage(_ kind: ktd_image_kind, since: UInt64, info: UnsafeMutablePointer<ktd_image_info>?, dst: UnsafeMutableRawPointer?, capacity: Int) -> UInt64 {
        guard kind.rawValue < KTD_IMAGE_COUNT.rawValue else { return 0 }
        lock.lock()
        interest[Int(kind.rawValue)] = DispatchTime.now().uptimeNanoseconds
        let needResub = mode == .client && (lastSubscriptionMask & (1 << UInt32(kind.rawValue))) == 0
        let config = running
        guard let slot = slots[Int(kind.rawValue)] else {
            lock.unlock()
            if needResub, let config { control.async { [self] in sendSubscription(config, force: false) } }
            return 0
        }
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

    static func convert(_ body: FrameBody) -> ktd_body {
        var result = ktd_body()
        result.id = body.id
        result.pose = body.pose
        withUnsafeMutablePointer(to: &result.bbox) { p in
            p.withMemoryRebound(to: Float.self, capacity: 4) { f in f[0] = body.bbox.x; f[1] = body.bbox.y; f[2] = body.bbox.z; f[3] = body.bbox.w }
        }
        withUnsafeMutablePointer(to: &result.joints) { p in
            p.withMemoryRebound(to: ktd_joint.self, capacity: Int(KTD_JOINT_COUNT)) { j in
                for i in 0..<Int(KTD_JOINT_COUNT) {
                    let src = body.joints[i]
                    var k = ktd_joint()
                    k.x = src.x; k.y = src.y; k.z = src.z
                    k.pixel_x = src.pixelX; k.pixel_y = src.pixelY
                    k.confidence = src.confidence; k.valid = src.valid
                    j[i] = k
                }
            }
        }
        return result
    }

    func stat(_ stat: ktd_stat) -> Double {
        lock.lock(); defer { lock.unlock() }
        if mode == .client {
            switch stat {
            case KTD_STAT_CAPTURES_PER_SECOND: return clientStats[0]
            case KTD_STAT_DECODE_MILLISECONDS: return clientStats[1]
            case KTD_STAT_SENSOR_TEMPERATURE_C: return clientStats[2]
            case KTD_STAT_BODY_MILLISECONDS: return clientStats[3]
            case KTD_STAT_BODY_COUNT: return Double(bodies.count)
            case KTD_STAT_DEVICES: return clientStats[5]
            default: return 0
            }
        }
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
