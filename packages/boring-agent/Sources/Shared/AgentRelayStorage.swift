// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Darwin

struct AgentProviderReport: Codable, Equatable, Sendable {
    var schemaVersion: Int = 1
    var providerID: String
    var updatedAt: Double = Date().timeIntervalSince1970
    var connected: Bool
    var sessions: [AgentSession] = []
    var usage: AgentUsageSnapshot? = nil
    var message: String? = nil
    var usageAccount: AgentUsageAccountStatus? = nil

    var isValid: Bool {
        schemaVersion == 1 && ClaudeValidation.identifier(providerID) &&
        updatedAt.isFinite && updatedAt > 0 && sessions.count <= 2000 &&
        sessions.allSatisfy { $0.providerID == providerID && $0.isValid } &&
        Set(sessions.map(\.nativeID)).count == sessions.count &&
        (message?.utf8.count ?? 0) <= 1024 && (usageAccount?.isValid ?? true) && (usage.map {
            $0.updatedAt.isFinite && $0.updatedAt > 0 && $0.windows.count <= 16 && $0.windows.allSatisfy(\.isValid)
        } ?? true)
    }
}

/// Private, bounded, atomic exchange between a native view and a helper.
/// Commands are claimed before dispatch. A crash after claim is ambiguous and
/// must never replay a prompt. Receipts contain status only, never prompt text.
enum AgentRelayStorage {
    static let maximumReportBytes = 4_194_304
    static let maximumCommands = 128

    static func prepare(directory: URL) throws {
        try ClaudeStorage.ensureDirectory(directory)
        for name in ["providers", "messages", "message-receipts"] {
            try ClaudeStorage.ensureDirectory(directory.appendingPathComponent(name))
        }
    }

    static func writeReport(_ report: AgentProviderReport, directory: URL) throws {
        guard report.isValid else { throw ClaudeStorageError.invalidRecord }
        try prepare(directory: directory)
        try ClaudeStorage.atomicWrite(JSONEncoder().encode(report),
            to: directory.appendingPathComponent("providers/\(report.providerID).json"), limit: maximumReportBytes)
    }

    static func report(providerID: String, directory: URL) throws -> AgentProviderReport? {
        guard ClaudeValidation.identifier(providerID) else { throw ClaudeStorageError.invalidRecord }
        try ClaudeStorage.checkDirectory(directory)
        let folder = directory.appendingPathComponent("providers")
        guard FileManager.default.fileExists(atPath: folder.path) else { return nil }
        try ClaudeStorage.checkDirectory(folder)
        let url = folder.appendingPathComponent(providerID + ".json")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let result = try JSONDecoder().decode(AgentProviderReport.self,
            from: ClaudeStorage.read(url, limit: maximumReportBytes))
        guard result.isValid, result.providerID == providerID else { throw ClaudeStorageError.invalidRecord }
        return result
    }

    static func submit(_ command: AgentMessageCommand, directory: URL, shouldSubmit: () -> Bool = { true }) throws {
        guard command.isValid else { throw ClaudeStorageError.invalidRecord }
        try prepare(directory: directory)
        try ClaudeStorage.locked(at: directory.appendingPathComponent(".messages.lock")) {
            guard shouldSubmit() else { throw CancellationError() }
            try expireCommands(directory: directory)
            let folder = directory.appendingPathComponent("messages")
            let paths = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            guard paths.count < maximumCommands else { throw ClaudeStorageError.full }
            let url = folder.appendingPathComponent(command.id + ".json")
            guard !FileManager.default.fileExists(atPath: url.path),
                  try receipt(id: command.id, directory: directory) == nil else { throw ClaudeStorageError.invalidRecord }
            guard shouldSubmit() else { throw CancellationError() }
            try ClaudeStorage.atomicWrite(JSONEncoder().encode(command), to: url)
        }
    }

    /// Claim only this provider's messages, optionally for one session. Other
    /// consumers can coexist without consuming each other's commands.
    static func takeCommands(providerID: String, sessionID: String? = nil, revision: String? = nil,
                             directory: URL) throws -> [AgentMessageCommand] {
        guard ClaudeValidation.identifier(providerID) else { throw ClaudeStorageError.invalidRecord }
        try prepare(directory: directory)
        return try ClaudeStorage.locked(at: directory.appendingPathComponent(".messages.lock")) {
            try expireCommands(directory: directory)
            let folder = directory.appendingPathComponent("messages")
            let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            var values: [AgentMessageCommand] = []
            for url in files.prefix(maximumCommands) where url.pathExtension == "json" {
                guard UUID(uuidString: url.deletingPathExtension().lastPathComponent) != nil,
                      let data = try? ClaudeStorage.read(url),
                      let command = try? JSONDecoder().decode(AgentMessageCommand.self, from: data),
                      command.isValid, command.id == url.deletingPathExtension().lastPathComponent,
                      command.providerID == providerID,
                      sessionID == nil || command.sessionID == sessionID,
                      revision == nil || command.revision == revision else { continue }
                // Persist an ambiguous receipt before deleting, fencing crash
                // recovery and duplicate UUID submissions across processes.
                if try receipt(id: command.id, directory: directory) == nil {
                    try writeReceipt(AgentMessageReceipt(id: command.id, sessionID: command.sessionID,
                        state: .pending, message: "Delivery is in progress."), directory: directory)
                    guard unlink(url.path) == 0 else { throw ClaudeStorageError.io }
                    values.append(command)
                } else { _ = unlink(url.path) }
            }
            return values.sorted { $0.createdAt < $1.createdAt }
        }
    }

