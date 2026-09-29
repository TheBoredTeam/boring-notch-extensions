// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// These adapters are deliberately memory-only. They never construct a Claude
/// backend, touch preferences/relay files, copy text, or open another app.
@MainActor
private final class FixtureAgentProvider: AgentProviderAdapter {
    let descriptor: AgentProviderDescriptor
    var snapshot: AgentProviderSnapshot
    var onChange: (() -> Void)?
    var starts = 0
    var stops = 0
    var actions: [String] = []

    init(id: String, sessions: [AgentSession] = [], usage: AgentUsageSnapshot? = nil) {
        descriptor = AgentProviderDescriptor(id: id, title: "Provider \(id)", shortName: id,
            symbol: "sparkles", accentRGB: AgentAccentRGB(red: 0.4, green: 0.5, blue: 0.6))
        snapshot = AgentProviderSnapshot(descriptor: descriptor, connection: .connected,
            sessions: sessions, usage: usage)
    }

    func start() { starts += 1 }
    func stop() { stops += 1; onChange = nil }
    func updateClock(_ now: Date) {}
    func refresh() { actions.append("refresh") }
    func connect() { actions.append("connect") }
    func disconnect() { actions.append("disconnect") }
    func selectSession(nativeID: String) { actions.append("select:\(nativeID)") }
    func openSession(nativeID: String) { actions.append("open:\(nativeID)") }
    func openOriginApp(nativeID: String) { actions.append("origin:\(nativeID)") }
    func copyResumeCommand(nativeID: String) { actions.append("resume:\(nativeID)") }
    func copySetupCommand() { actions.append("setup") }

    func publish(sessions: [AgentSession]) {
        snapshot.sessions = sessions
        onChange?()
    }
}

@main
@MainActor
struct AgentDashboardTests {
    static var assertions = 0
    static let instant = Date(timeIntervalSince1970: 2_000_000_000)

    static func expect(_ value: @autoclosure () -> Bool, _ message: String) throws {
        assertions += 1
        guard value() else {
            throw NSError(domain: "AgentDashboardTests", code: assertions,
                          userInfo: [NSLocalizedDescriptionKey: message])
        }
    }

    static func session(_ provider: String, _ nativeID: String = "shared",
                        phase: SessionPhase = .working, age: Double = 0) -> AgentSession {
        AgentSession(providerID: provider, nativeID: nativeID, project: "Project \(provider)",
            directory: "/fixture/\(provider)", phase: phase,
            createdAt: instant.timeIntervalSince1970 - 1_000,
            updatedAt: instant.timeIntervalSince1970 - age)
    }

    private static func dashboard(_ adapters: [FixtureAgentProvider]) -> AgentDashboardState {
        AgentDashboardState(adapters: adapters, clock: { instant }, schedulesClock: false)
    }

    static func main() throws {
        try identitiesAndRouting()
        try selectionAndMembership()
        try quotaSemantics()
        try latestActualClaudeUsage()
        try staleReports()
        try capacity()
        try stopFencesCallbacksAndActions()
        print("Agent dashboard tests passed: \(assertions) assertions; 1,000 sessions across 100 injected providers; no real integrations.")
    }

    static func identitiesAndRouting() throws {
        let claude = FixtureAgentProvider(id: "claude", sessions: [session("claude")])
        // Payload ownership must come from registration even if an adapter
        // accidentally repeats another provider's namespace in its snapshot.
        let codex = FixtureAgentProvider(id: "codex", sessions: [session("claude")])
        let duplicate = FixtureAgentProvider(id: "claude", sessions: [session("claude", "wrong-provider")])
        let state = dashboard([claude, codex, duplicate])
        state.start()
        defer { state.stop() }
        try expect(state.providers.count == 2, "Duplicate provider registrations cannot replace the first adapter")
        try expect(claude.starts == 1 && codex.starts == 1 && duplicate.starts == 0,
                   "Only accepted providers start")
        try expect(Set(state.sessions.map(\.id)) == ["claude:shared", "codex:shared"],
                   "Identical native IDs are namespaced by provider")

        guard let target = state.session(forID: "codex:shared") else {
            try expect(false, "Codex fixture is addressable"); return
        }
        claude.actions.removeAll(); codex.actions.removeAll()
        state.select(target.id)
        state.openSession(target)
        state.openOriginApp(target)
        state.copyResumeCommand(target)
        state.refresh(providerID: "codex")
        state.connectProvider("codex")
        state.disconnectProvider("codex")
        state.copySetupCommand(providerID: "codex")
        try expect(codex.actions == ["select:shared", "open:shared", "origin:shared", "resume:shared",
                                     "refresh", "connect", "disconnect", "setup"],
                   "Each session/provider action routes once to its owning adapter with the native ID")
        try expect(claude.actions.isEmpty && duplicate.actions.isEmpty, "Actions do not leak to another provider")
        codex.actions.removeAll()
        state.openSession(session("unknown"))
        state.connectProvider("unknown")
        state.copySetupCommand(providerID: "unknown")
        try expect(codex.actions.isEmpty && claude.actions.isEmpty, "Unknown providers and sessions cannot receive actions")
    }

