// SPDX-License-Identifier: GPL-3.0-only
import Combine
import Foundation

/// Each integration owns its authentication, observation, and native handoff.
/// Only normalized presentation data is shared with the dashboard. An adapter
/// never asks the host to understand its product's storage or credentials.
@MainActor
protocol AgentProviderAdapter: AnyObject {
    var descriptor: AgentProviderDescriptor { get }
    var snapshot: AgentProviderSnapshot { get }
    var onChange: (() -> Void)? { get set }
    func start()
    func stop()
    func updateClock(_ now: Date)
    func refresh()
    func connect()
    func disconnect()
    func selectSession(nativeID: String)
    func openSession(nativeID: String)
    func openOriginApp(nativeID: String)
    func copyResumeCommand(nativeID: String)
    func copySetupCommand()
    func connectUsage()
    func disconnectUsage()
    func refreshUsage()
}

extension AgentProviderAdapter {
    func updateClock(_ now: Date) {}
    func selectSession(nativeID: String) {}
    func connectUsage() {}
    func disconnectUsage() {}
    func refreshUsage() {}
}

enum AgentProviderDescriptors {
    static let claude = AgentProviderDescriptor(
        id: "claude", title: "Claude Code", shortName: "Claude", symbol: "sparkle",
        logoResource: "ClaudeLogo", applicationBundleID: "com.anthropic.claudefordesktop",
        accentRGB: AgentAccentRGB(red: 0.89, green: 0.55, blue: 0.35))
    static let codex = AgentProviderDescriptor(
        id: "codex", title: "Codex", shortName: "Codex", symbol: "terminal",
        applicationBundleID: "com.openai.codex",
        accentRGB: AgentAccentRGB(red: 0.56, green: 0.62, blue: 0.93))
    static let antigravity = AgentProviderDescriptor(
        id: "antigravity", title: "Antigravity", shortName: "Antigravity", symbol: "sparkles",
        applicationBundleID: "com.google.antigravity",
        accentRGB: AgentAccentRGB(red: 0.40, green: 0.67, blue: 0.91))
}

@MainActor
enum AgentProviderRegistry {
    static func makeDefaultAdapters() -> [any AgentProviderAdapter] {
        [ClaudeAgentProviderAdapter(),
         UnavailableAgentProviderAdapter(descriptor: AgentProviderDescriptors.codex),
         UnavailableAgentProviderAdapter(descriptor: AgentProviderDescriptors.antigravity)]
    }
}

/// Honest extension points: these adapters perform no discovery, requests,
/// account scraping, or credential access until a real integration exists.
@MainActor
final class UnavailableAgentProviderAdapter: AgentProviderAdapter {
    let descriptor: AgentProviderDescriptor
    let snapshot: AgentProviderSnapshot
    var onChange: (() -> Void)?

    init(descriptor: AgentProviderDescriptor) {
        self.descriptor = descriptor
        let explanation = "The \(descriptor.shortName) integration is not available yet. Claude is supported in this preview."
        snapshot = AgentProviderSnapshot(descriptor: descriptor, connection: .unavailable(explanation), message: explanation)
    }

    func start() {}
    func stop() { onChange = nil }
    func refresh() {}
    func connect() {}
    func disconnect() {}
    func openSession(nativeID: String) {}
    func openOriginApp(nativeID: String) {}
    func copyResumeCommand(nativeID: String) {}
    func copySetupCommand() {}
}

/// Reuses the verified Claude relay and its saved bookmark. Claude's file
/// schema, helper, preferences namespace, and focus broker remain unchanged.
@MainActor
final class ClaudeAgentProviderAdapter: AgentProviderAdapter {
    let descriptor = AgentProviderDescriptors.claude
    private(set) var snapshot: AgentProviderSnapshot
    var onChange: (() -> Void)?

