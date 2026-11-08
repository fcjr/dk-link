import Foundation
import DKCore

public enum DKError: Error, CustomStringConvertible {
    case noDevice
    case openFailed(index: Int)
    case slowLink
    case startFailed(String)
    case captureFailed
    case imuFailed
    case calibrationUnavailable
    case controlFailed(String)

    public var description: String {
        switch self {
        case .noDevice: return "No Azure Kinect is connected"
        case .openFailed(let index): return "Azure Kinect #\(index) could not be opened (is another app using it?)"
        case .slowLink: return "The Azure Kinect is connected over USB 2. It needs a USB 3 cable and port, plugged straight into the Mac, with its power supply connected."
        case .startFailed(let why): return "The cameras would not start: \(why)"
        case .captureFailed: return "Reading a capture failed"
        case .imuFailed: return "The IMU would not start"
        case .calibrationUnavailable: return "The device's calibration could not be read"
        case .controlFailed(let what): return "Colour control \(what) failed"
        }
    }
}

public enum DepthMode: String, CaseIterable, Codable, Identifiable, Sendable {
    case off
    case nfovBinned = "NFOV 2x2 binned (320x288)"
    case nfovUnbinned = "NFOV unbinned (640x576)"
    case wfovBinned = "WFOV 2x2 binned (512x512)"
    case wfovUnbinned = "WFOV unbinned (1024x1024)"
    case passiveIR = "Passive IR (1024x1024)"

    public var id: String { rawValue }

    public var k4a: k4a_depth_mode_t {
        switch self {
        case .off: return K4A_DEPTH_MODE_OFF
        case .nfovBinned: return K4A_DEPTH_MODE_NFOV_2X2BINNED
        case .nfovUnbinned: return K4A_DEPTH_MODE_NFOV_UNBINNED
        case .wfovBinned: return K4A_DEPTH_MODE_WFOV_2X2BINNED
        case .wfovUnbinned: return K4A_DEPTH_MODE_WFOV_UNBINNED
        case .passiveIR: return K4A_DEPTH_MODE_PASSIVE_IR
        }
    }

    public var size: (width: Int, height: Int) {
        switch self {
        case .off: return (0, 0)
        case .nfovBinned: return (320, 288)
        case .nfovUnbinned: return (640, 576)
        case .wfovBinned: return (512, 512)
        case .wfovUnbinned: return (1024, 1024)
        case .passiveIR: return (1024, 1024)
        }
    }

    public var hasDepth: Bool { self != .off && self != .passiveIR }

    /// What a user picks by: the view, then the pixels.
    public var label: String {
        switch self {
        case .off: return "Off"
        case .nfovUnbinned: return "Narrow view, 640×576"
        case .nfovBinned: return "Narrow view, long range, 320×288"
        case .wfovBinned: return "Wide view, 512×512"
        case .wfovUnbinned: return "Wide view, detailed, 1024×1024"
        case .passiveIR: return "Infrared only, 1024×1024"
        }
    }

    /// The reliable working distance, as Microsoft specifies it.
    public var rangeMetres: ClosedRange<Double>? {
        switch self {
        case .nfovUnbinned: return 0.5...3.9
        case .nfovBinned: return 0.5...5.5
        case .wfovBinned: return 0.25...2.9
        case .wfovUnbinned: return 0.25...2.2
        case .off, .passiveIR: return nil
        }
    }

    /// One line on what the mode is for.
    public var detail: String {
        switch self {
        case .off: return "No depth or infrared; the colour camera only."
        case .nfovUnbinned: return "The default. 75° wide, most detail, for a room-sized scene. NFOV unbinned."
        case .nfovBinned: return "Reaches further with less noise, at a quarter of the pixels. NFOV 2x2 binned."
        case .wfovBinned: return "120° wide for close scenes: tables, installations, near interaction. WFOV 2x2 binned."
        case .wfovUnbinned: return "120° wide and detailed, at half the frame rate. WFOV unbinned."
        case .passiveIR: return "An infrared picture with no distances in it."
        }
    }