    static func writeReceipt(_ value: AgentMessageReceipt, directory: URL) throws {
        guard value.isValid else { throw ClaudeStorageError.invalidRecord }
        let folder = directory.appendingPathComponent("message-receipts")
        try ClaudeStorage.checkDirectory(folder)
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])
        // Retain bounded status history for duplicate suppression. Stale commands
        // also fail the two-minute freshness guard at the owner boundary.
        if files.count >= 512 {
            for url in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                if let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                   Date().timeIntervalSince(modified) > 600 { _ = unlink(url.path) }
            }
            if try FileManager.default.contentsOfDirectory(atPath: folder.path).count >= 512,
               !FileManager.default.fileExists(atPath: folder.appendingPathComponent(value.id + ".json").path) {
                throw ClaudeStorageError.full
            }
        }
        try ClaudeStorage.atomicWrite(JSONEncoder().encode(value),
            to: folder.appendingPathComponent(value.id + ".json"))
    }

    /// Called under the messages lock. Expired commands cannot be delivered,
    /// even if a session reconnects later with the old capability revision.
    private static func expireCommands(directory: URL, now: Date = Date()) throws {
        let folder = directory.appendingPathComponent("messages")
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])
        for url in files.prefix(maximumCommands + 1) where url.pathExtension == "json" {
            guard UUID(uuidString: url.deletingPathExtension().lastPathComponent) != nil else { continue }
            if let bytes = try? ClaudeStorage.read(url),
               let command = try? JSONDecoder().decode(AgentMessageCommand.self, from: bytes),
               command.isValid, command.id == url.deletingPathExtension().lastPathComponent {
                guard now.timeIntervalSince1970 - command.createdAt > 120 || command.createdAt - now.timeIntervalSince1970 > 5 else { continue }
                try writeReceipt(AgentMessageReceipt(id: command.id, sessionID: command.sessionID,
                    state: .rejected, message: "The message expired before delivery. Review the session before sending again."), directory: directory)
                guard unlink(url.path) == 0 || errno == ENOENT else { throw ClaudeStorageError.io }
            } else if let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                      now.timeIntervalSince(modified) > 120 {
                _ = unlink(url.path)
            }
        }
    }

    static func receipt(id: String, directory: URL) throws -> AgentMessageReceipt? {
        guard UUID(uuidString: id) != nil else { throw ClaudeStorageError.invalidRecord }
        let folder = directory.appendingPathComponent("message-receipts")
        try ClaudeStorage.checkDirectory(folder)
        let url = folder.appendingPathComponent(id + ".json")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let value = try JSONDecoder().decode(AgentMessageReceipt.self, from: ClaudeStorage.read(url, limit: 4096))
        guard value.isValid, value.id == id else { throw ClaudeStorageError.invalidRecord }
        return value
    }

    /// One replaceable refresh request per provider; no growing queue, account
    /// credentials or automatic sign-in. The report acknowledges its UUID.
    @discardableResult
    static func requestUsageRefresh(providerID: String, directory: URL) throws -> String {
        guard ClaudeValidation.identifier(providerID) else { throw ClaudeStorageError.invalidRecord }
        try prepare(directory: directory)
        return try ClaudeStorage.locked(at: directory.appendingPathComponent(".usage-refresh.lock")) {
            try Task.checkCancellation()
            let request = AgentUsageRefreshRequest()
            try ClaudeStorage.atomicWrite(JSONEncoder().encode(request),
                to: directory.appendingPathComponent("usage-refresh-\(providerID).json"), limit: 1024)
            return request.id
        }
    }

    static func takeUsageRefresh(providerID: String, directory: URL, now: Date = Date()) throws -> AgentUsageRefreshRequest? {
        guard ClaudeValidation.identifier(providerID) else { throw ClaudeStorageError.invalidRecord }
        try ClaudeStorage.checkDirectory(directory)
        let path = directory.appendingPathComponent("usage-refresh-\(providerID).json")
        guard FileManager.default.fileExists(atPath: path.path) else { return nil }
        return try ClaudeStorage.locked(at: directory.appendingPathComponent(".usage-refresh.lock")) {
            guard let bytes = try? ClaudeStorage.read(path, limit: 1024) else { return nil }
            guard unlink(path.path) == 0 else { throw ClaudeStorageError.io }
            guard let request = try? JSONDecoder().decode(AgentUsageRefreshRequest.self, from: bytes),
                  request.isValid, (-5...120).contains(now.timeIntervalSince1970 - request.createdAt) else { return nil }
            return request
        }
    }
}
