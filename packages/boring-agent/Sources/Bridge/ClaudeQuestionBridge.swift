// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import CoreFoundation

/// Only AskUserQuestion has this bridge. Permission decisions, plan approvals,
/// MCP elicitation and an already-open terminal prompt are never intercepted.
enum ClaudeQuestionBridge {
    struct Pending {
        var sessionID: String
        var request: AgentInputRequest
        var originalInput: [String: Any]
        var originalQuestions: [String]
    }

    static func parse(_ input: Data) throws -> Pending? {
        guard input.count <= ClaudeStorage.maximumRecordBytes,
              let object = try JSONSerialization.jsonObject(with: input) as? [String: Any],
              object["agent_id"] == nil,
              object["hook_event_name"] as? String == "PreToolUse",
              object["tool_name"] as? String == "AskUserQuestion",
              let sessionID = object["session_id"] as? String, ClaudeValidation.identifier(sessionID),
              let requestID = object["tool_use_id"] as? String, ClaudeValidation.identifier(requestID),
              let toolInput = object["tool_input"] as? [String: Any], toolInput["answers"] == nil,
              let questions = toolInput["questions"] as? [[String: Any]], (1...4).contains(questions.count)
        else { return nil }
        var result: [AgentInputQuestion] = []
        var originals: [String] = []
        for (index, question) in questions.enumerated() {
            guard let prompt = question["question"] as? String,
                  ClaudeValidation.text(prompt, limit: 1024, multiline: true) == prompt,
                  !isSecret(question: question, prompt: prompt),
                  let choices = question["options"] as? [[String: Any]], (2...4).contains(choices.count)
            else { return nil }
            let title = question["header"] as? String ?? "Question \(index + 1)"
            guard ClaudeValidation.text(title, limit: 64) == title else { return nil }
            var labels: [String] = []
            for choice in choices {
                guard let label = choice["label"] as? String,
                      ClaudeValidation.text(label, limit: 256) == label else { return nil }
                labels.append(label)
            }
            guard Set(labels).count == labels.count else { return nil }
            var multiple = false
            if let flag = question["multiSelect"] {
                guard let value = flag as? NSNumber, CFGetTypeID(value) == CFBooleanGetTypeID() else { return nil }
                multiple = value.boolValue
            }
            result.append(AgentInputQuestion(id: "q\(index)", title: title, prompt: prompt,
                options: labels, allowsMultiple: multiple))
            originals.append(prompt)
        }
        // Claude's documented answers map is keyed by question text. Duplicates
        // cannot be addressed independently and must stay in the original UI.
        guard Set(originals).count == originals.count else { return nil }
        return Pending(sessionID: sessionID, request: AgentInputRequest(id: requestID, questions: result),
            originalInput: toolInput, originalQuestions: originals)
    }

    static func isSecret(question: [String: Any], prompt: String) -> Bool {
        if question["isSecret"] as? Bool == true || question["secret"] as? Bool == true ||
            question["type"] as? String == "password" { return true }
        // AskUserQuestion currently has no standard secret field. Conservatively
        // leave common credential requests in Claude; this is not a classifier
        // that can certify arbitrary natural-language text as non-sensitive.
        return prompt.range(of: #"(?i)\b(password|passphrase|api[ _-]?key|access[ _-]?token|secret|credential|private[ _-]?key|recovery[ _-]?(code|phrase)|seed[ _-]?phrase)\b"#,
            options: .regularExpression) != nil
    }

    static func output(for command: AgentMessageCommand, pending: Pending, control: AgentSessionControl,
                       now: Date = Date()) throws -> Data? {
        guard command.providerID == ClaudeMessagingStorage.providerID,
              command.sessionID == pending.sessionID, command.matches(control, now: now),
              command.requestID == pending.request.id else { return nil }
        var answers: [String: String] = [:]
        for (index, question) in pending.request.questions.enumerated() {
            guard let values = command.answers[question.id],
                  values.allSatisfy({ !$0.contains("\0") && ClaudeValidation.text($0,
                    limit: AgentMessageCommand.maximumTextBytes, multiline: true) == $0 }),
                  Set(values).count == values.count else { return nil }
            // Multiple selections use the exact comma-separated representation
            // documented by Claude. Comma-containing choices are ambiguous.
            if values.count > 1 && values.contains(where: { $0.contains(",") }) { return nil }
            answers[pending.originalQuestions[index]] = values.joined(separator: ", ")
        }
        var updated = pending.originalInput
        updated["answers"] = answers
        return try JSONSerialization.data(withJSONObject: ["hookSpecificOutput": [
            "hookEventName": "PreToolUse", "permissionDecision": "allow", "updatedInput": updated]])
    }

