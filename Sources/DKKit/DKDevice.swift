import Foundation
import DKCore

/// One Azure Kinect, open. Every call goes to the C core; this class owns the
/// handle and makes the results Swift-shaped. Not thread-safe by itself: the
/// streaming is done by `DKSession`, which serialises access.
public final class DKDevice: @unchecked Sendable {
    public let handle: k4a_device_t
    public let index: Int
    public let serialNumber: String
    private var running = false
    private var imuRunning = false
    private var sequence: UInt64 = 0

    public static var installedCount: Int { Int(k4a_device_get_installed_count()) }

    public init(index: Int = 0) throws {
        var handle: k4a_device_t? = nil
        guard k4a_device_open(UInt32(index), &handle) == K4A_RESULT_SUCCEEDED, let h = handle else {
            throw DKDevice.installedCount == 0 ? DKError.noDevice : DKError.openFailed(index: index)
        }
        self.handle = h
        self.index = index
        var size = 0
        _ = k4a_device_get_serialnum(h, nil, &size)
        var serial = [CChar](repeating: 0, count: max(size, 1) + 1)
        _ = k4a_device_get_serialnum(h, &serial, &size)
        serialNumber = String(cString: serial)
    }

    deinit {
        stopIMU()
        stop()
        k4a_device_close(handle)
    }

    public var firmwareVersion: FirmwareVersion? {
        var version = k4a_hardware_version_t()
        guard k4a_device_get_version(handle, &version) == K4A_RESULT_SUCCEEDED else { return nil }
        func text(_ v: k4a_version_t) -> String { "\(v.major).\(v.minor).\(v.iteration)" }
        return FirmwareVersion(rgb: text(version.rgb), depth: text(version.depth), audio: text(version.audio),
                               depthSensor: "\(version.depth_sensor.major).\(version.depth_sensor.minor)")
    }

    public var syncJacks: (input: Bool, output: Bool) {
        var input = false, output = false
        _ = k4a_device_get_sync_jack(handle, &input, &output)
        return (input, output)
    }

    /// The device's own calibration document (JSON text).
    public var rawCalibration: Data? {
        var size = 0
        _ = k4a_device_get_raw_calibration(handle, nil, &size)
        var raw = [UInt8](repeating: 0, count: size)
        guard k4a_device_get_raw_calibration(handle, &raw, &size) == K4A_BUFFER_RESULT_SUCCEEDED else { return nil }
        return Data(raw.prefix(while: { $0 != 0 }))
    }

    public func calibration(for configuration: DKConfiguration) throws -> k4a_calibration_t {
        var calibration = k4a_calibration_t()
        guard k4a_device_get_calibration(handle, configuration.depthMode.k4a, configuration.colorResolution.k4a, &calibration) == K4A_RESULT_SUCCEEDED else {
            throw DKError.calibrationUnavailable
        }
        return calibration
    }

    public func start(_ configuration: DKConfiguration) throws {
        guard !running else { return }
        var config = configuration.k4a
        guard k4a_device_start_cameras(handle, &config) == K4A_RESULT_SUCCEEDED else {
            throw DKError.startFailed("depth \(configuration.depthMode.rawValue), colour \(configuration.colorResolution.rawValue) at \(configuration.effectiveFrameRate.rawValue) fps")
        }
        running = true
    }

    public func stop() {
        guard running else { return }
        k4a_device_stop_cameras(handle)
        running = false
    }

    public var isRunning: Bool { running }

    /// The next capture, or nil when none arrived within the timeout.
    public func capture(timeoutMilliseconds: Int32 = 1000) throws -> DKCapture? {
        var capture: k4a_capture_t? = nil
        switch k4a_device_get_capture(handle, &capture, timeoutMilliseconds) {
        case K4A_WAIT_RESULT_SUCCEEDED:
            guard let c = capture else { return nil }
            defer { k4a_capture_release(c) }
            sequence += 1
            return DKCapture(handle: c, sequence: sequence)
        case K4A_WAIT_RESULT_TIMEOUT:
            return nil
        default:
            throw DKError.captureFailed
        }
    }

    /// The raw sensor frame behind the last capture (for recording).
    public var lastRawFrame: Data? {
        var size = 0
        guard let raw = openk4a_device_last_raw(handle, &size), size > 0 else { return nil }
        return Data(bytes: raw, count: size)
    }

    public func startIMU() throws {
        guard !imuRunning else { return }
        guard k4a_device_start_imu(handle) == K4A_RESULT_SUCCEEDED else { throw DKError.imuFailed }
        imuRunning = true
    }

