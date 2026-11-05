import Foundation
import Darwin

/// Serves camera frames and tracked bodies to local clients (the TouchDesigner
/// plugin) over the Unix-domain socket. The app owns the camera and calls
/// `publish` from its capture thread; each client gets the newest frame and a
/// slow client simply misses frames instead of backing up memory.
public final class FrameServer: @unchecked Sendable {
    /// Applied when a client asks for a configuration (last writer wins). The
    /// app wires this to update its own settings.
    public var onConfigRequest: (@Sendable (FrameProtocol.SessionRequest) -> Void)?
    /// Called when the set of subscribed clients changes.
    public var onClientsChanged: (@Sendable (Int) -> Void)?

    private let path: String
    private var listenFD: Int32 = -1
    private var accepting = false
    private let lock = NSLock()
    private var clients: [Client] = []
    private var lastStatus = "No Kinect connected"
    private var lastSerial = ""
    private var lastStats: [Double] = Array(repeating: 0, count: 6)

    public init(path: String = FrameProtocol.socketPath()) { self.path = path }

    deinit { stop() }

    public var clientCount: Int { lock.lock(); defer { lock.unlock() }; return clients.count }

    /// The union of what connected clients want, so the app produces only those.
    public var wantedKinds: Set<FrameKind> { lock.lock(); defer { lock.unlock() }; return clients.reduce(into: Set()) { $0.formUnion($1.subscription.kinds) } }
    public var wantsBodies: Bool { lock.lock(); defer { lock.unlock() }; return clients.contains { $0.subscription.bodies } }

    public func start() {
        lock.lock(); let already = accepting; lock.unlock()
        if already { return }
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return }
        var addr = UnixSocket.address(path)
        let bound = withUnsafePointer(to: &addr) { p in p.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        guard bound == 0, listen(fd, 8) == 0 else { close(fd); return }
        lock.lock(); listenFD = fd; accepting = true; lock.unlock()
        Thread.detachNewThread { [weak self] in self?.acceptLoop(fd) }
    }

    public func stop() {
        lock.lock()
        accepting = false
        let fd = listenFD; listenFD = -1
        let current = clients; clients = []
        lock.unlock()
        if fd >= 0 { shutdown(fd, SHUT_RDWR); close(fd) }
        current.forEach { $0.close() }
        unlink(path)
    }

    private func acceptLoop(_ fd: Int32) {
        Thread.current.name = "kinect.frameserver.accept"
        while true {
            let client = accept(fd, nil, nil)
            lock.lock(); let go = accepting; lock.unlock()
            if !go { if client >= 0 { close(client) }; break }
            guard client >= 0 else { continue }
            let c = Client(fd: client, server: self)
            lock.lock(); clients.append(c); let n = clients.count; lock.unlock()
            onClientsChanged?(n)
            c.start()
        }
    }

    /// The newest status, sent to clients on connect and on change.
    public func updateStatus(_ status: String, serial: String) {
        lock.lock()
        let changed = status != lastStatus || serial != lastSerial
        lastStatus = status; lastSerial = serial
        let current = clients
        lock.unlock()
        if changed { current.forEach { $0.send(statusMessage(status)) } }
    }

    /// Publishes a capture's images and bodies. Called per frame by the app.
    public func publish(images: [FrameImage], bodies: [FrameBody], stats: [Double]) {
        lock.lock(); lastStats = stats; let current = clients; lock.unlock()
        for client in current { client.offer(images: images, bodies: bodies, stats: stats) }
    }

    fileprivate func remove(_ client: Client) {
        lock.lock(); clients.removeAll { $0 === client }; let n = clients.count; lock.unlock()
        onClientsChanged?(n)
    }
    fileprivate func currentStatusAndSerial() -> (String, String) { lock.lock(); defer { lock.unlock() }; return (lastStatus, lastSerial) }

    fileprivate func statusMessage(_ status: String) -> Data { ByteWriter.message(FrameProtocol.ServerMessage.status.rawValue) { $0.string(status) } }

    // MARK: one connected client

    final class Client: @unchecked Sendable {
        let fd: Int32
        weak var server: FrameServer?
        let lock = NSLock()
        var subscription = FrameProtocol.Subscription()
        var pending: Data?          // latest frame payload waiting to be written (one slot)
        var writing = false
        var open = true
        let writeQueue = DispatchQueue(label: "kinect.frameserver.client")

        init(fd: Int32, server: FrameServer) { self.fd = fd; self.server = server }

