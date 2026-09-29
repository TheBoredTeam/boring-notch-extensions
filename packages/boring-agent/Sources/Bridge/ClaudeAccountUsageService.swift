// SPDX-License-Identifier: GPL-3.0-only
import CryptoKit
import Darwin
import Foundation
import LocalAuthentication
import Security

enum ClaudeAccountUsageError: Error, Equatable {
    case credentialsUnavailable, accessDenied, invalidCredentials, missingScope, expiredCredentials
    case unauthorized, malformedResponse, oversizedResponse, redirect, network, server(Int)
    case rateLimited(Date?)

    var clearsAccount: Bool {
        switch self {
        case .credentialsUnavailable, .invalidCredentials, .missingScope, .expiredCredentials, .unauthorized: return true
        default: return false
        }
    }

    var message: String {
        switch self {
        case .credentialsUnavailable: return "Claude Code account credentials are unavailable. Sign in to Claude Code, then reconnect usage."
        case .accessDenied: return "Claude Code Keychain access was not granted. Connect usage again to allow access."
        case .invalidCredentials: return "The selected Claude Code account does not contain a supported subscription login."
        case .missingScope: return "This Claude Code login cannot read account usage. Sign in through Claude Code; setup-token cannot grant usage access."
        case .expiredCredentials: return "The Claude Code login has expired. Let Claude Code renew its login, then refresh usage."
        case .unauthorized: return "Claude rejected account access. Sign in through Claude Code, then reconnect usage."
        case .malformedResponse: return "Claude returned an unsupported account usage response. Try again later."
        case .oversizedResponse: return "Claude returned an account response exceeding the size limit."
        case .redirect: return "Claude redirected the account request. Usage access was stopped."
        case .network: return "Account usage could not be reached. Any previous observation keeps its original capture time."
        case .server: return "Claude account usage is temporarily unavailable. Try again later."
        case .rateLimited: return "Claude is limiting usage refreshes. Wait until the next refresh time."
        }
    }
}

/// Deliberately excludes refreshToken. Only Claude may rotate its own login.
struct ClaudeAccountCredential: Sendable {
    let accessToken: String
    let expiresAt: Date
    let planName: String?

    private struct Envelope: Decodable {
        struct OAuth: Decodable {
            var accessToken: String
            var expiresAt: Double
            var scopes: [String]
            var subscriptionType: String?
            var rateLimitTier: String?
        }
        var claudeAiOauth: OAuth
    }

    static func parse(_ data: Data, now: Date) throws -> Self {
        guard data.count <= ClaudeStorage.maximumRecordBytes,
              let envelope = try? JSONDecoder().decode(Envelope.self, from: data) else {
            throw ClaudeAccountUsageError.invalidCredentials
        }
        let oauth = envelope.claudeAiOauth
        let token = oauth.accessToken
        guard
              !token.isEmpty, token.utf8.count <= 16_384,
              token.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) && !CharacterSet.whitespacesAndNewlines.contains($0) }),
              oauth.expiresAt.isFinite, oauth.expiresAt > 0 else { throw ClaudeAccountUsageError.invalidCredentials }
        guard oauth.scopes.contains("user:profile") else {
            throw ClaudeAccountUsageError.missingScope
        }
        let expiresAt = Date(timeIntervalSince1970: oauth.expiresAt / 1_000)
        guard expiresAt > now else { throw ClaudeAccountUsageError.expiredCredentials }
        let kind = oauth.subscriptionType?.lowercased()
        let tier = oauth.rateLimitTier?.lowercased() ?? ""
        var plan: String?
        if kind == "max" || tier.contains("claude_max") {
            plan = tier.contains("max_20x") ? "Max 20x" : tier.contains("max_5x") ? "Max 5x" : "Max"
        } else if kind == "pro" || tier.contains("claude_pro") { plan = "Pro" }
        else if kind == "team" || tier.contains("claude_team") { plan = "Team" }
        else if kind == "enterprise" || tier.contains("enterprise") { plan = "Enterprise" }
        else if kind == "ultra" { plan = "Ultra" }
        return Self(accessToken: token, expiresAt: expiresAt, planName: plan)
    }
}

