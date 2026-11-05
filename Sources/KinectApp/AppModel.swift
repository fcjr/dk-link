import Foundation
import SwiftUI
import Metal
import KinectKit
import KinectCore

/// Everything the menu and the preview show, on the main actor. The capture
/// thread talks to it through `Task { @MainActor in ... }`.
@MainActor
final class AppModel: ObservableObject {
    enum State: Equatable {
        case noDevice
        case idle(serial: String)
        case starting
        case running(serial: String)
        case failed(String)

        var label: String {
            switch self {
            case .noDevice: return "No Kinect connected"
            case .idle(let serial): return "Kinect \(serial) ready"
            case .starting: return "Starting…"
            case .running(let serial): return "Streaming from \(serial)"
            case .failed(let why): return why
            }
        }
        var isRunning: Bool { if case .running = self { return true } else { return false } }
    }

    static weak var shared: AppModel?

    @Published var state: State = .noDevice
    @Published var configuration: KinectConfiguration {
        didSet { save() }
    }
    @Published var output: OutputSettings {
        didSet {
            save()
            pipeline?.settings = output
            osc?.reconfigure(host: output.oscHost, port: output.oscPort)
        }
    }
    @Published var autoStart: Bool {
        didSet { save() }
    }
    @Published var statistics = KinectSessionStatistics()
    @Published var processingMilliseconds: Double = 0
    @Published var firmware: FirmwareVersion?
    @Published var controls: [ColorControl: ColorControlValue] = [:]
    @Published var controlCapabilities: [ColorControl: ColorControlCapabilities] = [:]
    @Published var lastIMU: IMUSample?
    @Published var bodyCount = 0
    @Published var bodyMilliseconds: Double = 0
    @Published var bodies: [Body] = []
    /// TouchDesigner (or other) clients attached to the app's frame server.
    @Published var frameClientCount = 0
    private var bodyTracker: BodyTracker?
    private var osc: OSCSender?

    let pipeline: OutputPipeline?
    private var device: KinectDevice?
    private var session: KinectSession?
    private var pollTimer: Timer?
    private var hotplugToken: Int32 = 0
    private let defaults = UserDefaults.standard

    init() {
        let decoder = JSONDecoder()
        if let data = defaults.data(forKey: "configuration"), let saved = try? decoder.decode(KinectConfiguration.self, from: data) {
            configuration = saved
        } else {
            configuration = KinectConfiguration()
        }
        if let data = defaults.data(forKey: "output"), let saved = try? decoder.decode(OutputSettings.self, from: data) {
            output = saved
        } else {
            output = OutputSettings()
        }
        autoStart = defaults.object(forKey: "autoStart") as? Bool ?? true
        pipeline = OutputPipeline()
        pipeline?.settings = output
        AppModel.shared = self
        AppFrameServer.shared.onClientCount = { [weak self] n in Task { @MainActor in self?.frameClientCount = n } }
        AppFrameServer.shared.onConfigRequest = { [weak self] request in Task { @MainActor in self?.applyClientRequest(request) } }
        AppFrameServer.shared.launch()
        refreshDevices()
        // Hotplug events arrive on a background thread; the 2 s poll stays as
        // the fallback for anything the event path misses.
        pollTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
        hotplugToken = openk4a_hotplug_subscribe({ _, arrived, serial in
            let text = serial.map { String(cString: $0) } ?? ""
            Task { @MainActor in AppModel.shared?.hotplug(arrived: arrived, serial: text) }
        }, nil)
    }

    private func hotplug(arrived: Bool, serial: String) {
        if arrived {
            if device == nil { refreshDevices() }
        } else if let device, device.serialNumber == serial || serial.isEmpty {
            // The camera we were using is gone: stop cleanly and wait for it.
            session?.stop()
            session = nil
            pipeline?.stop()
            self.device = nil
            state = .noDevice
        }
    }

    private func save() {
        let encoder = JSONEncoder()
        if let data = try? encoder.encode(configuration) { defaults.set(data, forKey: "configuration") }
        if let data = try? encoder.encode(output) { defaults.set(data, forKey: "output") }
        defaults.set(autoStart, forKey: "autoStart")
    }

    var previewFrames: PreviewFrames? { pipeline?.preview }
    var metalDevice: MTLDevice? { pipeline?.textures.device }

    // MARK: devices

    func refreshDevices() {
        if state.isRunning { return }
        if device == nil {
            if KinectDevice.installedCount > 0, let opened = try? KinectDevice(index: 0) {
                device = opened
                firmware = opened.firmwareVersion
                state = .idle(serial: opened.serialNumber)
                if autoStart { start() }
            } else {
                state = .noDevice
            }
        }
    }