        func start() { Thread.detachNewThread { [self] in readLoop() } }

        func close() {
            lock.lock(); let wasOpen = open; open = false; lock.unlock()
            if wasOpen { shutdown(fd, SHUT_RDWR); Darwin.close(fd) }
        }

        private func readLoop() {
            Thread.current.name = "kinect.frameserver.read"
            // Expect a hello first.
            guard let (type, payload) = UnixSocket.readMessage(fd), type == FrameProtocol.ClientMessage.hello.rawValue else { finish(); return }
            var r = ByteReader(payload)
            guard r.u32() == FrameProtocol.magic else { finish(); return }
            let (status, serial) = server?.currentStatusAndSerial() ?? ("", "")
            send(ByteWriter.message(FrameProtocol.ServerMessage.hello.rawValue) { $0.u32(FrameProtocol.magic); $0.u16(FrameProtocol.version); $0.string(serial) })
            send(server?.statusMessage(status) ?? Data())
            while true {
                guard let (t, p) = UnixSocket.readMessage(fd) else { break }
                if t == FrameProtocol.ClientMessage.bye.rawValue { break }
                if t == FrameProtocol.ClientMessage.subscribe.rawValue { applySubscription(p) }
            }
            finish()
        }

        private func applySubscription(_ payload: [UInt8]) {
            var r = ByteReader(payload)
            guard let mask = r.u32(), let bodies = r.u8(), let hasConfig = r.u8() else { return }
            var sub = FrameProtocol.Subscription()
            for kind in FrameKind.allCases where (mask & (1 << UInt32(kind.rawValue))) != 0 { sub.kinds.insert(kind) }
            sub.bodies = bodies != 0
            if hasConfig != 0, let d = r.u8(), let c = r.u8(), let f = r.u8(), let bt = r.u8(), let dev = r.i32(), let active = r.u8() {
                let request = FrameProtocol.SessionRequest(
                    depthMode: DepthMode.allCases.indices.contains(Int(d)) ? DepthMode.allCases[Int(d)] : .nfovUnbinned,
                    colorResolution: ColorResolution.allCases.indices.contains(Int(c)) ? ColorResolution.allCases[Int(c)] : .p720,
                    frameRate: f == 0 ? .fps5 : f == 1 ? .fps15 : .fps30,
                    bodyTracking: bt != 0, deviceIndex: dev, active: active != 0)
                sub.config = request
                server?.onConfigRequest?(request)
            }
            lock.lock(); subscription = sub; lock.unlock()
        }

        /// Offers a frame; drops it for this client if a write is still going.
        func offer(images: [FrameImage], bodies: [FrameBody], stats: [Double]) {
            lock.lock()
            let sub = subscription
            guard open else { lock.unlock(); return }
            lock.unlock()
            // Encode only the kinds this client subscribed to.
            var w = ByteWriter()
            for image in images where sub.kinds.contains(image.kind) {
                w.data.append(ByteWriter.message(FrameProtocol.ServerMessage.image.rawValue) { m in
                    m.i32(image.kind.rawValue); m.i32(image.width); m.i32(image.height); m.i32(image.pixelFormat.rawValue)
                    m.u64(image.frameID); m.u64(image.deviceTimestampMicroseconds); m.bytes(image.bytes)
                })
            }
            if sub.bodies {
                w.data.append(ByteWriter.message(FrameProtocol.ServerMessage.bodies.rawValue) { m in
                    m.u16(UInt16(bodies.count)); for b in bodies { b.encode(into: &m) }
                })
            }
            w.data.append(ByteWriter.message(FrameProtocol.ServerMessage.stats.rawValue) { m in for s in stats { m.f64(s) } })
            let blob = w.data
            lock.lock()
            pending = blob
            let launch = !writing
            if launch { writing = true }
            lock.unlock()
            if launch { drain() }
        }

        private func drain() {
            writeQueue.async { [self] in
                while true {
                    lock.lock()
                    guard open, let blob = pending else { writing = false; lock.unlock(); return }
                    pending = nil
                    lock.unlock()
                    if !UnixSocket.writeFully(fd, blob) { finish(); return }
                }
            }
        }

        func send(_ data: Data) {
            guard !data.isEmpty else { return }
            writeQueue.async { [self] in
                lock.lock(); let go = open; lock.unlock()
                if go, !UnixSocket.writeFully(fd, data) { finish() }
            }
        }

        private func finish() {
            close()
            server?.remove(self)
        }
    }
}
