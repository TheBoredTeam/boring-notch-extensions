// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Darwin

private struct CodexPendingInput {
    var wireID: Any
    var wireKey: String
    var turnID: String
    var input: AgentInputRequest
}

private struct CodexOwnedSession {
    var session: AgentSession
    var wirePhase: SessionPhase = .idle
    var joined = false
    var acceptsInput = false
    var turnID: String? = nil
    var input: CodexPendingInput? = nil
    var unsupportedRequest = false
    var epoch = 0
    var leaseExpiresAt: Double? = nil
}

/// One helper owns one connection to an already-running app-server. A new
/// connection gets a new opaque generation; commands from its predecessor can
/// never land in the replacement owner. Nothing here starts or resumes a user
/// thread in a second app-server process.
// Protocol, account, and session state are confined to `queue`. The lifecycle
// lock protects active/stopping, timer, accountRead and lockDescriptor transitions. Queued
// work retains the instance until it finishes, so deinit cannot race that work.
final class CodexBridgeService: @unchecked Sendable {
    static let maximumLoadedSessions = 128
    static let ownerLeaseSeconds: TimeInterval = 30
    private let directory: URL
    private let endpoint: URL
    private let accountExecutable: URL?
    private let makeTransport: (URL) -> CodexRPCTransport
    private let readAccount: (URL, String?, CodexAccountCancellation) -> CodexAccountBroker.Result
    private let accountClock: () -> Date
    private let queue = DispatchQueue(label: "org.theboredteam.boringagent.codex", qos: .utility)
    private let accountQueue = DispatchQueue(label: "org.theboredteam.boringagent.codex.account", qos: .utility)
    private let lifetime = NSLock()
    private var active = false
    private var stopping = false
    private var timer: DispatchSourceTimer?
    private var accountRead: CodexAccountCancellation?
    private var lockDescriptor: Int32 = -1
    private var client: CodexRPCClient?
    private var generation = UUID().uuidString
    private var sessions: [String: CodexOwnedSession] = [:]
    private var loadedIDs: [String] = []
    private var sessionsTruncated = false
    private var scanOffset = 0
    private var nextConnect = Date.distantPast
    private var nextScan = Date.distantPast
    private var nextUsage = Date.distantPast
    private var lastUsageAttempt = Date.distantPast
    private var pendingRefreshID: String?
    private var lastPublish = Date.distantPast
    private var usage: AgentUsageSnapshot?
    private var accountMessage: String?
    private var usageAccount: AgentUsageAccountStatus?
    private var usageFromOwner = false
    private var dirty = true

    init(directory: URL, endpoint: URL? = nil, accountExecutable: URL? = nil,
         makeTransport: @escaping (URL) -> CodexRPCTransport = { CodexUnixWebSocket(endpoint: $0) },
         readAccount: @escaping (URL, String?, CodexAccountCancellation) -> CodexAccountBroker.Result = {
             CodexAccountBroker.read(executable: $0, signInCommand: $1, cancellation: $2)
         },
         accountClock: @escaping () -> Date = Date.init) {
        self.directory = directory
        self.endpoint = endpoint ?? CodexUnixWebSocket.defaultEndpoint
        self.accountExecutable = accountExecutable ?? CodexAccountBroker.defaultExecutable
        self.makeTransport = makeTransport
        self.readAccount = readAccount
        self.accountClock = accountClock
    }

    deinit {
        timer?.cancel()
        accountRead?.cancel()
        client?.close()
        if lockDescriptor >= 0 { _ = flock(lockDescriptor, LOCK_UN); _ = Darwin.close(lockDescriptor) }
    }

