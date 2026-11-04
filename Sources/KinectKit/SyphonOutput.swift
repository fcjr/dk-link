import Foundation
import Metal
import Syphon

/// One named Syphon server per stream, created on demand and torn down when
/// the stream is switched off.
public final class SyphonOutput: @unchecked Sendable {
    public enum Stream: String, CaseIterable, Codable, Identifiable, Sendable {
        case color = "Color"
        case depth = "Depth"
        case ir = "IR"
        case depthInColor = "Depth (color aligned)"
        case colorInDepth = "Color (depth aligned)"
        case depthPreview = "Depth (colorized)"
        case xyTable = "XY Table"
        public var id: String { rawValue }
    }

    public let device: MTLDevice
    public var namePrefix: String
    private var servers: [Stream: SyphonMetalServer] = [:]
    private let lock = NSLock()

    public init(device: MTLDevice, namePrefix: String = "Kinect") {
        self.device = device
        self.namePrefix = namePrefix
    }

    deinit { stopAll() }

    public func server(for stream: Stream) -> SyphonMetalServer? {
        lock.lock()
        defer { lock.unlock() }
        if let existing = servers[stream] { return existing }
        guard let server = SyphonMetalServer(name: "\(namePrefix) \(stream.rawValue)", device: device, options: nil) else { return nil }
        servers[stream] = server
        return server
    }

    public func stop(_ stream: Stream) {
        lock.lock()
        let server = servers.removeValue(forKey: stream)
        lock.unlock()
        server?.stop()
    }

    public func stopAll() {
        lock.lock()
        let all = servers
        servers = [:]
        lock.unlock()
        all.values.forEach { $0.stop() }
    }

    public var activeStreams: Set<Stream> {
        lock.lock()
        defer { lock.unlock() }
        return Set(servers.keys)
    }

    public func hasClients(_ stream: Stream) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return servers[stream]?.hasClients ?? false
    }

    /// Publishes a texture on the stream's server, encoding the copy on the
    /// given command buffer. The caller commits the buffer.
    public func publish(_ texture: MTLTexture, on stream: Stream, commandBuffer: MTLCommandBuffer, flipped: Bool) {
        guard let server = server(for: stream) else { return }
        server.publishFrameTexture(texture, on: commandBuffer,
                                   imageRegion: NSRect(x: 0, y: 0, width: texture.width, height: texture.height),
                                   flipped: flipped)
    }
}
