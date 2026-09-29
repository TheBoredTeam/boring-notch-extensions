// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// Presentation describes only operations supported by the session's current
/// owner. An opaque revision binds a send to that owner, turn and request.
struct AgentSessionControl: Codable, Equatable, Sendable {
    var revision: String
    var canPrompt: Bool
    var request: AgentInputRequest? = nil
    var unavailableReason: String? = nil
    /// A provider may attach an independently verified process/transport lease.
    /// Keep it separate from the last activity timestamp and draft revision.
    var expiresAt: Double? = nil

    var isValid: Bool {
        !revision.isEmpty && revision.utf8.count <= 1024 &&
        (request?.isValid ?? true) && (unavailableReason?.utf8.count ?? 0) <= 1024 &&
        (expiresAt.map { $0.isFinite && $0 > 0 } ?? true)
    }

    func hasLiveLease(at now: Date) -> Bool {
        isValid && (expiresAt.map { $0 > now.timeIntervalSince1970 } ?? false)
    }

    func isExpired(at now: Date) -> Bool {
        expiresAt.map { !$0.isFinite || $0 <= now.timeIntervalSince1970 } ?? false
    }
}

struct AgentInputRequest: Codable, Equatable, Sendable {
    var id: String
    var questions: [AgentInputQuestion]
    var isValid: Bool {
        !id.isEmpty && id.utf8.count <= 256 && !questions.isEmpty && questions.count <= 4 &&
        questions.allSatisfy(\.isValid) && Set(questions.map(\.id)).count == questions.count
    }
}

struct AgentInputQuestion: Codable, Identifiable, Equatable, Sendable {
    var id: String
    var title: String
    var prompt: String
    var options: [String] = []
    var allowsMultiple: Bool = false
    var isSecret: Bool = false

    var isValid: Bool {
        !id.isEmpty && id.utf8.count <= 256 && title.utf8.count <= 256 &&
        !prompt.isEmpty && prompt.utf8.count <= 4096 && options.count <= 16 &&
        options.allSatisfy { !$0.isEmpty && $0.utf8.count <= 512 }
    }
}

/// UUIDs are idempotency identities, never permission to resend automatically.
/// A lost acknowledgement is ambiguous; the user must inspect the session.
struct AgentMessageCommand: Codable, Equatable, Sendable {
    var id: String = UUID().uuidString
    var providerID: String
    var sessionID: String
    var revision: String
    var createdAt: Double = Date().timeIntervalSince1970
    var text: String? = nil
    var answers: [String: [String]] = [:]
    var requestID: String? = nil

    static let maximumTextBytes = 16_384
    var isValid: Bool {
        guard UUID(uuidString: id) != nil, ClaudeValidation.identifier(providerID),
              !sessionID.isEmpty, sessionID.utf8.count <= 256,
              !revision.isEmpty, revision.utf8.count <= 1024,
              createdAt.isFinite, createdAt > 0 else { return false }
        if let requestID {
            return !requestID.isEmpty && requestID.utf8.count <= 256 && text == nil &&
                !answers.isEmpty && answers.count <= 4 && answers.allSatisfy { key, values in
                    !key.isEmpty && key.utf8.count <= 256 && !values.isEmpty && values.count <= 16 &&
                    values.allSatisfy { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                        $0.utf8.count <= Self.maximumTextBytes }
                } && answers.values.flatMap { $0 }.reduce(0, { $0 + $1.utf8.count }) <= Self.maximumTextBytes
        }
        guard answers.isEmpty, let text else { return false }
        return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            text.utf8.count <= Self.maximumTextBytes && !text.contains("\0")
    }

    func matches(_ control: AgentSessionControl, now: Date = Date()) -> Bool {
        guard isValid, control.isValid, !control.isExpired(at: now), revision == control.revision,
              (-5...120).contains(now.timeIntervalSince1970 - createdAt) else { return false }
        if let requestID {
            guard let request = control.request, request.id == requestID,
                  Set(answers.keys) == Set(request.questions.map(\.id)) else { return false }
            return request.questions.allSatisfy { question in
                guard !question.isSecret, let values = answers[question.id] else { return false }
                return question.allowsMultiple || values.count == 1
            }
        }
        return control.canPrompt && control.request == nil
    }
}

enum AgentMessageDelivery: String, Codable, Sendable { case pending, accepted, rejected, unknown }

struct AgentMessageReceipt: Codable, Equatable, Sendable {
    var id: String
    var sessionID: String
    var state: AgentMessageDelivery
    var message: String
    var updatedAt: Double = Date().timeIntervalSince1970

    var isValid: Bool {
        UUID(uuidString: id) != nil && !sessionID.isEmpty && sessionID.utf8.count <= 256 &&
        !message.isEmpty && message.utf8.count <= 1024 && updatedAt.isFinite && updatedAt > 0
    }
}

/// Kept in memory and keyed by provider + native session. Never persisted in
/// preferences, diagnostics, transcript files or a shared global text field.
struct AgentMessageDraft: Equatable {
    var revision: String
    var text = ""
    var answers: [String: [String]] = [:]
    var requestID: String? = nil
}

struct AgentMessageStatus: Equatable {
    var commandID: String
    var revision: String
    var requestID: String?
    var pending: Bool
    var delivery: AgentMessageDelivery? = nil
    var message: String
}
