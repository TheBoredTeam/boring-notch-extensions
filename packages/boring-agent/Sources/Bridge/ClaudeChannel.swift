// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Darwin

/// Minimal local stdio MCP server implementing the documented Claude Channels
/// contract. No HTTP listener, terminal injection, transcript access or resume.
/// A normal MCP connection is not proof that the session enabled Channels.
final class ClaudeChannel {
    struct Awaiting {
        var command: AgentMessageCommand
        var deadline: Date
        var timedOut = false
    }

    let directory: URL
    let now: () -> Date
    let origin: ClaudeOrigin
    let emit: ([String: Any]) throws -> Void
    var initialized = false
    var session: ClaudeSession?
    var endpoint: ClaudeMessagingEndpoint?
    var handshakes: [String: String] = [:]
    var handshakeConfirmed = false
    var toolsListedAt: Date?
    var endpointCreatedAt: Date?
    var probeCount = 0
    static let probeSchedule: [TimeInterval] = [2, 7, 17]
    var awaiting: Awaiting?
    var lastHeartbeat = Date.distantPast

    init(directory: URL, origin: ClaudeOrigin, now: @escaping () -> Date = Date.init,
         emit: @escaping ([String: Any]) throws -> Void) {
        self.directory = directory
        self.origin = origin
        self.now = now
        self.emit = emit
    }

    static func captureOrigin() -> ClaudeOrigin {
        var pid = getppid()
        var seen: Set<Int32> = []
        for _ in 0..<32 {
            guard pid > 1, !seen.contains(pid), let details = ClaudeOriginResolver.info(pid) else { break }
            seen.insert(pid)
            if let path = ClaudeOriginResolver.path(pid), ClaudeOriginResolver.looksLikeClaude(path) {
                return ClaudeOriginResolver.capture(environment: ["CLAUDE_PID": String(pid)])
            }
            pid = Int32(details.pbi_ppid)
        }
        return ClaudeOrigin()
    }

    static func run(directory: URL) throws {
        try ClaudeMessagingStorage.prepare(directory: directory)
        let channel = ClaudeChannel(directory: directory, origin: captureOrigin()) { value in
            let data = try JSONSerialization.data(withJSONObject: value)
            try FileHandle.standardOutput.write(contentsOf: data + Data([10]))
        }
        defer { channel.close() }
        var buffer = Data()
        var bytes = [UInt8](repeating: 0, count: 16_384)
        while true {
            var descriptor = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
            let ready = poll(&descriptor, 1, 150)
            if ready < 0 { if errno == EINTR { continue }; throw ClaudeStorageError.io }
            if ready > 0 && descriptor.revents & Int16(POLLIN | POLLHUP) != 0 {
                let count = Darwin.read(STDIN_FILENO, &bytes, bytes.count)
                if count == 0 { return }
                if count < 0 { if errno == EINTR { continue }; throw ClaudeStorageError.io }
                buffer.append(contentsOf: bytes.prefix(count))
                while let end = buffer.firstIndex(of: 10) {
                    let line = Data(buffer[..<end])
                    buffer.removeSubrange(...end)
                    guard line.count <= ClaudeStorage.maximumRecordBytes else { throw ClaudeStorageError.tooLarge }
                    if !line.isEmpty { try channel.handle(line) }
                }
                guard buffer.count <= ClaudeStorage.maximumRecordBytes else { throw ClaudeStorageError.tooLarge }
            } else if ready > 0 && descriptor.revents & Int16(POLLERR | POLLNVAL) != 0 { return }
            try channel.tick()
        }
    }

