import Foundation
import Network

/// A minimal OSC 1.0 encoder: address, type tags, 32-bit ints and floats,
/// strings, in a 4-byte-padded big-endian packet. Enough for TouchDesigner's
/// OSC In CHOP/DAT.
public enum OSC {
    public enum Argument: Equatable {
        case int(Int32)
        case float(Float)
        case string(String)
    }

    static func padded(_ data: Data) -> Data {
        var out = data
        out.append(0)
        while out.count % 4 != 0 { out.append(0) }
        return out
    }

    public static func message(_ address: String, _ arguments: [Argument]) -> Data {
        var packet = padded(Data(address.utf8))
        var tags = ","
        var body = Data()
        for argument in arguments {
            switch argument {
            case .int(let value):
                tags += "i"
                var be = value.bigEndian
                body.append(Data(bytes: &be, count: 4))
            case .float(let value):
                tags += "f"
                var be = value.bitPattern.bigEndian
                body.append(Data(bytes: &be, count: 4))
            case .string(let value):
                tags += "s"
                body.append(padded(Data(value.utf8)))
            }
        }
        packet.append(padded(Data(tags.utf8)))
        packet.append(body)
        return packet
    }

    /// A bundle with an immediate timetag, so a frame's messages arrive together.
    public static func bundle(_ messages: [Data]) -> Data {
        var packet = padded(Data("#bundle".utf8))
        var timetag: UInt64 = 1   // "immediately"
        timetag = timetag.bigEndian
        packet.append(Data(bytes: &timetag, count: 8))
        for message in messages {
            var size = Int32(message.count).bigEndian
            packet.append(Data(bytes: &size, count: 4))
            packet.append(message)
        }
        return packet
    }
}

/// Sends OSC packets over UDP.
public final class OSCSender: @unchecked Sendable {
    private var connection: NWConnection?
    private let queue = DispatchQueue(label: "dklink.osc")
    public private(set) var host: String
    public private(set) var port: UInt16

    public init(host: String = "127.0.0.1", port: UInt16 = 7000) {
        self.host = host
        self.port = port
        connect()
    }

    private func connect() {
        connection?.cancel()
        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port) ?? 7000)
        let connection = NWConnection(to: endpoint, using: .udp)
        connection.start(queue: queue)
        self.connection = connection
    }

    public func reconfigure(host: String, port: UInt16) {
        guard host != self.host || port != self.port else { return }
        self.host = host
        self.port = port
        connect()
    }

    public func send(_ packet: Data) {
        connection?.send(content: packet, completion: .contentProcessed { _ in })
    }

    public func close() {
        connection?.cancel()
        connection = nil
    }
}
