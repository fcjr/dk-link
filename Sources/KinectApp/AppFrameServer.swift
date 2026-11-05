import Foundation
import KinectKit
import KinectCore

/// Bridges the app's live camera to the frame server so the TouchDesigner
/// plugin (and any other local client) can share this one camera. Owns the
/// FrameServer and a FrameProducer; fed from the app's capture callback. All
/// the camera-sharing logic lives here so AppModel only starts/stops it and
/// hands it each capture.
final class AppFrameServer: @unchecked Sendable {
    static let shared = AppFrameServer()

    let server = FrameServer()
    private let lock = NSLock()
    private var producer: FrameProducer?
    private var serial = ""
    private var bodies: [FrameBody] = []
    private var frameID: UInt64 = 0
    private var windowStart = DispatchTime.now().uptimeNanoseconds
    private var windowCount = 0
    private var fps = 0.0
    private var temperature: Float = 0

    /// AppModel wires these so a client's config request and the client count
    /// reach the UI. Config requests are last-writer-wins: the app adopts them.
    var onConfigRequest: ((FrameProtocol.SessionRequest) -> Void)?
    var onClientCount: ((Int) -> Void)?

    private init() {
        server.onConfigRequest = { [weak self] request in self?.onConfigRequest?(request) }
        server.onClientsChanged = { [weak self] n in self?.onClientCount?(n) }
    }

    /// Starts serving once the camera is up. The producer uses a GPU transform
    /// built from this calibration, so the server's bytes equal the plugin's
    /// local-mode bytes exactly.
    func begin(calibration: k4a_calibration_t, serial: String) {
        let transformation = MetalTransformation(calibration: calibration)
        lock.lock()
        producer = FrameProducer(calibration: calibration, transformation: transformation)
        self.serial = serial
        bodies = []
        lock.unlock()
        server.updateStatus("Streaming from \(serial)", serial: serial)
    }

    /// Opens the socket at app launch so a plugin can connect and request a
    /// start even before the camera is streaming.
    func launch() {
        server.start()
        server.updateStatus("No Kinect connected", serial: "")
    }

    /// Stops producing frames but keeps the socket open, so a connected plugin
    /// can ask the app to start again.
    func end() {
        lock.lock(); producer = nil; bodies = []; lock.unlock()
        server.updateStatus("Kinect for Mac is not streaming", serial: "")
    }

    /// The app's tracker hands bodies here (converted once).
    func setBodies(_ tracked: [Body]) {
        let frames = tracked.map(FrameBody.from)
        lock.lock(); bodies = frames; lock.unlock()
    }

    /// Called from the capture thread for every frame. Cheap when no client is
    /// connected or none wants anything.
    func process(_ capture: KinectCapture) {
        let kinds = server.wantedKinds
        let clientsWantBodies = server.wantsBodies
        lock.lock()
        guard let producer else { lock.unlock(); return }
        frameID += 1
        let frame = frameID
        let bodies = self.bodies
        lock.unlock()

        // Rate and temperature for the client's Info CHOP.
        windowCount += 1
        let now = DispatchTime.now().uptimeNanoseconds
        if now - windowStart >= 1_000_000_000 {
            lock.lock(); fps = Double(windowCount) * 1e9 / Double(now - windowStart); lock.unlock()
            windowStart = now; windowCount = 0
        }
        temperature = capture.temperatureCelsius

        guard !kinds.isEmpty || clientsWantBodies else { return }
        let started = now
        let images = kinds.isEmpty ? [] : producer.images(from: capture, kinds: kinds, bodies: bodies, frameID: frame)
        let decodeMs = Double(DispatchTime.now().uptimeNanoseconds - started) / 1e6
        let stats: [Double] = [fps, decodeMs, Double(temperature), 0, Double(bodies.count), Double(KinectDevice.installedCount)]
        server.publish(images: images, bodies: bodies, stats: stats)
    }
}
