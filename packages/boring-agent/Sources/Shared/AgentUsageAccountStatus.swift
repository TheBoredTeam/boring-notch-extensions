// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// Subscription authentication is independent from the owner of a live session.
/// A connected Azure/API session does not imply a ChatGPT subscription login.
struct AgentUsageAccountStatus: Codable, Equatable, Sendable {
    enum State: String, Codable, Sendable { case connected, signInRequired, unavailable, failed }
    var state: State
    var message: String
    var signInCommand: String? = nil
    var refreshRequestID: String? = nil
    var isRefreshing: Bool = false

    var isValid: Bool {
        !message.isEmpty && message.utf8.count <= 1024 && !message.contains("\0") &&
        (signInCommand.map { !$0.isEmpty && $0.utf8.count <= 16_384 && !$0.contains("\0") } ?? true) &&
        (refreshRequestID.map { UUID(uuidString: $0) != nil } ?? true)
    }
}

struct AgentUsageRefreshRequest: Codable, Equatable, Sendable {
    var id: String = UUID().uuidString
    var createdAt: Double = Date().timeIntervalSince1970
    var isValid: Bool { UUID(uuidString: id) != nil && createdAt.isFinite && createdAt > 0 }
}