    private let backend: ClaudePluginState
    private var subscriptions: Set<AnyCancellable> = []
    private var nativeSessions: [String: ClaudeSession] = [:]
    private var projectedSessions: [AgentSession] = []
    private var latestActualUsage: AgentUsageSnapshot?
    private var publication: DispatchWorkItem?
    private var generation = UUID()
    private var isActive = true
    private var started = false

    init(backend: ClaudePluginState? = nil) {
        self.backend = backend ?? ClaudePluginState()
        snapshot = AgentProviderSnapshot(descriptor: AgentProviderDescriptors.claude,
                                         connection: .disconnected,
                                         setupCommand: ClaudePluginResources.setupCommand)
    }

    func start() {
        guard isActive, !started else { return }
        started = true
        backend.$sessions.sink { [weak self] values in
            self?.ingestSessions(values)
            self?.schedulePublication()
        }.store(in: &subscriptions)
        backend.$connection.sink { [weak self] connection in
            if connection == .disconnected { self?.latestActualUsage = nil }
            self?.schedulePublication()
        }.store(in: &subscriptions)
        backend.$directory.sink { [weak self] _ in self?.schedulePublication() }.store(in: &subscriptions)
        backend.$actionMessage.sink { [weak self] _ in self?.schedulePublication() }.store(in: &subscriptions)
        backend.$accountUsage.sink { [weak self] _ in self?.schedulePublication() }.store(in: &subscriptions)
        backend.$accountUsageError.sink { [weak self] _ in self?.schedulePublication() }.store(in: &subscriptions)
        backend.$accountUsageReadError.sink { [weak self] _ in self?.schedulePublication() }.store(in: &subscriptions)
        backend.$accountUsageRequestPending.sink { [weak self] _ in self?.schedulePublication() }.store(in: &subscriptions)
        backend.start(managesClock: false)
        publish()
    }