enum ClaudeAccountKeychain {
    static func read(allowUI: Bool, now: Date) throws -> ClaudeAccountCredential {
        let context = LAContext()
        context.interactionNotAllowed = !allowUI
        context.localizedReason = "BoringAgent reads Claude Code account usage without changing your login."
        defer { context.invalidate() }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Claude Code-credentials",
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true,
            kSecUseAuthenticationContext as String: context
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { throw ClaudeAccountUsageError.credentialsUnavailable }
        guard status == errSecSuccess else { throw ClaudeAccountUsageError.accessDenied }
        guard let data = result as? Data else { throw ClaudeAccountUsageError.invalidCredentials }
        return try ClaudeAccountCredential.parse(data, now: now)
    }
}

enum ClaudeAccountEndpoint: Sendable {
    case profile, usage
    var url: URL {
        // Fixed literals; neither the relay nor a request can select a host.
        URL(string: self == .profile ? "https://api.anthropic.com/api/oauth/profile" :
            "https://api.anthropic.com/api/oauth/usage")!
    }
}

struct ClaudeAccountHTTPResponse: Sendable {
    var status: Int
    var data: Data
    var retryAfter: String? = nil
}

protocol ClaudeAccountHTTPTransport: Sendable {
    func get(_ endpoint: ClaudeAccountEndpoint, accessToken: String) async throws -> ClaudeAccountHTTPResponse
}

private final class ClaudeAccountRedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

struct ClaudeAccountURLSessionTransport: ClaudeAccountHTTPTransport {
    static let maximumBytes = 262_144

    func get(_ endpoint: ClaudeAccountEndpoint, accessToken: String) async throws -> ClaudeAccountHTTPResponse {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 20
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let redirectGuard = ClaudeAccountRedirectGuard()
        let session = URLSession(configuration: configuration, delegate: redirectGuard, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: endpoint.url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("BoringAgent (macOS; account-usage)", forHTTPHeaderField: "User-Agent")
        if endpoint == .usage { request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta") }
        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse, response.url == endpoint.url else {
                throw ClaudeAccountUsageError.redirect
            }
            guard !(300..<400).contains(http.statusCode) else { throw ClaudeAccountUsageError.redirect }
            // Error response bodies are unnecessary and may contain arbitrary
            // server text. Preserve status/cooldown without decoding or logging.
            if http.statusCode != 200 {
                return ClaudeAccountHTTPResponse(status: http.statusCode, data: Data(),
                                                 retryAfter: http.value(forHTTPHeaderField: "Retry-After"))
            }
            guard response.expectedContentLength <= Self.maximumBytes else { throw ClaudeAccountUsageError.oversizedResponse }
            var data = Data()
            for try await byte in bytes {
                guard data.count < Self.maximumBytes else { throw ClaudeAccountUsageError.oversizedResponse }
                data.append(byte)
            }
            return ClaudeAccountHTTPResponse(status: http.statusCode, data: data,
                                             retryAfter: http.value(forHTTPHeaderField: "Retry-After"))
        } catch is CancellationError { throw CancellationError() }
        catch let error as ClaudeAccountUsageError { throw error }
        catch let error as URLError where error.code == .cancelled { throw CancellationError() }
        catch { throw ClaudeAccountUsageError.network }
    }
}

enum ClaudeAccountUsageParser {
    static func accountKey(_ data: Data) throws -> String {
        guard data.count <= ClaudeAccountURLSessionTransport.maximumBytes,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ClaudeAccountUsageError.malformedResponse
        }
        let account = root["account"] as? [String: Any]
        let organization = root["organization"] as? [String: Any]
        guard let accountID = ClaudeValidation.text(account?["uuid"] ?? root["account_uuid"] ?? root["accountUuid"], limit: 256),
              let organizationID = ClaudeValidation.text(organization?["uuid"] ?? root["organization_uuid"] ?? root["organizationUuid"], limit: 256) else {
            throw ClaudeAccountUsageError.malformedResponse
        }
        return digest("boringagent:claude-account:v1\0" + accountID + "\0" + organizationID)
    }

