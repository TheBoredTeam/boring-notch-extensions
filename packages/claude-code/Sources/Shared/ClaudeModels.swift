// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import CoreFoundation

enum SessionPhase: String, Codable, Sendable { case working, needsInput, idle, ended }

struct ClaudeQuotaWindow: Codable, Sendable {
    var remainingPercent: Double
    var resetsAt: Double?
}

struct ClaudeUsage: Codable, Sendable {
    var updatedAt: Double
    var fiveHour: ClaudeQuotaWindow?
    var sevenDay: ClaudeQuotaWindow?
    var contextRemaining: Double?
}

struct ClaudeOrigin: Codable, Sendable {
    var claudePID: Int32? = nil
    var processStartTime: Double? = nil
    var appBundleID: String? = nil
    var appPath: String? = nil
    var tty: String? = nil
    var remoteSessionID: String? = nil
}

struct ClaudeSession: Codable, Identifiable, Sendable {
    var schemaVersion: Int = 1
    var id: String
    var project: String
    var directory: String
    var phase: SessionPhase
    var createdAt: Double
    var updatedAt: Double
    var model: String? = nil
    var question: String? = nil
    var questionOptions: [String] = []
    var attentionKind: String? = nil
    var toolName: String? = nil
    var usage: ClaudeUsage? = nil
    var origin: ClaudeOrigin = ClaudeOrigin()
}

struct ClaudeFocusRequest: Codable, Sendable {
    var schemaVersion: Int = 1
    var id: String
    var sessionID: String
    var createdAt: Double
}

struct ClaudeFocusReceipt: Codable, Sendable {
    var schemaVersion: Int = 1
    var sessionID: String
    var status: String
    var message: String
    var updatedAt: Double
}

enum ClaudeValidation {
    static func identifier(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 128 && value.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95
        }
    }

    static func remoteID(_ value: String) -> Bool {
        value.hasPrefix("session_") && value.count > 8 && identifier(value)
    }

    static func text(_ value: Any?, limit: Int, multiline: Bool = false) -> String? {
        guard let source = value as? String else { return nil }
        let scalars = source.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0) || (multiline && $0 == "\n")
        }.filter { ![0x202A, 0x202B, 0x202C, 0x202D, 0x202E, 0x2066, 0x2067, 0x2068, 0x2069].contains($0.value) }
        var result = String(String.UnicodeScalarView(scalars)).trimmingCharacters(in: .whitespacesAndNewlines)
        while result.utf8.count > limit { result.removeLast() }
        return result.isEmpty ? nil : result
    }

    static func percentage(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let result = number.doubleValue
        return result.isFinite && (0...100).contains(result) ? result : nil
    }

    static func valid(_ session: ClaudeSession) -> Bool {
        guard session.schemaVersion == 1, identifier(session.id), session.createdAt.isFinite,
              session.updatedAt.isFinite, session.createdAt > 0, session.updatedAt > 0,
              text(session.project, limit: 256) == session.project,
              session.directory.hasPrefix("/"), session.directory.utf8.count <= 4096,
              text(session.directory, limit: 4096) == session.directory,
              session.model.map({ text($0, limit: 256) == $0 }) ?? true,
              session.question.map({ text($0, limit: 4096, multiline: true) == $0 }) ?? true,
              session.questionOptions.count <= 16,
              session.questionOptions.allSatisfy({ text($0, limit: 256) == $0 }),
              session.attentionKind.map({ text($0, limit: 64) == $0 }) ?? true,
              session.toolName.map({ text($0, limit: 128) == $0 }) ?? true,
              (session.origin.appBundleID?.utf8.count ?? 0) <= 256,
              (session.origin.appPath?.utf8.count ?? 0) <= 4096,
              (session.origin.tty?.utf8.count ?? 0) <= 128,
              session.origin.remoteSessionID.map(remoteID) ?? true,
              session.origin.processStartTime?.isFinite ?? true else { return false }
        if let usage = session.usage {
            guard usage.updatedAt.isFinite, usage.updatedAt > 0,
                  usage.contextRemaining.map({ $0.isFinite && (0...100).contains($0) }) ?? true else { return false }
            for window in [usage.fiveHour, usage.sevenDay].compactMap({ $0 }) {
                guard window.remainingPercent.isFinite, (0...100).contains(window.remainingPercent),
                      window.resetsAt.map({ $0.isFinite && $0 > 0 }) ?? true else { return false }
            }
        }
        return true
    }
}
