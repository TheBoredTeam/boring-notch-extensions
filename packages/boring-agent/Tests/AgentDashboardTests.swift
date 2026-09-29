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
    var messages: [AgentMessageCommand] = []
    var messageCompletion: (@MainActor (AgentMessageReceipt) -> Void)?

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
    func copyUsageSignInCommand() -> Bool { actions.append("usage-signin-copy"); return true }
    func connectUsage() { actions.append("usage-connect") }
    func disconnectUsage() { actions.append("usage-disconnect") }
    func refreshUsage() { actions.append("usage-refresh") }
    func sendMessage(_ command: AgentMessageCommand, completion: @escaping @MainActor (AgentMessageReceipt) -> Void) {
        messages.append(command); messageCompletion = completion
    }

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
        try accountUsageRoutingAndScopes()
        try subscriptionUsageSignInRouting()
        try messageRoutingAndFencing()
        try messageReceiptValidation()
        try messageStatusFollowsRequest()
        try messageAvailabilityAndRequestIdentity()
        try liveChannelKeepsIdleSessionAvailable()
        try messageCommandValidation()
        try latestActualClaudeUsage()
        try staleReports()
        try capacity()
        try stopFencesCallbacksAndActions()
        print("Agent dashboard tests passed: \(assertions) assertions; 1,000 sessions across 100 injected providers; no real integrations.")
    }

    static func subscriptionUsageSignInRouting() throws {
        let codex = FixtureAgentProvider(id: "codex")
        let claude = FixtureAgentProvider(id: "claude")
        let command = "'/fixture/boring-claude-bridge' codex-login-usage --data-dir '/fixture/relay'"
        codex.snapshot.usageAccount = AgentUsageAccountStatus(state: .signInRequired,
            message: "Sign in to read ChatGPT subscription usage.", signInCommand: command)
        let state = dashboard([codex, claude]); state.start()
        try expect(state.provider(forID: "codex")?.connection == .connected &&
                   state.provider(forID: "codex")?.usageAccount?.state == .signInRequired,
                   "A healthy session relay does not conceal missing subscription-account sign-in")
        try expect(state.provider(forID: "codex")?.usage == nil,
                   "An account sign-in requirement does not invent a usage percentage")
        try expect(state.copyUsageSignInCommand(providerID: "codex") && codex.actions == ["usage-signin-copy"],
                   "Explicit Copy routes only to the account provider without connecting or launching login")
        try expect(!state.copyUsageSignInCommand(providerID: "claude") && !state.copyUsageSignInCommand(providerID: "unknown") && claude.actions.isEmpty,
                   "Providers without an account command cannot copy or start a sign-in action")
        codex.snapshot.connection = .failed("Session relay unavailable"); codex.onChange?()
        try expect(state.provider(forID: "codex")?.usageAccount?.message == "Sign in to read ChatGPT subscription usage.",
                   "Session errors cannot replace account-specific usage information")
        try expect(state.copyUsageSignInCommand(providerID: "codex"),
                   "The account setup command stays actionable without an active session connection")
        state.refreshUsage(providerID: "codex")
        try expect(codex.actions.last == "usage-refresh" && !codex.actions.contains("refresh"),
                   "Subscription Refresh requests a real account refresh instead of only rereading the report")
        codex.snapshot.usageIsRefreshing = true; codex.onChange?()
        let actionCount = codex.actions.count
        state.refreshUsage(providerID: "codex")
        try expect(codex.actions.count == actionCount, "A pending subscription refresh cannot enqueue duplicate UI requests")
        codex.snapshot.usageIsRefreshing = false
        codex.snapshot.usageAccount = AgentUsageAccountStatus(state: .connected,
            message: "The account has not reported a quota.", signInCommand: nil)
        codex.onChange?()
        try expect(state.provider(forID: "codex")?.usage == nil && !state.copyUsageSignInCommand(providerID: "codex"),
                   "Connected-but-unreported usage stays unavailable rather than looking exhausted or inventing a sign-in action")
        state.stop()
        try expect(!state.copyUsageSignInCommand(providerID: "codex"), "Destroyed state cannot perform account actions")
    }

    static func messageRoutingAndFencing() throws {
        var left = session("claude")
        left.control = AgentSessionControl(revision: "owner-a:turn-a", canPrompt: true)
        var right = session("codex")
        right.control = AgentSessionControl(revision: "owner-b:turn-b", canPrompt: true)
        let claude = FixtureAgentProvider(id: "claude", sessions: [left])
        let codex = FixtureAgentProvider(id: "codex", sessions: [right])
        let state = dashboard([claude, codex]); state.start()
        state.setDraftText("Prompt for Claude", for: left.id)
        state.setDraftText("Prompt for Codex", for: right.id)
        try expect(state.draft(for: left.id).text == "Prompt for Claude", "Drafts stay with their provider and session")
        try expect(state.canSendDraft(for: right.id), "A fresh capable connected target enables send")
        state.sendDraft(for: right.id)
        try expect(codex.messages.count == 1 && claude.messages.isEmpty, "Send reaches only the selected provider")
        let first = codex.messages[0]
        try expect(first.sessionID == "shared" && first.revision == "owner-b:turn-b" && first.text == "Prompt for Codex",
                   "The exact native session, owner revision and draft are passed through")
        state.sendDraft(for: right.id)
        try expect(codex.messages.count == 1, "Double send while pending is ignored")
        codex.messageCompletion?(AgentMessageReceipt(id: UUID().uuidString, sessionID: first.sessionID,
            state: .accepted, message: "Wrong ack"))
        try expect(state.messageStatus(for: right.id)?.pending == true, "An unrelated receipt cannot complete this send")
        codex.messageCompletion?(AgentMessageReceipt(id: first.id, sessionID: first.sessionID,
            state: .rejected, message: "Turn changed"))
        try expect(state.draft(for: right.id).text == "Prompt for Codex", "Rejected send preserves the draft")
        try expect(state.messageStatus(for: right.id)?.delivery == .rejected, "Rejected delivery is visible")
        right.control?.revision = "owner-b:turn-c"; codex.publish(sessions: [right])
        try expect(!state.canSendDraft(for: right.id), "A draft bound to the prior turn cannot send")
        state.refreshDraft(for: right.id)
        try expect(state.canSendDraft(for: right.id), "Explicit target review can retain and rebind a prompt")
        state.sendDraft(for: right.id)
        let second = codex.messages[1]
        codex.messageCompletion?(AgentMessageReceipt(id: second.id, sessionID: second.sessionID,
            state: .accepted, message: "Prompt accepted"))
        try expect(state.draft(for: right.id).text.isEmpty, "Only an exact accepted receipt clears the draft")
        try expect(state.draft(for: left.id).text == "Prompt for Claude", "Acknowledgments do not clear another provider's draft")
        let question = AgentInputQuestion(id: "color", title: "Choice", prompt: "Which color?", options: ["Blue", "Green"])
        right.phase = .needsInput
        right.control = AgentSessionControl(revision: "request-one", canPrompt: false,
            request: AgentInputRequest(id: "question-one", questions: [question]))
        codex.publish(sessions: [right]); state.refreshDraft(for: right.id)
        state.setDraftAnswers(["color": ["Blue"]], for: right.id)
        try expect(state.canSendDraft(for: right.id), "A complete fresh question reply is sendable")
        right.control?.request?.id = "question-two"; right.control?.revision = "request-two"
        codex.publish(sessions: [right])
        try expect(!state.canSendDraft(for: right.id), "Question identity changes fence old answers")
        state.refreshDraft(for: right.id)
        try expect(state.draft(for: right.id).answers.isEmpty, "Reviewing a new question clears old choices")
        state.setDraftAnswers(["color": ["Blue"]], for: right.id)
        right.control?.request?.questions[0].isSecret = true; codex.publish(sessions: [right])
        try expect(!state.canSendDraft(for: right.id), "Secret questions cannot be answered through the relay")
        right.control?.request?.questions[0].isSecret = false; codex.publish(sessions: [right])
        state.sendDraft(for: right.id)
        let last = codex.messages.last!
        let callback = codex.messageCompletion
        state.stop()
        callback?(AgentMessageReceipt(id: last.id, sessionID: last.sessionID, state: .accepted, message: "Late"))
        try expect(state.messageStatus(for: right.id) == nil && state.draft(for: left.id).text.isEmpty,
                   "Destroy clears private drafts and fences late receipt callbacks")
    }

    static func messageReceiptValidation() throws {
        var target = session("claude", "receipt-target")
        target.control = AgentSessionControl(revision: "owner:turn", canPrompt: true)
        let provider = FixtureAgentProvider(id: "claude", sessions: [target])
        let state = dashboard([provider]); state.start()
        defer { state.stop() }
        state.setDraftText("Keep this draft until acceptance", for: target.id)
        state.sendDraft(for: target.id)
        let first = provider.messages[0]
        let firstCompletion = provider.messageCompletion!

        state.setDraftText("A pending edit must not replace it", for: target.id)
        state.setDraftAnswers(["unexpected": ["Answer"]], for: target.id)
        try expect(state.draft(for: target.id).text == first.text && state.draft(for: target.id).answers.isEmpty,
                   "A pending command locks both prompt and answer edits")
        firstCompletion(AgentMessageReceipt(id: first.id, sessionID: first.sessionID,
            state: .pending, message: "The helper claimed the command"))
        try expect(state.messageStatus(for: target.id)?.pending == true && !state.canSendDraft(for: target.id),
                   "A transport pending receipt cannot unlock or complete the UI send")
        firstCompletion(AgentMessageReceipt(id: first.id, sessionID: "another-session",
            state: .accepted, message: "Wrong session"))
        firstCompletion(AgentMessageReceipt(id: first.id, sessionID: first.sessionID,
            state: .accepted, message: ""))
        firstCompletion(AgentMessageReceipt(id: first.id, sessionID: first.sessionID,
            state: .accepted, message: "Invalid timestamp", updatedAt: .nan))
        try expect(state.messageStatus(for: target.id)?.pending == true && state.draft(for: target.id).text == first.text,
                   "Wrong-session and malformed receipts leave the send pending and preserve its draft")

        firstCompletion(AgentMessageReceipt(id: first.id, sessionID: first.sessionID,
            state: .unknown, message: "Acknowledgment was lost"))
        try expect(state.messageStatus(for: target.id)?.delivery == .unknown && state.draft(for: target.id).text == first.text,
                   "Unknown delivery is visible without discarding the draft")
        try expect(provider.messages.count == 1, "Unknown delivery does not automatically retry")
        state.sendDraft(for: target.id)
        let second = provider.messages[1]
        let secondCompletion = provider.messageCompletion!
        try expect(second.id != first.id, "A new explicit Send gets a distinct command identity")
        firstCompletion(AgentMessageReceipt(id: first.id, sessionID: first.sessionID,
            state: .accepted, message: "Late first acknowledgment"))
        try expect(state.messageStatus(for: target.id)?.commandID == second.id &&
                   state.messageStatus(for: target.id)?.pending == true && state.draft(for: target.id).text == first.text,
                   "A late older acknowledgment cannot clear the draft or complete a newer send")
        secondCompletion(AgentMessageReceipt(id: second.id, sessionID: second.sessionID,
            state: .accepted, message: "Second accepted"))
        secondCompletion(AgentMessageReceipt(id: second.id, sessionID: second.sessionID,
            state: .rejected, message: "Duplicate callback"))
        try expect(state.messageStatus(for: target.id)?.delivery == .accepted && state.draft(for: target.id).text.isEmpty,
                   "The first terminal acknowledgment wins and duplicates cannot rewrite its result")
    }

    static func messageStatusFollowsRequest() throws {
        var target = session("codex", "status-target")
        target.control = AgentSessionControl(revision: "owner-one", canPrompt: true)
        let provider = FixtureAgentProvider(id: "codex", sessions: [target])
        let state = dashboard([provider]); state.start()
        defer { state.stop() }
        state.setDraftText("Ask me a question", for: target.id)
        state.sendDraft(for: target.id)
        let prompt = provider.messages[0]
        try expect(state.currentMessageStatus(for: target.id)?.pending == true,
                   "Composer shows pending feedback for its exact prompt target")
        provider.messageCompletion?(AgentMessageReceipt(id: prompt.id, sessionID: prompt.sessionID,
            state: .accepted, message: "Codex accepted your message"))
        try expect(state.currentMessageStatus(for: target.id)?.delivery == .accepted,
                   "Acceptance remains visible for the prompt it actually acknowledges")

        let question = AgentInputQuestion(id: "color", title: "Color", prompt: "Which color?", options: ["Blue", "Green"])
        target.phase = .needsInput
        target.control = AgentSessionControl(revision: "owner-one", canPrompt: false,
            request: AgentInputRequest(id: "question-one", questions: [question]))
        provider.publish(sessions: [target])
        try expect(state.currentMessageStatus(for: target.id) == nil,
                   "Opening a later question never shows the previous prompt's accepted receipt, even under the same owner")
        try expect(state.messageStatus(for: target.id)?.delivery == .accepted,
                   "The separately labeled dashboard can retain the latest delivery history")
        state.setDraftAnswers([question.id: ["Blue"]], for: target.id)
        state.sendDraft(for: target.id)
        let firstReply = provider.messages[1]
        let firstCompletion = provider.messageCompletion!
        try expect(state.currentMessageStatus(for: target.id)?.pending == true,
                   "Reply feedback begins only after that question is explicitly sent")
        target.control?.request?.id = "question-two"
        provider.publish(sessions: [target])
        try expect(state.currentMessageStatus(for: target.id) == nil && state.messageStatus(for: target.id)?.pending == true,
                   "A new request hides the previous request's pending status without releasing its send lock")
        firstCompletion(AgentMessageReceipt(id: firstReply.id, sessionID: firstReply.sessionID,
            state: .accepted, message: "First reply accepted"))
        try expect(state.currentMessageStatus(for: target.id) == nil,
                   "A late receipt cannot make an unsent second question appear answered")
        state.setDraftAnswers([question.id: ["Green"]], for: target.id)
        state.sendDraft(for: target.id)
        let secondReply = provider.messages[2]
        provider.messageCompletion?(AgentMessageReceipt(id: secondReply.id, sessionID: secondReply.sessionID,
            state: .unknown, message: "Reply delivery unconfirmed"))
        try expect(state.currentMessageStatus(for: target.id)?.delivery == .unknown,
                   "Unknown delivery stays visible for its own current request")
        target.control?.revision = "owner-two"
        provider.publish(sessions: [target])
        try expect(state.currentMessageStatus(for: target.id) == nil,
                   "A changed owner also hides receipt status belonging to the prior target")
    }

    static func messageAvailabilityAndRequestIdentity() throws {
        var target = session("codex", "availability-target")
        target.control = AgentSessionControl(revision: "owner:turn", canPrompt: true)
        let provider = FixtureAgentProvider(id: "codex", sessions: [target])
        let state = dashboard([provider]); state.start()
        defer { state.stop() }
        state.setDraftText("A useful prompt", for: target.id)
        provider.snapshot.connection = .disconnected; provider.onChange?()
        state.sendDraft(for: target.id)
        try expect(!state.canSendDraft(for: target.id) && provider.messages.isEmpty,
                   "Disconnect fences sending even while the last session snapshot is visible")
        provider.snapshot.connection = .connected; provider.onChange?()
        state.updateClock(instant.addingTimeInterval(601))
        state.sendDraft(for: target.id)
        try expect(!state.canSendDraft(for: target.id) && provider.messages.isEmpty,
                   "A stale session cannot receive a draft")
        state.updateClock(instant)
        try expect(state.canSendDraft(for: target.id), "A fresh connected target can resume draft composition")
        state.setDraftText(String(repeating: "x", count: AgentMessageCommand.maximumTextBytes + 1), for: target.id)
        try expect(state.draft(for: target.id).text == "A useful prompt", "An oversized edit preserves the last bounded draft")

        target.phase = .needsInput
        let question = AgentInputQuestion(id: "approach", title: "Approach", prompt: "Choose an approach", options: ["Small", "Large"])
        target.control = AgentSessionControl(revision: "request-owner", canPrompt: false,
            request: AgentInputRequest(id: "request-one", questions: [question]))
        provider.publish(sessions: [target]); state.refreshDraft(for: target.id)
        state.setDraftAnswers([question.id: ["Small"]], for: target.id)
        try expect(state.canSendDraft(for: target.id), "A complete structured reply is valid without generic prompt support")
        target.control?.request?.id = "request-two"
        provider.publish(sessions: [target])
        try expect(!state.canSendDraft(for: target.id), "Request identity fences a reply even if a provider reused the same revision")
        state.refreshDraft(for: target.id)
        try expect(state.draft(for: target.id).answers.isEmpty && !state.canSendDraft(for: target.id),
                   "Reviewing a different request requires answering that request afresh")
        state.setDraftAnswers([question.id: ["Small"]], for: target.id)
        target.control?.revision = "new-owner"
        provider.publish(sessions: [target])
        try expect(!state.canSendDraft(for: target.id), "An owner revision change fences a same-request reply until explicit review")
        provider.publish(sessions: [])
        state.sendDraft(for: target.id)
        try expect(provider.messages.isEmpty, "A removed session cannot receive its retained draft")
    }

    static func liveChannelKeepsIdleSessionAvailable() throws {
        var time = instant
        var target = session("claude", "long-idle", phase: .idle, age: 3_600)
        target.control = AgentSessionControl(revision: "live-channel-owner", canPrompt: true,
            expiresAt: instant.timeIntervalSince1970 + 8)
        let provider = FixtureAgentProvider(id: "claude", sessions: [target])
        let state = AgentDashboardState(adapters: [provider], clock: { time }, schedulesClock: false)
        state.start()
        defer { state.stop() }
        state.setDraftText("What is 2 + 2?", for: target.id)
        try expect(!state.isStale(target) && state.canSendDraft(for: target.id),
                   "A verified live channel keeps a long-idle session controllable")
        try expect(state.sessions.first?.updatedAt == target.updatedAt,
                   "Channel liveness does not rewrite activity history or ordering")

        // The capability must expire even if a crashed helper generates no
        // final file notification. A recent activity timestamp cannot save it.
        time = instant.addingTimeInterval(8)
        state.updateClock(time)
        try expect(state.isStale(target) && !state.canSendDraft(for: target.id),
                   "An expired channel lease makes an idle session stale again")
        target.updatedAt = time.timeIntervalSince1970
        provider.publish(sessions: [target])
        try expect(!state.isStale(target) && !state.canSendDraft(for: target.id),
                   "A recent event cannot authorize an expired channel capability")

        target.updatedAt = instant.timeIntervalSince1970 - 3_600
        target.control?.expiresAt = time.timeIntervalSince1970 + 8
        provider.publish(sessions: [target])
        try expect(state.canSendDraft(for: target.id),
                   "A refreshed verified lease restores the same draft without a revision change")
        provider.snapshot.connection = .disconnected; provider.onChange?()
        try expect(!state.canSendDraft(for: target.id), "A live-looking lease cannot override provider disconnection")
        provider.snapshot.connection = .connected
        target.phase = .ended; provider.publish(sessions: [target])
        try expect(!state.canSendDraft(for: target.id), "A live-looking lease cannot reopen an ended session")

        target.phase = .idle; target.control?.expiresAt = nil
        provider.publish(sessions: [target])
        try expect(state.isStale(target) && !state.canSendDraft(for: target.id),
                   "A capability with no liveness evidence cannot refresh an old observation")
    }

    static func messageCommandValidation() throws {
        let control = AgentSessionControl(revision: "current-owner", canPrompt: true)
        let valid = AgentMessageCommand(providerID: "claude", sessionID: "target", revision: control.revision,
            createdAt: instant.timeIntervalSince1970, text: "A deliberate prompt")
        try expect(valid.matches(control, now: instant), "A current well-formed prompt matches its capability")
        var invalid = valid; invalid.createdAt -= 121
        try expect(!invalid.matches(control, now: instant), "An expired command cannot be delivered")
        invalid = valid; invalid.createdAt += 6
        try expect(!invalid.matches(control, now: instant), "A command beyond allowed clock skew cannot be delivered")
        invalid = valid; invalid.text = "text\0payload"
        try expect(!invalid.matches(control, now: instant), "A NUL-bearing prompt is rejected")
        invalid = valid; invalid.answers = ["question": ["Unexpected answer"]]
        try expect(!invalid.matches(control, now: instant), "Prompt commands cannot also carry structured answers")

        let question = AgentInputQuestion(id: "question", title: "Question", prompt: "Choose", options: ["A", "B"])
        let request = AgentInputRequest(id: "request", questions: [question])
        let replyControl = AgentSessionControl(revision: "reply-owner", canPrompt: false, request: request)
        var reply = AgentMessageCommand(providerID: "claude", sessionID: "target", revision: replyControl.revision,
            createdAt: instant.timeIntervalSince1970, answers: [question.id: ["A"]], requestID: request.id)
        try expect(reply.matches(replyControl, now: instant), "A complete non-secret reply matches its request")
        reply.answers["extra"] = ["Answer"]
        try expect(!reply.matches(replyControl, now: instant), "A reply cannot add question identities absent from the request")
        reply.answers = [question.id: ["A", "B"]]
        try expect(!reply.matches(replyControl, now: instant), "A single-choice question rejects multiple answers")
        reply.answers = [question.id: ["A"]]
        var secretControl = replyControl; secretControl.request?.questions[0].isSecret = true
        try expect(!reply.matches(secretControl, now: instant), "Private input never enters an inline command")
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

    static func accountUsageRoutingAndScopes() throws {
        let provider = FixtureAgentProvider(id: "claude")
        provider.snapshot.usageConnection = .disconnected
        provider.snapshot.usage = AgentUsageSnapshot(updatedAt: instant.timeIntervalSince1970, windows: [
            AgentQuotaWindow(id: "five-hour", title: "5-hour limit", remainingPercent: 57),
            AgentQuotaWindow(id: "weekly", title: "Weekly · all models", remainingPercent: 11),
            AgentQuotaWindow(id: "fable", title: "Weekly · Fable", remainingPercent: 0, contributesToOverall: false),
        ])
        let unavailable = FixtureAgentProvider(id: "codex")
        let state = dashboard([provider, unavailable])
        state.start()
        try expect(state.provider(forID: "claude")?.usage?.limitingRemainingPercent == 11,
                   "An exhausted model-specific window does not report that every model is exhausted")
        try expect(state.provider(forID: "claude")?.usage?.windows.count == 3,
                   "Model-specific quota remains visible in detailed usage")
        state.connectUsage(providerID: "claude")
        state.disconnectUsage(providerID: "claude")
        state.refreshUsage(providerID: "claude")
        state.connectUsage(providerID: "codex")
        try expect(provider.actions == ["usage-connect", "usage-disconnect", "usage-refresh"] && unavailable.actions.isEmpty,
                   "Account access routes only to an adapter exposing that independent source")
        state.stop()
        state.connectUsage(providerID: "claude")
        try expect(provider.actions.count == 3, "Destroyed dashboards cannot enable account access")
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