    static func usage(_ data: Data, planName: String?, now: Date) throws -> AgentUsageSnapshot {
        guard data.count <= ClaudeAccountURLSessionTransport.maximumBytes,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ClaudeAccountUsageError.malformedResponse
        }
        var windows: [AgentQuotaWindow] = []
        for (key, title) in [("five_hour", "5-hour limit"), ("seven_day", "Weekly · all models")] {
            guard let value = root[key] as? [String: Any], let used = ClaudeValidation.percentage(value["utilization"]) else { continue }
            windows.append(AgentQuotaWindow(id: key.replacingOccurrences(of: "_", with: "-"), title: title,
                remainingPercent: 100 - used, resetsAt: resetDate(value["resets_at"])))
        }
        var modelNames: Set<String> = []
        var modelIDs: Set<String> = []
        if let limits = root["limits"] as? [[String: Any]] {
            for entry in limits.prefix(128) where windows.count < 16 {
                guard entry["kind"] as? String == "weekly_scoped", entry["group"] as? String == "weekly",
                      let used = ClaudeValidation.percentage(entry["percent"]),
                      let scope = entry["scope"] as? [String: Any], let model = scope["model"] as? [String: Any],
                      let name = ClaudeValidation.text(model["display_name"], limit: 120) else { continue }
                let modelID = ClaudeValidation.text(model["id"], limit: 128) ?? name
                let normalizedName = name.lowercased().replacingOccurrences(of: "-", with: " ")
                guard normalizedName != "all models", !modelID.lowercased().hasSuffix("all-models"),
                      modelIDs.insert(modelID).inserted, modelNames.insert(normalizedName).inserted else { continue }
                // is_active is not a filter: the API has returned enforceable
                // scoped quotas marked false. Retain the reported measurement.
                windows.append(AgentQuotaWindow(id: "weekly-model-" + String(digest(modelID).prefix(24)),
                    title: "Weekly · \(name)", remainingPercent: 100 - used,
                    resetsAt: resetDate(entry["resets_at"]), contributesToOverall: false))
            }
        }
        for (key, name) in [("seven_day_sonnet", "Sonnet"), ("seven_day_opus", "Opus")] where windows.count < 16 {
            guard !modelNames.contains(name.lowercased()), let value = root[key] as? [String: Any],
                  let used = ClaudeValidation.percentage(value["utilization"]) else { continue }
            windows.append(AgentQuotaWindow(id: key.replacingOccurrences(of: "_", with: "-"), title: "Weekly · \(name)",
                remainingPercent: 100 - used, resetsAt: resetDate(value["resets_at"]), contributesToOverall: false))
        }
        guard !windows.isEmpty else { throw ClaudeAccountUsageError.malformedResponse }
        return AgentUsageSnapshot(updatedAt: now.timeIntervalSince1970, planName: planName, windows: windows)
    }

    static func retryDate(_ raw: String?, now: Date) -> Date? {
        guard let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        if let seconds = Double(value), seconds.isFinite, seconds >= 0 {
            let timestamp = now.timeIntervalSince1970 + seconds
            return timestamp.isFinite ? Date(timeIntervalSince1970: timestamp) : nil
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss zzz"
        return formatter.date(from: value)
    }

    static func checked(_ response: ClaudeAccountHTTPResponse, now: Date) throws -> Data {
        guard response.data.count <= ClaudeAccountURLSessionTransport.maximumBytes else { throw ClaudeAccountUsageError.oversizedResponse }
        switch response.status {
        case 200: return response.data
        case 401, 403: throw ClaudeAccountUsageError.unauthorized
        case 429: throw ClaudeAccountUsageError.rateLimited(retryDate(response.retryAfter, now: now))
        case 300..<400: throw ClaudeAccountUsageError.redirect
        default: throw ClaudeAccountUsageError.server(response.status)
        }
    }

    private static func resetDate(_ value: Any?) -> Double? {
        guard let string = value as? String, string.utf8.count <= 128 else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var date = formatter.date(from: string)
        if date == nil { formatter.formatOptions = [.withInternetDateTime]; date = formatter.date(from: string) }
        guard let timestamp = date?.timeIntervalSince1970, timestamp.isFinite, timestamp > 0 else { return nil }
        return timestamp
    }

    private static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

struct ClaudeAccountUsageDependencies: Sendable {
    var now: @Sendable () -> Date = { Date() }
    var credential: @Sendable (Bool, Date) throws -> ClaudeAccountCredential = { try ClaudeAccountKeychain.read(allowUI: $0, now: $1) }
    var transport: any ClaudeAccountHTTPTransport = ClaudeAccountURLSessionTransport()
    var schedulesTimers = true
}

/// Only this separately executable broker handles account credentials. The
/// plugin sees bounded, sanitized records and can never receive a bearer token.
final class ClaudeAccountUsageService: @unchecked Sendable {
    private struct Configuration: Codable {
        var schemaVersion = 1
        var enabled = false
        var lastAttemptAt: Double?
        var blockedUntil: Double?
        var nextRefreshAt: Double?
    }
    private struct Outcome: Sendable {
        var accountKey: String?
        var report: AgentUsageSnapshot?
        var error: ClaudeAccountUsageError?
    }

    private let directory: URL
    private let allowUI: Bool
    private let dependencies: ClaudeAccountUsageDependencies
    private let queue = DispatchQueue(label: "theboringteam.claude.account-usage", qos: .utility)
    private var configuration = Configuration()
    private var record: ClaudeAccountUsageRecord?
    private var initialized = false
    private var stopped = false
    private var generation = UUID()
    private var task: Task<Void, Never>?
    private var timer: DispatchSourceTimer?
    private var watch: DispatchSourceFileSystemObject?
    private var ownershipDescriptor: Int32 = -1
    private var lastRequestID: String?

    init(directory: URL, allowUI: Bool = true, dependencies: ClaudeAccountUsageDependencies = ClaudeAccountUsageDependencies()) {
        self.directory = directory
        self.allowUI = allowUI
        self.dependencies = dependencies
    }

    func start() throws {
        try queue.sync {
            try initialize()
            guard !stopped else { return }
            if watch == nil {
                let descriptor = open(directory.path, O_EVTONLY | O_NOFOLLOW | O_CLOEXEC)
                guard descriptor >= 0 else { throw ClaudeStorageError.io }
                let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: [.write, .rename, .delete, .revoke], queue: queue)
                source.setEventHandler { [weak self] in self?.consumeRequest() }
                source.setCancelHandler { close(descriptor) }
                watch = source
                source.resume()
            }
            consumeRequest()
            if configuration.enabled { refreshIfDue(explicit: false, prompt: false) }
            scheduleNext()
        }
    }

    /// Does not wait for an HTTP operation. Disabled fixtures do no credential
    /// work; a long-running broker owns asynchronous enabled operations.
    func processPending() {
        queue.sync {
            guard !stopped else { return }
            do { try initialize(); consumeRequest() } catch { /* No credentials or raw errors are logged. */ }
        }
    }

    func stop() {
        queue.sync {
            guard !stopped else { return }
            stopped = true
            generation = UUID()
            task?.cancel()
            task = nil
            timer?.cancel(); timer = nil
            watch?.cancel(); watch = nil
            if ownershipDescriptor >= 0 { close(ownershipDescriptor); ownershipDescriptor = -1 }
        }
    }

    deinit {
        task?.cancel()
        timer?.cancel()
        watch?.cancel()
        if ownershipDescriptor >= 0 { close(ownershipDescriptor) }
    }

    private func initialize() throws {
        guard !initialized, !stopped else { return }
        try ClaudeStorage.prepare(directory: directory)
        let lockURL = directory.appendingPathComponent(".account-usage-service.lock")
        let descriptor = open(lockURL.path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw ClaudeStorageError.io }
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == getuid(), info.st_nlink == 1, flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor); throw ClaudeStorageError.io
        }
        ownershipDescriptor = descriptor
        do {
            let url = directory.appendingPathComponent("usage-enabled.json")
            var recoveredConfiguration = false
            record = try? ClaudeStorage.accountUsage(directory: directory)
            // Read revocation first. It remains authoritative even if the
            // scheduling path became unreadable and could not be unlinked.
            if record?.enabled != false && FileManager.default.fileExists(atPath: url.path) {
                let data = try ClaudeStorage.read(url)
                if let saved = try? JSONDecoder().decode(Configuration.self, from: data), saved.schemaVersion == 1,
                   [saved.lastAttemptAt, saved.blockedUntil, saved.nextRefreshAt].compactMap({ $0 }).allSatisfy({ $0.isFinite && $0 > 0 }) {
                    configuration = saved
                } else { configuration = Configuration(); recoveredConfiguration = true }
            }
            // A successfully written revocation record is authoritative even
            // if the previous process could not update its scheduling file.
            if record?.enabled == false { configuration = Configuration() }
            initialized = true
            if !configuration.enabled {
                record = ClaudeAccountUsageRecord(enabled: false, state: .disabled,
                    message: recoveredConfiguration ? "Usage configuration was unreadable. Connect usage again to continue." : nil,
                    updatedAt: dependencies.now().timeIntervalSince1970)
                if recoveredConfiguration { persistConfiguration() }
                persistRecord()
            }
        } catch {
            close(descriptor); ownershipDescriptor = -1
            throw error
        }
    }

    private func consumeRequest() {
        guard initialized, !stopped else { return }
        guard let request = try? ClaudeStorage.takeAccountUsageRequest(directory: directory) else { return }
        let now = dependencies.now().timeIntervalSince1970
        guard request.createdAt <= now + 30, now - request.createdAt <= 600 else { return }
        lastRequestID = request.id
        switch request.operation {
        case .disable:
            configuration.enabled = false
            configuration.nextRefreshAt = nil
            generation = UUID()
            task?.cancel(); task = nil
            record = ClaudeAccountUsageRecord(enabled: false, state: .disabled, updatedAt: now)
            // Deleting the opt-in is the primary durable revocation. A disabled
            // record is independently authoritative at initialization if the
            // configuration cannot be removed. Failed writes never produce an
            // acknowledgement file claiming an unpersisted revocation.
            let removedOptIn = removeConfiguration()
            let savedDisabledRecord = persistRecord()
            if !removedOptIn && !savedDisabledRecord {
                // In-memory work stays disabled. There is no durable success to
                // acknowledge; native request timeout reports that uncertainty.
                record?.lastRequestID = nil
            }
            scheduleNext()
        case .enable:
            configuration.enabled = true
            persistConfiguration()
            refreshIfDue(explicit: true, prompt: allowUI)
        case .refresh:
            guard configuration.enabled else { persistRecord(); return }
            refreshIfDue(explicit: true, prompt: false)
        }
    }

    private func refreshIfDue(explicit: Bool, prompt: Bool) {
        guard initialized, !stopped, configuration.enabled else { return }
        if task != nil {
            if explicit { record?.updatedAt = dependencies.now().timeIntervalSince1970; persistRecord() }
            return
        }
        let now = dependencies.now()
        let timestamp = now.timeIntervalSince1970
        let minimum = max(configuration.blockedUntil ?? 0,
                          (configuration.lastAttemptAt ?? (timestamp - 30)) + 30)
        let due = explicit ? minimum : max(minimum, configuration.nextRefreshAt ?? 0)
        if due > timestamp {
            configuration.nextRefreshAt = max(configuration.nextRefreshAt ?? due, due)
            if explicit || record?.enabled != true {
                let priorState = record?.enabled == true ? record?.state : nil
                let state: ClaudeAccountUsagePhase = priorState == .ready ? .ready : priorState == .failed ? .failed : .loading
                let message = priorState == .failed ? record?.message :
                    "Usage was refreshed recently. The next scheduled refresh is unchanged."
                record = ClaudeAccountUsageRecord(enabled: true, state: state,
                    message: message,
                    report: record?.report, accountKey: record?.accountKey,
                    updatedAt: timestamp, nextRefreshAt: configuration.nextRefreshAt)
                persistRecord()
            }
            scheduleNext()
            return
        }
        configuration.lastAttemptAt = timestamp
        configuration.nextRefreshAt = timestamp + 300
        record = ClaudeAccountUsageRecord(enabled: true, state: .loading, report: record?.report,
            accountKey: record?.accountKey, updatedAt: timestamp, nextRefreshAt: configuration.nextRefreshAt)
        guard persistConfiguration(), persistRecord() else { return }
        let current = generation
        let dependencies = dependencies
        task = Task.detached(priority: .utility) { [weak self] in
            var outcome = Outcome()
            do {
                try Task.checkCancellation()
                let credential = try dependencies.credential(prompt, dependencies.now())
                try Task.checkCancellation()
                let profileResponse = try await dependencies.transport.get(.profile, accessToken: credential.accessToken)
                let profile = try ClaudeAccountUsageParser.checked(profileResponse, now: dependencies.now())
                outcome.accountKey = try ClaudeAccountUsageParser.accountKey(profile)
                try Task.checkCancellation()
                let usageResponse = try await dependencies.transport.get(.usage, accessToken: credential.accessToken)
                let usage = try ClaudeAccountUsageParser.checked(usageResponse, now: dependencies.now())
                outcome.report = try ClaudeAccountUsageParser.usage(usage, planName: credential.planName, now: dependencies.now())
            } catch is CancellationError { return }
            catch let error as ClaudeAccountUsageError { outcome.error = error }
            catch { outcome.error = .network }
            guard !Task.isCancelled else { return }
            let completed = outcome
            self?.queue.async { [weak self] in self?.complete(completed, generation: current) }
        }
    }

    private func complete(_ outcome: Outcome, generation current: UUID) {
        guard !stopped, generation == current, configuration.enabled else { return }
        task = nil
        let now = dependencies.now()
        let timestamp = now.timeIntervalSince1970
        configuration.nextRefreshAt = timestamp + 300
        if let report = outcome.report, let accountKey = outcome.accountKey {
            configuration.blockedUntil = nil
            record = ClaudeAccountUsageRecord(enabled: true, state: .ready, report: report,
                accountKey: accountKey, updatedAt: timestamp, nextRefreshAt: configuration.nextRefreshAt)
        } else {
            let error = outcome.error ?? .network
            let changedAccount = outcome.accountKey.map { $0 != record?.accountKey } ?? false
            let clear = changedAccount || error.clearsAccount
            if case .rateLimited(let retryAfter) = error {
                let serverDate = retryAfter?.timeIntervalSince1970 ?? (timestamp + 300)
                configuration.blockedUntil = max(serverDate, (configuration.lastAttemptAt ?? timestamp) + 30)
                configuration.nextRefreshAt = max(timestamp, configuration.blockedUntil ?? timestamp)
            }
            record = ClaudeAccountUsageRecord(enabled: true, state: .failed, message: error.message,
                report: clear ? nil : record?.report,
                accountKey: error.clearsAccount ? nil : outcome.accountKey ?? record?.accountKey,
                updatedAt: timestamp, nextRefreshAt: configuration.nextRefreshAt)
        }
        persistConfiguration(); persistRecord(); scheduleNext()
    }

    private func scheduleNext() {
        guard dependencies.schedulesTimers, initialized, !stopped else { return }
        if timer == nil {
            let source = DispatchSource.makeTimerSource(queue: queue)
            source.setEventHandler { [weak self] in
                guard let self, !self.stopped else { return }
                self.refreshIfDue(explicit: false, prompt: false)
            }
            timer = source
            source.resume()
        }
        guard configuration.enabled, let next = configuration.nextRefreshAt else {
            timer?.schedule(deadline: .distantFuture)
            return
        }
        let delay = min(86_400, max(0.1, next - dependencies.now().timeIntervalSince1970))
        timer?.schedule(deadline: .now() + delay, leeway: .seconds(1))
    }

    @discardableResult private func persistConfiguration() -> Bool {
        guard let data = try? JSONEncoder().encode(configuration) else { return false }
        do { try ClaudeStorage.atomicWrite(data, to: directory.appendingPathComponent("usage-enabled.json")); return true }
        catch { return false }
    }

    private func removeConfiguration() -> Bool {
        do { try ClaudeStorage.checkDirectory(directory) } catch { return false }
        let result = unlink(directory.appendingPathComponent("usage-enabled.json").path)
        return result == 0 || errno == ENOENT
    }

    @discardableResult private func persistRecord() -> Bool {
        guard var value = record else { return false }
        value.lastRequestID = lastRequestID
        record = value
        do { try ClaudeStorage.writeAccountUsage(value, directory: directory); return true }
        catch { return false }
    }
}
