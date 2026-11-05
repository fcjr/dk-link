import Foundation
import DKCore

/// What a session reports as it runs.
public struct DKSessionStatistics: Sendable, Equatable {
    public var capturesPerSecond: Double = 0
    public var droppedCaptures: Int = 0
    public var totalCaptures: UInt64 = 0
    public var imuSamplesPerSecond: Double = 0
    public var sensorTemperatureCelsius: Float = 0
    public init() {}
}

/// Owns the capture thread: opens the device, starts it, and hands every
/// capture to the delegate on the capture thread. IMU samples go to a second
/// thread. Start and stop are safe from any thread.
public final class DKSession: @unchecked Sendable {
    public typealias CaptureHandler = @Sendable (DKCapture) -> Void
    public typealias IMUHandler = @Sendable (IMUSample) -> Void
    public typealias StatisticsHandler = @Sendable (DKSessionStatistics) -> Void
    public typealias ErrorHandler = @Sendable (Error) -> Void

    public let device: DKDevice
    public let configuration: DKConfiguration
    public private(set) var calibration: k4a_calibration_t

    public var onCapture: CaptureHandler?
    public var onIMU: IMUHandler?
    public var onStatistics: StatisticsHandler?
    public var onError: ErrorHandler?

    private let lock = NSLock()
    private var captureThread: Thread?
    private var imuThread: Thread?
    private var stopping = false
    private var statistics = DKSessionStatistics()

    public init(device: DKDevice, configuration: DKConfiguration) throws {
        self.device = device
        self.configuration = configuration
        self.calibration = try device.calibration(for: configuration)
    }

    public func start(imu: Bool) throws {
        lock.lock()
        defer { lock.unlock() }
        guard captureThread == nil else { return }
        stopping = false
        try device.start(configuration)
        if imu {
            try device.startIMU()
            let thread = Thread { [weak self] in self?.runIMU() }
            thread.name = "DKSession.imu"
            thread.qualityOfService = .userInteractive
            imuThread = thread
            thread.start()
        }
        let thread = Thread { [weak self] in self?.runCaptures() }
        thread.name = "DKSession.capture"
        thread.qualityOfService = .userInteractive
        captureThread = thread
        thread.start()
    }

    public func stop() {
        lock.lock()
        stopping = true
        let capture = captureThread
        let imu = imuThread
        captureThread = nil
        imuThread = nil
        lock.unlock()
        // The threads poll with short timeouts and notice `stopping`.
        while let thread = capture, !thread.isFinished { usleep(5000) }
        while let thread = imu, !thread.isFinished { usleep(5000) }
        device.stopIMU()
        device.stop()
    }

    public var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return captureThread != nil
    }

    private func runCaptures() {
        var windowStart = DispatchTime.now().uptimeNanoseconds
        var windowCount = 0
        var consecutiveTimeouts = 0
        while !stopping {
            do {
                guard let capture = try device.capture(timeoutMilliseconds: 250) else {
                    consecutiveTimeouts += 1
                    if consecutiveTimeouts == 12 {
                        onError?(DKError.startFailed("no frames for 3 seconds"))
                    }
                    continue
                }
                consecutiveTimeouts = 0
                windowCount += 1
                statistics.totalCaptures += 1
                statistics.sensorTemperatureCelsius = capture.temperatureCelsius
                onCapture?(capture)
                let now = DispatchTime.now().uptimeNanoseconds
                if now - windowStart >= 1_000_000_000 {
                    statistics.capturesPerSecond = Double(windowCount) * 1e9 / Double(now - windowStart)
                    windowStart = now
                    windowCount = 0
                    onStatistics?(statistics)
                }
            } catch {
                onError?(error)
                usleep(100_000)
            }
        }
    }

    private func runIMU() {
        var windowStart = DispatchTime.now().uptimeNanoseconds
        var windowCount = 0
        while !stopping {
            guard let sample = device.imuSample(timeoutMilliseconds: 50) else { continue }
            windowCount += 1
            onIMU?(sample)
            let now = DispatchTime.now().uptimeNanoseconds
            if now - windowStart >= 1_000_000_000 {
                statistics.imuSamplesPerSecond = Double(windowCount) * 1e9 / Double(now - windowStart)
                windowStart = now
                windowCount = 0
            }
        }
    }
}