    /// The fastest rate the sensor takes in this mode.
    public var maximumFrameRate: FrameRate {
        switch self {
        case .wfovUnbinned: return .fps15
        default: return .fps30
        }
    }
}

public enum FrameRate: Int, CaseIterable, Codable, Identifiable, Sendable {
    case fps5 = 5
    case fps15 = 15
    case fps30 = 30
    public var id: Int { rawValue }
    public var k4a: k4a_fps_t {
        switch self {
        case .fps5: return K4A_FRAMES_PER_SECOND_5
        case .fps15: return K4A_FRAMES_PER_SECOND_15
        case .fps30: return K4A_FRAMES_PER_SECOND_30
        }
    }
}

public enum ColorResolution: String, CaseIterable, Codable, Identifiable, Sendable {
    case off
    case p720 = "720p (1280x720)"
    case p1080 = "1080p (1920x1080)"
    case p1440 = "1440p (2560x1440)"
    case p1536 = "1536p (2048x1536)"
    case p2160 = "2160p (3840x2160)"
    case p3072 = "3072p (4096x3072)"
    public var id: String { rawValue }
    public var k4a: k4a_color_resolution_t {
        switch self {
        case .off: return K4A_COLOR_RESOLUTION_OFF
        case .p720: return K4A_COLOR_RESOLUTION_720P
        case .p1080: return K4A_COLOR_RESOLUTION_1080P
        case .p1440: return K4A_COLOR_RESOLUTION_1440P
        case .p1536: return K4A_COLOR_RESOLUTION_1536P
        case .p2160: return K4A_COLOR_RESOLUTION_2160P
        case .p3072: return K4A_COLOR_RESOLUTION_3072P
        }
    }
    public var size: (width: Int, height: Int) {
        switch self {
        case .off: return (0, 0)
        case .p720: return (1280, 720)
        case .p1080: return (1920, 1080)
        case .p1440: return (2560, 1440)
        case .p1536: return (2048, 1536)
        case .p2160: return (3840, 2160)
        case .p3072: return (4096, 3072)
        }
    }
    /// 3072p runs at 15 fps at most.
    public var maximumFrameRate: FrameRate { self == .p3072 ? .fps15 : .fps30 }
}

public enum ColorFormat: String, CaseIterable, Codable, Sendable {
    case bgra32, nv12, yuy2, mjpg
    public var k4a: k4a_image_format_t {
        switch self {
        case .bgra32: return K4A_IMAGE_FORMAT_COLOR_BGRA32
        case .nv12: return K4A_IMAGE_FORMAT_COLOR_NV12
        case .yuy2: return K4A_IMAGE_FORMAT_COLOR_YUY2
        case .mjpg: return K4A_IMAGE_FORMAT_COLOR_MJPG
        }
    }
}

public struct DKConfiguration: Codable, Equatable, Sendable {
    public var depthMode: DepthMode = .nfovUnbinned
    public var colorResolution: ColorResolution = .p720
    public var colorFormat: ColorFormat = .bgra32
    public var frameRate: FrameRate = .fps30
    public var synchronizedImagesOnly = false

    public init() {}

    public init(depthMode: DepthMode, colorResolution: ColorResolution, frameRate: FrameRate, colorFormat: ColorFormat = .bgra32) {
        self.depthMode = depthMode
        self.colorResolution = colorResolution
        self.frameRate = frameRate
        self.colorFormat = colorFormat
    }

    /// The rate both cameras can run at together.
    public var effectiveFrameRate: FrameRate {
        var rate = frameRate
        if rate.rawValue > depthMode.maximumFrameRate.rawValue { rate = depthMode.maximumFrameRate }
        if colorResolution != .off, rate.rawValue > colorResolution.maximumFrameRate.rawValue { rate = colorResolution.maximumFrameRate }
        return rate
    }