    func start() throws {
        try AgentRelayStorage.prepare(directory: directory)
        lifetime.lock()
        defer { lifetime.unlock() }
        guard !active else { return }
        guard !stopping else { throw ClaudeStorageError.io }
        let fd = open(directory.appendingPathComponent(".codex-service.lock").path,
            O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw ClaudeStorageError.io }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { _ = Darwin.close(fd); throw ClaudeStorageError.io }
        lockDescriptor = fd; active = true
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(250), leeway: .milliseconds(75))
        timer.setEventHandler { [weak self] in self?.tick() }
        self.timer = timer; timer.resume()
    }

    func processPending() { queue.async { [weak self] in self?.tick() } }

    func stop() {
        lifetime.lock(); let wasActive = active; active = false
        if wasActive { stopping = true }
        let pendingAccount = accountRead; accountRead = nil
        timer?.cancel(); timer = nil; lifetime.unlock()
        pendingAccount?.cancel()
        guard wasActive else { return }
        queue.async { [self] in
            disconnect()
            try? AgentRelayStorage.writeReport(AgentProviderReport(providerID: "codex", connected: false,
                message: "Codex bridge is stopped."), directory: directory)
            nextConnect = .distantPast; nextScan = .distantPast; nextUsage = .distantPast; lastPublish = .distantPast
            usage = nil; accountMessage = nil; sessionsTruncated = false
            usageAccount = nil; usageFromOwner = false; pendingRefreshID = nil; lastUsageAttempt = .distantPast
            lifetime.lock()
            if lockDescriptor >= 0 { _ = flock(lockDescriptor, LOCK_UN); _ = Darwin.close(lockDescriptor); lockDescriptor = -1 }
            stopping = false
            lifetime.unlock()
        }
    }

    private var isActive: Bool { lifetime.lock(); defer { lifetime.unlock() }; return active }
    private var isReadingAccount: Bool { lifetime.lock(); defer { lifetime.unlock() }; return accountRead != nil }

    private func tick() {
        guard isActive else { return }
        do {
            if let request = try? AgentRelayStorage.takeUsageRefresh(providerID: "codex", directory: directory) {
                pendingRefreshID = request.id
                nextUsage = Self.manualRefreshDate(now: accountClock(), lastAttempt: lastUsageAttempt)
                if usageAccount == nil { usageAccount = .init(state: .unavailable, message: "Refreshing Codex account information.") }
                usageAccount?.refreshRequestID = request.id; usageAccount?.isRefreshing = true
                dirty = true
            }
            if client == nil && Date() >= nextConnect {
                let connection = CodexRPCClient(transport: makeTransport(endpoint))
                connection.event = { [weak self] value in self?.handle(value) }
                do {
                    try connection.connect()
                    guard isActive else { connection.close(); return }
                    client = connection; generation = UUID().uuidString
                    sessions.removeAll(); loadedIDs.removeAll(); scanOffset = 0
                    nextScan = .distantPast
                    nextUsage = Self.manualRefreshDate(now: accountClock(), lastAttempt: lastUsageAttempt)
                    dirty = true
                } catch { connection.close(); nextConnect = Date().addingTimeInterval(10); dirty = true }
            }
            if let client {
                try client.drain()
                if Date() >= nextScan {
                    try refreshLoaded(client)
                    // Spread metadata and subscriptions over bounded batches so
                    // hundreds of loaded threads cannot starve reply handling.
                    let count = min(16, loadedIDs.count)
                    let scanDeadline = Date().addingTimeInterval(4)
                    for _ in 0..<count where isActive && !loadedIDs.isEmpty {
                        scanOffset %= loadedIDs.count
                        let id = loadedIDs[scanOffset]; scanOffset += 1
                        try refreshSession(id, client: client, join: true)
                        if Date() >= scanDeadline { break }
                    }
                    nextScan = Date().addingTimeInterval(loadedIDs.count > 16 ? 1 : 4)
                }
                guard isActive else { return }
            }
            guard isActive else { return }
            if !isReadingAccount && accountClock() >= nextUsage { refreshUsage() }
            guard isActive else { return }
            processCommands()
            publish()
        } catch {
            disconnect(); nextConnect = Date().addingTimeInterval(10)
            publish()
        }
    }

    private func disconnect() {
        client?.close(); client = nil; generation = UUID().uuidString
        sessions.removeAll(); loadedIDs.removeAll(); dirty = true
    }

    private func refreshLoaded(_ client: CodexRPCClient) throws {
        var result: [String] = [], cursor: String? = nil
        var seenCursors = Set<String>()
        repeat {
            var params: [String: Any] = ["limit": 100]
            if let cursor { params["cursor"] = cursor }
            let response = try client.request("thread/loaded/list", params: params)
            guard let page = response["data"] as? [String], page.count <= 100 else { throw CodexTransportError.invalidMessage }
            result += page.compactMap(CodexProtocol.identifier)
            cursor = CodexProtocol.identifier(response["nextCursor"])
            if let cursor, !seenCursors.insert(cursor).inserted { throw CodexTransportError.invalidMessage }
        } while cursor != nil && result.count < Self.maximumLoadedSessions
        sessionsTruncated = cursor != nil || result.count > Self.maximumLoadedSessions
        loadedIDs = Array(Set(result.prefix(Self.maximumLoadedSessions))).sorted()
        let current = Set(loadedIDs)
        for id in sessions.keys where !current.contains(id) { sessions.removeValue(forKey: id); dirty = true }
        let expires = Date().addingTimeInterval(Self.ownerLeaseSeconds).timeIntervalSince1970
        for id in Array(sessions.keys) where sessions[id]?.joined == true {
            sessions[id]?.leaseExpiresAt = expires
            updateControl(id)
            dirty = true
        }
    }

    private func refreshSession(_ id: String, client: CodexRPCClient, join: Bool) throws {
        let response: [String: Any]
        do { response = try client.request("thread/read", params: ["threadId": id, "includeTurns": false]) }
        catch CodexTransportError.remote { sessions.removeValue(forKey: id); dirty = true; return }
        guard let raw = response["thread"] as? [String: Any],
              let session = CodexProtocol.session(raw), session.nativeID == id,
              session.phase != .ended else { sessions.removeValue(forKey: id); dirty = true; return }
        var state = sessions[id] ?? CodexOwnedSession(session: session)
        if state.wirePhase != session.phase { state.epoch += 1 }
        state.wirePhase = session.phase
        state.session = session
        state.acceptsInput = raw["canAcceptDirectInput"] as? Bool ?? false
        let flags = (raw["status"] as? [String: Any])?["activeFlags"] as? [String] ?? []
        state.unsupportedRequest = flags.contains("waitingOnApproval") ||
            (flags.contains("waitingOnUserInput") && state.input == nil)
        if session.phase != .working { state.turnID = nil; state.input = nil; state.unsupportedRequest = false }
        sessions[id] = state
        guard isActive else { throw CodexTransportError.disconnected }
        if join && !state.joined {
            // Loaded-list preflight avoids creating an owner for historical
            // threads. App-server has no atomic loaded-generation precondition;
            // no override or alternate process is used during this rejoin.
            do {
                let resumed = try client.request("thread/resume", params: ["threadId": id, "excludeTurns": true])
                guard let thread = resumed["thread"] as? [String: Any], thread["id"] as? String == id else { throw CodexTransportError.invalidMessage }
                sessions[id]?.joined = true
                sessions[id]?.acceptsInput = thread["canAcceptDirectInput"] as? Bool ?? false
            } catch CodexTransportError.remote {
                // Fresh/ephemeral threads may have no persisted rollout. Never
                // start a turn or recover a rollout to make them subscribable.
                sessions[id]?.joined = false
            }
        }
        guard isActive else { throw CodexTransportError.disconnected }
        if sessions[id]?.wirePhase == .working {
            do {
                let turns = try client.request("thread/turns/list", params: ["threadId": id,
                    "itemsView": "notLoaded", "limit": 1, "sortDirection": "desc"])
                let newest = (turns["data"] as? [[String: Any]])?.first
                let turnID = newest?["status"] as? String == "inProgress" ? CodexProtocol.identifier(newest?["id"]) : nil
                if sessions[id]?.turnID != turnID { sessions[id]?.epoch += 1; sessions[id]?.turnID = turnID }
            } catch CodexTransportError.remote { sessions[id]?.turnID = nil }
        }
        if sessions[id]?.joined == true {
            sessions[id]?.leaseExpiresAt = Date().addingTimeInterval(Self.ownerLeaseSeconds).timeIntervalSince1970
        } else { sessions[id]?.leaseExpiresAt = nil }
        updateControl(id); dirty = true
    }

    private func updateControl(_ id: String) {
        guard var state = sessions[id] else { return }
        let canPrompt = state.joined && state.acceptsInput && !state.unsupportedRequest && state.input == nil &&
            (state.wirePhase == .idle || state.turnID != nil)
        let revision = CodexProtocol.opaqueID("\(generation)|\(id)|\(state.epoch)|\(state.turnID ?? "idle")|\(state.input?.input.id ?? "")")
        let reason: String?
        if !state.joined { reason = "This session cannot be attached. Open it in Codex." }
        else if state.unsupportedRequest { reason = "Review this approval in the original Codex session." }
        else if !state.acceptsInput { reason = "Codex does not allow direct input to this session." }
        else if state.wirePhase == .working && state.turnID == nil { reason = "The current Codex turn is unavailable. Open the original session." }
        else { reason = nil }
        state.session.control = AgentSessionControl(revision: revision, canPrompt: canPrompt,
            request: state.input?.input, unavailableReason: reason, expiresAt: state.leaseExpiresAt)
        state.session.phase = state.wirePhase
        state.session.question = nil; state.session.questionOptions = []
        if let input = state.input {
            state.session.phase = .needsInput
            state.session.question = input.input.questions.first?.prompt
            state.session.questionOptions = (input.input.questions.first?.options ?? []).filter { $0.utf8.count <= 256 }
        } else if state.unsupportedRequest { state.session.phase = .needsInput }
        sessions[id] = state
    }

    private func handle(_ value: [String: Any]) {
        guard isActive, let method = value["method"] as? String,
              let params = value["params"] as? [String: Any] else { return }
        if method == "account/rateLimits/updated" {
            guard usageFromOwner else { return }
            usage = CodexProtocol.usage(params); accountMessage = usage == nil ? "Codex account limits are unavailable." : nil
            dirty = true; return
        }
        guard let id = CodexProtocol.identifier(params["threadId"]), sessions[id] != nil else { return }
        switch method {
        case "item/tool/requestUserInput":
            guard let wireID = value["id"], let key = CodexProtocol.requestKey(wireID),
                  let turn = CodexProtocol.identifier(params["turnId"]) else { return }
            let requestID = CodexProtocol.opaqueID(generation + "|" + id + "|" + key)
            guard let input = CodexProtocol.inputRequest(params, id: requestID) else {
                sessions[id]?.unsupportedRequest = true; updateControl(id); dirty = true; return
            }
            sessions[id]?.input = CodexPendingInput(wireID: wireID, wireKey: key, turnID: turn, input: input)
            sessions[id]?.turnID = turn; sessions[id]?.wirePhase = .working; sessions[id]?.epoch += 1
        case "serverRequest/resolved":
            guard let wireID = params["requestId"], CodexProtocol.requestKey(wireID) == sessions[id]?.input?.wireKey else { return }
            sessions[id]?.input = nil; sessions[id]?.epoch += 1; nextScan = .distantPast
        case "turn/started":
            let turn = params["turn"] as? [String: Any]
            sessions[id]?.turnID = CodexProtocol.identifier(turn?["id"])
            sessions[id]?.wirePhase = .working
            sessions[id]?.input = nil; sessions[id]?.unsupportedRequest = false; sessions[id]?.epoch += 1
        case "turn/completed":
            sessions[id]?.wirePhase = .idle; sessions[id]?.turnID = nil
            sessions[id]?.input = nil; sessions[id]?.unsupportedRequest = false; sessions[id]?.epoch += 1
        case "thread/closed", "thread/archived":
            sessions.removeValue(forKey: id); dirty = true; return
        default:
            if value["id"] != nil {
                // Commands, file changes, MCP elicitation and permission grants
                // stay in the original owner. Never auto-approve or auto-reject.
                sessions[id]?.unsupportedRequest = true; sessions[id]?.epoch += 1
            } else { return }
        }
        sessions[id]?.session.updatedAt = Date().timeIntervalSince1970
        updateControl(id); dirty = true
    }

    static func manualRefreshDate(now: Date, lastAttempt: Date) -> Date {
        max(now, lastAttempt.addingTimeInterval(30))
    }

    private func refreshUsage() {
        let cancellation = CodexAccountCancellation()
        lifetime.lock()
        guard active, accountRead == nil else { lifetime.unlock(); return }
        accountRead = cancellation
        lifetime.unlock()
        lastUsageAttempt = accountClock()
        nextUsage = .distantFuture
        if usageAccount == nil { usageAccount = .init(state: .unavailable, message: "Refreshing Codex account information.") }
        usageAccount?.isRefreshing = true
        dirty = true
        let command = Bundle.main.executableURL.map {
            CodexAccountSetup.signInCommand(helper: $0, directory: directory, executable: accountExecutable)
        }
        let refreshRequestID = pendingRefreshID
        accountQueue.async { [weak self] in
            guard let self, !cancellation.isCancelled else { return }
            let result: CodexAccountBroker.Result
            if let executable = self.accountExecutable { result = self.readAccount(executable, command, cancellation) }
            else {
                result = .init(message: "Install the official Codex CLI to connect ChatGPT subscription usage.",
                    usageAccount: .init(state: .unavailable, message: "Install the official Codex CLI to connect ChatGPT subscription usage."))
            }
            self.queue.async { [weak self] in
                self?.completeUsage(result, cancellation: cancellation, refreshRequestID: refreshRequestID)
            }
        }
    }

    private func completeUsage(_ account: CodexAccountBroker.Result, cancellation: CodexAccountCancellation, refreshRequestID: String?) {
        lifetime.lock()
        let current = active && accountRead === cancellation
        if accountRead === cancellation { accountRead = nil }
        lifetime.unlock()
        guard current, !cancellation.isCancelled else { return }
        var result = account
        usageFromOwner = false
        // A separately selected usage account takes precedence. Never replace
        // it with another owner's quota after a transient error or auth expiry.
        if result.allowsOwnerFallback && !result.authenticated, let client,
           let raw = try? client.request("account/rateLimits/read"), let quota = CodexProtocol.usage(raw) {
            result = .init(usage: quota, usageAccount: .init(state: .connected, message: "ChatGPT subscription connected through the current Codex owner."), authenticated: true)
            usageFromOwner = true
        }
        usage = result.usage; accountMessage = result.message; usageAccount = result.usageAccount
        usageAccount?.refreshRequestID = pendingRefreshID
        let needsAnotherRead = pendingRefreshID != refreshRequestID
        usageAccount?.isRefreshing = needsAnotherRead
        // A login or refresh arriving after this read began needs a fresh read.
        // Keep only its latest UUID, and preserve the minimum interval.
        nextUsage = needsAnotherRead ? Self.manualRefreshDate(now: accountClock(), lastAttempt: lastUsageAttempt) : accountClock().addingTimeInterval(300)
        dirty = true
        publish()
    }

    private func processCommands() {
        guard let commands = try? AgentRelayStorage.takeCommands(providerID: "codex", directory: directory) else { return }
        for command in commands {
            guard isActive else { return }
            var receipt = AgentMessageReceipt(id: command.id, sessionID: command.sessionID,
                state: .rejected, message: "The Codex session changed. Review it before sending again.")
            guard let client, let before = sessions[command.sessionID]?.session.control,
                  command.matches(before) else { try? AgentRelayStorage.writeReceipt(receipt, directory: directory); continue }
            var dispatched = false
            do {
                // Drain pending turn/request changes and re-read the same owner's
                // loaded list before any effect. Never reuse stale UI controls.
                try client.drain()
                try refreshLoaded(client)
                guard loadedIDs.contains(command.sessionID) else { throw CodexTransportError.unavailable }
                try refreshSession(command.sessionID, client: client, join: false)
                guard let state = sessions[command.sessionID], let control = state.session.control,
                      isActive, command.matches(control) else { throw CodexTransportError.unavailable }
                if let pending = state.input, command.requestID == pending.input.id {
                    let answers = command.answers.mapValues { ["answers": $0] }
                    dispatched = true
                    try client.reply(id: pending.wireID, result: ["answers": answers])
                    // Server-request replies do not have a reply acknowledgement.
                    // A resolved notification can also mean another client won.
                    receipt.state = .unknown
                    receipt.message = "Reply sent to Codex. Check the original session to confirm it was applied."
                    sessions[command.sessionID]?.input = nil
                    sessions[command.sessionID]?.epoch += 1
                } else if let text = command.text {
                    let input: [[String: Any]] = [["type": "text", "text": text]]
                    var params: [String: Any] = ["threadId": command.sessionID, "input": input,
                        "clientUserMessageId": command.id]
                    let method: String
                    if let turn = state.turnID {
                        method = "turn/steer"; params["expectedTurnId"] = turn
                    } else {
                        guard state.wirePhase == .idle else { throw CodexTransportError.unavailable }
                        // The protocol has no atomic expected-idle guard. A turn
                        // that starts after this read can receive the input as a
                        // steer in this same session. Never retry automatically.
                        method = "turn/start"
                    }
                    dispatched = true
                    _ = try client.request(method, params: params)
                    receipt.state = .accepted; receipt.message = "Codex accepted your message."
                    sessions[command.sessionID]?.epoch += 1
                }
            } catch CodexTransportError.remote {
                receipt.state = .rejected; receipt.message = "Codex rejected the message. Open the original session for details."
            } catch {
                if dispatched {
                    receipt.state = .unknown
                    receipt.message = "Codex did not confirm delivery. Check the original session before sending again."
                    disconnect(); nextConnect = Date().addingTimeInterval(10)
                }
            }
            updateControl(command.sessionID); dirty = true; nextScan = .distantPast
            try? AgentRelayStorage.writeReceipt(receipt, directory: directory)
        }
    }

    private func publish() {
        guard isActive, dirty || Date().timeIntervalSince(lastPublish) >= 10 else { return }
        var message = client == nil ? "No attachable Codex app-server. Codex Desktop sessions require an endpoint exposed by their owner. \(accountMessage ?? "")" : accountMessage
        if sessionsTruncated { message = "Showing up to \(Self.maximumLoadedSessions) loaded Codex sessions. " + (message ?? "") }
        // Keep the aggregate report below its byte ceiling even when every
        // visible session carries several unusually long questions/options.
        var size = 65_536
        var visible: [AgentSession] = []
        for session in sessions.values.map(\.session).sorted(by: { $0.updatedAt > $1.updatedAt }) {
            let encodedSize = (try? JSONEncoder().encode(session).count) ?? AgentRelayStorage.maximumReportBytes
            guard size + encodedSize < AgentRelayStorage.maximumReportBytes else { continue }
            visible.append(session); size += encodedSize + 1
        }
        let report = AgentProviderReport(providerID: "codex", connected: client != nil,
            sessions: visible, usage: usage, message: message, usageAccount: usageAccount)
        if (try? AgentRelayStorage.writeReport(report, directory: directory)) != nil { dirty = false; lastPublish = Date() }
    }
}
