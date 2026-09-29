// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Darwin

private final class FixtureTransport: CodexRPCTransport {
    let lock = NSLock()
    var inbound: [[String: Any]] = []
    var requests: [[String: Any]] = []
    var timeouts: [String: TimeInterval] = [:]
    var phase = "idle"
    var turnID = "fixture-turn"
    var loaded = true
    var rejectSend = false
    var loseSendAcknowledgement = false
    var closed = false
    var closeBarrier: (() -> Void)?
    let sessionID = "fixture-codex-session"

    func withLock<T>(_ body: () throws -> T) rethrows -> T { lock.lock(); defer { lock.unlock() }; return try body() }
    func connect() throws { withLock { closed = false } }
    func close() {
        let barrier = withLock { closed = true; return closeBarrier }
        barrier?()
    }
    func send(_ value: [String: Any], timeout: TimeInterval) throws {
        try withLock {
            requests.append(value)
            guard let method = value["method"] as? String else { return }
            timeouts[method] = timeout
            if method == "initialized" { return }
            let id = value["id"]!
            var result: [String: Any] = [:]
            let thread: [String: Any] = ["id": sessionID, "cwd": "/tmp/fixture-project", "createdAt": 1000,
                "updatedAt": 1001, "canAcceptDirectInput": true, "status": ["type": phase, "activeFlags": []],
                "preview": "This private conversation preview must be discarded."]
            switch method {
            case "initialize": break
            case "thread/loaded/list": result = ["data": loaded ? [sessionID] : []]
            case "thread/read", "thread/resume": result = ["thread": thread]
            case "thread/turns/list": result = ["data": [["id": turnID, "status": "inProgress", "items": []]]]
            case "account/rateLimits/read":
                result = ["rateLimits": ["planType": "plus", "primary": ["usedPercent": 25, "windowDurationMins": 300]]]
            case "turn/start", "turn/steer":
                if rejectSend { inbound.append(["id": id, "error": ["code": -32600, "message": "fixture private error"]]); return }
                if loseSendAcknowledgement { throw CodexTransportError.disconnected }
                result = ["turnId": turnID]
            default: throw CodexTransportError.invalidMessage
            }
            inbound.append(["id": id, "result": result])
        }
    }
    func receive(timeout: TimeInterval) throws -> [String: Any]? {
        withLock { inbound.isEmpty ? nil : inbound.removeFirst() }
    }
    func injectQuestion(secret: Bool = false) {
        withLock {
            phase = "active"
            inbound.append(["id": 77, "method": "item/tool/requestUserInput", "params": [
                "threadId": sessionID, "turnId": turnID, "itemId": "fixture-question-item", "isBlocking": true,
                "questions": [["id": "color", "header": "Color", "question": "Choose a color.", "isSecret": secret,
                    "options": [["label": "Blue", "description": "A blue color."], ["label": "Green", "description": "A green color."]]]]]])
        }
    }
    func sent(_ method: String) -> [[String: Any]] { withLock { requests.filter { $0["method"] as? String == method } } }
}

private final class FixtureAccountReadProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var reads = 0
    private var completions = 0
    private var cancellation: CodexAccountCancellation?
    private let firstResultGate: DispatchSemaphore?
    init(holdFirstResult: Bool = false) { firstResultGate = holdFirstResult ? DispatchSemaphore(value: 0) : nil }
    var count: Int { lock.lock(); defer { lock.unlock() }; return reads }
    var completed: Int { lock.lock(); defer { lock.unlock() }; return completions }
    var cancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancellation?.isCancelled == true }
    func releaseFirstResult() { firstResultGate?.signal() }
    func read(executable: URL, home: URL, cancellation: CodexAccountCancellation) -> CodexAccountBroker.Result {
        lock.lock(); reads += 1; let ordinal = reads; self.cancellation = cancellation; lock.unlock()
        let result = CodexAccountBroker.read(executable: executable, dedicatedHome: home, cancellation: cancellation)
        lock.lock(); completions += 1; lock.unlock()
        if ordinal == 1 { firstResultGate?.wait() }
        return result
    }
}

private final class FixtureAccount {
    private let lock = NSLock()
    private var time = Date()
    private var reads = 0
    func now() -> Date { lock.lock(); defer { lock.unlock() }; return time }
    func advance() { lock.lock(); time = time.addingTimeInterval(31); lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return reads }
    func read() -> CodexAccountBroker.Result {
        lock.lock(); defer { lock.unlock() }; reads += 1
        return .init(usage: .init(updatedAt: time.timeIntervalSince1970,
            windows: [.init(id: "primary", title: "5 hours", remainingPercent: reads == 1 ? 42 : 40)]),
            usageAccount: .init(state: .connected, message: "Fixture subscription connected."),
            authenticated: true, allowsOwnerFallback: false)
    }
}

