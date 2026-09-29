// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Darwin

@main
@MainActor
struct ClaudeMessagingTests {
    static var assertions = 0
    static func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        assertions += 1
        if try !condition() { throw NSError(domain: "ClaudeMessagingTests", code: assertions,
            userInfo: [NSLocalizedDescriptionKey: message]) }
    }
    static func payload(sessionID: String = "question-session", event: String = "PreToolUse",
                        tool: String = "AskUserQuestion", prompt: String = "Which color?") throws -> Data {
        try JSONSerialization.data(withJSONObject: ["session_id": sessionID, "hook_event_name": event,
            "tool_name": tool, "tool_use_id": "toolu_question1", "tool_input": [
                "questions": [["question": prompt, "header": "Color", "options": [
                    ["label": "Blue", "description": "Cool"], ["label": "Green", "description": "Fresh"]], "multiSelect": false]],
                "futureField": "PRIVATE-INPUT-ONLY"]])
    }
    static func session(id: String, root: URL, now: Date, origin: ClaudeOrigin) throws -> ClaudeSession {
        let value = ClaudeSession(id: id, project: "Fixture", directory: "/tmp/fixture",
            phase: .working, createdAt: now.timeIntervalSince1970, updatedAt: now.timeIntervalSince1970, origin: origin)
        try ClaudeStorage.update(id: id, directory: root) { _ in value }
        return value
    }

    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("boring-claude-messaging-\(UUID().uuidString)")
        try ClaudeStorage.prepare(directory: root)
        defer { try? FileManager.default.removeItem(at: root) }
        let origin = ClaudeOrigin(claudePID: getpid(), processStartTime: ClaudeMessagingStorage.processStart(getpid()))
        let bytes = try payload()
        let parsed = try ClaudeQuestionBridge.parse(bytes)!
        let control = AgentSessionControl(revision: UUID().uuidString, canPrompt: false, request: parsed.request)
        let legacyControl = try JSONDecoder().decode(AgentSessionControl.self,
            from: Data(#"{"revision":"legacy","canPrompt":true}"#.utf8))
        try expect(legacyControl.expiresAt == nil && legacyControl.isValid,
                   "Control lease is backward-compatible with older provider snapshots")
        try expect(!AgentSessionControl(revision: "invalid", canPrompt: true, expiresAt: .nan).isValid,
                   "Non-finite lease is invalid")
        let answer = AgentMessageCommand(providerID: "claude", sessionID: parsed.sessionID,
            revision: control.revision, answers: ["q0": ["Blue"]], requestID: parsed.request.id)
        try expect(ClaudeQuestionBridge.output(for: answer, pending: parsed, control: control) != nil, "Exact answer produces hook output")
        try expect(ClaudeQuestionBridge.parse(payload(tool: "Bash")) == nil, "Permissions never enter the question bridge")
        try expect(ClaudeQuestionBridge.parse(payload(prompt: "Enter your API key")) == nil, "Credential prompts stay in Claude")
        var wrong = answer; wrong.requestID = "other"
        try expect(ClaudeQuestionBridge.output(for: wrong, pending: parsed, control: control) == nil, "Request ID fenced")
        wrong = answer; wrong.revision = "stale"
        try expect(ClaudeQuestionBridge.output(for: wrong, pending: parsed, control: control) == nil, "Revision fenced")
        wrong = answer; wrong.providerID = "codex"
        try expect(ClaudeQuestionBridge.output(for: wrong, pending: parsed, control: control) == nil, "Provider fenced")
        wrong = answer; wrong.answers = ["q0": ["Blue", "Green"]]
        try expect(ClaudeQuestionBridge.output(for: wrong, pending: parsed, control: control) == nil, "Single selection count enforced")
        wrong = answer; wrong.createdAt -= 121
        try expect(ClaudeQuestionBridge.output(for: wrong, pending: parsed, control: control) == nil, "Expired answer fenced")
        try expect(!ClaudeMessagingStorage.questionsEnabled(directory: root), "Question interception defaults off")
        var emitted: Data?
        try expect(!ClaudeQuestionBridge.run(input: bytes, directory: root, origin: origin,
            verifyOrigin: { _ in true }, emit: { emitted = $0 }), "Disabled bridge falls through")
        try expect(emitted == nil, "Disabled hook writes nothing")
        try ClaudeMessagingStorage.setQuestionsEnabled(true, directory: root)
        try expect(!ClaudeMessagingStorage.questionClientActive(directory: root), "Opt-in alone cannot hold a question without a live UI")
        try ClaudeMessagingStorage.touchQuestionClient(directory: root)
        var time = Date()
        let questionSession = try session(id: parsed.sessionID, root: root, now: time, origin: origin)
        var sentID: String?
        var metadataContainedRawInput = false
        let replied = try ClaudeQuestionBridge.run(input: bytes, directory: root, origin: origin,
            now: { time }, pause: { interval in
                if sentID == nil {
                    do {
                        let current = ClaudeMessagingStorage.control(session: questionSession, directory: root, now: time)!
                        let command = AgentMessageCommand(providerID: "claude", sessionID: parsed.sessionID,
                            revision: current.revision, createdAt: time.timeIntervalSince1970,
                            answers: ["q0": ["Blue"]], requestID: parsed.request.id)
                        let url = try ClaudeMessagingStorage.endpointURL(sessionID: parsed.sessionID, kind: "question", directory: root)
                        metadataContainedRawInput = String(decoding: try ClaudeStorage.read(url), as: UTF8.self).contains("PRIVATE-INPUT-ONLY")
                        try AgentRelayStorage.submit(command, directory: root)
                        sentID = command.id
                    } catch { fatalError("Fixture setup failed: \(error)") }
                }
                time.addTimeInterval(interval)
            }, verifyOrigin: { _ in true }, emit: { emitted = $0 })
        try expect(replied && emitted != nil, "Waiting hook accepts a matching reply")
        let output = try JSONSerialization.jsonObject(with: emitted!) as! [String: Any]
        let decision = output["hookSpecificOutput"] as! [String: Any]
        let updated = decision["updatedInput"] as! [String: Any]
        try expect(decision["permissionDecision"] as? String == "allow", "Only answered question has allow output")
        try expect(updated["futureField"] as? String == "PRIVATE-INPUT-ONLY", "Unknown tool input preserved in memory")
        try expect((updated["answers"] as? [String: String])?["Which color?"] == "Blue", "Original question text keys answer")
        try expect(!metadataContainedRawInput, "Raw tool input never enters control record")
        try expect(ClaudeMessagingStorage.receipt(commandID: sentID!, sessionID: parsed.sessionID, directory: root)?.state == .accepted,
            "Accepted receipt follows output write")
        try expect(ClaudeMessagingStorage.endpoint(sessionID: parsed.sessionID, kind: "question", directory: root) == nil,
            "Question lease withdrawn after response")
        emitted = nil
        try expect(!ClaudeQuestionBridge.run(input: bytes, directory: root, origin: origin, timeout: 0.3,
            now: { time }, pause: { time.addTimeInterval($0) }, verifyOrigin: { _ in true }, emit: { emitted = $0 }),
            "Timeout falls through")
        try expect(emitted == nil, "Timeout leaves original question untouched")
        try expect(!ClaudeQuestionBridge.run(input: bytes, directory: root, origin: origin,
            verifyOrigin: { _ in false }, emit: { emitted = $0 }), "Unverified origin cannot intercept")
        time.addTimeInterval(9)
        try expect(!ClaudeQuestionBridge.run(input: bytes, directory: root, origin: origin,
            now: { time }, verifyOrigin: { _ in true }, emit: { emitted = $0 }), "Disconnected UI lease falls through immediately")
        try expect(emitted == nil, "Expired UI cannot emit a reply")

        let retired = ClaudeMessagingEndpoint(sessionID: parsed.sessionID,
            helperStartedAt: ClaudeMessagingStorage.processStart(getpid())!, claudePID: getpid(),
            claudeStartedAt: origin.processStartTime!, ready: true, request: parsed.request)
        try expect(ClaudeMessagingStorage.claim(retired, kind: "question", directory: root), "Endpoint can be claimed once")
        var competing = retired; competing.revision = UUID().uuidString
        try expect(!ClaudeMessagingStorage.claim(competing, kind: "question", directory: root), "Live endpoint ownership cannot be stolen")
        ClaudeMessagingStorage.remove(sessionID: retired.sessionID, kind: "question", revision: retired.revision, directory: root)
        try expect(!ClaudeMessagingStorage.refresh(retired, kind: "question", directory: root), "Late heartbeat cannot revive withdrawn question")

        try channelTests(root: root, origin: origin)
        print("Claude messaging tests passed: \(assertions) assertions. Isolated fixtures; no real Claude session or credentials accessed.")
    }

    static func channelTests(root: URL, origin: ClaudeOrigin) throws {
        var time = Date().addingTimeInterval(-7)
        let value = try session(id: "channel-session", root: root, now: time, origin: origin)
        try ClaudeMessagingStorage.noteHook(input: payload(sessionID: value.id, event: "SessionStart"), directory: root, origin: origin)
        var sent: [[String: Any]] = []
        let channel = ClaudeChannel(directory: root, origin: origin, now: { time }, emit: { sent.append($0) })
        defer { channel.close() }
        try channel.handle(JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": 1, "method": "initialize"]))
        try expect((sent.first?["result"] as? [String: Any])?["protocolVersion"] as? String == "2025-11-25", "Supported protocol negotiated")
        try channel.handle(Data(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#.utf8))
        try channel.tick()
        try expect(sent.count == 1, "No handshake before tool discovery")
        try channel.handle(Data(#"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#.utf8))
        try channel.tick()
        try expect(sent.count == 2, "Tool discovery alone does not race a handshake into startup")
        time.addTimeInterval(2)
        try channel.tick()
        let handshake = (sent.last?["params"] as? [String: Any])?["meta"] as! [String: String]
        try expect(ClaudeMessagingStorage.control(session: value, directory: root, now: time)?.canPrompt == false,
            "MCP initialize alone cannot advertise live messaging")
        var forged = handshake; forged["session_id"] = "wrong-session"
        try expect(!channel.acknowledge(forged), "Wrong-session handshake rejected")
        time.addTimeInterval(5)
        try channel.tick()
        let laterHandshake = (sent.last?["params"] as? [String: Any])?["meta"] as! [String: String]
        try expect(laterHandshake["command_id"] != handshake["command_id"], "Missed startup probe has a fresh bounded nonce")
        try expect(channel.acknowledge(handshake), "An earlier issued nonce still activates its exact live endpoint")
        let control = ClaudeMessagingStorage.control(session: value, directory: root, now: time)!
        try expect(control.canPrompt, "Prompting enabled only after real echo")
        try expect(control.hasLiveLease(at: time) && !control.hasLiveLease(at: time.addingTimeInterval(8)),
                   "Verified channel advertises an independently expiring liveness lease")
        let command = AgentMessageCommand(providerID: "claude", sessionID: value.id,
            revision: control.revision, createdAt: time.timeIntervalSince1970, text: "Synthetic channel message")
        try expect(!command.matches(control, now: time.addingTimeInterval(8)),
                   "Cached channel control cannot send after its lease expires")
        try ClaudeMessagingStorage.enqueue(command, directory: root)
        let before = sent.count
        try channel.tick()
        try expect(sent.count == before + 1, "One notification sends one command")
        try expect(AgentRelayStorage.receipt(id: command.id, directory: root)?.state == .pending,
            "Writing notification is pending, not accepted")
        try channel.tick()
        try expect(sent.count == before + 1, "Pending notification never retries")
        let meta = (sent.last?["params"] as? [String: Any])?["meta"] as! [String: String]
        forged = meta; forged["command_id"] = UUID().uuidString
        try expect(!channel.acknowledge(forged), "Wrong command acknowledgement rejected")
        try expect(channel.acknowledge(meta), "Exact request acknowledgement accepted")
        try expect(AgentRelayStorage.receipt(id: command.id, directory: root)?.state == .accepted, "Receipt means Claude acknowledged event")
        try expect(!channel.acknowledge(meta), "Duplicate acknowledgement is inert")
        let next = AgentMessageCommand(providerID: "claude", sessionID: value.id,
            revision: control.revision, createdAt: time.timeIntervalSince1970, text: "Synthetic timeout")
        try ClaudeMessagingStorage.enqueue(next, directory: root)
        try channel.tick()
        let count = sent.count
        time.addTimeInterval(26)
        try channel.tick()
        try expect(AgentRelayStorage.receipt(id: next.id, directory: root)?.state == .unknown, "Missing echo has honest unknown receipt")
        try expect(sent.count == count, "Ambiguous delivery never automatically resends")
        try expect(ClaudeMessagingStorage.control(session: value, directory: root, now: time)?.canPrompt == false,
            "Unknown channel delivery remains unavailable")
        channel.close()
        try expect(ClaudeMessagingStorage.control(session: value, directory: root, now: time) == nil,
            "Closed channel withdraws capability")
    }
}
