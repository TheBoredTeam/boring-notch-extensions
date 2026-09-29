// SPDX-License-Identifier: GPL-3.0-only
import Combine
import Foundation

/// One durable state per extension instance, shared by every mounted tab,
/// activity region, and settings view. Views never own provider services.
@MainActor
final class AgentDashboardState: ObservableObject {
    static let maximumProviders = 128
    static let maximumSessionsPerProvider = 2_000
    static let maximumSessions = 4_096

    @Published private(set) var providers: [AgentProviderSnapshot] = []
    @Published private(set) var sessions: [AgentSession] = []
    @Published private(set) var visibleSessions: [AgentSession] = []
    @Published private(set) var attentionSession: AgentSession?
    @Published private(set) var attentionCount = 0
    @Published private(set) var currentAttentionCount = 0
    @Published private(set) var workingCount = 0
    @Published private(set) var isActive = true
    @Published private(set) var now: Date
    @Published private(set) var actionMessage: String?
    @Published var selectedID: String?
    @Published var section: AgentDashboardSection = .usage
    @Published var query = "" { didSet { if query != oldValue { filterSessions() } } }
    @Published var waitingOnly = false { didSet { if waitingOnly != oldValue { filterSessions() } } }
    @Published var compactSearch = false
    @Published private var messageDrafts: [String: AgentMessageDraft] = [:]
    @Published private var messageStatuses: [String: AgentMessageStatus] = [:]

    var activitiesChanged: (() -> Void)?

    private let adapters: [any AgentProviderAdapter]
    private let adaptersByID: [String: any AgentProviderAdapter]
    private let clockSource: () -> Date
    private let schedulesClock: Bool
    private var rawSnapshots: [String: AgentProviderSnapshot] = [:]
    private var snapshotsByID: [String: AgentProviderSnapshot] = [:]
    private var byID: [String: AgentSession] = [:]
    private var searchText: [String: String] = [:]
    private var visibleIDs: Set<String> = []
    private var actionProviderID: String?
    private var timer: Timer?
    private var generation = UUID()
    private var started = false

    init(adapters: [any AgentProviderAdapter]? = nil,
         clock: @escaping () -> Date = Date.init,
         schedulesClock: Bool = true) {
        // Supplying adapters, including [], bypasses all real provider setup.
        let requested = adapters ?? AgentProviderRegistry.makeDefaultAdapters()
        var seen: Set<String> = []
        var registered: [any AgentProviderAdapter] = []
        for adapter in requested {
            let id = adapter.descriptor.id
            guard !id.isEmpty, id.utf8.count <= 128, !id.contains(":"), seen.insert(id).inserted else { continue }
            registered.append(adapter)
            if registered.count == Self.maximumProviders { break }
        }
        self.adapters = registered
        adaptersByID = Dictionary(self.adapters.map { ($0.descriptor.id, $0) }, uniquingKeysWith: { first, _ in first })
        clockSource = clock
        self.schedulesClock = schedulesClock
        now = clock()
        for adapter in self.adapters {
            rawSnapshots[adapter.descriptor.id] = adapter.snapshot
            snapshotsByID[adapter.descriptor.id] = Self.normalize(adapter.snapshot, descriptor: adapter.descriptor)
        }
        providers = self.adapters.compactMap { snapshotsByID[$0.descriptor.id] }
        rebuildSessions()
    }

    var selectedSession: AgentSession? {
        if let selectedID, visibleIDs.contains(selectedID) { return byID[selectedID] }
        return visibleSessions.first
    }

    func provider(forID id: String) -> AgentProviderSnapshot? { snapshotsByID[id] }
    func session(forID id: String) -> AgentSession? { byID[id] }

