import Foundation
import Darwin

/// Connects to the Kinect for Mac app's frame server over the Unix-domain
/// socket and delivers images, bodies, stats and status as they arrive. Used
/// by the TouchDesigner library's client mode and by the tests.
public final class FrameClient: @unchecked Sendable {
    public var onImage: (@Sendable (FrameImage) -> Void)?
    public var onBodies: (@Sendable ([FrameBody]) -> Void)?
    public var onStatus: (@Sendable (String) -> Void)?
    public var onStats: (@Sendable ([Double]) -> Void)?
    public var onDisconnect: (@Sendable () -> Void)?

    private let path: String
    private var fd: Int32 = -1
    private let lock = NSLock()
    private var open = false
    public private(set) var serial = ""

    public init(path: String = FrameProtocol.socketPath()) { self.path = path }
    deinit { close() }

    public var isConnected: Bool { lock.lock(); defer { lock.unlock() }; return open }

    /// Connects and completes the hello handshake. Returns false when the app
    /// is not running (no socket) or does not answer.
    public func connect(timeoutMs: Int = 500) -> Bool {
        guard FileManager.default.fileExists(atPath: path) else { return false }
        let s = socket(AF_UNIX, SOCK_STREAM, 0)
        guard s >= 0 else { return false }
        var tv = timeval(tv_sec: timeoutMs / 1000, tv_usec: Int32((timeoutMs % 1000) * 1000))
        setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var addr = UnixSocket.address(path)
        let ok = withUnsafePointer(to: &addr) { p in p.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(s, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        guard ok == 0 else { Darwin.close(s); return false }
        let hello = ByteWriter.message(FrameProtocol.ClientMessage.hello.rawValue) { $0.u32(FrameProtocol.magic); $0.u16(FrameProtocol.version) }
        guard UnixSocket.writeFully(s, hello), let (type, payload) = UnixSocket.readMessage(s), type == FrameProtocol.ServerMessage.hello.rawValue else { Darwin.close(s); return false }
        var r = ByteReader(payload)
        guard r.u32() == FrameProtocol.magic, let _ = r.u16() else { Darwin.close(s); return false }
        serial = r.string() ?? ""
        // Drop the receive timeout for the streaming reads.
        var zero = timeval(tv_sec: 0, tv_usec: 0)
        setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, &zero, socklen_t(MemoryLayout<timeval>.size))
        lock.lock(); fd = s; open = true; lock.unlock()
        Thread.detachNewThread { [weak self] in self?.readLoop(s) }
        return true
    }

    public func subscribe(_ subscription: FrameProtocol.Subscription) {
        lock.lock(); let s = fd; let go = open; lock.unlock()
        guard go else { return }
        var mask: UInt32 = 0
        for kind in subscription.kinds { mask |= 1 << UInt32(kind.rawValue) }
        let message = ByteWriter.message(FrameProtocol.ClientMessage.subscribe.rawValue) { w in
            w.u32(mask); w.u8(subscription.bodies ? 1 : 0)
            if let c = subscription.config {
                w.u8(1)
                w.u8(UInt8(DepthMode.allCases.firstIndex(of: c.depthMode) ?? 0))
                w.u8(UInt8(ColorResolution.allCases.firstIndex(of: c.colorResolution) ?? 0))
                w.u8(c.frameRate == .fps5 ? 0 : c.frameRate == .fps15 ? 1 : 2)
                w.u8(c.bodyTracking ? 1 : 0); w.i32(c.deviceIndex); w.u8(c.active ? 1 : 0)
            } else { w.u8(0) }
        }
        _ = UnixSocket.writeFully(s, message)
    }

    public func close() {
        lock.lock(); let was = open; open = false; let s = fd; fd = -1; lock.unlock()
        if was, s >= 0 {
            _ = UnixSocket.writeFully(s, ByteWriter.message(FrameProtocol.ClientMessage.bye.rawValue) { _ in })
            shutdown(s, SHUT_RDWR); Darwin.close(s)
        }
    }

    private func readLoop(_ s: Int32) {
        Thread.current.name = "kinect.frameclient.read"
        while true {
            guard let (type, payload) = UnixSocket.readMessage(s) else { break }
            switch FrameProtocol.ServerMessage(rawValue: type) {
            case .status: var r = ByteReader(payload); if let text = r.string() { onStatus?(text) }
            case .stats: var r = ByteReader(payload); var stats: [Double] = []; for _ in 0..<6 { if let v = r.f64() { stats.append(v) } }; if stats.count == 6 { onStats?(stats) }
            case .image:
                var r = ByteReader(payload)
                guard let k = r.i32(), let kind = FrameKind(rawValue: k), let w = r.i32(), let h = r.i32(), let f = r.i32(), let fmt = FramePixelFormat(rawValue: f),
                      let frame = r.u64(), let ts = r.u64(), let bytes = r.bytes() else { break }
                onImage?(FrameImage(kind: kind, width: w, height: h, pixelFormat: fmt, frameID: frame, deviceTimestampMicroseconds: ts, bytes: bytes))
            case .bodies:
                var r = ByteReader(payload)
                guard let count = r.u16() else { break }
                var bodies: [FrameBody] = []
                for _ in 0..<count { guard let b = FrameBody.decode(from: &r) else { break }; bodies.append(b) }
                onBodies?(bodies)
            default: break
            }
        }
        lock.lock(); open = false; lock.unlock()
        onDisconnect?()
    }
}