    static func selectionAndMembership() throws {
        let first = session("claude", "first")
        let chosen = session("claude", "chosen", phase: .idle)
        let provider = FixtureAgentProvider(id: "claude", sessions: [first, chosen])
        let state = dashboard([provider])
        state.start()
        defer { state.stop() }
        state.select(chosen.id)
        let question = session("claude", "question", phase: .needsInput)
        provider.publish(sessions: [question, chosen, first])
        try expect(state.selectedID == chosen.id && state.selectedSession?.id == chosen.id,
                   "A new attention report and reordered snapshot preserve the user's selection")
        try expect(state.currentAttentionCount == 1, "Provider updates refresh attention without stealing selection")
        provider.publish(sessions: [chosen, chosen, first])
        try expect(state.sessions.count == 2, "Duplicate native IDs in one snapshot do not duplicate rows")
        provider.publish(sessions: [first])
        try expect(state.selectedSession?.id == first.id, "Withdrawal of selected session chooses an existing fallback")
        provider.actions.removeAll()
        state.openSession(chosen)
        try expect(provider.actions.isEmpty, "A removed session cannot route an action through a retained UI model")
        provider.publish(sessions: [])
        try expect(state.sessions.isEmpty && state.visibleSessions.isEmpty && state.selectedSession == nil,
                   "An empty publication withdraws all sessions and selection")
    }

    static func quotaSemantics() throws {
        let report = AgentUsageSnapshot(updatedAt: instant.timeIntervalSince1970,
            windows: [AgentQuotaWindow(id: "five-hour", title: "5-hour", remainingPercent: 70),
                      AgentQuotaWindow(id: "seven-day", title: "7-day", remainingPercent: 30)])
        try expect(report.limitingRemainingPercent == 30, "Multiple account windows use the binding minimum, never their sum")
        let empty = AgentUsageSnapshot(updatedAt: instant.timeIntervalSince1970, windows: [])
        try expect(empty.limitingRemainingPercent == nil, "Unavailable quota is distinct from zero")
        let exhausted = AgentUsageSnapshot(updatedAt: instant.timeIntervalSince1970,
            windows: [AgentQuotaWindow(id: "quota", title: "Quota", remainingPercent: 0)])
        try expect(exhausted.limitingRemainingPercent == 0, "A real exhausted allowance remains zero")
        let malformed = AgentUsageSnapshot(updatedAt: instant.timeIntervalSince1970,
            windows: [AgentQuotaWindow(id: "nan", title: "NaN", remainingPercent: .nan),
                      AgentQuotaWindow(id: "negative", title: "Negative", remainingPercent: -1),
                      AgentQuotaWindow(id: "overflow", title: "Overflow", remainingPercent: 101),
                      AgentQuotaWindow(id: "valid", title: "Valid", remainingPercent: 42)])
        try expect(malformed.limitingRemainingPercent == 42, "Invalid percentages cannot become the binding allowance")

        var context = session("claude")
        context.contextRemaining = 1
        let claude = FixtureAgentProvider(id: "claude", sessions: [context], usage: report)
        let codex = FixtureAgentProvider(id: "codex", usage: exhausted)
        let unavailable = FixtureAgentProvider(id: "antigravity", usage: nil)
        let state = dashboard([claude, codex, unavailable])
        state.start()
        defer { state.stop() }
        try expect(state.provider(forID: "claude")?.usage?.limitingRemainingPercent == 30,
                   "Session context does not replace account allowance")
        try expect(state.provider(forID: "codex")?.usage?.limitingRemainingPercent == 0,
                   "Provider-specific zero quota does not contaminate another provider")
        try expect(state.provider(forID: "antigravity")?.usage == nil,
                   "A provider without usage never receives another provider's values")
        claude.snapshot.usage = nil
        claude.onChange?()
        try expect(state.provider(forID: "claude")?.usage == nil && state.sessions.first?.contextRemaining == 1,
                   "Context-only data stays session context when provider quota is unavailable")
    }

