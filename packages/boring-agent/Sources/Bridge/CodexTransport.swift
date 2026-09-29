// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Darwin
import CryptoKit

enum CodexTransportError: Error, LocalizedError {
    case unavailable, invalidEndpoint, invalidMessage, tooLarge, timedOut, disconnected
    case remote(Int)
    var errorDescription: String? {
        switch self {
        case .unavailable: return "Codex app-server is not available."
        case .invalidEndpoint: return "Select an existing private Codex app-server socket owned by your macOS account."
        case .invalidMessage: return "Codex returned an unsupported protocol message."
        case .tooLarge: return "Codex returned a message larger than the supported limit."
        case .timedOut: return "Codex did not acknowledge the request in time."
        case .disconnected: return "The Codex connection closed."
        case .remote: return "Codex rejected this request. Open the original session for details."
        }
    }
}

protocol CodexRPCTransport: AnyObject {
    func connect() throws
    func send(_ value: [String: Any], timeout: TimeInterval) throws
    func receive(timeout: TimeInterval) throws -> [String: Any]?
    func close()
}

/// Synchronous bounded I/O used exclusively on the bridge's private queue.
/// No app-server is started, resumed in another owner, or reconfigured here.
final class CodexUnixWebSocket: CodexRPCTransport {
    static let maximumMessageBytes = 4_194_304
    static var defaultEndpoint: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/app-server-control/app-server-control.sock")
    }
    let endpoint: URL
    private var descriptor: Int32 = -1
    private var bytes = Data()
    private var fragmented = Data()
    private var fragmentOpcode: UInt8? = nil

    init(endpoint: URL) { self.endpoint = endpoint }
    deinit { close() }

    func connect() throws {
        close()
        let path = endpoint.resolvingSymlinksInPath().standardizedFileURL.path
        var info = stat()
        guard path.hasPrefix("/"), !path.contains("\0"), path.utf8.count < 104,
              lstat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFSOCK,
              info.st_uid == getuid(), (info.st_mode & 0o077) == 0 else { throw CodexTransportError.invalidEndpoint }
        // A world-writable parent is unsuitable even when the socket itself is
        // private; the standard daemon locator resolves into a UID-owned folder.
        var parent = stat()
        let parentPath = URL(fileURLWithPath: path).deletingLastPathComponent().path
        guard lstat(parentPath, &parent) == 0, (parent.st_mode & S_IFMT) == S_IFDIR,
              parent.st_uid == getuid(), (parent.st_mode & 0o022) == 0 else { throw CodexTransportError.invalidEndpoint }
        descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw CodexTransportError.unavailable }
        do {
            var one: Int32 = 1
            _ = setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
            _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)
            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
            withUnsafeMutableBytes(of: &address.sun_path) { target in
                _ = target.initializeMemory(as: UInt8.self, repeating: 0)
                target.copyBytes(from: Array(path.utf8))
            }
            let result = withUnsafePointer(to: &address) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard result == 0 else { throw CodexTransportError.unavailable }
            var after = stat()
            guard lstat(path, &after) == 0, after.st_ino == info.st_ino, after.st_dev == info.st_dev,
                  after.st_uid == getuid(), (after.st_mode & 0o077) == 0 else { throw CodexTransportError.invalidEndpoint }
            _ = fcntl(descriptor, F_SETFL, O_NONBLOCK)
            let key = Data((0..<16).map { _ in UInt8.random(in: 0...255) }).base64EncodedString()
            let header = "GET / HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: \(key)\r\nSec-WebSocket-Version: 13\r\n\r\n"
            try write(Data(header.utf8), deadline: Date().addingTimeInterval(5))
            let deadline = Date().addingTimeInterval(5)
            let separator = Data("\r\n\r\n".utf8)
            while bytes.range(of: separator) == nil {
                guard bytes.count <= 8192, try read(deadline: deadline) else { throw CodexTransportError.timedOut }
            }
            guard let end = bytes.range(of: separator), end.upperBound <= 8192,
                  let response = String(data: bytes[..<end.lowerBound], encoding: .utf8) else { throw CodexTransportError.invalidMessage }
            bytes.removeSubrange(..<end.upperBound)
            let lines = response.components(separatedBy: "\r\n")
            guard lines.first?.hasPrefix("HTTP/1.1 101 ") == true else { throw CodexTransportError.invalidMessage }
            var fields: [String: String] = [:]
            for line in lines.dropFirst() {
                let parts = line.split(separator: ":", maxSplits: 1)
                guard parts.count == 2 else { continue }
                fields[String(parts[0]).lowercased()] = parts[1].trimmingCharacters(in: .whitespaces)
            }
            let accept = Data(Insecure.SHA1.hash(data: Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8))).base64EncodedString()
            guard fields["sec-websocket-accept"] == accept,
                  fields["upgrade"]?.lowercased() == "websocket",
                  fields["connection"]?.lowercased().split(separator: ",").contains(where: { $0.trimmingCharacters(in: .whitespaces) == "upgrade" }) == true else { throw CodexTransportError.invalidMessage }
        } catch { close(); throw error }
    }

    func send(_ value: [String: Any], timeout: TimeInterval = 8) throws {
        let data = try JSONSerialization.data(withJSONObject: value)
        guard data.count <= Self.maximumMessageBytes else { throw CodexTransportError.tooLarge }
        try write(Self.frame(data, opcode: 1), deadline: Date().addingTimeInterval(timeout))
    }

    static func frame(_ payload: Data, opcode: UInt8) -> Data {
        let mask = (0..<4).map { _ in UInt8.random(in: 0...255) }
        var output = Data([0x80 | opcode])
        if payload.count < 126 { output.append(0x80 | UInt8(payload.count)) }
        else if payload.count <= Int(UInt16.max) {
            output.append(0xfe); var length = UInt16(payload.count).bigEndian
            withUnsafeBytes(of: &length) { output.append(contentsOf: $0) }
        } else {
            output.append(0xff); var length = UInt64(payload.count).bigEndian
            withUnsafeBytes(of: &length) { output.append(contentsOf: $0) }
        }
        output.append(contentsOf: mask)
        output.append(contentsOf: payload.enumerated().map { $0.element ^ mask[$0.offset % 4] })
        return output
    }

    func receive(timeout: TimeInterval) throws -> [String: Any]? {
        let deadline = Date().addingTimeInterval(max(0, timeout))
        while true {
            if let payload = try nextPayload(deadline: deadline) {
                guard let object = try JSONSerialization.jsonObject(with: payload) as? [String: Any] else { throw CodexTransportError.invalidMessage }
                return object
            }
            guard try read(deadline: deadline) else { return nil }
        }
    }

    private func nextPayload(deadline: Date) throws -> Data? {
        while bytes.count >= 2 {
            let input = [UInt8](bytes.prefix(10))
            let final = input[0] & 0x80 != 0, opcode = input[0] & 0x0f
            guard input[0] & 0x70 == 0, input[1] & 0x80 == 0 else { throw CodexTransportError.invalidMessage }
            var length = UInt64(input[1] & 0x7f), header = 2
            if length == 126 {
                guard input.count >= 4 else { return nil }
                length = UInt64(input[2]) << 8 | UInt64(input[3]); header = 4
            } else if length == 127 {
                guard input.count >= 10 else { return nil }
                length = input[2..<10].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }; header = 10
            }
            guard length <= Self.maximumMessageBytes else { throw CodexTransportError.tooLarge }
            guard bytes.count >= header + Int(length) else { return nil }
            let payload = Data(bytes.dropFirst(header).prefix(Int(length)))
            bytes.removeFirst(header + Int(length))
            if opcode >= 8 {
                guard final, length <= 125 else { throw CodexTransportError.invalidMessage }
                switch opcode {
                case 8: throw CodexTransportError.disconnected
                case 9: try write(Self.frame(payload, opcode: 10), deadline: deadline)
                case 10: break
                default: throw CodexTransportError.invalidMessage
                }
                continue
            }
            guard opcode == 0 || opcode == 1 else { throw CodexTransportError.invalidMessage }
            if opcode == 1 {
                guard fragmentOpcode == nil else { throw CodexTransportError.invalidMessage }
                if final { return payload }
                fragmentOpcode = opcode; fragmented = payload
            } else {
                guard fragmentOpcode != nil, fragmented.count + payload.count <= Self.maximumMessageBytes else { throw CodexTransportError.invalidMessage }
                fragmented.append(payload)
                if final { let result = fragmented; fragmented.removeAll(); fragmentOpcode = nil; return result }
            }
        }
        return nil
    }

    private func read(deadline: Date) throws -> Bool {
        guard try wait(events: Int16(POLLIN), deadline: deadline) else { return false }
        var buffer = [UInt8](repeating: 0, count: 16_384)
        let count = Darwin.read(descriptor, &buffer, buffer.count)
        if count < 0 && (errno == EAGAIN || errno == EINTR) { return true }
        guard count > 0 else { throw CodexTransportError.disconnected }
        guard bytes.count + count <= Self.maximumMessageBytes + 16_384 else { throw CodexTransportError.tooLarge }
        bytes.append(contentsOf: buffer.prefix(count)); return true
    }

    private func write(_ data: Data, deadline: Date) throws {
        var offset = 0
        while offset < data.count {
            guard try wait(events: Int16(POLLOUT), deadline: deadline) else { throw CodexTransportError.timedOut }
            let count = data.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress!.advanced(by: offset), data.count - offset) }
            if count < 0 && (errno == EAGAIN || errno == EINTR) { continue }
            guard count > 0 else { throw CodexTransportError.disconnected }
            offset += count
        }
    }

    private func wait(events: Int16, deadline: Date) throws -> Bool {
        guard descriptor >= 0 else { throw CodexTransportError.disconnected }
        var fd = pollfd(fd: descriptor, events: events, revents: 0)
        let milliseconds = Int32(max(0, min(30_000, deadline.timeIntervalSinceNow * 1000)))
        let result = poll(&fd, 1, milliseconds)
        if result < 0 && errno == EINTR { return try wait(events: events, deadline: deadline) }
        guard result >= 0, fd.revents & Int16(POLLNVAL | POLLERR) == 0 else { throw CodexTransportError.disconnected }
        if fd.revents & events != 0 { return true }
        if fd.revents & Int16(POLLHUP) != 0 { throw CodexTransportError.disconnected }
        return false
    }

    func close() {
        if descriptor >= 0 { _ = Darwin.close(descriptor); descriptor = -1 }
        bytes.removeAll(); fragmented.removeAll(); fragmentOpcode = nil
    }
}

