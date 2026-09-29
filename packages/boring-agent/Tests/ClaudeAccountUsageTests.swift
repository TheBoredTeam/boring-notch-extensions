// SPDX-License-Identifier: GPL-3.0-only
import Foundation

private final class UsageTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Date(timeIntervalSince1970: 2_000_000_000)
    func now() -> Date { lock.lock(); defer { lock.unlock() }; return value }
    func advance(_ seconds: Double) { lock.lock(); value.addTimeInterval(seconds); lock.unlock() }
}

/// Every transport and credential in this executable is injected. No test
/// constructs the production transport or reads the user's Keychain.
private final class UsageTestTransport: ClaudeAccountHTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var responses: [ClaudeAccountHTTPResponse] = []
    private var observed: [ClaudeAccountEndpoint] = []
    private var prompts: [Bool] = []
    private var suspended: CheckedContinuation<ClaudeAccountHTTPResponse, Error>?
    private var pauseUsage = false
    var calls: [ClaudeAccountEndpoint] { lock.lock(); defer { lock.unlock() }; return observed }
    var promptFlags: [Bool] { lock.lock(); defer { lock.unlock() }; return prompts }
    var hasSuspended: Bool { lock.lock(); defer { lock.unlock() }; return suspended != nil }
    func append(_ response: ClaudeAccountHTTPResponse) { lock.lock(); responses.append(response); lock.unlock() }
    func recordPrompt(_ value: Bool) { lock.lock(); prompts.append(value); lock.unlock() }
    func suspendNextUsage() { lock.lock(); pauseUsage = true; lock.unlock() }
    func releaseUsage(_ response: ClaudeAccountHTTPResponse) {
        lock.lock(); let pending = suspended; suspended = nil; lock.unlock()
        pending?.resume(returning: response)
    }
    func get(_ endpoint: ClaudeAccountEndpoint, accessToken: String) async throws -> ClaudeAccountHTTPResponse {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            observed.append(endpoint)
            if endpoint == .usage && pauseUsage {
                pauseUsage = false; suspended = continuation; lock.unlock(); return
            }
            let next = responses.isEmpty ? nil : responses.removeFirst()
            lock.unlock()
            if let next { continuation.resume(returning: next) }
            else { continuation.resume(throwing: ClaudeAccountUsageError.network) }
        }
    }
}

@main
struct ClaudeAccountUsageTests {
    static var assertions = 0
    static func expect(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
        assertions += 1
        if try !value() { throw NSError(domain: "ClaudeAccountUsageTests", code: assertions,
                                    userInfo: [NSLocalizedDescriptionKey: message]) }
    }
    static func json(_ value: Any) throws -> Data { try JSONSerialization.data(withJSONObject: value) }
    static func profile(_ account: String = "account-a") throws -> ClaudeAccountHTTPResponse {
        ClaudeAccountHTTPResponse(status: 200, data: try json(["account": ["uuid": account], "organization": ["uuid": "org-a"]]))
    }
    static func quota(_ used: Double = 28) throws -> ClaudeAccountHTTPResponse {
        ClaudeAccountHTTPResponse(status: 200, data: try json(["five_hour": ["utilization": used], "seven_day": ["utilization": 44]]))
    }
    static func wait(_ label: String, until predicate: () -> Bool) throws {
        let end = Date().addingTimeInterval(3)
        while Date() < end {
            if predicate() { return }
            Thread.sleep(forTimeInterval: 0.01)
        }
        try expect(false, "Timed out: \(label)")
    }
    @discardableResult private static func request(_ operation: ClaudeAccountUsageOperation, directory: URL, clock: UsageTestClock,
                        service: ClaudeAccountUsageService) throws -> String {
        let id = UUID().uuidString
        try ClaudeStorage.requestAccountUsage(ClaudeAccountUsageRequest(id: id,
            operation: operation, createdAt: clock.now().timeIntervalSince1970), directory: directory)
        service.processPending()
        return id
    }
    private static func dependencies(_ clock: UsageTestClock, _ transport: UsageTestTransport) -> ClaudeAccountUsageDependencies {
        ClaudeAccountUsageDependencies(now: { clock.now() }, credential: { prompt, now in
            transport.recordPrompt(prompt)
            return ClaudeAccountCredential(accessToken: "fake-test-token", expiresAt: now.addingTimeInterval(3600), planName: "Max 5x")
        }, transport: transport, schedulesTimers: false)
    }
    static func main() throws {
        try parsing()
        try lifecycleAndCooldowns()
        try accountChangeAndRevocation()
        try lateCompletion()
        try malformedConfiguration()
        try durableRevocationFallback()
        print("Claude account usage tests passed: \(assertions) assertions; injected credentials and HTTP only.")
    }