    var k4a: k4a_device_configuration_t {
        var config = K4A_DEVICE_CONFIG_INIT_DISABLE_ALL
        config.depth_mode = depthMode.k4a
        config.color_resolution = colorResolution.k4a
        config.color_format = colorFormat.k4a
        config.camera_fps = effectiveFrameRate.k4a
        config.synchronized_images_only = synchronizedImagesOnly
        return config
    }
}

public enum ImageFormat: Sendable {
    case depth16, ir16, bgra32, nv12, yuy2, mjpg, custom16, custom8, custom
    init(_ format: k4a_image_format_t) {
        switch format {
        case K4A_IMAGE_FORMAT_DEPTH16: self = .depth16
        case K4A_IMAGE_FORMAT_IR16: self = .ir16
        case K4A_IMAGE_FORMAT_COLOR_BGRA32: self = .bgra32
        case K4A_IMAGE_FORMAT_COLOR_NV12: self = .nv12
        case K4A_IMAGE_FORMAT_COLOR_YUY2: self = .yuy2
        case K4A_IMAGE_FORMAT_COLOR_MJPG: self = .mjpg
        case K4A_IMAGE_FORMAT_CUSTOM16: self = .custom16
        case K4A_IMAGE_FORMAT_CUSTOM8: self = .custom8
        default: self = .custom
        }
    }
}

/// A reference-counted view of a k4a image. Holding it keeps the buffer alive.
public final class DKImage: @unchecked Sendable {
    public let handle: k4a_image_t
    public let width: Int
    public let height: Int
    public let strideBytes: Int
    public let byteCount: Int
    public let format: ImageFormat
    public let deviceTimestampMicroseconds: UInt64
    public let systemTimestampNanoseconds: UInt64

    /// Takes a reference; the caller keeps its own.
    public init(retaining handle: k4a_image_t) {
        k4a_image_reference(handle)
        self.handle = handle
        width = Int(k4a_image_get_width_pixels(handle))
        height = Int(k4a_image_get_height_pixels(handle))
        strideBytes = Int(k4a_image_get_stride_bytes(handle))
        byteCount = k4a_image_get_size(handle)
        format = ImageFormat(k4a_image_get_format(handle))
        deviceTimestampMicroseconds = k4a_image_get_device_timestamp_usec(handle)
        systemTimestampNanoseconds = k4a_image_get_system_timestamp_nsec(handle)
    }

    /// Takes ownership of a reference the caller already holds.
    public convenience init(owning handle: k4a_image_t) {
        self.init(retaining: handle)
        k4a_image_release(handle)
    }

    public static func allocate(format: k4a_image_format_t, width: Int, height: Int, strideBytes: Int) -> DKImage? {
        var handle: k4a_image_t? = nil
        guard k4a_image_create(format, Int32(width), Int32(height), Int32(strideBytes), &handle) == K4A_RESULT_SUCCEEDED,
              let h = handle else { return nil }
        return DKImage(owning: h)
    }

    deinit { k4a_image_release(handle) }

    public var bytes: UnsafeMutableRawBufferPointer {
        UnsafeMutableRawBufferPointer(start: k4a_image_get_buffer(handle), count: byteCount)
    }

    public func withUInt16<T>(_ body: (UnsafeBufferPointer<UInt16>) throws -> T) rethrows -> T {
        let pointer = k4a_image_get_buffer(handle)!.withMemoryRebound(to: UInt16.self, capacity: byteCount / 2) { $0 }
        return try body(UnsafeBufferPointer(start: pointer, count: byteCount / 2))
    }

    public var data: Data { Data(bytes: k4a_image_get_buffer(handle), count: byteCount) }
}

/// One capture: whichever of depth, IR and colour arrived together.
public final class DKCapture: @unchecked Sendable {
    public let depth: DKImage?
    public let ir: DKImage?
    public let color: DKImage?
    public let temperatureCelsius: Float
    public let sequence: UInt64

