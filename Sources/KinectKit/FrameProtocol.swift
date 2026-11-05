import Foundation

/// The local frame-sharing link between the Kinect for Mac app (server) and
/// the TouchDesigner plugin (client), over a Unix-domain socket.
///
/// Both sides speak length-prefixed binary messages, little-endian:
///   [u32 payloadLength][u8 type][payload...]
///
/// The app owns the camera; a client subscribes to the image kinds it wants
/// and may request a configuration. **Config requests are applied last-writer-
/// wins**: the app updates its own configuration to match, exactly as if a
/// person changed it in the menu. The socket carries only data the plugin
/// would otherwise get by opening the camera itself, so quality is identical;
/// the only cost is one frame of inter-process latency.
public enum FrameProtocol {
    public static let socketName = "kinect.sock"
    public static let magic: UInt32 = 0x4B4D4331 // "KMC1"
    public static let version: UInt16 = 1

    /// ~/Library/Application Support/Kinect for Mac/kinect.sock
    public static func socketPath() -> String {
        if let override = ProcessInfo.processInfo.environment["KINECT_SOCKET"], !override.isEmpty { return override }
        let base = (NSHomeDirectory() as NSString).appendingPathComponent("Library/Application Support/Kinect for Mac")
        try? FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
        return (base as NSString).appendingPathComponent(socketName)
    }

    public enum ClientMessage: UInt8 { case hello = 1, subscribe = 2, bye = 3 }
    public enum ServerMessage: UInt8 { case hello = 0x81, status = 0x82, image = 0x83, bodies = 0x84, stats = 0x85 }

    /// What a client wants: a set of kinds, bodies yes/no, and optionally a
    /// configuration to apply.
    public struct Subscription: Sendable, Equatable {
        public var kinds: Set<FrameKind> = []
        public var bodies = false
        public var config: SessionRequest?
        public init() {}
    }

    /// A configuration request mirroring the operator parameters.
    public struct SessionRequest: Sendable, Equatable {
        public var depthMode: DepthMode
        public var colorResolution: ColorResolution
        public var frameRate: FrameRate
        public var bodyTracking: Bool
        public var deviceIndex: Int32
        public var active: Bool
        public init(depthMode: DepthMode, colorResolution: ColorResolution, frameRate: FrameRate, bodyTracking: Bool, deviceIndex: Int32, active: Bool) {
            self.depthMode = depthMode; self.colorResolution = colorResolution; self.frameRate = frameRate
            self.bodyTracking = bodyTracking; self.deviceIndex = deviceIndex; self.active = active
        }
    }
}

/// A little-endian append-only writer.
struct ByteWriter {
    var data = Data()
    mutating func u8(_ v: UInt8) { data.append(v) }
    mutating func u16(_ v: UInt16) { var x = v.littleEndian; withUnsafeBytes(of: &x) { data.append(contentsOf: $0) } }
    mutating func u32(_ v: UInt32) { var x = v.littleEndian; withUnsafeBytes(of: &x) { data.append(contentsOf: $0) } }
    mutating func i32(_ v: Int32) { u32(UInt32(bitPattern: v)) }
    mutating func u64(_ v: UInt64) { var x = v.littleEndian; withUnsafeBytes(of: &x) { data.append(contentsOf: $0) } }
    mutating func f32(_ v: Float) { u32(v.bitPattern) }
    mutating func f64(_ v: Double) { u64(v.bitPattern) }
    mutating func bytes(_ b: [UInt8]) { u32(UInt32(b.count)); data.append(contentsOf: b) }
    mutating func string(_ s: String) { let b = Array(s.utf8); u32(UInt32(b.count)); data.append(contentsOf: b) }

    /// Wraps the payload as [u32 length][u8 type][payload].
    static func message(_ type: UInt8, _ build: (inout ByteWriter) -> Void) -> Data {
        var w = ByteWriter(); build(&w)
        var frame = ByteWriter(); frame.u32(UInt32(w.data.count + 1)); frame.u8(type); frame.data.append(w.data)
        return frame.data
    }
}