    static func staleReports() throws {
        let freshQuestion = session("claude", "fresh", phase: .needsInput)
        let staleQuestion = session("claude", "stale", phase: .needsInput, age: 601)
        let working = session("claude", "working")
        let ended = session("claude", "ended", phase: .ended, age: 50_000)
        let provider = FixtureAgentProvider(id: "claude", sessions: [staleQuestion, working, ended, freshQuestion])
        let state = dashboard([provider])
        state.start()
        defer { state.stop() }
        try expect(state.attentionCount == 2 && state.currentAttentionCount == 1,
                   "Stale unanswered sessions remain visible but lose current activity urgency")
        try expect(state.attentionSession?.id == freshQuestion.id && state.workingCount == 1,
                   "Only current reports contribute to notch state")
        try expect(state.isStale(staleQuestion) && !state.isStale(ended), "Ended sessions are not mislabeled as stale work")
        state.updateClock(instant.addingTimeInterval(601))
        try expect(state.currentAttentionCount == 0 && state.workingCount == 0 && state.attentionSession == nil,
                   "The shared injected clock expires current activity without deleting session history")
        try expect(state.sessions.count == 4 && state.attentionCount == 2, "Clock expiry preserves reported session data")
        let usage = AgentUsageSnapshot(updatedAt: instant.timeIntervalSince1970, windows: [])
        try expect(!usage.isStale(at: instant.addingTimeInterval(300)) &&
                   usage.isStale(at: instant.addingTimeInterval(301)),
                   "Usage becomes stale after five minutes independently of session activity")
        let reset = AgentUsageSnapshot(updatedAt: instant.timeIntervalSince1970,
            windows: [AgentQuotaWindow(id: "quota", title: "Quota", remainingPercent: 0,
                                      resetsAt: instant.timeIntervalSince1970 + 10)])
        try expect(!reset.isStale(at: instant.addingTimeInterval(9)) &&
                   reset.isStale(at: instant.addingTimeInterval(10)) && reset.limitingRemainingPercent == 0,
                   "A passed reset marks the observation stale without inventing replenished allowance")
    }

    static func latestActualClaudeUsage() throws {
        func observation(_ id: String, sessionTime: Double, usageTime: Double,
                         fiveHour: Double? = nil, sevenDay: Double? = nil,
                         context: Double? = nil) -> ClaudeSession {
            var value = ClaudeSession(id: id, project: "Fixture", directory: "/fixture",
                phase: .working, createdAt: instant.timeIntervalSince1970 - 1_000, updatedAt: sessionTime)
            value.usage = ClaudeUsage(updatedAt: usageTime,
                fiveHour: fiveHour.map { ClaudeQuotaWindow(remainingPercent: $0) },
                sevenDay: sevenDay.map { ClaudeQuotaWindow(remainingPercent: $0) }, contextRemaining: context)
            return value
        }
        let now = instant.timeIntervalSince1970
        let oldQuota = observation("old-quota", sessionTime: now + 100, usageTime: now - 500,
                                   fiveHour: 90, sevenDay: 5, context: 99)
        let latestQuota = observation("latest-quota", sessionTime: now - 200, usageTime: now - 100,
                                      fiveHour: 40, context: 1)
        let contextOnly = observation("context-only", sessionTime: now + 200, usageTime: now + 200, context: 0)
        let rows = [oldQuota, latestQuota, contextOnly]
        let usage = ClaudeAgentProviderAdapter.projectUsage(from: rows)
        try expect(usage?.updatedAt == now - 100 && usage?.limitingRemainingPercent == 40,
                   "Claude account usage follows actual quota observation time, not the latest session/context update")
        try expect(usage?.windows.map(\.id) == ["five-hour"],
                   "A missing current window is not filled from an older report or summed across sessions")
        try expect(ClaudeAgentProviderAdapter.projectUsage(from: Array(rows.reversed())) == usage,
                   "Input ordering does not alter the selected account observation")
        try expect(ClaudeAgentProviderAdapter.projectUsage(from: [contextOnly]) == nil,
                   "A provider with only context reports has no observed account quota")
        let zero = observation("exhausted", sessionTime: now, usageTime: now,
                               fiveHour: 0, sevenDay: 70)
        try expect(ClaudeAgentProviderAdapter.projectUsage(from: [oldQuota, zero])?.limitingRemainingPercent == 0,
                   "The latest actual zero quota remains exhausted instead of becoming unavailable")
        let invalid = observation("invalid", sessionTime: now, usageTime: now + 300,
                                  fiveHour: .nan, sevenDay: -1)
        try expect(ClaudeAgentProviderAdapter.projectUsage(from: [invalid, latestQuota]) == usage,
                   "Malformed newer percentages cannot replace a valid observed quota")
        let tiedFirst = observation("a", sessionTime: now, usageTime: now, fiveHour: 20)
        let tiedSecond = observation("b", sessionTime: now, usageTime: now, fiveHour: 80)
        try expect(ClaudeAgentProviderAdapter.projectUsage(from: [tiedFirst, tiedSecond]) ==
                   ClaudeAgentProviderAdapter.projectUsage(from: [tiedSecond, tiedFirst]),
                   "Equal observation times choose a deterministic whole report")
    }

