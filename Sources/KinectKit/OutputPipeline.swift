import Foundation
import Metal
import KinectCore

/// What the pipeline should put out, and how.
public struct OutputSettings: Codable, Equatable, Sendable {
    public var streams: Set<SyphonOutput.Stream> = [.color, .depth]
    public var previewRangeMillimetres: Float = 5000
    public var flipVertically = false
    public var serverNamePrefix = "Kinect"
    public var bodyTracking = false
    public var oscHost = "127.0.0.1"
    public var oscPort: UInt16 = 7000
    public init() {}
}

/// The latest textures for a preview, swapped under a lock.
public final class PreviewFrames: @unchecked Sendable {
    private let lock = NSLock()
    private var textures: [SyphonOutput.Stream: MTLTexture] = [:]
    public init() {}
    public func set(_ texture: MTLTexture, for stream: SyphonOutput.Stream) {
        lock.lock(); textures[stream] = texture; lock.unlock()
    }
    public func texture(for stream: SyphonOutput.Stream) -> MTLTexture? {
        lock.lock(); defer { lock.unlock() }
        return textures[stream]
    }
    public func clear() { lock.lock(); textures = [:]; lock.unlock() }
}

/// Takes captures from a session, builds the textures, publishes them on
/// Syphon and keeps a copy for the preview. Runs on the session's capture
/// thread; one capture at a time.
public final class OutputPipeline: @unchecked Sendable {
    public let textures: FrameTextures
    public let syphon: SyphonOutput
    public let preview = PreviewFrames()
    public var settings: OutputSettings {
        get { lock.lock(); defer { lock.unlock() }; return _settings }
        set { lock.lock(); _settings = newValue; lock.unlock(); syphon.namePrefix = newValue.serverNamePrefix }
    }
    private var _settings = OutputSettings()
    private let lock = NSLock()
    private var transformation: KinectTransformation?
    private var metalTransformation: MetalTransformation?
    private var xyTable: MTLTexture?
    private var framesSinceXYTable = 0
    public private(set) var lastProcessingMilliseconds: Double = 0

    public init?(device: MTLDevice? = MTLCreateSystemDefaultDevice()) {
        guard let device, let textures = FrameTextures(device: device) else { return nil }
        self.textures = textures
        self.syphon = SyphonOutput(device: device)
    }

    public func setCalibration(_ calibration: k4a_calibration_t) {
        let table = textures.xyTableTexture(calibration: calibration, key: "xyTable")
        let gpu = MetalTransformation(device: textures.device, calibration: calibration)
        lock.lock()
        transformation = KinectTransformation(calibration: calibration)
        metalTransformation = gpu
        xyTable = table
        framesSinceXYTable = 0
        lock.unlock()
    }

    public func stop() {
        syphon.stopAll()
        preview.clear()
    }

    public func process(_ capture: KinectCapture) {
        let started = DispatchTime.now().uptimeNanoseconds
        let settings = self.settings
        var packing = FrameTextures.Packing()
        packing.previewRangeMillimetres = settings.previewRangeMillimetres
        guard let commandBuffer = textures.queue.makeCommandBuffer() else { return }
        let wanted = settings.streams
        let flipped = settings.flipVertically

        // Streams that are no longer wanted are torn down so clients see them go.
        for stream in syphon.activeStreams.subtracting(wanted) {
            syphon.stop(stream)
        }

        if let color = capture.color, wanted.contains(.color), let texture = textures.uploadBGRA(color, key: "color") {
            syphon.publish(texture, on: .color, commandBuffer: commandBuffer, flipped: flipped)
            preview.set(texture, for: .color)
        }
        if let depth = capture.depth {
            if let packed = textures.packedDepth(depth, key: "depth", packing: packing, on: commandBuffer) {
                if wanted.contains(.depth) {
                    syphon.publish(packed, on: .depth, commandBuffer: commandBuffer, flipped: flipped)
                }
                preview.set(packed, for: .depth)
            }
            if let colorized = textures.colorizedDepth(depth, key: "depthPreview", range: settings.previewRangeMillimetres, on: commandBuffer) {
                preview.set(colorized, for: .depthPreview)
                if wanted.contains(.depthPreview) {
                    syphon.publish(colorized, on: .depthPreview, commandBuffer: commandBuffer, flipped: flipped)
                }
            }
            lock.lock()
            let transformation = self.transformation
            let gpu = self.metalTransformation
            lock.unlock()
            // The GPU engine when there is one (it is, on every Mac with Metal); the CPU engine otherwise.
            if wanted.contains(.depthInColor) {
                if let gpu, let packed = gpu.packedDepthToColorCamera(depth, previewRangeMillimetres: settings.previewRangeMillimetres) {
                    syphon.publish(packed, on: .depthInColor, commandBuffer: commandBuffer, flipped: flipped)
                } else if let transformation, let aligned = transformation.depthToColorCamera(depth),
                          let packed = textures.packedDepth(aligned, key: "depthInColor", packing: packing, on: commandBuffer) {
                    syphon.publish(packed, on: .depthInColor, commandBuffer: commandBuffer, flipped: flipped)
                }
            }
            if wanted.contains(.colorInDepth), let color = capture.color {
                if let gpu, let texture = gpu.colorToDepthCamera(depth: depth, color: color) {
                    syphon.publish(texture, on: .colorInDepth, commandBuffer: commandBuffer, flipped: flipped)
                } else if let transformation, let aligned = transformation.colorToDepthCamera(depth: depth, color: color),
                          let texture = textures.uploadBGRA(aligned, key: "colorInDepth") {
                    syphon.publish(texture, on: .colorInDepth, commandBuffer: commandBuffer, flipped: flipped)
                }
            }
        }
        // The XY table is static: once a second is plenty for a client that
        // joined late, and the first frame gets it straight away.
        lock.lock()
        let table = xyTable
        let dueXY = framesSinceXYTable % 30 == 0
        framesSinceXYTable += 1
        lock.unlock()
        if wanted.contains(.xyTable), dueXY, let table {
            syphon.publish(table, on: .xyTable, commandBuffer: commandBuffer, flipped: flipped)
        }
        // IR is always packed for the preview; it is cheap, and a pane that
        // only lit up when its Syphon output was ticked was confusing.
        if let ir = capture.ir, let packed = textures.packedIR(ir, key: "ir", on: commandBuffer) {
            if wanted.contains(.ir) {
                syphon.publish(packed, on: .ir, commandBuffer: commandBuffer, flipped: flipped)
            }
            preview.set(packed, for: .ir)
        }
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        lastProcessingMilliseconds = Double(DispatchTime.now().uptimeNanoseconds - started) / 1e6
    }
}
