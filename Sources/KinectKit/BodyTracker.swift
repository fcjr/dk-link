import Foundation
import Vision
import CoreVideo
import KinectCore

/// Body tracking the Mac way: Apple's Vision framework finds 2D body joints
/// in the colour image; each joint is then lifted to a 3D point in the depth
/// camera's frame by looking up the depth behind it through the calibration.
/// Joints are named after Microsoft's k4abt where there is a counterpart.
public struct BodyJoint: Sendable, Equatable {
    public var name: String
    public var confidence: Float       // Vision's confidence, 0..1
    public var colorPixel: SIMD2<Float> // in the colour image
    public var position: SIMD3<Float>?  // mm, depth camera frame; nil when no depth behind the joint
}

public struct Body: Sendable, Equatable {
    public var index: Int
    public var joints: [BodyJoint]
    public var deviceTimestampMicroseconds: UInt64
}

public final class BodyTracker: @unchecked Sendable {
    public var calibration: k4a_calibration_t
    private let queue = DispatchQueue(label: "kinect.bodytracker", qos: .userInteractive)
    private var busy = false
    private let lock = NSLock()
    public private(set) var lastBodies: [Body] = []
    public private(set) var lastProcessingMilliseconds: Double = 0
    public var onBodies: (@Sendable ([Body]) -> Void)?

    /// Vision joint names mapped to k4abt-style names.
    static let jointNames: [(VNHumanBodyPoseObservation.JointName, String)] = [
        (.nose, "nose"), (.leftEye, "eye_left"), (.rightEye, "eye_right"), (.leftEar, "ear_left"), (.rightEar, "ear_right"),
        (.neck, "neck"), (.leftShoulder, "shoulder_left"), (.rightShoulder, "shoulder_right"),
        (.leftElbow, "elbow_left"), (.rightElbow, "elbow_right"), (.leftWrist, "wrist_left"), (.rightWrist, "wrist_right"),
        (.root, "pelvis"), (.leftHip, "hip_left"), (.rightHip, "hip_right"),
        (.leftKnee, "knee_left"), (.rightKnee, "knee_right"), (.leftAnkle, "ankle_left"), (.rightAnkle, "ankle_right"),
    ]

    public init(calibration: k4a_calibration_t) {
        self.calibration = calibration
    }

    /// Hands a capture to the tracker; a capture that arrives while the last
    /// one is still being analysed is skipped, so this never falls behind.
    public func submit(_ capture: KinectCapture) {
        guard let color = capture.color, color.format == .bgra32 else { return }
        lock.lock()
        if busy { lock.unlock(); return }
        busy = true
        lock.unlock()
        queue.async { [self] in
            defer { lock.lock(); busy = false; lock.unlock() }
            let started = DispatchTime.now().uptimeNanoseconds
            let bodies = track(color: color, depth: capture.depth, timestamp: capture.deviceTimestampMicroseconds)
            lock.lock()
            lastBodies = bodies
            lastProcessingMilliseconds = Double(DispatchTime.now().uptimeNanoseconds - started) / 1e6
            lock.unlock()
            onBodies?(bodies)
        }
    }

    /// Synchronous tracking of one frame; used by `submit` and by tests.
    public func track(color: KinectImage, depth: KinectImage?, timestamp: UInt64) -> [Body] {
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreateWithBytes(nil, color.width, color.height, kCVPixelFormatType_32BGRA,
                                                  color.bytes.baseAddress!, color.strideBytes, nil, nil, nil, &pixelBuffer)
        guard status == kCVReturnSuccess, let buffer = pixelBuffer else { return [] }
        let request = VNDetectHumanBodyPoseRequest()
        let handler = VNImageRequestHandler(cvPixelBuffer: buffer, orientation: .up, options: [:])
        do { try handler.perform([request]) } catch { return [] }
        guard let observations = request.results else { return [] }
        var bodies: [Body] = []
        for (index, observation) in observations.enumerated() {
            guard let points = try? observation.recognizedPoints(.all) else { continue }
            var joints: [BodyJoint] = []
            for (visionName, name) in BodyTracker.jointNames {
                guard let point = points[visionName], point.confidence > 0.1 else { continue }
                // Vision's origin is bottom-left, normalised.
                let pixel = SIMD2<Float>(Float(point.location.x) * Float(color.width),
                                         Float(1 - point.location.y) * Float(color.height))
                let position = depth.flatMap { lift(pixel: pixel, depth: $0) }
                joints.append(BodyJoint(name: name, confidence: Float(point.confidence), colorPixel: pixel, position: position))
            }
            if !joints.isEmpty {
                bodies.append(Body(index: index, joints: joints, deviceTimestampMicroseconds: timestamp))
            }
        }
        return bodies
    }

    /// A colour pixel to a 3D point: find the depth pixel it sees (along the
    /// epipolar line, through the calibration), take a robust depth from its
    /// neighbourhood, and unproject.
    func lift(pixel: SIMD2<Float>, depth: KinectImage) -> SIMD3<Float>? {
        var source = k4a_float2_t(xy: .init(x: pixel.x, y: pixel.y))
        var target = k4a_float2_t()
        var valid: Int32 = 0
        var calibration = self.calibration
        guard k4a_calibration_color_2d_to_depth_2d(&calibration, &source, depth.handle, &target, &valid) == K4A_RESULT_SUCCEEDED,
              valid == 1 else { return nil }
        let x = Int(target.xy.x.rounded()), y = Int(target.xy.y.rounded())
        guard x >= 0, y >= 0, x < depth.width, y < depth.height else { return nil }
        var samples: [UInt16] = []
        depth.withUInt16 { values in
            for dy in -2...2 { for dx in -2...2 {
                let sx = x + dx, sy = y + dy
                guard sx >= 0, sy >= 0, sx < depth.width, sy < depth.height else { continue }
                let v = values[sy * depth.width + sx]
                if v != 0 { samples.append(v) }
            } }
        }
        guard samples.count >= 3 else { return nil }
        samples.sort()
        let z = Float(samples[samples.count / 2])
        var point2d = k4a_float2_t(xy: .init(x: Float(x), y: Float(y)))
        var point3d = k4a_float3_t()
        guard k4a_calibration_2d_to_3d(&calibration, &point2d, z, K4A_CALIBRATION_TYPE_DEPTH, K4A_CALIBRATION_TYPE_DEPTH, &point3d, &valid) == K4A_RESULT_SUCCEEDED,
              valid == 1 else { return nil }
        return SIMD3(point3d.xyz.x, point3d.xyz.y, point3d.xyz.z)
    }

    /// The OSC form: one bundle per frame.
    ///   /kinect/bodies            count
    ///   /kinect/body/<i>/<joint>  x y z confidence   (mm, depth camera frame; z = 0 when unknown)
    ///   /kinect/body/<i>/<joint>/pixel  u v         (colour pixels)
    public static func oscBundle(_ bodies: [Body]) -> Data {
        var messages = [OSC.message("/kinect/bodies", [.int(Int32(bodies.count))])]
        for body in bodies {
            for joint in body.joints {
                let p = joint.position ?? SIMD3<Float>(0, 0, 0)
                messages.append(OSC.message("/kinect/body/\(body.index)/\(joint.name)", [.float(p.x), .float(p.y), .float(p.z), .float(joint.confidence)]))
                messages.append(OSC.message("/kinect/body/\(body.index)/\(joint.name)/pixel", [.float(joint.colorPixel.x), .float(joint.colorPixel.y)]))
            }
        }
        return OSC.bundle(messages)
    }
}