    static func parsing() throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let credentialData = try json(["claudeAiOauth": ["accessToken": "fake", "expiresAt": (now.timeIntervalSince1970 + 3600) * 1000,
            "scopes": ["user:profile"], "subscriptionType": "max", "rateLimitTier": "default_claude_max_5x",
            "refreshToken": ["unexpected": "ignored-field"]]])
        let credential = try ClaudeAccountCredential.parse(credentialData, now: now)
        try expect(credential.planName == "Max 5x" && credential.expiresAt == now.addingTimeInterval(3600), "Credentials use milliseconds and source-reported Max multiplier")
        for (scopes, expiry, expected) in [(["user:inference"], now.timeIntervalSince1970 + 3600, ClaudeAccountUsageError.missingScope),
                                            (["user:profile"], now.timeIntervalSince1970 - 1, .expiredCredentials)] {
            let data = try json(["claudeAiOauth": ["accessToken": "fake", "expiresAt": expiry * 1000, "scopes": scopes]])
            do { _ = try ClaudeAccountCredential.parse(data, now: now); try expect(false, "Invalid credential must fail") }
            catch let error as ClaudeAccountUsageError { try expect(error == expected, "Correct credential failure category") }
        }
        let raw: [String: Any] = [
            "five_hour": ["utilization": 28, "resets_at": "2033-05-18T04:33:20.000Z"],
            "seven_day": ["utilization": 44, "resets_at": "2033-05-20T04:33:20Z"],
            "limits": [
                ["kind": "weekly_scoped", "group": "weekly", "percent": 100, "is_active": false,
                 "scope": ["model": ["id": "fable-id", "display_name": "Fable"]]],
                ["kind": "weekly_scoped", "group": "weekly", "percent": 99,
                 "scope": ["model": ["id": "all-models", "display_name": "All models"]]]
            ],
            "extra_usage": ["used_credits": 100000, "monthly_limit": 100001],
            "context_window": ["remaining_percentage": 1]
        ]
        let report = try ClaudeAccountUsageParser.usage(json(raw), planName: "Max 5x", now: now)
        try expect(report.windows.count == 3 && report.limitingRemainingPercent == 56, "Scoped Fable exhaustion does not misrepresent overall account allowance")
        try expect(report.windows.last?.title == "Weekly · Fable" && report.windows.last?.remainingPercent == 0 && report.windows.last?.contributesToOverall == false, "Fable is retained even when is_active is false")
        try expect(report.windows.prefix(2).allSatisfy { $0.resetsAt != nil }, "Both ISO8601 reset formats are parsed")
        let exhausted = try ClaudeAccountUsageParser.usage(quota(100).data, planName: nil, now: now)
        try expect(exhausted.limitingRemainingPercent == 0, "A real zero remaining is not unavailable")
        do { _ = try ClaudeAccountUsageParser.usage(json(["context_window": ["remaining_percentage": 1]]), planName: nil, now: now); try expect(false, "Context-only report must fail") }
        catch let error as ClaudeAccountUsageError { try expect(error == .malformedResponse, "No account quota is fabricated from context") }
        let accountA = try ClaudeAccountUsageParser.accountKey(profile().data)
        let accountB = try ClaudeAccountUsageParser.accountKey(profile("account-b").data)
        try expect(accountA != accountB && accountA.count == 64 && !accountA.contains("account"), "Cache uses opaque distinct account identity")
        try expect(ClaudeAccountUsageParser.retryDate("120", now: now) == now.addingTimeInterval(120), "Retry-After seconds respected")
        try expect(ClaudeAccountUsageParser.retryDate("Wed, 18 May 2033 03:35:20 GMT", now: now) != nil, "Retry-After HTTP-date accepted")
        for (response, expected) in [(ClaudeAccountHTTPResponse(status: 302, data: Data()), ClaudeAccountUsageError.redirect),
                                    (ClaudeAccountHTTPResponse(status: 401, data: Data()), .unauthorized),
                                    (ClaudeAccountHTTPResponse(status: 200, data: Data(count: 262145)), .oversizedResponse)] {
            do { _ = try ClaudeAccountUsageParser.checked(response, now: now); try expect(false, "Response must fail validation") }
            catch let error as ClaudeAccountUsageError { try expect(error == expected, "Redirect/auth/size rejection classified") }
        }
    }

    static func lifecycleAndCooldowns() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("boring-account-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let clock = UsageTestClock(), transport = UsageTestTransport()
        let service = ClaudeAccountUsageService(directory: directory, dependencies: dependencies(clock, transport))
        try service.start()
        defer { service.stop() }
        try expect(transport.calls.isEmpty && transport.promptFlags.isEmpty, "Disabled service starts without Keychain or network")
        transport.append(try profile()); transport.append(try quota())
        try request(.enable, directory: directory, clock: clock, service: service)
        try wait("first live fixture", until: { (try? ClaudeStorage.accountUsage(directory: directory))?.state == .ready })
        let first = try ClaudeStorage.accountUsage(directory: directory)
        try expect(first?.report?.limitingRemainingPercent == 56 && transport.promptFlags == [true], "Explicit enable permits one user-initiated credential prompt")
        for name in ["account-usage.json", "usage-enabled.json"] {
            let saved = try String(decoding: ClaudeStorage.read(directory.appendingPathComponent(name)), as: UTF8.self)
            try expect(!saved.contains("fake-test-token") && !saved.contains("refreshToken"), "Private observations and scheduling never persist bearer or refresh tokens")
        }
        clock.advance(1)
        let cooledRequestID = try request(.refresh, directory: directory, clock: clock, service: service)
        try expect(transport.calls.count == 2 && (try? ClaudeStorage.accountUsage(directory: directory))?.updatedAt == clock.now().timeIntervalSince1970, "Manual cooldown acknowledges request without refetching")
        try expect((try ClaudeStorage.accountUsage(directory: directory))?.state == .ready && (try ClaudeStorage.accountUsage(directory: directory))?.report == first?.report,
                   "A healthy quota remains ready and intact during a too-soon manual refresh")
        try expect((try ClaudeStorage.accountUsage(directory: directory))?.lastRequestID == cooledRequestID, "Cooldown acknowledges the exact request ID")
        let sameInstantRequestID = try request(.refresh, directory: directory, clock: clock, service: service)
        try expect((try ClaudeStorage.accountUsage(directory: directory))?.lastRequestID == sameInstantRequestID, "Repeated requests at identical timestamps remain distinguishable")
        clock.advance(30)
        transport.append(try profile()); transport.append(ClaudeAccountHTTPResponse(status: 429, data: Data(), retryAfter: "120"))
        try request(.refresh, directory: directory, clock: clock, service: service)
        try wait("rate limit", until: { (try? ClaudeStorage.accountUsage(directory: directory))?.message?.contains("limiting") == true })
        let limited = try ClaudeStorage.accountUsage(directory: directory)
        try expect(limited?.nextRefreshAt == clock.now().addingTimeInterval(120).timeIntervalSince1970 && limited?.report?.updatedAt == first?.report?.updatedAt, "429 honors server cooldown and preserves original observation time")
        try expect(transport.promptFlags == [true, false], "A refresh never prompts for credentials")
        clock.advance(40)
        try request(.enable, directory: directory, clock: clock, service: service)
        try expect(transport.calls.count == 4, "Repeated enable cannot bypass server cooldown")
        try request(.disable, directory: directory, clock: clock, service: service)
        let disabled = try ClaudeStorage.accountUsage(directory: directory)
        try expect(disabled?.enabled == false && disabled?.report == nil && disabled?.accountKey == nil, "Disable revokes account state and clears observations")
        try expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("usage-enabled.json").path), "Disable durably removes the saved opt-in")
        service.stop()
        let restarted = ClaudeAccountUsageService(directory: directory, dependencies: dependencies(clock, transport))
        try restarted.start(); restarted.stop()
        try expect(transport.calls.count == 4, "Disabled configuration survives process restart without credential access")
    }

    static func accountChangeAndRevocation() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("boring-account-identity-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let clock = UsageTestClock(), transport = UsageTestTransport()
        let service = ClaudeAccountUsageService(directory: directory, allowUI: false, dependencies: dependencies(clock, transport))
        try service.start(); defer { service.stop() }
        transport.append(try profile()); transport.append(try quota())
        try request(.enable, directory: directory, clock: clock, service: service)
        try wait("account a", until: { (try? ClaudeStorage.accountUsage(directory: directory))?.state == .ready })
        try expect(transport.promptFlags == [false], "--no-ui also constrains explicit enable")
        clock.advance(31)
        transport.append(try profile("account-b")); transport.append(ClaudeAccountHTTPResponse(status: 500, data: Data()))
        try request(.refresh, directory: directory, clock: clock, service: service)
        try wait("new account failure", until: { (try? ClaudeStorage.accountUsage(directory: directory))?.state == .failed })
        try expect((try ClaudeStorage.accountUsage(directory: directory))?.report == nil, "Account b cannot inherit account a quota after failed fetch")
        clock.advance(31)
        transport.append(try profile("account-b")); transport.append(try quota(12))
        try request(.refresh, directory: directory, clock: clock, service: service)
        try wait("account b", until: { (try? ClaudeStorage.accountUsage(directory: directory))?.state == .ready })
        clock.advance(31)
        transport.append(ClaudeAccountHTTPResponse(status: 401, data: Data()))
        try request(.refresh, directory: directory, clock: clock, service: service)
        try wait("revoked", until: { (try? ClaudeStorage.accountUsage(directory: directory))?.state == .failed })
        let revoked = try ClaudeStorage.accountUsage(directory: directory)
        try expect(revoked?.report == nil && revoked?.accountKey == nil, "Authentication rejection clears account identity and measurements")
    }

    static func lateCompletion() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("boring-account-cancel-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let clock = UsageTestClock(), transport = UsageTestTransport()
        let service = ClaudeAccountUsageService(directory: directory, dependencies: dependencies(clock, transport))
        try service.start(); defer { service.stop() }
        transport.append(try profile()); transport.suspendNextUsage()
        try request(.enable, directory: directory, clock: clock, service: service)
        try wait("suspended request", until: { transport.hasSuspended })
        try expect((try ClaudeStorage.accountUsage(directory: directory))?.state == .loading, "Loading is acknowledged before transport completes")
        clock.advance(31)
        try request(.refresh, directory: directory, clock: clock, service: service)
        try expect(transport.calls.count == 2, "In-flight requests are single-flight even after manual cooldown")
        try request(.disable, directory: directory, clock: clock, service: service)
        transport.releaseUsage(try quota())
        Thread.sleep(forTimeInterval: 0.08)
        try expect((try ClaudeStorage.accountUsage(directory: directory))?.enabled == false && (try ClaudeStorage.accountUsage(directory: directory))?.report == nil, "A late completion cannot republish after disable")
        clock.advance(31)
        transport.append(try profile()); transport.suspendNextUsage()
        try request(.enable, directory: directory, clock: clock, service: service)
        try wait("second suspended request", until: { transport.hasSuspended })
        service.stop()
        let before = try ClaudeStorage.read(directory.appendingPathComponent("account-usage.json"))
        transport.releaseUsage(try quota())
        Thread.sleep(forTimeInterval: 0.08)
        try expect((try ClaudeStorage.read(directory.appendingPathComponent("account-usage.json"))) == before, "Stop fences a late completion from writing any record")
    }

    static func malformedConfiguration() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("boring-account-malformed-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try ClaudeStorage.prepare(directory: directory)
        try ClaudeStorage.atomicWrite(Data("{broken".utf8), to: directory.appendingPathComponent("usage-enabled.json"))
        let clock = UsageTestClock(), transport = UsageTestTransport()
        let service = ClaudeAccountUsageService(directory: directory, dependencies: dependencies(clock, transport))
        try service.start(); defer { service.stop() }
        let recovered = try ClaudeStorage.accountUsage(directory: directory)
        try expect(recovered?.enabled == false && recovered?.message?.contains("unreadable") == true && transport.calls.isEmpty && transport.promptFlags.isEmpty,
                   "Malformed scheduling state recovers disabled without affecting the relay or reading credentials")
        transport.append(try profile()); transport.append(try quota())
        try request(.enable, directory: directory, clock: clock, service: service)
        try wait("recovered config reconnect", until: { (try? ClaudeStorage.accountUsage(directory: directory))?.state == .ready })
        try expect(transport.calls.count == 2, "An explicit connection can recover malformed prior configuration")
    }

    static func durableRevocationFallback() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("boring-account-revoke-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let clock = UsageTestClock(), transport = UsageTestTransport()
        let service = ClaudeAccountUsageService(directory: directory, dependencies: dependencies(clock, transport))
        try service.start(); defer { service.stop() }
        transport.append(try profile()); transport.append(try quota())
        try request(.enable, directory: directory, clock: clock, service: service)
        try wait("revocation fixture", until: { (try? ClaudeStorage.accountUsage(directory: directory))?.state == .ready })
        // A directory at the scheduling path makes unlink/atomic replacement
        // fail. The independently written disabled record must still revoke.
        let config = directory.appendingPathComponent("usage-enabled.json")
        try FileManager.default.removeItem(at: config)
        try FileManager.default.createDirectory(at: config, withIntermediateDirectories: false)
        let id = try request(.disable, directory: directory, clock: clock, service: service)
        try expect((try ClaudeStorage.accountUsage(directory: directory))?.lastRequestID == id, "Durable disabled record acknowledges revocation when config deletion fails")
        service.stop()
        let restarted = ClaudeAccountUsageService(directory: directory, dependencies: dependencies(clock, transport))
        try restarted.start(); restarted.stop()
        try expect(transport.calls.count == 2 && transport.promptFlags.count == 1 && (try ClaudeStorage.accountUsage(directory: directory))?.enabled == false,
                   "Disabled record remains authoritative after restart despite an unreadable scheduling path")
    }
}
