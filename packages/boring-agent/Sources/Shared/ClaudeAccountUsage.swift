// SPDX-License-Identifier: GPL-3.0-only
import Foundation

enum ClaudeAccountUsagePhase: String, Codable, Sendable {
    case disabled, loading, ready, failed
}

enum ClaudeAccountUsageOperation: String, Codable, Sendable {
    case enable, disable, refresh
}

/// Sanitized account observations are separate from session hook records.
/// Credentials never enter this file, the plugin process, or the host ABI.
struct ClaudeAccountUsageRecord: Codable, Equatable, Sendable {
    var schemaVersion = 1
    var enabled: Bool
    var state: ClaudeAccountUsagePhase
    var message: String? = nil
    var report: AgentUsageSnapshot? = nil
    var accountKey: String? = nil
    var updatedAt: Double
    var nextRefreshAt: Double? = nil
    var lastRequestID: String? = nil

    var isValid: Bool {
        guard schemaVersion == 1, updatedAt.isFinite, updatedAt > 0,
              nextRefreshAt.map({ $0.isFinite && $0 > 0 }) ?? true,
              message.map({ $0.utf8.count <= 1024 }) ?? true,
              accountKey.map({ !$0.isEmpty && $0.utf8.count <= 256 }) ?? true else { return false }
        guard lastRequestID.map({ UUID(uuidString: $0) != nil }) ?? true else { return false }
        guard enabled || (state == .disabled && report == nil) else { return false }
        if let report {
            guard report.updatedAt.isFinite, report.updatedAt > 0,
                  report.planName.map({ $0.utf8.count <= 128 }) ?? true,
                  !report.windows.isEmpty, report.windows.count <= 16,
                  report.windows.allSatisfy(\.isValid),
                  Set(report.windows.map(\.id)).count == report.windows.count else { return false }
        }
        return state != .ready || report != nil
    }
}

struct ClaudeAccountUsageRequest: Codable, Equatable, Sendable {
    var schemaVersion = 1
    var id: String
    var operation: ClaudeAccountUsageOperation
    var createdAt: Double

    var isValid: Bool {
        schemaVersion == 1 && UUID(uuidString: id) != nil && createdAt.isFinite && createdAt > 0
    }
}