    public func stopIMU() {
        guard imuRunning else { return }
        k4a_device_stop_imu(handle)
        imuRunning = false
    }

    public func imuSample(timeoutMilliseconds: Int32 = 100) -> IMUSample? {
        var sample = k4a_imu_sample_t()
        guard k4a_device_get_imu_sample(handle, &sample, timeoutMilliseconds) == K4A_WAIT_RESULT_SUCCEEDED else { return nil }
        return IMUSample(sample)
    }

    public func capabilities(of control: ColorControl) -> ColorControlCapabilities? {
        var supportsAuto = false
        var minimum: Int32 = 0, maximum: Int32 = 0, step: Int32 = 0, defaultValue: Int32 = 0
        var defaultMode = K4A_COLOR_CONTROL_MODE_MANUAL
        guard k4a_device_get_color_control_capabilities(handle, control.k4a, &supportsAuto, &minimum, &maximum, &step, &defaultValue, &defaultMode) == K4A_RESULT_SUCCEEDED else { return nil }
        return ColorControlCapabilities(supportsAuto: supportsAuto, minimum: minimum, maximum: maximum, step: step,
                                        defaultValue: defaultValue, defaultIsAuto: defaultMode == K4A_COLOR_CONTROL_MODE_AUTO)
    }

    public func value(of control: ColorControl) -> ColorControlValue? {
        var mode = K4A_COLOR_CONTROL_MODE_MANUAL
        var value: Int32 = 0
        guard k4a_device_get_color_control(handle, control.k4a, &mode, &value) == K4A_RESULT_SUCCEEDED else { return nil }
        return ColorControlValue(isAuto: mode == K4A_COLOR_CONTROL_MODE_AUTO, value: value)
    }

    public func set(_ control: ColorControl, _ value: ColorControlValue) throws {
        let mode = value.isAuto ? K4A_COLOR_CONTROL_MODE_AUTO : K4A_COLOR_CONTROL_MODE_MANUAL
        guard k4a_device_set_color_control(handle, control.k4a, mode, value.value) == K4A_RESULT_SUCCEEDED else {
            throw DKError.controlFailed(control.rawValue)
        }
    }
}

/// The transformation engine for one calibration: point clouds and the two
/// registrations, on the CPU, through the core.
public final class DKTransformation: @unchecked Sendable {
    public let calibration: k4a_calibration_t
    private let handle: k4a_transformation_t

    public init?(calibration: k4a_calibration_t) {
        var copy = calibration
        guard let handle = k4a_transformation_create(&copy) else { return nil }
        self.calibration = calibration
        self.handle = handle
    }

    deinit { k4a_transformation_destroy(handle) }

    /// XYZ in millimetres, three int16 per pixel, in the geometry of the camera the depth image is in.
    public func pointCloud(from depth: DKImage, camera: k4a_calibration_type_t = K4A_CALIBRATION_TYPE_DEPTH) -> DKImage? {
        guard let xyz = DKImage.allocate(format: K4A_IMAGE_FORMAT_CUSTOM, width: depth.width, height: depth.height, strideBytes: depth.width * 6) else { return nil }
        guard k4a_transformation_depth_image_to_point_cloud(handle, depth.handle, camera, xyz.handle) == K4A_RESULT_SUCCEEDED else { return nil }
        return xyz
    }

    /// The depth image resampled into the colour camera's geometry.
    public func depthToColorCamera(_ depth: DKImage) -> DKImage? {
        let width = Int(calibration.color_camera_calibration.resolution_width)
        let height = Int(calibration.color_camera_calibration.resolution_height)
        guard let out = DKImage.allocate(format: K4A_IMAGE_FORMAT_DEPTH16, width: width, height: height, strideBytes: width * 2) else { return nil }
        guard k4a_transformation_depth_image_to_color_camera(handle, depth.handle, out.handle) == K4A_RESULT_SUCCEEDED else { return nil }
        return out
    }

    /// The colour image resampled into the depth camera's geometry (BGRA).
    public func colorToDepthCamera(depth: DKImage, color: DKImage) -> DKImage? {
        guard let out = DKImage.allocate(format: K4A_IMAGE_FORMAT_COLOR_BGRA32, width: depth.width, height: depth.height, strideBytes: depth.width * 4) else { return nil }
        guard k4a_transformation_color_image_to_depth_camera(handle, depth.handle, color.handle, out.handle) == K4A_RESULT_SUCCEEDED else { return nil }
        return out
    }
}