    private func ingestSessions(_ values: [ClaudeSession]) {
        // ClaudeStorage already returns a bounded, priority-ordered registry.
        let bounded = Array(values.prefix(AgentDashboardState.maximumSessionsPerProvider))
        nativeSessions = Dictionary(bounded.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        projectedSessions = bounded.map {
            AgentSession(providerID: descriptor.id, nativeID: $0.id, project: $0.project,
                         directory: $0.directory, phase: $0.phase, createdAt: $0.createdAt,
                         updatedAt: $0.updatedAt, model: $0.model, question: $0.question,
                         questionOptions: $0.questionOptions, contextRemaining: $0.usage?.contextRemaining)
        }
        if let observation = Self.projectUsage(from: bounded),
           latestActualUsage.map({ observation.updatedAt >= $0.updatedAt }) ?? true {
            latestActualUsage = observation
        }
    }

    /// One account report wins by its own observation time. Do not add quotas
    /// across sessions or fill missing windows from a different report. A later
    /// context-only update does not erase the last observed account allowance.
    static func projectUsage(from sessions: [ClaudeSession]) -> AgentUsageSnapshot? {
        var winner: (sessionID: String, usage: AgentUsageSnapshot)?
        for session in sessions {
            guard let usage = session.usage, usage.updatedAt.isFinite, usage.updatedAt > 0 else { continue }
            var windows: [AgentQuotaWindow] = []
            if let value = usage.fiveHour {
                let window = AgentQuotaWindow(id: "five-hour", title: "5-hour limit",
                                              remainingPercent: value.remainingPercent, resetsAt: value.resetsAt)
                if window.isValid { windows.append(window) }
            }
            if let value = usage.sevenDay {
                let window = AgentQuotaWindow(id: "seven-day", title: "Weekly · all models",
                                              remainingPercent: value.remainingPercent, resetsAt: value.resetsAt)
                if window.isValid { windows.append(window) }
            }
            guard !windows.isEmpty else { continue }
            let projected = AgentUsageSnapshot(updatedAt: usage.updatedAt, windows: windows)
            if let previous = winner {
                if usage.updatedAt > previous.usage.updatedAt ||
                   (usage.updatedAt == previous.usage.updatedAt && session.id < previous.sessionID) {
                    winner = (session.id, projected)
                }
            } else { winner = (session.id, projected) }
        }
        return winner?.usage
    }

    /// Combine's @Published sends before storage changes. Publish once on the
    /// next main turn to observe a coherent batch and avoid rebuilding the
    /// dashboard for every field in one directory update.
    private func schedulePublication() {
        guard isActive, publication == nil else { return }
        let current = generation
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.isActive, self.generation == current else { return }
                self.publication = nil
                self.publish()
            }
        }
        publication = work
        DispatchQueue.main.async(execute: work)
    }

    private func publish() {
        guard isActive else { return }
        let connection: AgentConnection
        switch backend.connection {
        case .connected: connection = .connected
        case .connecting, .disconnected: connection = .disconnected
        case .failed(let message): connection = .failed(message)
        }
        let account = backend.accountUsage
        let usageConnection: AgentConnection?
        if let error = backend.accountUsageError ?? backend.accountUsageReadError {
            usageConnection = .failed(error)
        } else if let account {
            switch account.state {
            case .disabled: usageConnection = .disconnected
            case .loading: usageConnection = account.report == nil ? .disconnected : .connected
            case .ready: usageConnection = .connected
            case .failed: usageConnection = .failed(account.message ?? "Account usage is unavailable. Reconnect usage to retry.")
            }
        } else if latestActualUsage != nil {
            usageConnection = nil // Older CLI relays can still supply status-line quotas.
        } else {
            usageConnection = .unavailable(backend.directory == nil
                ? "Connect the Claude session relay in BoringAgent settings first."
                : "Update the Claude relay with the setup command in BoringAgent settings, then connect account usage.")
        }
        // Once account access is enabled, never mix its data with potentially
        // different CLI session accounts or resurrect it from hook snapshots.
        let usage = account?.enabled == true ? account?.report : latestActualUsage
        let value = AgentProviderSnapshot(descriptor: descriptor, connection: connection,
            sessions: projectedSessions, usage: usage,
            setupCommand: ClaudePluginResources.setupCommand,
            message: backend.actionMessage ?? connection.message,
            relayDirectory: backend.directory?.path, usageConnection: usageConnection,
            usageIsRefreshing: account?.state == .loading || backend.accountUsageRequestPending)
        guard value != snapshot else { return }
        snapshot = value
        onChange?()
    }

    func updateClock(_ now: Date) { if isActive { backend.updateClock(now) } }
    func refresh() {
        guard isActive else { return }
        backend.refresh()
    }
    func connect() { if isActive { backend.chooseDirectory() } }
    func disconnect() { if isActive { backend.disconnect() } }
    func connectUsage() { if isActive { backend.requestAccountUsage(.enable) } }
    func disconnectUsage() { if isActive { backend.requestAccountUsage(.disable) } }
    func refreshUsage() {
        guard isActive, backend.accountUsage?.enabled == true else { return }
        backend.requestAccountUsage(.refresh)
    }
    func selectSession(nativeID: String) { if isActive { backend.select(nativeID) } }

    func openSession(nativeID: String) {
        guard isActive, let session = nativeSessions[nativeID] else { return }
        backend.openSession(session)
    }

    func openOriginApp(nativeID: String) {
        guard isActive, let session = nativeSessions[nativeID] else { return }
        backend.openOriginApp(session)
    }

    func copyResumeCommand(nativeID: String) {
        guard isActive, nativeSessions[nativeID] != nil else { return }
        backend.copy("claude --resume \(nativeID)", message: "Resume command copied.")
    }

    func copySetupCommand() { if isActive { backend.copySetupCommand() } }

    func stop() {
        guard isActive else { return }
        isActive = false
        onChange = nil
        generation = UUID()
        publication?.cancel()
        publication = nil
        subscriptions.removeAll()
        latestActualUsage = nil
        nativeSessions.removeAll()
        projectedSessions.removeAll()
        backend.stop()
    }
}