final class CodexRPCClient {
    let transport: CodexRPCTransport
    var event: (([String: Any]) -> Void)?
    private let identity = UUID().uuidString
    private var sequence = 0
    init(transport: CodexRPCTransport) { self.transport = transport }
    func connect(timeout: TimeInterval = 8) throws {
        try transport.connect()
        _ = try request("initialize", params: ["clientInfo": ["name": "boringagent", "title": "BoringAgent", "version": "0.3.0"],
            "capabilities": ["experimentalApi": true]], timeout: timeout)
        try transport.send(["method": "initialized", "params": [:]], timeout: 5)
    }
    func request(_ method: String, params: [String: Any] = [:], timeout: TimeInterval = 8) throws -> [String: Any] {
        sequence += 1; let id = "boringagent-\(identity)-\(sequence)"
        try transport.send(["id": id, "method": method, "params": params], timeout: timeout)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            guard let value = try transport.receive(timeout: max(0, deadline.timeIntervalSinceNow)) else { break }
            if value["id"] as? String == id, value["method"] == nil {
                if let error = value["error"] as? [String: Any] { throw CodexTransportError.remote(error["code"] as? Int ?? -1) }
                guard let result = value["result"] as? [String: Any] else { throw CodexTransportError.invalidMessage }
                return result
            }
            event?(value)
        }
        throw CodexTransportError.timedOut
    }
    func drain(maximum: Int = 128) throws {
        for _ in 0..<maximum {
            guard let value = try transport.receive(timeout: 0) else { return }
            event?(value)
        }
    }
    func reply(id: Any, result: [String: Any]) throws {
        try transport.send(["id": id, "result": result], timeout: 5)
    }
    func close() { event = nil; transport.close() }
}