    private func poll() {
        if state.isRunning {
            // A device that went away stops delivering frames; the session reports that.
            return
        }
        if device != nil, KinectDevice.installedCount == 0 {
            device = nil
            state = .noDevice
        }
        if device == nil {
            if case .failed = state, KinectDevice.installedCount == 0 { return }
            refreshDevices()
        }
    }

    // MARK: streaming

    func start() {
        guard let device, !state.isRunning else { return }
        state = .starting
        do {
            let session = try KinectSession(device: device, configuration: configuration)
            pipeline?.setCalibration(session.calibration)
            let pipeline = self.pipeline
            let tracker = BodyTracker(calibration: session.calibration)
            let osc = OSCSender(host: output.oscHost, port: output.oscPort)
            tracker.onBodies = { [weak self] bodies in
                osc.send(BodyTracker.oscBundle(bodies))
                AppFrameServer.shared.setBodies(bodies)
                let milliseconds = tracker.lastProcessingMilliseconds
                Task { @MainActor in
                    self?.bodyCount = bodies.count
                    self?.bodyMilliseconds = milliseconds
                    self?.bodies = bodies
                }
            }
            bodyTracker = tracker
            self.osc = osc
            let trackingWanted = { [weak self] () -> Bool in
                // Read on the capture thread; a stale value for one frame is harmless.
                self?.output.bodyTracking ?? false
            }
            session.onCapture = { capture in
                pipeline?.process(capture)
                if trackingWanted() { tracker.submit(capture) }
                AppFrameServer.shared.process(capture)
            }
            session.onStatistics = { [weak self] statistics in
                let milliseconds = pipeline?.lastProcessingMilliseconds ?? 0
                Task { @MainActor in
                    self?.statistics = statistics
                    self?.processingMilliseconds = milliseconds
                }
            }
            session.onIMU = { [weak self] sample in
                // Keep the UI copy cheap: one in fifty.
                if sample.accelerationTimestampMicroseconds % 50 == 0 {
                    Task { @MainActor in self?.lastIMU = sample }
                }
            }
            session.onError = { [weak self] error in
                Task { @MainActor in
                    guard let self else { return }
                    // No frames for a while usually means the cable went: let go
                    // of the device so the poll can find it again when it is back.
                    self.session?.stop()
                    self.session = nil
                    self.pipeline?.stop()
                    self.device = nil
                    self.state = .failed("\(error)")
                }
            }
            try session.start(imu: true)
            self.session = session
            state = .running(serial: device.serialNumber)
            AppFrameServer.shared.begin(calibration: session.calibration, serial: device.serialNumber)
            readControls()
        } catch {
            state = .failed("\(error)")
            session = nil
        }
    }

    func stop() {
        AppFrameServer.shared.end()
        frameClientCount = 0
        session?.stop()
        session = nil
        pipeline?.stop()
        osc?.close()
        osc = nil
        bodyTracker = nil
        bodyCount = 0
        bodies = []
        if let device {
            state = .idle(serial: device.serialNumber)
        } else {
            state = .noDevice
        }
    }

    /// A TouchDesigner client asked for a configuration; adopt it, as if the
    /// menu changed. Body tracking must be on whenever a client wants bodies.
    func applyClientRequest(_ request: FrameProtocol.SessionRequest) {
        var changed = false
        if configuration.depthMode != request.depthMode { configuration.depthMode = request.depthMode; changed = true }
        if configuration.colorResolution != request.colorResolution { configuration.colorResolution = request.colorResolution; changed = true }
        if configuration.frameRate != request.frameRate { configuration.frameRate = request.frameRate; changed = true }
        if request.bodyTracking && !output.bodyTracking { output.bodyTracking = true }
        if changed && state.isRunning { restart() }
        else if !state.isRunning && request.active { start() }
    }

    func restart() {
        if state.isRunning {
            stop()
            start()
        }
    }

    // MARK: colour controls

    func readControls() {
        guard let device, configuration.colorResolution != .off else { return }
        var values: [ColorControl: ColorControlValue] = [:]
        var capabilities: [ColorControl: ColorControlCapabilities] = [:]
        for control in ColorControl.allCases where control != .autoExposurePriority {
            if let value = device.value(of: control) { values[control] = value }
            if let caps = device.capabilities(of: control) { capabilities[control] = caps }
        }
        controls = values
        controlCapabilities = capabilities
    }

    func set(_ control: ColorControl, _ value: ColorControlValue) {
        guard let device else { return }
        do {
            try device.set(control, value)
            controls[control] = value
        } catch {
            state = .failed("\(error)")
        }
    }
}
