import Foundation
import Vision
import CoreVideo
import simd
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
    /// A stable id that follows the person from frame to frame (matched by
    /// position; kept through short occlusions), used in the OSC addresses.
    public var index: Int
    public var joints: [BodyJoint]
    public var deviceTimestampMicroseconds: UInt64
    /// Colour-pixel bounding box (x, y, width, height) from the person detector.
    public var boundingBox: SIMD4<Float>?
    /// "pose" when joints came from the pose detector, "rect" when only the
    /// person detector saw someone (partly out of frame, blurred): then the
    /// single joint is "center", the box centre lifted with depth.
    public var source: String
}

public final class BodyTracker: @unchecked Sendable {
    public var calibration: k4a_calibration_t
    private let queue = DispatchQueue(label: "kinect.bodytracker", qos: .userInteractive)
    private var busy = false
    private let lock = NSLock()
    public private(set) var lastBodies: [Body] = []
    public private(set) var lastProcessingMilliseconds: Double = 0
    public var onBodies: (@Sendable ([Body]) -> Void)?

    /// Identity across frames: each track remembers where its person was last
    /// seen (colour pixels) and how many frames ago.
    private struct Track { var id: Int; var centre: SIMD2<Float>; var missed: Int }
    private var tracks: [Track] = []
    private var nextID = 1
    /// How far (colour pixels) a person may move between frames and still be the same track.
    public var matchDistance: Float = 220
    /// How many frames a track survives without a detection.
    public var missedFramesAllowed = 15

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
        let people = VNDetectHumanRectanglesRequest()
        people.upperBodyOnly = true
        let handler = VNImageRequestHandler(cvPixelBuffer: buffer, orientation: .up, options: [:])
        do { try handler.perform([request, people]) } catch { return [] }
        let observations = request.results ?? []
        var bodies: [Body] = []
        func pixelBox(_ box: CGRect) -> SIMD4<Float> {
            // Vision's boxes are normalised with a bottom-left origin.
            SIMD4(Float(box.minX) * Float(color.width), Float(1 - box.maxY) * Float(color.height),
                  Float(box.width) * Float(color.width), Float(box.height) * Float(color.height))
        }
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
                // The person box that overlaps this pose, if the detector found one.
                let xs = joints.map { $0.colorPixel.x }, ys = joints.map { $0.colorPixel.y }
                let centre = CGPoint(x: Double(xs.reduce(0, +) / Float(xs.count)) / Double(color.width),
                                     y: 1 - Double(ys.reduce(0, +) / Float(ys.count)) / Double(color.height))
                let box = (people.results ?? []).first { $0.boundingBox.contains(centre) }.map { pixelBox($0.boundingBox) }
                bodies.append(Body(index: index, joints: joints, deviceTimestampMicroseconds: timestamp, boundingBox: box, source: "pose"))
            }
        }
        // People the pose detector could not resolve (partly out of frame, blurred)
        // still count: one body with a centre joint and the box.
        for person in people.results ?? [] where person.confidence > 0.3 {
            let box = person.boundingBox
            let alreadyPosed = bodies.contains { body in
                body.joints.contains { joint in
                    box.contains(CGPoint(x: Double(joint.colorPixel.x) / Double(color.width), y: 1 - Double(joint.colorPixel.y) / Double(color.height)))
                }
            }
            if alreadyPosed { continue }
            let pixel = SIMD2<Float>(Float(box.midX) * Float(color.width), Float(1 - box.midY) * Float(color.height))
            let position = depth.flatMap { lift(pixel: pixel, depth: $0) }
            let joint = BodyJoint(name: "center", confidence: Float(person.confidence), colorPixel: pixel, position: position)
            bodies.append(Body(index: bodies.count, joints: [joint], deviceTimestampMicroseconds: timestamp, boundingBox: pixelBox(box), source: "rect"))
        }
        return assignIDs(bodies)
    }

    /// The centre a body is tracked by: its box centre, else the mean of its joints.
    static func centre(of body: Body) -> SIMD2<Float> {
        if let box = body.boundingBox { return SIMD2(box.x + box.z / 2, box.y + box.w / 2) }
        let sum = body.joints.reduce(SIMD2<Float>(0, 0)) { $0 + $1.colorPixel }
        return sum / Float(max(body.joints.count, 1))
    }

    /// Greedy nearest-neighbour matching of this frame's bodies to live
    /// tracks, closest pairs first; unmatched bodies start new tracks and
    /// unmatched tracks age out.
    private func assignIDs(_ detected: [Body]) -> [Body] {
        lock.lock()
        defer { lock.unlock() }
        var centres = detected.map { BodyTracker.centre(of: $0) }
        var pairs: [(distance: Float, body: Int, track: Int)] = []
        for (b, c) in centres.enumerated() {
            for (t, track) in tracks.enumerated() {
                let d = simd_distance(c, track.centre)
                if d <= matchDistance { pairs.append((d, b, t)) }
            }
        }
        pairs.sort { $0.distance < $1.distance }
        var bodyToTrack = [Int: Int]()
        var usedTracks = Set<Int>()
        for pair in pairs where bodyToTrack[pair.body] == nil && !usedTracks.contains(pair.track) {
            bodyToTrack[pair.body] = pair.track
            usedTracks.insert(pair.track)
        }
        var result = detected
        for b in result.indices {
            if let t = bodyToTrack[b] {
                tracks[t].centre = centres[b]
                tracks[t].missed = 0
                result[b].index = tracks[t].id
            } else {
                let id = nextID
                nextID += 1
                tracks.append(Track(id: id, centre: centres[b], missed: 0))
                result[b].index = id
            }
        }
        let liveCount = tracks.count
        for t in 0..<liveCount where !usedTracks.contains(t) && !result.contains(where: { $0.index == tracks[t].id }) {
            tracks[t].missed += 1
        }
        tracks.removeAll { $0.missed > missedFramesAllowed }
        return result.sorted { $0.index < $1.index }
    }

    /// Test hook for the id assignment.
    public func assignIDsForTesting(_ detected: [Body]) -> [Body] { assignIDs(detected) }

    /// Forgets every track, so ids restart at 1.
    public func resetIDs() {
        lock.lock(); tracks = []; nextID = 1; lock.unlock()
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
    ///   /kinect/body/<i>/bbox       x y w h           (colour pixels, when the person detector saw the body)
    ///   /kinect/body/<i>/source     "pose" | "rect"
    public static func oscBundle(_ bodies: [Body]) -> Data {
        var messages = [OSC.message("/kinect/bodies", [.int(Int32(bodies.count))])]
        for body in bodies {
            messages.append(OSC.message("/kinect/body/\(body.index)/source", [.string(body.source)]))
            if let box = body.boundingBox {
                messages.append(OSC.message("/kinect/body/\(body.index)/bbox", [.float(box.x), .float(box.y), .float(box.z), .float(box.w)]))
            }
            for joint in body.joints {
                let p = joint.position ?? SIMD3<Float>(0, 0, 0)
                messages.append(OSC.message("/kinect/body/\(body.index)/\(joint.name)", [.float(p.x), .float(p.y), .float(p.z), .float(joint.confidence)]))
                messages.append(OSC.message("/kinect/body/\(body.index)/\(joint.name)/pixel", [.float(joint.colorPixel.x), .float(joint.colorPixel.y)]))
            }
        }
        return OSC.bundle(messages)
    }
}
