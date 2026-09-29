// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Darwin

/// A short-lived capability owned by one helper process and one Claude process.
/// These records contain presentation metadata, never raw tool input or prompts.
struct ClaudeMessagingEndpoint: Codable, Sendable {
    var schemaVersion = 1
    var sessionID: String
    var revision: String = UUID().uuidString
    var helperPID: Int32 = getpid()
    var helperStartedAt: Double
    var claudePID: Int32
    var claudeStartedAt: Double
    var updatedAt: Double = Date().timeIntervalSince1970
    var ready = false
    var request: AgentInputRequest? = nil

    var isValid: Bool {
        schemaVersion == 1 && ClaudeValidation.identifier(sessionID) &&
        UUID(uuidString: revision) != nil && helperPID > 1 && claudePID > 1 &&
        helperStartedAt.isFinite && helperStartedAt > 0 &&
        claudeStartedAt.isFinite && claudeStartedAt > 0 &&
        updatedAt.isFinite && updatedAt > 0 && (request?.isValid ?? true)
    }
}

struct ClaudeMessagingOwner: Codable, Sendable {
    var sessionID: String
    var revision = UUID().uuidString
    var claudePID: Int32
    var claudeStartedAt: Double
}

struct ClaudeQuestionClient: Codable {
    var pid: Int32
    var startedAt: Double
    var updatedAt: Double
}

enum ClaudeMessagingStorage {
    static let providerID = "claude"
    static let leaseSeconds: TimeInterval = 8