    init(handle: k4a_capture_t, sequence: UInt64) {
        if let image = k4a_capture_get_depth_image(handle) { depth = DKImage(owning: image) } else { depth = nil }
        if let image = k4a_capture_get_ir_image(handle) { ir = DKImage(owning: image) } else { ir = nil }
        if let image = k4a_capture_get_color_image(handle) { color = DKImage(owning: image) } else { color = nil }
        temperatureCelsius = k4a_capture_get_temperature_c(handle)
        self.sequence = sequence
    }

    /// The depth frame's device time, else the colour frame's.
    public var deviceTimestampMicroseconds: UInt64 {
        depth?.deviceTimestampMicroseconds ?? ir?.deviceTimestampMicroseconds ?? color?.deviceTimestampMicroseconds ?? 0
    }
}

public struct IMUSample: Sendable, Equatable {
    public var temperatureCelsius: Float
    public var acceleration: SIMD3<Float>      // m/s^2
    public var accelerationTimestampMicroseconds: UInt64
    public var rotationRate: SIMD3<Float>      // rad/s
    public var rotationTimestampMicroseconds: UInt64

    init(_ sample: k4a_imu_sample_t) {
        temperatureCelsius = sample.temperature
        acceleration = SIMD3(sample.acc_sample.xyz.x, sample.acc_sample.xyz.y, sample.acc_sample.xyz.z)
        accelerationTimestampMicroseconds = sample.acc_timestamp_usec
        rotationRate = SIMD3(sample.gyro_sample.xyz.x, sample.gyro_sample.xyz.y, sample.gyro_sample.xyz.z)
        rotationTimestampMicroseconds = sample.gyro_timestamp_usec
    }
}

public enum ColorControl: String, CaseIterable, Codable, Identifiable, Sendable {
    case exposure, autoExposurePriority, brightness, contrast, saturation, sharpness, whiteBalance, backlightCompensation, gain, powerlineFrequency
    public var id: String { rawValue }
    public var k4a: k4a_color_control_command_t {
        switch self {
        case .exposure: return K4A_COLOR_CONTROL_EXPOSURE_TIME_ABSOLUTE
        case .autoExposurePriority: return K4A_COLOR_CONTROL_AUTO_EXPOSURE_PRIORITY
        case .brightness: return K4A_COLOR_CONTROL_BRIGHTNESS
        case .contrast: return K4A_COLOR_CONTROL_CONTRAST
        case .saturation: return K4A_COLOR_CONTROL_SATURATION
        case .sharpness: return K4A_COLOR_CONTROL_SHARPNESS
        case .whiteBalance: return K4A_COLOR_CONTROL_WHITEBALANCE
        case .backlightCompensation: return K4A_COLOR_CONTROL_BACKLIGHT_COMPENSATION
        case .gain: return K4A_COLOR_CONTROL_GAIN
        case .powerlineFrequency: return K4A_COLOR_CONTROL_POWERLINE_FREQUENCY
        }
    }
    public var label: String {
        switch self {
        case .exposure: return "Exposure (µs)"
        case .autoExposurePriority: return "Auto exposure priority"
        case .brightness: return "Brightness"
        case .contrast: return "Contrast"
        case .saturation: return "Saturation"
        case .sharpness: return "Sharpness"
        case .whiteBalance: return "White balance (K)"
        case .backlightCompensation: return "Backlight compensation"
        case .gain: return "Gain"
        case .powerlineFrequency: return "Powerline frequency"
        }
    }
}

public struct ColorControlCapabilities: Sendable, Equatable {
    public var supportsAuto: Bool
    public var minimum: Int32
    public var maximum: Int32
    public var step: Int32
    public var defaultValue: Int32
    public var defaultIsAuto: Bool
}

public struct ColorControlValue: Sendable, Equatable {
    public var isAuto: Bool
    public var value: Int32
    public init(isAuto: Bool, value: Int32) {
        self.isAuto = isAuto
        self.value = value
    }
}

public struct FirmwareVersion: Sendable, Equatable, CustomStringConvertible {
    public var rgb: String
    public var depth: String
    public var audio: String
    public var depthSensor: String
    public var description: String { "rgb \(rgb), depth \(depth), audio \(audio), sensor \(depthSensor)" }
}