/// A little-endian reader over a payload (the type byte already consumed).
struct ByteReader {
    let data: [UInt8]; var offset = 0
    init(_ data: [UInt8]) { self.data = data }
    mutating func u8() -> UInt8? { guard offset < data.count else { return nil }; defer { offset += 1 }; return data[offset] }
    mutating func u16() -> UInt16? { guard offset + 2 <= data.count else { return nil }; defer { offset += 2 }; return UInt16(data[offset]) | UInt16(data[offset+1]) << 8 }
    mutating func u32() -> UInt32? { guard offset + 4 <= data.count else { return nil }; defer { offset += 4 }
        return UInt32(data[offset]) | UInt32(data[offset+1]) << 8 | UInt32(data[offset+2]) << 16 | UInt32(data[offset+3]) << 24 }
    mutating func i32() -> Int32? { u32().map { Int32(bitPattern: $0) } }
    mutating func u64() -> UInt64? { guard let lo = u32(), let hi = u32() else { return nil }; return UInt64(lo) | UInt64(hi) << 32 }
    mutating func f32() -> Float? { u32().map { Float(bitPattern: $0) } }
    mutating func f64() -> Double? { u64().map { Double(bitPattern: $0) } }
    mutating func bytes() -> [UInt8]? { guard let n = u32(), offset + Int(n) <= data.count else { return nil }; defer { offset += Int(n) }; return Array(data[offset..<offset+Int(n)]) }
    mutating func string() -> String? { bytes().map { String(decoding: $0, as: UTF8.self) } }
}

/// Encodes a FrameBody the way the client decodes it (32 joints, k4abt order).
extension FrameBody {
    func encode(into w: inout ByteWriter) {
        w.i32(id); w.u8(pose ? 1 : 0)
        w.f32(bbox.x); w.f32(bbox.y); w.f32(bbox.z); w.f32(bbox.w)
        for j in joints {
            w.f32(j.x); w.f32(j.y); w.f32(j.z); w.f32(j.pixelX); w.f32(j.pixelY); w.f32(j.confidence); w.u8(j.valid ? 1 : 0)
        }
    }
    static func decode(from r: inout ByteReader) -> FrameBody? {
        var b = FrameBody()
        guard let id = r.i32(), let pose = r.u8(), let bx = r.f32(), let by = r.f32(), let bz = r.f32(), let bw = r.f32() else { return nil }
        b.id = id; b.pose = pose != 0; b.bbox = SIMD4(bx, by, bz, bw)
        for i in 0..<32 {
            guard let x = r.f32(), let y = r.f32(), let z = r.f32(), let px = r.f32(), let py = r.f32(), let c = r.f32(), let v = r.u8() else { return nil }
            var j = FrameJoint(); j.x = x; j.y = y; j.z = z; j.pixelX = px; j.pixelY = py; j.confidence = c; j.valid = v != 0
            b.joints[i] = j
        }
        return b
    }
}

/// Blocking Unix-domain socket helpers shared by the server and client.
enum UnixSocket {
    static func address(_ path: String) -> sockaddr_un {
        var addr = sockaddr_un(); addr.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        withUnsafeMutablePointer(to: &addr.sun_path) { p in
            p.withMemoryRebound(to: CChar.self, capacity: capacity) { dst in
                path.withCString { c in strncpy(dst, c, capacity - 1) }
            }
        }
        return addr
    }
    /// Reads exactly `count` bytes; nil on EOF or error.
    static func readFully(_ fd: Int32, _ count: Int) -> [UInt8]? {
        guard count >= 0 else { return nil }
        if count == 0 { return [] }
        var buffer = [UInt8](repeating: 0, count: count); var got = 0
        while got < count {
            let n = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress! + got, count - got) }
            if n <= 0 { return nil }
            got += n
        }
        return buffer
    }
    static func writeFully(_ fd: Int32, _ data: Data) -> Bool {
        var ok = true
        data.withUnsafeBytes { raw in
            var sent = 0; let total = raw.count
            while sent < total {
                let n = write(fd, raw.baseAddress! + sent, total - sent)
                if n <= 0 { ok = false; break }
                sent += n
            }
        }
        return ok
    }
    /// Reads one framed message: returns (type, payload).
    static func readMessage(_ fd: Int32) -> (UInt8, [UInt8])? {
        guard let header = readFully(fd, 5) else { return nil }
        let length = UInt32(header[0]) | UInt32(header[1]) << 8 | UInt32(header[2]) << 16 | UInt32(header[3]) << 24
        let type = header[4]
        guard length >= 1 else { return nil }
        guard let payload = readFully(fd, Int(length) - 1) else { return nil }
        return (type, payload)
    }
}