    func start() {
        guard isActive, !started else { return }
        started = true
        let current = generation
        for adapter in adapters {
            let id = adapter.descriptor.id
            adapter.onChange = { [weak self] in
                guard let self, self.isActive, self.generation == current else { return }
                self.receiveChange(providerID: id)
            }
            adapter.start()
            receiveChange(providerID: id)
        }
        updateClock(clockSource())
        if schedulesClock {
            timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.isActive else { return }
                    self.updateClock(self.clockSource())
                }
            }
        }
    }

    private func receiveChange(providerID: String) {
        guard isActive, let adapter = adaptersByID[providerID] else { return }
        let raw = adapter.snapshot
        guard rawSnapshots[providerID] != raw else { return }
        rawSnapshots[providerID] = raw
        let value = Self.normalize(raw, descriptor: adapter.descriptor)
        let previous = snapshotsByID[providerID]
        guard previous != value else { return }
        snapshotsByID[providerID] = value
        if let index = providers.firstIndex(where: { $0.id == providerID }) {
            providers[index] = value
        }
        // Message or quota changes update provider UI without sorting and
        // indexing all sessions again. Clock ticks never reproject snapshots.
        if previous?.sessions != value.sessions { rebuildSessions() }
        refreshActionMessage()
        ClaudeTelemetry.write("agent.state.loaded", ["sessionCount": sessions.count,
            "visibleCount": visibleSessions.count, "attentionCount": attentionCount,
            "selectedID": selectedID ?? "", "selectedQuestionPresent": selectedSession?.question != nil])
    }

    private static func normalize(_ source: AgentProviderSnapshot,
                                  descriptor: AgentProviderDescriptor) -> AgentProviderSnapshot {
        var result = source
        result.descriptor = descriptor
        var seen: Set<String> = []
        let validSessions = source.sessions.compactMap { original -> AgentSession? in
            var session = original
            // Namespace ownership comes from the registered adapter, never a
            // mutable payload. Native IDs may collide across providers safely.
            session.providerID = descriptor.id
            guard session.isValid, seen.insert(session.id).inserted else { return nil }
            return session
        }
        result.sessions = Array(validSessions.sorted(by: sessionPrecedes).prefix(maximumSessionsPerProvider))
        if var usage = source.usage {
            var windowIDs: Set<String> = []
            usage.windows = usage.windows.prefix(16).filter { $0.isValid && windowIDs.insert($0.id).inserted }
            result.usage = usage.updatedAt.isFinite && usage.updatedAt > 0 && !usage.windows.isEmpty ? usage : nil
        }
        return result
    }

    private func rebuildSessions() {
        let ranked = providers.flatMap(\.sessions).sorted(by: Self.sessionPrecedes)
        let bounded = Array(ranked.prefix(Self.maximumSessions))
        if sessions != bounded { sessions = bounded }
        byID = Dictionary(bounded.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        messageStatuses = messageStatuses.filter { byID[$0.key] != nil }
        messageDrafts = messageDrafts.filter { byID[$0.key] != nil }
        searchText = Dictionary(bounded.map { session in
            let providerName = snapshotsByID[session.providerID]?.descriptor.title ?? session.providerID
            return (session.id, [providerName, session.project, session.directory, session.nativeID,
                                session.model ?? ""].joined(separator: " ").lowercased())
        }, uniquingKeysWith: { first, _ in first })
        let count = bounded.reduce(0) { $0 + ($1.phase == .needsInput ? 1 : 0) }
        if attentionCount != count { attentionCount = count }
        refreshActivityEligibility()
        filterSessions()
    }

    private static func rank(_ phase: SessionPhase) -> Int {
        switch phase {
        case .needsInput: return 0
        case .working: return 1
        case .idle: return 2
        case .ended: return 3
        }
    }

    private static func sessionPrecedes(_ left: AgentSession, _ right: AgentSession) -> Bool {
        let leftRank = rank(left.phase)
        let rightRank = rank(right.phase)
        if leftRank != rightRank { return leftRank < rightRank }
        if left.updatedAt != right.updatedAt { return left.updatedAt > right.updatedAt }
        return left.id < right.id
    }

    private func filterSessions() {
        guard isActive else { return }
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let filtered = sessions.filter {
            (!waitingOnly || $0.phase == .needsInput) &&
            (term.isEmpty || (searchText[$0.id]?.contains(term) ?? false))
        }
        if visibleSessions != filtered { visibleSessions = filtered }
        visibleIDs = Set(filtered.map(\.id))
        if selectedID.map({ !visibleIDs.contains($0) }) ?? true {
            selectedID = filtered.first?.id
            actionProviderID = nil
            refreshActionMessage()
        }
        ClaudeTelemetry.write("agent.state.search", ["visibleCount": visibleSessions.count,
            "selectedID": selectedID ?? "", "selectedQuestionPresent": selectedSession?.question != nil])
    }

    func updateClock(_ date: Date) {
        guard isActive, date.timeIntervalSince1970.isFinite else { return }
        if now != date { now = date }
        for adapter in adapters { adapter.updateClock(date) }
        refreshActivityEligibility()
    }

    func isStale(_ session: AgentSession) -> Bool {
        session.phase != .ended && session.control?.hasLiveLease(at: now) != true &&
            now.timeIntervalSince1970 - session.updatedAt > 600
    }

    func statusLabel(_ session: AgentSession) -> String {
        isStale(session) ? "Status stale" : session.phase.label
    }

    func statusDescription(_ session: AgentSession) -> String {
        if isStale(session) {
            let minutes = max(1, Int((now.timeIntervalSince1970 - session.updatedAt) / 60))
            let age = minutes < 60 ? "\(minutes)m" : "\(minutes / 60)h"
            return "Last seen \(age) ago. Open the session to check its status."
        }
        let agent = provider(forID: session.providerID)?.descriptor.shortName ?? "Your agent"
        switch session.phase {
        case .working: return "Latest report: \(agent) is working"
        case .needsInput: return "\(agent) is waiting for your input"
        case .idle: return "Your session is ready"
        case .ended: return "This session has ended"
        }
    }

    private func refreshActivityEligibility() {
        let eligible = sessions.filter { $0.phase == .needsInput && !isStale($0) }
        let current = eligible.count
        let working = sessions.reduce(0) { $0 + ($1.phase == .working && !isStale($1) ? 1 : 0) }
        let previousCount = currentAttentionCount
        let previousSessionID = attentionSession?.id
        if currentAttentionCount != current { currentAttentionCount = current }
        if workingCount != working { workingCount = working }
        if attentionSession != eligible.first { attentionSession = eligible.first }
        if previousCount != current || previousSessionID != attentionSession?.id { activitiesChanged?() }
    }

    func select(_ id: String) {
        guard isActive, let session = byID[id], visibleIDs.contains(id) else { return }
        selectedID = id
        actionProviderID = nil
        if actionMessage != nil { actionMessage = nil }
        adaptersByID[session.providerID]?.selectSession(nativeID: session.nativeID)
    }

    func moveSelection(_ delta: Int) {
        guard isActive, !visibleSessions.isEmpty else { return }
        let current = visibleSessions.firstIndex { $0.id == selectedID } ?? 0
        let destination: Int
        // Avoid overflow even if a malformed event supplies an extreme delta.
        if delta > 0 { destination = current + min(delta, visibleSessions.count - 1 - current) }
        else { destination = current + max(delta, -current) }
        select(visibleSessions[destination].id)
    }

    private func perform(_ session: AgentSession, action: (any AgentProviderAdapter, String) -> Void) {
        guard isActive, let current = byID[session.id], let adapter = adaptersByID[current.providerID] else { return }
        actionProviderID = current.providerID
        action(adapter, current.nativeID)
        receiveChange(providerID: current.providerID)
        refreshActionMessage()
    }

    func openSession(_ session: AgentSession) { perform(session) { $0.openSession(nativeID: $1) } }
    func openOriginApp(_ session: AgentSession) { perform(session) { $0.openOriginApp(nativeID: $1) } }
    func copyResumeCommand(_ session: AgentSession) { perform(session) { $0.copyResumeCommand(nativeID: $1) } }

    func draft(for sessionID: String) -> AgentMessageDraft {
        if let draft = messageDrafts[sessionID] { return draft }
        let control = byID[sessionID]?.control
        return AgentMessageDraft(revision: control?.revision ?? "", requestID: control?.request?.id)
    }

    func setDraftText(_ text: String, for sessionID: String) {
        guard isActive, byID[sessionID] != nil, messageStatuses[sessionID]?.pending != true else { return }
        var value = draft(for: sessionID)
        value.text = text
        storeDraft(value, for: sessionID)
    }

    func setDraftAnswers(_ answers: [String: [String]], for sessionID: String) {
        guard isActive, byID[sessionID] != nil, messageStatuses[sessionID]?.pending != true else { return }
        var value = draft(for: sessionID)
        value.answers = answers
        storeDraft(value, for: sessionID)
    }

    /// Explicitly review the current target after a turn/question changes.
    /// Keep a prompt draft, but never carry answers onto a different request.
    func refreshDraft(for sessionID: String) {
        guard isActive, let control = byID[sessionID]?.control,
              messageStatuses[sessionID]?.pending != true else { return }
        var value = draft(for: sessionID)
        if value.requestID != control.request?.id { value.answers = [:] }
        value.revision = control.revision
        value.requestID = control.request?.id
        storeDraft(value, for: sessionID)
        messageStatuses[sessionID] = nil
    }

    private func storeDraft(_ draft: AgentMessageDraft, for id: String) {
        // Typing remains bounded even if a view receives a very large paste.
        guard draft.text.utf8.count <= AgentMessageCommand.maximumTextBytes,
              draft.answers.count <= 4,
              draft.answers.values.flatMap({ $0 }).reduce(0, { $0 + $1.utf8.count }) <= AgentMessageCommand.maximumTextBytes else { return }
        if messageDrafts[id] == nil, messageDrafts.count >= 64,
           let evict = messageDrafts.keys.sorted().first(where: { messageStatuses[$0]?.pending != true && $0 != selectedID }) {
            messageDrafts[evict] = nil
        }
        messageDrafts[id] = draft
    }

    func messageStatus(for sessionID: String) -> AgentMessageStatus? { messageStatuses[sessionID] }

    /// The session can move to another question before a receipt arrives. Keep
    /// that delivery history for the dashboard, but never present it as the
    /// result of the different draft or request now shown by the composer.
    func currentMessageStatus(for sessionID: String) -> AgentMessageStatus? {
        guard let control = byID[sessionID]?.control, let status = messageStatuses[sessionID],
              status.revision == control.revision, status.requestID == control.request?.id else { return nil }
        let draft = draft(for: sessionID)
        guard draft.revision == control.revision, draft.requestID == control.request?.id else { return nil }
        return status
    }

    private func command(for sessionID: String) -> AgentMessageCommand? {
        guard isActive, let session = byID[sessionID], let control = session.control,
              session.phase != .ended,
              snapshotsByID[session.providerID]?.connection.isConnected == true,
              !isStale(session), messageStatuses[sessionID]?.pending != true else { return nil }
        let draft = draft(for: sessionID)
        let value = AgentMessageCommand(providerID: session.providerID, sessionID: session.nativeID,
            revision: draft.revision, createdAt: clockSource().timeIntervalSince1970,
            text: draft.requestID == nil ? draft.text : nil,
            answers: draft.requestID == nil ? [:] : draft.answers, requestID: draft.requestID)
        return value.matches(control, now: clockSource()) ? value : nil
    }

    func canSendDraft(for sessionID: String) -> Bool { command(for: sessionID) != nil }

    func sendDraft(for sessionID: String) {
        guard let command = command(for: sessionID), let adapter = adaptersByID[command.providerID] else { return }
        let sentDraft = draft(for: sessionID)
        let lifetime = generation
        messageStatuses[sessionID] = AgentMessageStatus(commandID: command.id,
            revision: command.revision, requestID: command.requestID, pending: true, message: "Sending…")
        adapter.sendMessage(command) { [weak self] receipt in
            guard let self, self.isActive, self.generation == lifetime,
                  receipt.isValid, receipt.state != .pending,
                  receipt.id == command.id, receipt.sessionID == command.sessionID,
                  self.messageStatuses[sessionID]?.commandID == command.id,
                  self.messageStatuses[sessionID]?.pending == true else { return }
            self.messageStatuses[sessionID] = AgentMessageStatus(commandID: command.id,
                revision: command.revision, requestID: command.requestID, pending: false,
                delivery: receipt.state, message: receipt.message)
            if receipt.state == .accepted, self.messageDrafts[sessionID] == sentDraft {
                self.messageDrafts[sessionID] = nil
            }
        }
        // Lost replies are ambiguous. Never retry or clear the user's draft.
        DispatchQueue.main.asyncAfter(deadline: .now() + 35) { [weak self] in
            guard let self, self.isActive, self.generation == lifetime,
                  self.messageStatuses[sessionID]?.commandID == command.id,
                  self.messageStatuses[sessionID]?.pending == true else { return }
            self.messageStatuses[sessionID] = AgentMessageStatus(commandID: command.id,
                revision: command.revision, requestID: command.requestID, pending: false,
                delivery: .unknown, message: "Delivery could not be confirmed. Check the session before sending again.")
        }
    }

    func refresh(providerID: String? = nil) {
        guard isActive else { return }
        updateClock(clockSource())
        for adapter in adapters where providerID == nil || adapter.descriptor.id == providerID {
            adapter.refresh()
            receiveChange(providerID: adapter.descriptor.id)
        }
    }

    func connectProvider(_ id: String) { configureProvider(id) { $0.connect() } }
    func disconnectProvider(_ id: String) { configureProvider(id) { $0.disconnect() } }
    func copySetupCommand(providerID: String) { configureProvider(providerID) { $0.copySetupCommand() } }
    func copyMessagingSetupCommand(providerID: String) { configureProvider(providerID) { $0.copyMessagingSetupCommand() } }
    func copyUsageSignInCommand(providerID: String) -> Bool {
        guard isActive, let adapter = adaptersByID[providerID],
              snapshotsByID[providerID]?.usageAccount?.signInCommand != nil else { return false }
        return adapter.copyUsageSignInCommand()
    }

    func connectUsage(providerID: String) {
        configureUsage(providerID) { $0.connectUsage() }
    }

    func disconnectUsage(providerID: String) {
        configureUsage(providerID) { $0.disconnectUsage() }
    }

    func setInlineRepliesEnabled(_ enabled: Bool, providerID: String) {
        guard isActive, snapshotsByID[providerID]?.inlineRepliesEnabled != nil,
              snapshotsByID[providerID]?.connection.isConnected == true else { return }
        configureProvider(providerID) { $0.setInlineRepliesEnabled(enabled) }
    }

    func refreshUsage(providerID: String) {
        guard isActive else { return }
        updateClock(clockSource())
        if snapshotsByID[providerID]?.usageAccount != nil {
            guard let adapter = adaptersByID[providerID], snapshotsByID[providerID]?.usageIsRefreshing != true else { return }
            adapter.refreshUsage()
            receiveChange(providerID: providerID)
        } else if snapshotsByID[providerID]?.usageConnection == nil {
            refresh(providerID: providerID)
        } else {
            configureUsage(providerID) { $0.refreshUsage() }
        }
    }

    private func configureUsage(_ id: String, action: (any AgentProviderAdapter) -> Void) {
        guard isActive, let adapter = adaptersByID[id],
              snapshotsByID[id]?.usageConnection?.canConfigure == true else { return }
        action(adapter)
        receiveChange(providerID: id)
    }

    private func configureProvider(_ id: String, action: (any AgentProviderAdapter) -> Void) {
        guard isActive, let adapter = adaptersByID[id], snapshotsByID[id]?.connection.canConfigure == true else { return }
        actionProviderID = id
        action(adapter)
        receiveChange(providerID: id)
        refreshActionMessage()
    }

    private func refreshActionMessage() {
        let message = actionProviderID.flatMap { snapshotsByID[$0]?.message }
        if actionMessage != message { actionMessage = message }
    }

    func stop() {
        guard isActive else { return }
        isActive = false
        activitiesChanged = nil
        generation = UUID()
        timer?.invalidate()
        timer = nil
        messageDrafts.removeAll()
        messageStatuses.removeAll()
        // Clear callbacks before stopping any provider: even a provider which
        // synchronously publishes during stop cannot reach a destroyed host.
        for adapter in adapters { adapter.onChange = nil }
        for adapter in adapters { adapter.stop() }
    }
}