@main
@MainActor
struct CodexBridgeTests {
    static var count = 0
    static func expect(_ condition: @autoclosure () -> Bool, _ label: String) {
        count += 1
        if !condition() { fatalError("Codex assertion failed: \(label)") }
    }
    static func eventually(_ label: String, _ body: () -> Bool) {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if body() { count += 1; return }
            Thread.sleep(forTimeInterval: 0.02)
        }
        fatalError("Codex timed out: \(label)")
    }

    static func main() throws {
        signal(SIGPIPE, SIG_IGN)
        if CommandLine.arguments.last == "app-server" { try accountServerFixture(); return }
        protocolTests()
        try accountRestrictionTests()
        accountContextTests()
        try usageRefreshTests()
        try accountStartupAndIsolationTests()
        try serviceTests()
        print("Codex bridge: \(count) assertions passed (isolated fixtures; no real accounts or sessions).")
    }

    static func protocolTests() {
        let raw: [String: Any] = ["id": "thread-1", "cwd": "/tmp/my-project", "createdAt": 1000, "updatedAt": 2000,
            "status": ["type": "active"], "preview": "PRIVATE", "name": "PRIVATE TITLE"]
        let parsed = CodexProtocol.session(raw)
        expect(parsed?.project == "my-project", "directory basename identifies project")
        expect(parsed?.phase == .working, "active phase")
        expect(parsed?.question == nil, "preview discarded")
        var child = raw; child["parentThreadId"] = "parent"
        expect(CodexProtocol.session(child) == nil, "subagents excluded")
        var bad = raw; bad["createdAt"] = true
        expect(CodexProtocol.session(bad) == nil, "boolean is not timestamp")
        bad = raw; bad["cwd"] = "relative/path"
        expect(CodexProtocol.session(bad) == nil, "relative cwd rejected")
        expect(CodexProtocol.requestKey(77) != CodexProtocol.requestKey("77"), "numeric and string IDs remain distinct")
        expect(CodexProtocol.requestKey(true) == nil, "boolean request ID rejected")
        expect(CodexProtocol.identifier("bad\nidentifier") == nil, "control characters rejected")
        expect(CodexProtocol.opaqueID("owner-a") != CodexProtocol.opaqueID("owner-b"), "connection generations differ")

        let usage: [String: Any] = ["rateLimits": ["primary": ["usedPercent": 99]],
            "rateLimitsByLimitId": ["codex": ["planType": "pro", "primary": ["usedPercent": 25, "windowDurationMins": 300],
                "secondary": ["usedPercent": 50, "windowDurationMins": 10080]],
                "special-model": ["primary": ["usedPercent": 100]]]]
        let quota = CodexProtocol.usage(usage, now: Date(timeIntervalSince1970: 1000))
        expect(quota?.limitingRemainingPercent == 50, "ordinary Codex allowance, not specialized quota")
        expect(quota?.windows.count == 2, "both quota windows")
        expect(quota?.windows.first?.title == "5 hours", "five-hour label")
        expect(quota?.windows.last?.title == "Weekly", "weekly label")
        expect(quota?.planName == "pro", "plan exposed without identity")
        expect(CodexProtocol.usage(["rateLimits": [:]]) == nil, "missing quota never zero")
        expect(CodexProtocol.usage(["rateLimits": ["primary": ["usedPercent": true]]]) == nil, "boolean quota rejected")
        expect(CodexProtocol.usage(["rateLimits": ["primary": ["usedPercent": 101]]]) == nil, "out-of-range quota rejected")
        expect(CodexProtocol.usage(["rateLimits": ["limitId": "special-model", "primary": ["usedPercent": 99]]]) == nil, "specialized fallback is not ordinary allowance")
        expect(CodexProtocol.usage(["rateLimits": ["primary": ["usedPercent": 100]]])?.limitingRemainingPercent == 0, "exhausted quota preserved")

        let question: [String: Any] = ["questions": [["id": "a", "header": "A", "question": "Choose.", "isSecret": true]]]
        expect(CodexProtocol.inputRequest(question, id: "req")?.questions.first?.isSecret == true, "secret question remains marked")
        expect(CodexProtocol.inputRequest(["questions": []], id: "req") == nil, "empty questions rejected")
        expect(CodexProtocol.inputRequest(["questions": Array(repeating: ["id": "a", "question": "Q"], count: 5)], id: "req") == nil, "question count bounded")
        for size in [0, 12, 125, 126, 65_535, 65_536] {
            let payload = Data(repeating: 0x41, count: size)
            let frame = [UInt8](CodexUnixWebSocket.frame(payload, opcode: 1))
            expect(frame[0] == 0x81 && frame[1] & 0x80 != 0, "client frames masked and final")
            let offset = size < 126 ? 2 : size <= 65_535 ? 4 : 10
            let mask = Array(frame[offset..<(offset + 4)])
            let decoded = frame.dropFirst(offset + 4).enumerated().map { $0.element ^ mask[$0.offset % 4] }
            expect(Data(decoded) == payload, "frame mask roundtrip \(size)")
        }
    }

    static func accountRestrictionTests() throws {
        expect(CodexAccountBroker.accountUnavailable(["account": ["type": "apiKey"]])?.contains("API-key") == true, "API-key quota unavailable")
        expect(CodexAccountBroker.accountUnavailable(["account": NSNull()])?.contains("not signed in") == true, "absent login honest")
        expect(CodexAccountBroker.accountUnavailable(["account": NSNull(), "requiresOpenaiAuth": false])?.contains("provider") == true, "configured external provider is not mislabeled signed out")
        expect(CodexAccountBroker.accountUnavailable(["account": ["type": "chatgpt"]]) == nil, "ChatGPT account eligible")
        expect(CodexAccountBroker.accountUnavailable(["account": ["type": "future"]]) != nil, "unknown auth unsupported")
        expect(!CodexAccountTransport.allowedMethods.contains("thread/resume"), "account broker cannot resume")
        expect(!CodexAccountTransport.allowedMethods.contains("turn/start"), "account broker cannot start")
        expect(!CodexAccountTransport.allowedMethods.contains("account/login/start"), "account broker cannot login")
        let transport = CodexAccountTransport(executable: URL(fileURLWithPath: "/not/an/executable"))
        do { try transport.send(["method": "thread/resume"], timeout: 1); expect(false, "thread send rejected") }
        catch { expect(true, "thread send rejected") }
        let unsafe = CodexUnixWebSocket(endpoint: URL(fileURLWithPath: "/tmp/does-not-exist-boringagent.sock"))
        do { try unsafe.connect(); expect(false, "absent socket rejected") }
        catch { expect(true, "absent socket rejected") }

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("boring-codex-unsafe-account-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try ClaudeStorage.ensureDirectory(directory)
        let accountHome = directory.appendingPathComponent("account")
        try FileManager.default.createDirectory(at: accountHome, withIntermediateDirectories: false)
        guard chmod(accountHome.path, 0o777) == 0 else { throw ClaudeStorageError.io }
        let rejectedAccount = CodexAccountBroker.read(executable: URL(fileURLWithPath: "/not/an/executable"), dedicatedHome: accountHome)
        expect(rejectedAccount.usageAccount.state == .failed && !rejectedAccount.allowsOwnerFallback,
            "unsafe dedicated account cannot select unrelated owner quota")
        let fixture = FixtureTransport()
        let service = CodexBridgeService(directory: directory.appendingPathComponent("relay"),
            accountExecutable: URL(fileURLWithPath: "/not/an/executable"), makeTransport: { _ in fixture },
            readAccount: { _, _, _ in rejectedAccount })
        try service.start(); defer { service.stop() }
        eventually("unsafe account reports failure while sessions remain connected") {
            let report = try? AgentRelayStorage.report(providerID: "codex", directory: directory.appendingPathComponent("relay"))
            return report?.connected == true && report?.usageAccount?.state == .failed && report?.usage == nil
        }
        expect(fixture.sent("account/rateLimits/read").isEmpty, "unsafe dedicated account blocks owner quota fallback")
    }

    static func accountContextTests() {
        let original = ["OPENAI_API_KEY": "fixture", "AZURE_OPENAI_API_KEY": "fixture",
            "OPENAI_BASE_URL": "https://fixture.invalid", "CODEX_ACCESS_TOKEN": "fixture",
            "CODEX_HOME": "/fixture/normal-codex", "HTTPS_PROXY": "https://fixture-proxy.invalid",
            "SSL_CERT_FILE": "/fixture/ca.pem", "PATH": "/usr/bin"]
        let clean = CodexAccountSetup.environment(original, home: nil)
        expect(clean["OPENAI_API_KEY"] == nil && clean["AZURE_OPENAI_API_KEY"] == nil, "account child cannot inherit provider API keys")
        expect(clean["OPENAI_BASE_URL"] == nil && clean["CODEX_ACCESS_TOKEN"] == nil, "API endpoint and token overrides removed")
        expect(clean["CODEX_HOME"] == original["CODEX_HOME"], "existing CLI credential home preserved for fallback")
        expect(clean["HTTPS_PROXY"] == original["HTTPS_PROXY"] && clean["SSL_CERT_FILE"] == original["SSL_CERT_FILE"], "TLS and proxy configuration preserved")
        expect(original["OPENAI_API_KEY"] == "fixture", "parent environment is unchanged")
        let launchd = CodexAccountSetup.runtimeEnvironment(["PATH": "/usr/bin:/bin", "OPENAI_API_KEY": "fixture"],
            home: nil, executable: URL(fileURLWithPath: "/fixture/node/bin/codex.js"), usableNode: { $0.path == "/fixture/node/bin/node" })
        expect(launchd["PATH"] == "/fixture/node/bin:/usr/bin:/bin", "npm runtime resolved under minimal launchd PATH")
        expect(launchd["OPENAI_API_KEY"] == nil, "runtime fix preserves authentication sanitization")
        let dedicated = CodexAccountSetup.environment(original, home: URL(fileURLWithPath: "/fixture/private-usage"))
        expect(dedicated["CODEX_HOME"] == "/fixture/private-usage", "usage login has separate credential home")
        let readArgs = CodexAccountSetup.arguments(command: ["app-server"], dedicated: false)
        expect(readArgs == ["-c", "model_provider=\"openai\"", "app-server"], "account provider selected per process")
        let loginArgs = CodexAccountSetup.arguments(command: ["login", "--device-auth"], dedicated: true)
        expect(loginArgs.contains("cli_auth_credentials_store=\"file\""), "dedicated credentials bound to documented home")
        expect(loginArgs.suffix(2) == ["login", "--device-auth"], "explicit official device login")
        expect(!loginArgs.contains(where: { $0.contains("forced_login_method") }), "no forced-login mismatch can clear default credentials")
        expect(!CodexAccountSetup.accountHome.path.hasPrefix(ClaudeStorage.defaultDirectory.path + "/"), "credential home outside relay")
        let command = CodexAccountSetup.signInCommand(helper: URL(fileURLWithPath: "/fixture/a'b/helper"),
            directory: URL(fileURLWithPath: "/fixture/data $(unsafe)"), executable: nil)
        expect(command.contains("'\\''") && command.contains("'/fixture/data $(unsafe)'"), "sign-in command paths are shell-quoted")

        let connected = CodexAccountBroker.Result(usageAccount: .init(state: .connected, message: "Connected"), authenticated: true)
        let missing = CodexAccountBroker.Result(usageAccount: .init(state: .signInRequired, message: "Sign in", signInCommand: "fixture-login"))
        let failed = CodexAccountBroker.Result(usageAccount: .init(state: .failed, message: "Retry", signInCommand: "fixture-login"), authenticated: true)
        var usedFallback = false
        let preferred = CodexAccountBroker.preferred(dedicatedExists: true, dedicated: { connected }, existing: { usedFallback = true; return missing })
        expect(preferred.usageAccount.state == .connected && !usedFallback && !preferred.allowsOwnerFallback, "dedicated account wins")
        _ = CodexAccountBroker.preferred(dedicatedExists: true, dedicated: { failed }, existing: { usedFallback = true; return connected })
        expect(!usedFallback, "failed dedicated account never becomes unrelated account")
        let fallback = CodexAccountBroker.preferred(dedicatedExists: true, dedicated: { missing }, existing: { connected })
        expect(fallback.authenticated, "empty dedicated store can use existing ChatGPT login")
        let status = AgentUsageAccountStatus(state: .signInRequired, message: "Sign in", signInCommand: command)
        expect(status.isValid, "actionable auth status validates")
        expect(!AgentUsageAccountStatus(state: .failed, message: "", signInCommand: nil).isValid, "empty account message rejected")
        let now = Date(timeIntervalSince1970: 1000)
        expect(CodexBridgeService.manualRefreshDate(now: now, lastAttempt: now) == now.addingTimeInterval(30), "manual refresh minimum interval")
        expect(CodexBridgeService.manualRefreshDate(now: now.addingTimeInterval(31), lastAttempt: now) == now.addingTimeInterval(31), "elapsed cooldown refresh is immediate")
    }

    static func usageRefreshTests() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("boring-codex-refresh-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = try AgentRelayStorage.requestUsageRefresh(providerID: "codex", directory: directory)
        let second = try AgentRelayStorage.requestUsageRefresh(providerID: "codex", directory: directory)
        expect(first != second, "each refresh has a new acknowledgment identity")
        let claimed = try AgentRelayStorage.takeUsageRefresh(providerID: "codex", directory: directory)
        expect(claimed?.id == second, "latest request replaces one pending slot")
        let duplicate = try AgentRelayStorage.takeUsageRefresh(providerID: "codex", directory: directory)
        expect(duplicate == nil, "refresh consumed once")
        let stale = AgentUsageRefreshRequest(createdAt: Date().addingTimeInterval(-121).timeIntervalSince1970)
        try ClaudeStorage.atomicWrite(JSONEncoder().encode(stale), to: directory.appendingPathComponent("usage-refresh-codex.json"))
        let expired = try AgentRelayStorage.takeUsageRefresh(providerID: "codex", directory: directory)
        expect(expired == nil, "stale refresh discarded")

        let fixture = FixtureTransport(), account = FixtureAccount()
        let service = CodexBridgeService(directory: directory, accountExecutable: URL(fileURLWithPath: "/fixture/codex"),
            makeTransport: { _ in fixture }, readAccount: { _, _, _ in account.read() }, accountClock: { account.now() })
        try service.start(); defer { service.stop() }
        func report() -> AgentProviderReport? { try? AgentRelayStorage.report(providerID: "codex", directory: directory) }
        eventually("dedicated quota report") { report()?.usage?.limitingRemainingPercent == 42 }
        expect(fixture.sent("account/rateLimits/read").isEmpty, "owner account never overrides selected subscription")
        fixture.withLock { fixture.inbound.append(["method": "account/rateLimits/updated", "params": ["rateLimits": ["primary": ["usedPercent": 99]]]]) }
        service.processPending(); Thread.sleep(forTimeInterval: 0.1)
        expect(report()?.usage?.limitingRemainingPercent == 42, "unrelated owner quota notification ignored")
        let refreshID = try AgentRelayStorage.requestUsageRefresh(providerID: "codex", directory: directory)
        eventually("refresh scheduling acknowledgment") { report()?.usageAccount?.refreshRequestID == refreshID && report()?.usageAccount?.isRefreshing == true }
        expect(account.count == 1, "manual refresh during cooldown does not spawn another account broker")
        let replacement = try AgentRelayStorage.requestUsageRefresh(providerID: "codex", directory: directory)
        eventually("replacement coalesced") { report()?.usageAccount?.refreshRequestID == replacement }
        expect(account.count == 1, "repeated refresh stays bounded")
        account.advance(); service.processPending()
        eventually("real refresh runs after cooldown") { account.count == 2 && report()?.usageAccount?.refreshRequestID == replacement && report()?.usageAccount?.isRefreshing == false }
        expect(report()?.usage?.limitingRemainingPercent == 40, "manual refresh publishes newly fetched quota")
        service.stop()
        eventually("refresh test stop") { report()?.connected == false }
    }

    /// This test binary doubles as a private slow account-only server. It never
    /// invokes Codex or reads any real credentials/configuration.
    static func accountServerFixture() throws {
        guard let home = ProcessInfo.processInfo.environment["CODEX_HOME"] else { throw ClaudeStorageError.invalidRecord }
        let directory = URL(fileURLWithPath: home)
        let delay = Double(try String(contentsOf: directory.appendingPathComponent("fixture-delay"), encoding: .utf8)) ?? 0
        try String(getpid()).write(to: directory.appendingPathComponent("fixture-pid"), atomically: true, encoding: .utf8)
        while let line = readLine() {
            guard let request = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let id = request["id"], let method = request["method"] as? String else { continue }
            let result: [String: Any]
            if method == "initialize" { Thread.sleep(forTimeInterval: delay); result = [:] }
            else if method == "account/read" { result = ["account": ["type": "chatgpt"], "requiresOpenaiAuth": true] }
            else if method == "account/rateLimits/read" { result = ["rateLimits": ["primary": ["usedPercent": 10]]] }
            else { throw ClaudeStorageError.invalidRecord }
            var bytes = try JSONSerialization.data(withJSONObject: ["id": id, "result": result]); bytes.append(0x0a)
            try FileHandle.standardOutput.write(contentsOf: bytes)
        }
    }

    static func accountStartupAndIsolationTests() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("boring-codex-cold-start-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let accountHome = directory.appendingPathComponent("account")
        try ClaudeStorage.ensureDirectory(accountHome)
        try "9".write(to: accountHome.appendingPathComponent("fixture-delay"), atomically: true, encoding: .utf8)
        let fixture = FixtureTransport(), account = FixtureAccountReadProbe(), clock = FixtureAccount()
        let service = CodexBridgeService(directory: directory.appendingPathComponent("relay"),
            accountExecutable: Bundle.main.executableURL, makeTransport: { _ in fixture },
            readAccount: { executable, _, cancellation in account.read(executable: executable, home: accountHome, cancellation: cancellation) },
            accountClock: { clock.now() })
        func report() -> AgentProviderReport? { try? AgentRelayStorage.report(providerID: "codex", directory: directory.appendingPathComponent("relay")) }
        try service.start(); defer { service.stop() }
        let started = Date()
        eventually("cold account child starts") { FileManager.default.fileExists(atPath: accountHome.appendingPathComponent("fixture-pid").path) }
        eventually("session controls available during slow account initialization") { report()?.sessions.first?.control?.canPrompt == true }
        let control = report()!.sessions[0].control!
        let command = AgentMessageCommand(providerID: "codex", sessionID: fixture.sessionID, revision: control.revision, text: "fixture cold-start prompt")
        try AgentRelayStorage.submit(command, directory: directory.appendingPathComponent("relay"))
        eventually("prompt acknowledged before account initializes") {
            (try? AgentRelayStorage.receipt(id: command.id, directory: directory.appendingPathComponent("relay")))?.state == .accepted
        }
        expect(account.completed == 0, "slow account startup never blocks prompt processing")
        fixture.injectQuestion()
        eventually("question remains live during account startup") { report()?.sessions.first?.control?.request != nil }
        let question = report()!.sessions[0].control!
        let reply = AgentMessageCommand(providerID: "codex", sessionID: fixture.sessionID, revision: question.revision,
            answers: ["color": ["Blue"]], requestID: question.request!.id)
        try AgentRelayStorage.submit(reply, directory: directory.appendingPathComponent("relay"))
        eventually("question reply dispatched before account initializes") {
            (try? AgentRelayStorage.receipt(id: reply.id, directory: directory.appendingPathComponent("relay")))?.state == .unknown
        }
        let first = try AgentRelayStorage.requestUsageRefresh(providerID: "codex", directory: directory.appendingPathComponent("relay"))
        eventually("first overlapping refresh acknowledged pending") { report()?.usageAccount?.refreshRequestID == first }
        let second = try AgentRelayStorage.requestUsageRefresh(providerID: "codex", directory: directory.appendingPathComponent("relay"))
        eventually("overlapping refresh coalesces") { report()?.usageAccount?.refreshRequestID == second && report()?.usageAccount?.isRefreshing == true }
        expect(account.count == 1, "only one account child during overlapping refresh")
        let deadline = Date().addingTimeInterval(12)
        while report()?.usageAccount?.state != .connected && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        expect(report()?.usage?.limitingRemainingPercent == 90 && Date().timeIntervalSince(started) >= 8,
            "account initialization exceeding ordinary deadline succeeds")
        expect(report()?.usageAccount?.refreshRequestID == second && report()?.usageAccount?.isRefreshing == true && account.count == 1,
            "refresh arriving during account read remains pending after older result")
        try "0".write(to: accountHome.appendingPathComponent("fixture-delay"), atomically: true, encoding: .utf8)
        clock.advance(); service.processPending()
        eventually("coalesced follow-up read completes after cooldown") {
            report()?.usageAccount?.refreshRequestID == second && report()?.usageAccount?.isRefreshing == false && account.count == 2
        }
        expect(fixture.withLock { fixture.timeouts["initialize"] == 8 && fixture.timeouts["turn/start"] == 8 },
            "owner initialization and interactive RPC deadlines remain eight seconds")
        service.stop()
        eventually("cold-start service stopped") { report()?.connected == false }

        let cancelHome = directory.appendingPathComponent("cancel-account")
        try ClaudeStorage.ensureDirectory(cancelHome)
        try "60".write(to: cancelHome.appendingPathComponent("fixture-delay"), atomically: true, encoding: .utf8)
        let cancelOwner = FixtureTransport(), cancelRead = FixtureAccountReadProbe(holdFirstResult: true)
        defer { cancelRead.releaseFirstResult() }
        let cancelDirectory = directory.appendingPathComponent("cancel-relay")
        func cancelReport() -> AgentProviderReport? { try? AgentRelayStorage.report(providerID: "codex", directory: cancelDirectory) }
        let cancelledService = CodexBridgeService(directory: directory.appendingPathComponent("cancel-relay"),
            accountExecutable: Bundle.main.executableURL, makeTransport: { _ in cancelOwner },
            readAccount: { executable, _, cancellation in cancelRead.read(executable: executable, home: cancelHome, cancellation: cancellation) })
        try cancelledService.start(); defer { cancelledService.stop() }
        eventually("cancellable account child starts") { FileManager.default.fileExists(atPath: cancelHome.appendingPathComponent("fixture-pid").path) }
        eventually("cancellable service has published its live report") { cancelReport()?.connected == true }
        let pid = Int32(try String(contentsOf: cancelHome.appendingPathComponent("fixture-pid"), encoding: .utf8))!

        // Stop publishes on the service queue; process termination completes
        // on the independent account queue. Force the ordering that exposed
        // the former test race instead of treating child exit as a queue barrier.
        let stopEntered = DispatchSemaphore(value: 0), allowStop = DispatchSemaphore(value: 0)
        cancelOwner.withLock { cancelOwner.closeBarrier = { stopEntered.signal(); allowStop.wait() } }
        defer { allowStop.signal() }
        cancelledService.stop()
        eventually("stop report is deliberately held on service queue") { stopEntered.wait(timeout: .now()) == .success }
        eventually("stop cancels cold account child promptly") { cancelRead.cancelled && cancelRead.completed == 1 && kill(pid, 0) != 0 }
        expect(cancelReport()?.connected == true, "child exit alone does not imply stop report is published")
        allowStop.signal()
        eventually("stop report publishes independently of child completion") {
            cancelReport()?.connected == false && cancelReport()?.usageAccount == nil && cancelReport()?.usage == nil
        }
        cancelOwner.withLock { cancelOwner.closeBarrier = nil }

        // Hold the old account result until a new service lifetime is active.
        // Starting its next account read proves the old completion was queued;
        // an acknowledged prompt then proves the service queue processed it.
        eventually("service restarts after asynchronous stop completes") {
            do { try cancelledService.start(); return true } catch { return false }
        }
        eventually("new lifetime publishes controls while old result is held") { cancelReport()?.sessions.first?.control?.canPrompt == true }
        let restartedControl = cancelReport()!.sessions[0].control!
        cancelRead.releaseFirstResult()
        eventually("next account read follows queued old completion") { cancelRead.count == 2 }
        let restartedPrompt = AgentMessageCommand(providerID: "codex", sessionID: cancelOwner.sessionID,
            revision: restartedControl.revision, text: "fixture restarted lifetime prompt")
        try AgentRelayStorage.submit(restartedPrompt, directory: cancelDirectory)
        eventually("new lifetime processes prompt after stale account completion") {
            (try? AgentRelayStorage.receipt(id: restartedPrompt.id, directory: cancelDirectory))?.state == .accepted
        }
        expect(cancelReport()?.connected == true && cancelReport()?.usageAccount?.state == .unavailable &&
            cancelReport()?.usageAccount?.isRefreshing == true && cancelReport()?.usage == nil,
            "late cancelled result cannot overwrite the new lifetime")
        var restartedPID: Int32?
        eventually("new account child is independently cancellable") {
            restartedPID = (try? String(contentsOf: cancelHome.appendingPathComponent("fixture-pid"), encoding: .utf8)).flatMap(Int32.init)
            return restartedPID != nil && restartedPID != pid && kill(restartedPID!, 0) == 0
        }
        cancelledService.stop()
        eventually("restarted service and account child both stop") {
            cancelRead.cancelled && cancelRead.completed == 2 && kill(restartedPID!, 0) != 0 && cancelReport()?.connected == false
        }
        expect(cancelReport()?.usageAccount == nil && cancelReport()?.usage == nil, "stopped report contains no account result")
        expect(cancelOwner.sent("turn/interrupt").isEmpty, "account cancellation never interrupts the session owner")
    }

    static func serviceTests() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("boring-codex-fixtures-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = FixtureTransport()
        let service = CodexBridgeService(directory: directory, accountExecutable: URL(fileURLWithPath: "/fixture/no-account-executable"), makeTransport: { _ in fixture })
        try service.start()
        defer { service.stop() }
        func report() -> AgentProviderReport? { try? AgentRelayStorage.report(providerID: "codex", directory: directory) }
        eventually("connected report") { report()?.sessions.first?.control?.canPrompt == true }
        expect(report()?.connected == true, "existing owner connected")
        eventually("quota wired independently") { report()?.usage?.limitingRemainingPercent == 75 }
        let resume = fixture.sent("thread/resume").first?["params"] as? [String: Any]
        expect(Set(resume?.keys.map { $0 } ?? []) == Set(["threadId", "excludeTurns"]), "rejoin has no config or path overrides")
        let stored = try String(contentsOf: directory.appendingPathComponent("providers/codex.json"), encoding: .utf8)
        expect(!stored.contains("private conversation"), "report contains no conversation preview")
        let control = report()!.sessions[0].control!
        expect(control.hasLiveLease(at: Date()), "verified idle owner has a live lease despite old activity timestamp")
        expect(report()!.sessions[0].updatedAt == 1001, "lease does not falsify session activity time")
        expect(control.isExpired(at: Date().addingTimeInterval(CodexBridgeService.ownerLeaseSeconds + 1)), "owner lease has a bounded expiry")
        eventually("owner poll renews lease without invalidating draft") {
            guard let renewed = report()?.sessions.first?.control else { return false }
            return (renewed.expiresAt ?? 0) > (control.expiresAt ?? 0) && renewed.revision == control.revision
        }
        let stale = AgentMessageCommand(providerID: "codex", sessionID: fixture.sessionID, revision: "stale", text: "fixture stale")
        try AgentRelayStorage.submit(stale, directory: directory)
        eventually("stale rejection") { (try? AgentRelayStorage.receipt(id: stale.id, directory: directory))?.state == .rejected }
        expect(fixture.sent("turn/start").isEmpty, "stale command has no effect")

        let prompt = AgentMessageCommand(providerID: "codex", sessionID: fixture.sessionID, revision: control.revision, text: "fixture prompt")
        try AgentRelayStorage.submit(prompt, directory: directory)
        eventually("prompt accepted") { (try? AgentRelayStorage.receipt(id: prompt.id, directory: directory))?.state == .accepted }
        expect(fixture.sent("turn/start").count == 1, "single idle prompt")
        let promptParams = fixture.sent("turn/start").last?["params"] as? [String: Any]
        expect(promptParams?["clientUserMessageId"] as? String == prompt.id, "command identity passed to Codex")
        eventually("prompt revision refreshed") { report()?.sessions.first?.control?.revision != control.revision }

        fixture.injectQuestion()
        eventually("question arrives") { report()?.sessions.first?.control?.request != nil }
        let questionControl = report()!.sessions[0].control!
        expect(report()?.sessions.first?.phase == .needsInput, "question phase")
        expect(questionControl.request?.questions.first?.options == ["Blue", "Green"], "real options preserved")
        let reply = AgentMessageCommand(providerID: "codex", sessionID: fixture.sessionID,
            revision: questionControl.revision, answers: ["color": ["Blue"]], requestID: questionControl.request!.id)
        try AgentRelayStorage.submit(reply, directory: directory)
        eventually("reply dispatched without invented ack") { (try? AgentRelayStorage.receipt(id: reply.id, directory: directory))?.state == .unknown }
        let replies = fixture.withLock { fixture.requests.filter { ($0["id"] as? Int) == 77 && $0["result"] != nil } }
        expect(replies.count == 1, "exact server request ID answered once")
        let answers = (replies.first?["result"] as? [String: Any])?["answers"] as? [String: [String: [String]]]
        expect(answers?["color"]?["answers"] == ["Blue"], "Codex answer envelope")

        eventually("post-reply revision") { report()?.sessions.first?.control?.request == nil }
        expect(report()?.sessions.first?.question == nil, "resolved question text removed")
        expect(report()?.sessions.first?.phase == .working, "reply restores working phase")
        let activeControl = report()!.sessions[0].control!
        let steer = AgentMessageCommand(providerID: "codex", sessionID: fixture.sessionID, revision: activeControl.revision, text: "fixture steer")
        try AgentRelayStorage.submit(steer, directory: directory)
        eventually("steer accepted") { (try? AgentRelayStorage.receipt(id: steer.id, directory: directory))?.state == .accepted }
        let steerParams = fixture.sent("turn/steer").last?["params"] as? [String: Any]
        expect(steerParams?["expectedTurnId"] as? String == fixture.turnID, "active steer fenced to turn")

        eventually("post-steer revision") { report()?.sessions.first?.control?.revision != activeControl.revision }
        let lostControl = report()!.sessions[0].control!
        fixture.withLock { fixture.loseSendAcknowledgement = true }
        let lost = AgentMessageCommand(providerID: "codex", sessionID: fixture.sessionID, revision: lostControl.revision, text: "fixture ambiguous")
        try AgentRelayStorage.submit(lost, directory: directory)
        eventually("lost acknowledgement remains unknown") { (try? AgentRelayStorage.receipt(id: lost.id, directory: directory))?.state == .unknown }
        let sends = fixture.sent("turn/steer").count
        service.processPending(); Thread.sleep(forTimeInterval: 0.3)
        expect(fixture.sent("turn/steer").count == sends, "ambiguous command never replayed")
        service.stop()
        eventually("stop report") { report()?.connected == false && report()?.sessions.isEmpty == true }
        expect(fixture.sent("turn/interrupt").isEmpty && fixture.sent("thread/unsubscribe").isEmpty, "stop never interrupts owner")
        eventually("serialized restart becomes available") {
            do { try service.start(); return true } catch { return false }
        }
        eventually("restart establishes fresh owner connection") { report()?.connected == true }
        let restartControl = report()?.sessions.first?.control
        expect(restartControl?.revision != lostControl.revision, "restart invalidates previous connection revisions")
        service.stop()
        eventually("second stop finishes before fixture deletion") { report()?.connected == false }
    }
}