    static func capacity() throws {
        let providers = (0..<100).map { number -> FixtureAgentProvider in
            let id = String(format: "provider-%03d", number)
            let sessions = (0..<10).map { session(id, "native-\($0)", phase: $0.isMultiple(of: 2) ? .working : .idle) }
            return FixtureAgentProvider(id: id, sessions: sessions)
        }
        let state = dashboard(providers)
        state.start()
        defer { state.stop() }
        try expect(state.providers.count == 100 && state.sessions.count == 1_000,
                   "One dashboard supports 1,000 sessions across 100 independently registered providers")
        try expect(Set(state.sessions.map(\.id)).count == 1_000, "Repeated native IDs remain unique across 100 providers")
        for provider in providers {
            provider.actions.removeAll()
            for value in provider.snapshot.sessions {
                state.select(value.id)
                try expect(state.selectedSession?.id == value.id, "Every session remains individually selectable at scale")
            }
            if let value = provider.snapshot.sessions.first { state.openSession(value) }
            try expect(provider.actions.filter { $0.hasPrefix("open:") } == ["open:native-0"],
                       "Opening a session at scale reaches precisely its owning provider")
        }
        state.query = "Project provider-099"
        try expect(state.visibleSessions.count == 10, "Search filters a large registry without losing provider identity")
        state.query = ""
        state.select("provider-050:native-5")
        providers[0].publish(sessions: [])
        try expect(state.sessions.count == 990 && state.selectedID == "provider-050:native-5",
                   "One provider's withdrawal preserves unrelated selection at scale")
    }

    static func stopFencesCallbacksAndActions() throws {
        let value = session("claude", phase: .needsInput)
        let provider = FixtureAgentProvider(id: "claude", sessions: [value])
        let state = dashboard([provider])
        var activityCallbacks = 0
        state.activitiesChanged = { activityCallbacks += 1 }
        state.start()
        state.start()
        try expect(provider.starts == 1, "Repeated start does not duplicate subscriptions")
        provider.publish(sessions: [value, session("claude", "second", phase: .needsInput)])
        try expect(activityCallbacks > 0, "An active provider can notify the host before lifecycle fencing")
        let lateCallback = provider.onChange
        state.stop()
        let sessionsAfterStop = state.sessions
        let providersAfterStop = state.providers
        let callbacksAfterStop = activityCallbacks
        provider.actions.removeAll()
        provider.snapshot.sessions = [session("claude", "late")]
        lateCallback?()
        state.openSession(value)
        state.openOriginApp(value)
        state.copyResumeCommand(value)
        state.refresh()
        state.connectProvider("claude")
        state.disconnectProvider("claude")
        state.copySetupCommand(providerID: "claude")
        state.start()
        state.stop()
        try expect(!state.isActive && provider.onChange == nil && provider.stops == 1,
                   "Stop is terminal, unsubscribes, and stops each adapter exactly once")
        try expect(state.sessions == sessionsAfterStop && state.providers == providersAfterStop,
                   "A captured callback arriving after stop cannot republish state")
        try expect(activityCallbacks == callbacksAfterStop && provider.actions.isEmpty,
                   "Destroyed dashboard models neither notify the host nor trigger provider actions")
    }
}