    static func processStart(_ pid: Int32) -> Double? {
        guard pid > 1 else { return nil }
        var info = proc_bsdinfo()
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)) == MemoryLayout<proc_bsdinfo>.size,
              info.pbi_uid == getuid(), info.pbi_status != SZOMB else { return nil }
        return Double(info.pbi_start_tvsec) + Double(info.pbi_start_tvusec) / 1_000_000
    }

    static func prepare(directory: URL) throws {
        try ClaudeStorage.prepare(directory: directory)
        try AgentRelayStorage.prepare(directory: directory)
        try ClaudeStorage.ensureDirectory(directory.appendingPathComponent("claude-controls"))
        try ClaudeStorage.ensureDirectory(directory.appendingPathComponent("claude-owners"))
    }

    static func questionsEnabled(directory: URL) -> Bool {
        guard (try? ClaudeStorage.checkDirectory(directory)) != nil,
              let bytes = try? ClaudeStorage.read(directory.appendingPathComponent("claude-question-opt-in.json"), limit: 1024),
              let value = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any]
        else { return false }
        return value["schemaVersion"] as? Int == 1 && value["enabled"] as? Bool == true
    }

    static func setQuestionsEnabled(_ enabled: Bool, directory: URL) throws {
        try prepare(directory: directory)
        try ClaudeStorage.locked(at: directory.appendingPathComponent(".claude-messaging.lock")) {
            try ClaudeStorage.atomicWrite(JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "enabled": enabled]),
                to: directory.appendingPathComponent("claude-question-opt-in.json"))
        }
    }

    static func questionClient(directory: URL) -> ClaudeQuestionClient? {
        guard (try? ClaudeStorage.checkDirectory(directory)) != nil,
              let bytes = try? ClaudeStorage.read(directory.appendingPathComponent("claude-question-client.json"), limit: 1024),
              let client = try? JSONDecoder().decode(ClaudeQuestionClient.self, from: bytes),
              client.pid > 1, client.startedAt.isFinite, client.startedAt > 0,
              client.updatedAt.isFinite, client.updatedAt > 0 else { return nil }
        return client
    }

    static func questionClientActive(directory: URL, now: Date = Date()) -> Bool {
        guard let client = questionClient(directory: directory),
              processStart(client.pid) == client.startedAt,
              (-2...leaseSeconds).contains(now.timeIntervalSince1970 - client.updatedAt) else { return false }
        return true
    }

    /// Called by the connected UI's regular refresh. Throttled so its own file
    /// notification cannot create a refresh/write feedback loop.
    static func touchQuestionClient(directory: URL, now: Date = Date()) throws {
        guard questionsEnabled(directory: directory), let started = processStart(getpid()) else { return }
        if let old = questionClient(directory: directory), old.pid == getpid(), old.startedAt == started,
           (0..<2).contains(now.timeIntervalSince1970 - old.updatedAt) { return }
        try ClaudeStorage.atomicWrite(JSONEncoder().encode(ClaudeQuestionClient(pid: getpid(), startedAt: started,
            updatedAt: now.timeIntervalSince1970)), to: directory.appendingPathComponent("claude-question-client.json"))
    }

    static func endpointURL(sessionID: String, kind: String, directory: URL) throws -> URL {
        guard ClaudeValidation.identifier(sessionID), ["question", "channel"].contains(kind) else {
            throw ClaudeStorageError.invalidRecord
        }
        return directory.appendingPathComponent("claude-controls/\(sessionID).\(kind).json")
    }

    static func endpoint(sessionID: String, kind: String, directory: URL) throws -> ClaudeMessagingEndpoint? {
        let url = try endpointURL(sessionID: sessionID, kind: kind, directory: directory)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        try ClaudeStorage.checkDirectory(directory)
        try ClaudeStorage.checkDirectory(url.deletingLastPathComponent())
        let value = try JSONDecoder().decode(ClaudeMessagingEndpoint.self, from: ClaudeStorage.read(url))
        guard value.isValid, value.sessionID == sessionID else { throw ClaudeStorageError.invalidRecord }
        return value
    }

    static func write(_ endpoint: ClaudeMessagingEndpoint, kind: String, directory: URL) throws {
        guard endpoint.isValid else { throw ClaudeStorageError.invalidRecord }
        try prepare(directory: directory)
        try ClaudeStorage.atomicWrite(JSONEncoder().encode(endpoint),
            to: endpointURL(sessionID: endpoint.sessionID, kind: kind, directory: directory))
    }

    static func claim(_ value: ClaudeMessagingEndpoint, kind: String, directory: URL) throws -> Bool {
        try prepare(directory: directory)
        return try ClaudeStorage.locked(at: directory.appendingPathComponent(".claude-messaging.lock")) {
            if let old = try endpoint(sessionID: value.sessionID, kind: kind, directory: directory),
               old.revision != value.revision,
               (-2...leaseSeconds).contains(value.updatedAt - old.updatedAt),
               processStart(old.helperPID) == old.helperStartedAt { return false }
            try write(value, kind: kind, directory: directory)
            return true
        }
    }

    /// A late heartbeat must never revive an endpoint removed by a lifecycle
    /// event or overwrite a newer hook/channel process's generation.
    static func refresh(_ value: ClaudeMessagingEndpoint, kind: String, directory: URL) throws -> Bool {
        try ClaudeStorage.locked(at: directory.appendingPathComponent(".claude-messaging.lock")) {
            guard let old = try endpoint(sessionID: value.sessionID, kind: kind, directory: directory),
                  old.revision == value.revision, old.helperPID == value.helperPID,
                  old.helperStartedAt == value.helperStartedAt else { return false }
            try write(value, kind: kind, directory: directory)
            return true
        }
    }

    static func remove(sessionID: String, kind: String, revision: String, directory: URL) {
        try? ClaudeStorage.locked(at: directory.appendingPathComponent(".claude-messaging.lock")) {
            guard let current = try endpoint(sessionID: sessionID, kind: kind, directory: directory),
                  current.revision == revision else { return }
            _ = unlink(try endpointURL(sessionID: sessionID, kind: kind, directory: directory).path)
        }
    }

    static func live(_ endpoint: ClaudeMessagingEndpoint, session: ClaudeSession, now: Date) -> Bool {
        guard endpoint.isValid, session.phase != .ended, endpoint.sessionID == session.id,
              endpoint.claudePID == session.origin.claudePID,
              endpoint.claudeStartedAt == session.origin.processStartTime,
              (-2...leaseSeconds).contains(now.timeIntervalSince1970 - endpoint.updatedAt),
              processStart(endpoint.helperPID) == endpoint.helperStartedAt,
              processStart(endpoint.claudePID) == endpoint.claudeStartedAt else { return false }
        return true
    }

    static func control(session: ClaudeSession, directory: URL, now: Date = Date()) -> AgentSessionControl? {
        guard session.phase != .ended else { return nil }
        if questionsEnabled(directory: directory), questionClientActive(directory: directory, now: now),
           let client = questionClient(directory: directory),
           let question = try? endpoint(sessionID: session.id, kind: "question", directory: directory),
           live(question, session: session, now: now), question.ready, let request = question.request {
            return AgentSessionControl(revision: question.revision, canPrompt: false, request: request,
                expiresAt: min(question.updatedAt, client.updatedAt) + leaseSeconds)
        }
        if let channel = try? endpoint(sessionID: session.id, kind: "channel", directory: directory),
           live(channel, session: session, now: now) {
            let owner = try? owner(pid: channel.claudePID, directory: directory)
            if let owner, owner.sessionID != session.id || owner.claudeStartedAt != channel.claudeStartedAt { return nil }
            let revision = channel.revision + ":" + (owner?.revision ?? "initial")
            let waiting = session.phase == .needsInput
            return AgentSessionControl(revision: revision, canPrompt: channel.ready && !waiting,
                unavailableReason: waiting ? "Answer the pending request in Claude." :
                    (channel.ready ? nil : "Waiting for Claude to acknowledge the channel."),
                expiresAt: channel.updatedAt + leaseSeconds)
        }
        return nil
    }

    static func owner(pid: Int32, directory: URL) throws -> ClaudeMessagingOwner? {
        guard pid > 1 else { throw ClaudeStorageError.invalidRecord }
        let folder = directory.appendingPathComponent("claude-owners")
        let url = folder.appendingPathComponent("\(pid).json")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        try ClaudeStorage.checkDirectory(directory)
        try ClaudeStorage.checkDirectory(folder)
        let value = try JSONDecoder().decode(ClaudeMessagingOwner.self, from: ClaudeStorage.read(url, limit: 2048))
        guard value.claudePID == pid, ClaudeValidation.identifier(value.sessionID),
              UUID(uuidString: value.revision) != nil, value.claudeStartedAt.isFinite,
              value.claudeStartedAt > 0 else { throw ClaudeStorageError.invalidRecord }
        return value
    }

    /// Called only for validated, primary-session lifecycle hooks. Status-line
    /// refreshes do not advance the revision or replace a pending question.
    static func noteHook(input: Data, directory: URL, origin: ClaudeOrigin) throws {
        guard input.count <= ClaudeStorage.maximumRecordBytes,
              let object = try JSONSerialization.jsonObject(with: input) as? [String: Any],
              object["agent_id"] == nil,
              let sessionID = object["session_id"] as? String, ClaudeValidation.identifier(sessionID),
              let event = object["hook_event_name"] as? String,
              let pid = origin.claudePID, let started = origin.processStartTime,
              processStart(pid) == started else { return }
        try prepare(directory: directory)
        try ClaudeStorage.locked(at: directory.appendingPathComponent(".claude-messaging.lock")) {
            let old = try owner(pid: pid, directory: directory)
            let advances = ["SessionStart", "UserPromptSubmit", "PermissionRequest", "Stop", "StopFailure", "SessionEnd"].contains(event)
            if advances || old?.sessionID != sessionID || old?.claudeStartedAt != started {
                let value = ClaudeMessagingOwner(sessionID: sessionID, claudePID: pid, claudeStartedAt: started)
                try ClaudeStorage.atomicWrite(JSONEncoder().encode(value),
                    to: directory.appendingPathComponent("claude-owners/\(pid).json"))
            }
            let isQuestionResult = ["PostToolUse", "PostToolUseFailure"].contains(event) && object["tool_name"] as? String == "AskUserQuestion"
            let clear = ["SessionStart", "UserPromptSubmit", "Stop", "StopFailure", "SessionEnd"].contains(event)
            if let question = try endpoint(sessionID: sessionID, kind: "question", directory: directory),
               clear || (isQuestionResult && question.request?.id == object["tool_use_id"] as? String) {
                _ = unlink(try endpointURL(sessionID: sessionID, kind: "question", directory: directory).path)
            }
        }
    }

    static func enqueue(_ command: AgentMessageCommand, directory: URL) throws {
        guard command.providerID == providerID,
              let session = try ClaudeStorage.session(id: command.sessionID, directory: directory),
              let current = control(session: session, directory: directory), command.matches(current) else {
            throw ClaudeStorageError.invalidRecord
        }
        try AgentRelayStorage.submit(command, directory: directory)
    }

    static func receipt(commandID: String, sessionID: String, directory: URL) throws -> AgentMessageReceipt? {
        guard let value = try AgentRelayStorage.receipt(id: commandID, directory: directory),
              value.sessionID == sessionID else { return nil }
        return value
    }
}
