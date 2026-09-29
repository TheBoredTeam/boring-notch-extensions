// SPDX-License-Identifier: GPL-3.0-only
import Foundation

enum AgentDashboardSection: String, CaseIterable, Sendable {
    case progress, usage

    var title: String { self == .progress ? "Progress" : "Usage" }
}

struct AgentAccentRGB: Equatable, Sendable {
    var red: Double
    var green: Double
    var blue: Double
}

/// Product identity belongs to an adapter. Provider-specific artwork and
/// application identifiers never enter the host's generic extension API.
struct AgentProviderDescriptor: Identifiable, Equatable, Sendable {
    var id: String
    var title: String
    var shortName: String
    var symbol: String
    var logoResource: String? = nil
    var applicationBundleID: String? = nil
    var accentRGB: AgentAccentRGB
}

enum AgentConnection: Equatable, Sendable {
    case connected
    case disconnected
    case unavailable(String)
    case failed(String)

    var label: String {
        switch self {
        case .connected: return "Connected"
        case .disconnected: return "Not connected"
        case .unavailable: return "Unavailable"
        case .failed: return "Needs attention"
        }
    }

    var message: String? {
        switch self {
        case .unavailable(let reason), .failed(let reason): return reason
        case .connected, .disconnected: return nil
        }
    }

    var canConfigure: Bool {
        if case .unavailable = self { return false }
        return true
    }

    var isConnected: Bool { self == .connected }
}

/// Account allowance only. Session context usage is intentionally represented
/// on AgentSession and must never be substituted for a quota window.
struct AgentQuotaWindow: Identifiable, Codable, Equatable, Sendable {
    var id: String
    var title: String
    var remainingPercent: Double
    var resetsAt: Double? = nil
    var contributesToOverall: Bool = true

    var isValid: Bool {
        !id.isEmpty && id.utf8.count <= 128 && !title.isEmpty && title.utf8.count <= 256 &&
        remainingPercent.isFinite && (0...100).contains(remainingPercent) &&
        (resetsAt.map { $0.isFinite && $0 > 0 } ?? true)
    }
}

struct AgentUsageSnapshot: Codable, Equatable, Sendable {
    var updatedAt: Double
    var planName: String? = nil
    var windows: [AgentQuotaWindow]

    /// The least remaining allowance is the binding limit. An unavailable
    /// report is nil; a real exhausted quota is zero.
    var limitingRemainingPercent: Double? {
        guard updatedAt.isFinite, updatedAt > 0 else { return nil }
        return windows.lazy.filter { $0.isValid && $0.contributesToOverall }.map(\.remainingPercent).min()
    }

    func isStale(at now: Date) -> Bool {
        now.timeIntervalSince1970 - updatedAt > 300 || windows.contains {
            $0.resetsAt.map { $0 <= now.timeIntervalSince1970 } ?? false
        }
    }
}

/// Stable IDs include the provider so two tools reporting the same native
/// session ID cannot share selection or receive one another's commands.
struct AgentSession: Identifiable, Equatable, Sendable {
    var providerID: String
    var nativeID: String
    var project: String
    var directory: String
    var phase: SessionPhase
    var createdAt: Double
    var updatedAt: Double
    var model: String? = nil
    var question: String? = nil
    var questionOptions: [String] = []
    var contextRemaining: Double? = nil

    var id: String { providerID + ":" + nativeID }

    var isValid: Bool {
        !providerID.isEmpty && providerID.utf8.count <= 128 && !providerID.contains(":") &&
        !nativeID.isEmpty && nativeID.utf8.count <= 256 &&
        !project.isEmpty && project.utf8.count <= 256 && directory.utf8.count <= 4096 &&
        createdAt.isFinite && createdAt > 0 && updatedAt.isFinite && updatedAt > 0 &&
        (model?.utf8.count ?? 0) <= 256 && (question?.utf8.count ?? 0) <= 4096 &&
        questionOptions.count <= 16 && questionOptions.allSatisfy { $0.utf8.count <= 256 } &&
        (contextRemaining.map { $0.isFinite && (0...100).contains($0) } ?? true)
    }
}

struct AgentProviderSnapshot: Identifiable, Equatable, Sendable {
    var descriptor: AgentProviderDescriptor
    var connection: AgentConnection
    var sessions: [AgentSession] = []
    var usage: AgentUsageSnapshot? = nil
    var setupCommand: String? = nil
    var message: String? = nil
    var relayDirectory: String? = nil
    var usageConnection: AgentConnection? = nil
    var usageIsRefreshing: Bool = false

    var id: String { descriptor.id }
}
