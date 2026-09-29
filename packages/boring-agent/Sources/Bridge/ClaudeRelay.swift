// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import CoreFoundation

enum ClaudeRelay {
    static let maximumInputBytes = 1_048_576
    static let hookEvents = ["SessionStart", "UserPromptSubmit", "PreToolUse", "PermissionRequest",
                             "PostToolUse", "PostToolUseFailure", "Notification", "Stop", "StopFailure", "SessionEnd"]

    static func ingest(_ data: Data, directory: URL, statusline: Bool = false,
                       origin: ClaudeOrigin = ClaudeOrigin(), now: Double = Date().timeIntervalSince1970) throws {
        guard data.count <= maximumInputBytes else { throw ClaudeStorageError.tooLarge }
        guard let input = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = input["session_id"] as? String, ClaudeValidation.identifier(id),
              now.isFinite && now > 0 else { throw ClaudeStorageError.invalidRecord }
        if input["agent_id"] != nil { return }
        let event = input["hook_event_name"] as? String ?? ""
        guard statusline || hookEvents.contains(event) else { return }
        try ClaudeStorage.update(id: id, directory: directory) { previous in
            guard let cwd = ClaudeValidation.text(input["cwd"] ?? (input["workspace"] as? [String: Any])?["current_dir"], limit: 4096),
                  cwd.hasPrefix("/") else { throw ClaudeStorageError.invalidRecord }
            let folder = URL(fileURLWithPath: cwd).lastPathComponent
            var session = previous ?? ClaudeSession(id: id,
                project: ClaudeValidation.text(folder, limit: 256) ?? "Project", directory: cwd,
                phase: .idle, createdAt: now, updatedAt: now)
            session.directory = cwd
            session.project = ClaudeValidation.text(folder, limit: 256) ?? "Project"
            session.updatedAt = max(session.updatedAt, now)
            if origin.claudePID != nil { session.origin = origin }
            else if origin.remoteSessionID != nil { session.origin.remoteSessionID = origin.remoteSessionID }
            if let model = input["model"] as? [String: Any] {
                session.model = ClaudeValidation.text(model["display_name"] ?? model["id"], limit: 256)
            } else if let model = ClaudeValidation.text(input["model"], limit: 256) { session.model = model }
            if statusline {
                session.usage = usage(input, now: now)
                return session // A usage refresh must never acknowledge or replace a question.
            }
            switch event {
            case "SessionStart":
                if input["source"] as? String != "compact" { clearAttention(&session, phase: .idle) }
            case "UserPromptSubmit": clearAttention(&session, phase: .working)
            case "PreToolUse":
                let tool = ClaudeValidation.text(input["tool_name"], limit: 128)
                if tool == "AskUserQuestion" {
                    let arguments = input["tool_input"] as? [String: Any]
                    let questions = (arguments?["questions"] as? [[String: Any]] ?? []).prefix(4)
                    let text = questions.compactMap { ClaudeValidation.text($0["question"], limit: 1024, multiline: true) }
                    session.question = ClaudeValidation.text(text.joined(separator: "\n\n"), limit: 4096, multiline: true) ?? "Claude has a question."
                    session.questionOptions = Array(questions.flatMap { question in
                        (question["options"] as? [[String: Any]] ?? []).prefix(4).compactMap {
                            ClaudeValidation.text($0["label"], limit: 256)
                        }
                    }.prefix(16))
                    session.phase = .needsInput
                    session.attentionKind = "question"
                    session.toolName = tool
                } else if session.phase != .needsInput {
                    session.phase = .working
                    session.toolName = tool
                }
            case "PermissionRequest":
                if session.attentionKind != "question" {
                    let tool = ClaudeValidation.text(input["tool_name"], limit: 128) ?? "a tool"
                    session.question = "Claude needs permission to use \(tool)."
                    session.questionOptions = []
                    session.attentionKind = "permission"
                    session.toolName = tool
                    session.phase = .needsInput
                }
            case "PostToolUse", "PostToolUseFailure":
                let tool = ClaudeValidation.text(input["tool_name"], limit: 128)
                if session.phase != .needsInput || tool == session.toolName {
                    clearAttention(&session, phase: .working)
                }
            case "Notification":
                let kind = input["notification_type"] as? String ?? ""
                if kind == "idle_prompt" { if session.phase != .needsInput { session.phase = .idle } }
                else if ["permission_prompt", "elicitation_dialog", "elicitation_url_dialog", "agent_needs_input"].contains(kind) {
                    if session.attentionKind != "question" {
                        session.question = kind == "permission_prompt" ? "Claude needs your permission." : "Claude needs your input."
                        session.questionOptions = []
                        session.attentionKind = kind == "permission_prompt" ? "permission" : "question"
                        session.phase = .needsInput
                    }
                }
            case "Stop": clearAttention(&session, phase: .idle)
            case "StopFailure":
                clearAttention(&session, phase: .needsInput)
                let knownErrors = ["rate_limit", "overloaded", "authentication_failed", "billing_error", "server_error"]
                let kind = input["error"] as? String ?? ""
                session.attentionKind = "error"
                session.question = kind == "rate_limit" ? "Claude reached a usage limit." : "Claude stopped with an error. Open the session for details."
                session.toolName = knownErrors.contains(kind) ? kind : nil
            case "SessionEnd": clearAttention(&session, phase: .ended)
            default: break
            }
            return session
        }
    }

    static func clearAttention(_ session: inout ClaudeSession, phase: SessionPhase) {
        session.phase = phase
        session.question = nil
        session.questionOptions = []
        session.attentionKind = nil
        session.toolName = nil
    }

    static func usage(_ input: [String: Any], now: Double) -> ClaudeUsage {
        let quotas = input["rate_limits"] as? [String: Any] ?? [:]
        func window(_ key: String) -> ClaudeQuotaWindow? {
            guard let value = quotas[key] as? [String: Any], let used = ClaudeValidation.percentage(value["used_percentage"]) else { return nil }
            let reset = value["resets_at"] as? NSNumber
            let resetValue = reset?.doubleValue
            return ClaudeQuotaWindow(remainingPercent: 100 - used,
                resetsAt: resetValue.flatMap { $0.isFinite && $0 > 0 ? $0 : nil })
        }
        return ClaudeUsage(updatedAt: now, fiveHour: window("five_hour"), sevenDay: window("seven_day"),
                           contextRemaining: ClaudeValidation.percentage((input["context_window"] as? [String: Any])?["remaining_percentage"]))
    }
}