    /// No output on disable, stale origin, unsupported input or timeout: Claude
    /// proceeds to its untouched original question. The waiting hook is bounded
    /// and may be interrupted normally from Claude's original session.
    @discardableResult
    static func run(input: Data, directory: URL, origin: ClaudeOrigin, timeout: TimeInterval = 90,
                    now: () -> Date = Date.init,
                    pause: (TimeInterval) -> Void = Thread.sleep(forTimeInterval:),
                    verifyOrigin: (ClaudeOrigin) -> Bool = ClaudeOriginResolver.verified,
                    emit: (Data) throws -> Void = { try FileHandle.standardOutput.write(contentsOf: $0) }) throws -> Bool {
        guard ClaudeMessagingStorage.questionsEnabled(directory: directory),
              ClaudeMessagingStorage.questionClientActive(directory: directory, now: now()),
              let pending = try parse(input), verifyOrigin(origin),
              let pid = origin.claudePID, let started = origin.processStartTime,
              let helperStarted = ClaudeMessagingStorage.processStart(ProcessInfo.processInfo.processIdentifier)
        else { return false }
        try ClaudeMessagingStorage.prepare(directory: directory)
        var endpoint = ClaudeMessagingEndpoint(sessionID: pending.sessionID, helperStartedAt: helperStarted,
            claudePID: pid, claudeStartedAt: started, updatedAt: now().timeIntervalSince1970,
            ready: true, request: pending.request)
        guard try ClaudeMessagingStorage.claim(endpoint, kind: "question", directory: directory) else { return false }
        defer { ClaudeMessagingStorage.remove(sessionID: pending.sessionID, kind: "question", revision: endpoint.revision, directory: directory) }
        let deadline = now().addingTimeInterval(min(max(timeout, 0), 90))
        var heartbeat = now()
        let control = AgentSessionControl(revision: endpoint.revision, canPrompt: false, request: pending.request)
        while now() < deadline {
            guard ClaudeMessagingStorage.questionsEnabled(directory: directory),
                  ClaudeMessagingStorage.questionClientActive(directory: directory, now: now()), verifyOrigin(origin),
                  let current = try ClaudeMessagingStorage.endpoint(sessionID: pending.sessionID, kind: "question", directory: directory),
                  current.revision == endpoint.revision else { return false }
            let commands = try AgentRelayStorage.takeCommands(providerID: ClaudeMessagingStorage.providerID,
                sessionID: pending.sessionID, revision: endpoint.revision, directory: directory)
            var chosen: (AgentMessageCommand, Data)?
            for command in commands {
                if chosen == nil, let data = try output(for: command, pending: pending, control: control, now: now()) {
                    chosen = (command, data)
                } else {
                    try AgentRelayStorage.writeReceipt(AgentMessageReceipt(id: command.id, sessionID: pending.sessionID,
                        state: .rejected, message: "This question changed or already has a reply. Answer it in Claude."), directory: directory)
                }
            }
            if let (command, data) = chosen {
                // Recheck after claiming so a local answer, disable, termination
                // or a newer question cannot acquire an old reply.
                guard ClaudeMessagingStorage.questionsEnabled(directory: directory),
                      ClaudeMessagingStorage.questionClientActive(directory: directory, now: now()), verifyOrigin(origin),
                      let current = try ClaudeMessagingStorage.endpoint(sessionID: pending.sessionID, kind: "question", directory: directory),
                      current.revision == endpoint.revision else {
                    try AgentRelayStorage.writeReceipt(AgentMessageReceipt(id: command.id, sessionID: pending.sessionID,
                        state: .rejected, message: "The question is no longer waiting for this reply."), directory: directory)
                    return false
                }
                do {
                    let passed = try ClaudeStorage.locked(at: directory.appendingPathComponent(".claude-messaging.lock")) {
                        guard ClaudeMessagingStorage.questionsEnabled(directory: directory),
                              ClaudeMessagingStorage.questionClientActive(directory: directory, now: now()), verifyOrigin(origin),
                              let active = try ClaudeMessagingStorage.endpoint(sessionID: pending.sessionID, kind: "question", directory: directory),
                              active.revision == endpoint.revision else { return false }
                        try emit(data + Data([10]))
                        return true
                    }
                    guard passed else {
                        try AgentRelayStorage.writeReceipt(AgentMessageReceipt(id: command.id, sessionID: pending.sessionID,
                            state: .rejected, message: "The question is no longer waiting for this reply."), directory: directory)
                        return false
                    }
                    try AgentRelayStorage.writeReceipt(AgentMessageReceipt(id: command.id, sessionID: pending.sessionID,
                        state: .accepted, message: "Reply passed to Claude."), directory: directory)
                    return true
                } catch {
                    try? AgentRelayStorage.writeReceipt(AgentMessageReceipt(id: command.id, sessionID: pending.sessionID,
                        state: .unknown, message: "Reply delivery could not be confirmed. Check Claude before trying again."), directory: directory)
                    throw error
                }
            }
            if now().timeIntervalSince(heartbeat) >= 2 {
                endpoint.updatedAt = now().timeIntervalSince1970
                guard try ClaudeMessagingStorage.refresh(endpoint, kind: "question", directory: directory) else { return false }
                heartbeat = now()
            }
            pause(0.15)
        }
        return false
    }
}