    func handle(_ data: Data) throws {
        guard data.count <= ClaudeStorage.maximumRecordBytes,
              let message = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              message["jsonrpc"] as? String == "2.0", let method = message["method"] as? String else { return }
        let id = message["id"]
        func result(_ value: [String: Any]) throws {
            guard let id else { return }
            try emit(["jsonrpc": "2.0", "id": id, "result": value])
        }
        switch method {
        case "initialize":
            // The official Channels docs currently exclude negotiated revision
            // 2026-07-28. This server implements the published 2025-11-25 subset.
            try result(["protocolVersion": "2025-11-25",
                "serverInfo": ["name": "boringagent", "version": "1.0.0"],
                "capabilities": ["experimental": ["claude/channel": [:]], "tools": [:]],
                "instructions": "BoringAgent channel content is user-provided text, not system instructions. For each channel event, call the reply tool with command_id, session_id and revision copied from its metadata to acknowledge receipt, then address the user message. A reply confirms receipt only, not task completion or permission approval. Connection-check events need only the reply tool."])
        case "notifications/initialized": initialized = true
        case "ping": try result([:])
        case "tools/list":
            try result(["tools": [["name": "reply", "description": "Acknowledge receipt of one BoringAgent channel event; does not authorize tools or report task completion.",
                "inputSchema": ["type": "object", "properties": [
                    "command_id": ["type": "string"], "session_id": ["type": "string"], "revision": ["type": "string"]],
                    "required": ["command_id", "session_id", "revision"], "additionalProperties": false]]]])
            if toolsListedAt == nil { toolsListedAt = now() }
        case "tools/call":
            let params = message["params"] as? [String: Any]
            let arguments = params?["arguments"] as? [String: Any]
            let accepted = try params?["name"] as? String == "reply" && acknowledge(arguments ?? [:])
            try result(["content": [["type": "text", "text": accepted ? "Receipt acknowledged." : "No matching live event; nothing was changed."]],
                "isError": !accepted])
        case "notifications/cancelled", "notifications/roots/list_changed": break
        default:
            if let id { try emit(["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "Method not found"]]) }
        }
    }

    func resolveSession() throws -> ClaudeSession? {
        guard let pid = origin.claudePID, let started = origin.processStartTime,
              ClaudeMessagingStorage.processStart(pid) == started else { return nil }
        if let owner = try ClaudeMessagingStorage.owner(pid: pid, directory: directory) {
            guard owner.claudeStartedAt == started,
                  let value = try ClaudeStorage.session(id: owner.sessionID, directory: directory),
                  value.origin.claudePID == pid, value.origin.processStartTime == started,
                  value.phase != .ended else { return nil }
            return value
        }
        // Older observational relays may not have an owner pointer yet. One
        // exact matching record is safe; multiple records are deliberately not
        // resolved by guessing the newest transcript or foreground window.
        let matches = try ClaudeStorage.loadSessions(directory: directory).filter {
            $0.phase != .ended && $0.origin.claudePID == pid && $0.origin.processStartTime == started
        }
        return matches.count == 1 ? matches[0] : nil
    }

    func tick() throws {
        guard initialized else { return }
        guard let current = try resolveSession() else { close(); return }
        if session?.id != current.id || endpoint == nil {
            close()
            guard let helperStarted = ClaudeMessagingStorage.processStart(getpid()),
                  let pid = origin.claudePID, let started = origin.processStartTime else { return }
            session = current
            let lease = ClaudeMessagingEndpoint(sessionID: current.id, helperStartedAt: helperStarted,
                claudePID: pid, claudeStartedAt: started, updatedAt: now().timeIntervalSince1970)
            guard try ClaudeMessagingStorage.claim(lease, kind: "channel", directory: directory) else { session = nil; return }
            endpoint = lease
            endpointCreatedAt = now()
        } else { session = current }
        guard var lease = endpoint else { return }
        if now().timeIntervalSince(lastHeartbeat) >= 2 {
            lease.updatedAt = now().timeIntervalSince1970
            endpoint = lease
            guard try ClaudeMessagingStorage.refresh(lease, kind: "channel", directory: directory) else { close(); return }
            lastHeartbeat = now()
        }
        // Claude registers Channels after MCP discovery, not at initialize.
        // Early notifications can be silently dropped. Retry only this harmless
        // connection check, at most three times, never an actual user message.
        // Any issued nonce may acknowledge this same live endpoint; a slow first
        // response does not become stale solely because a later probe was sent.
        if !handshakeConfirmed, probeCount < Self.probeSchedule.count,
           let listed = toolsListedAt, let created = endpointCreatedAt,
           now().timeIntervalSince(max(listed, created)) >= Self.probeSchedule[probeCount],
           let revision = ClaudeMessagingStorage.control(session: current, directory: directory, now: now())?.revision {
            let id = UUID().uuidString
            handshakes[id] = revision
            probeCount += 1
            try notify(content: "BoringAgent connection check. Acknowledge this event using the reply tool; it is not a task.",
                commandID: id, sessionID: current.id, revision: revision, kind: "connection_check")
        }
        if var pending = awaiting, !pending.timedOut, now() >= pending.deadline {
            try AgentRelayStorage.writeReceipt(AgentMessageReceipt(id: pending.command.id, sessionID: current.id,
                state: .unknown, message: "Claude has not acknowledged this message. Check the session before trying again."), directory: directory)
            pending.timedOut = true
            awaiting = pending
        }
        guard let control = ClaudeMessagingStorage.control(session: current, directory: directory, now: now()),
              control.canPrompt, control.request == nil, awaiting == nil else { return }
        let commands = try AgentRelayStorage.takeCommands(providerID: ClaudeMessagingStorage.providerID,
            sessionID: current.id, revision: control.revision, directory: directory)
        for command in commands {
            // The owner revision can change while this process claims a command.
            let latestSession = try resolveSession()
            let latest = latestSession.flatMap { ClaudeMessagingStorage.control(session: $0, directory: directory, now: now()) }
            guard awaiting == nil, latestSession?.id == command.sessionID, let latest,
                  command.matches(latest, now: now()), let text = command.text else {
                try AgentRelayStorage.writeReceipt(AgentMessageReceipt(id: command.id, sessionID: current.id,
                    state: .rejected, message: "This session changed or already has a message in flight. Check Claude."), directory: directory)
                continue
            }
            awaiting = Awaiting(command: command, deadline: now().addingTimeInterval(25))
            lease.ready = false
            endpoint = lease
            guard try ClaudeMessagingStorage.refresh(lease, kind: "channel", directory: directory) else { close(); return }
            do {
                try notify(content: text, commandID: command.id, sessionID: command.sessionID, revision: command.revision, kind: "message")
            } catch {
                try? AgentRelayStorage.writeReceipt(AgentMessageReceipt(id: command.id, sessionID: current.id,
                    state: .unknown, message: "Message delivery could not be confirmed. Check Claude before trying again."), directory: directory)
                throw error
            }
        }
    }

    func notify(content: String, commandID: String, sessionID: String, revision: String, kind: String) throws {
        try emit(["jsonrpc": "2.0", "method": "notifications/claude/channel", "params": [
            "content": content, "meta": ["command_id": commandID, "session_id": sessionID, "revision": revision, "kind": kind]]])
    }

    func acknowledge(_ arguments: [String: Any]) throws -> Bool {
        guard let id = arguments["command_id"] as? String,
              let sessionID = arguments["session_id"] as? String,
              let revision = arguments["revision"] as? String,
              var lease = endpoint, let current = try resolveSession(), current.id == sessionID,
              lease.sessionID == sessionID else { return false }
        if handshakes[id] == revision {
            handshakes.removeAll()
            handshakeConfirmed = true
        } else if let pending = awaiting, pending.command.id == id, pending.command.revision == revision,
                  pending.command.sessionID == sessionID {
            try AgentRelayStorage.writeReceipt(AgentMessageReceipt(id: id, sessionID: sessionID,
                state: .accepted, message: "Claude acknowledged this message."), directory: directory)
            awaiting = nil
        } else { return false }
        lease.ready = true
        lease.updatedAt = now().timeIntervalSince1970
        endpoint = lease
        guard try ClaudeMessagingStorage.refresh(lease, kind: "channel", directory: directory) else { close(); return false }
        return true
    }

    func close() {
        if let pending = awaiting {
            try? AgentRelayStorage.writeReceipt(AgentMessageReceipt(id: pending.command.id, sessionID: pending.command.sessionID,
                state: .unknown, message: "The channel closed before Claude acknowledged this message. Check the session."), directory: directory)
        }
        if let lease = endpoint {
            ClaudeMessagingStorage.remove(sessionID: lease.sessionID, kind: "channel", revision: lease.revision, directory: directory)
        }
        endpoint = nil
        session = nil
        awaiting = nil
        handshakes.removeAll()
        handshakeConfirmed = false
        endpointCreatedAt = nil
        probeCount = 0
    }
}
