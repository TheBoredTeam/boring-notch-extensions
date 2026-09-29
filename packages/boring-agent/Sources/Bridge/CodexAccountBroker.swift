// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Darwin

/// Cancels only the observational CLI child. The session owner is never
/// registered here. Pipe I/O stays on the account queue and exits after the
/// child terminates; cancellation does not close descriptors from another queue.
final class CodexAccountCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var process: Process?

    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }

    func attach(_ process: Process) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if cancelled {
            if process.isRunning { process.terminate() }
            return false
        }
        self.process = process
        return true
    }

    func detach(_ process: Process) {
        lock.lock(); defer { lock.unlock() }
        if self.process === process { self.process = nil }
    }

    func cancel() {
        lock.lock(); defer { lock.unlock() }
        cancelled = true
        if let process, process.isRunning { process.terminate() }
    }
}

/// A short-lived official CLI process can read its existing account without
/// taking ownership of any conversation. Its transport rejects every thread,
/// turn, login, logout and configuration method by construction.
enum CodexAccountBroker {
    // A cold official app-server under launchd Background policy can exceed
    // the interactive RPC deadline before initialize completes.
    static let startupTimeout: TimeInterval = 30

    struct Result: Sendable {
        var usage: AgentUsageSnapshot? = nil
        var message: String? = nil
        var usageAccount: AgentUsageAccountStatus = .init(state: .unavailable, message: "Codex account information is unavailable.")
        var authenticated = false
        var allowsOwnerFallback = true
    }

    static var defaultExecutable: URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = [
            // Native executables work in launchd's minimal environment. An npm
            // launcher may need a separate Node executable on PATH.
            URL(fileURLWithPath: "/Applications/Codex.app/Contents/Resources/codex"),
            URL(fileURLWithPath: "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex"),
            URL(fileURLWithPath: "/opt/homebrew/bin/codex"),
            URL(fileURLWithPath: "/usr/local/bin/codex"),
            home.appendingPathComponent(".local/bin/codex")
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    static func read(executable: URL, signInCommand: String? = nil,
                     dedicatedHome: URL = CodexAccountSetup.accountHome,
                     cancellation: CodexAccountCancellation? = nil) -> Result {
        let dedicated = FileManager.default.fileExists(atPath: dedicatedHome.path)
        if dedicated {
            do { try ClaudeStorage.checkDirectory(dedicatedHome) }
            catch { return Result(message: "The private Codex account folder cannot be opened.",
                usageAccount: .init(state: .failed, message: "The private Codex account folder cannot be opened."),
                allowsOwnerFallback: false) }
        }
        return preferred(dedicatedExists: dedicated, dedicated: {
            readContext(executable: executable, home: dedicatedHome, signInCommand: signInCommand, cancellation: cancellation)
        }, existing: {
            readContext(executable: executable, home: nil, signInCommand: signInCommand, cancellation: cancellation)
        })
    }

    static func preferred(dedicatedExists: Bool, dedicated: () -> Result, existing: () -> Result) -> Result {
        if dedicatedExists {
            let result = dedicated()
            // Never replace this account with unrelated fallback quota after a
            // transient read error. An empty/logged-out store may use the CLI.
            if result.usageAccount.state != .signInRequired {
                var selected = result; selected.allowsOwnerFallback = false; return selected
            }
        }
        return existing()
    }

    private static func readContext(executable: URL, home: URL?, signInCommand: String?, cancellation: CodexAccountCancellation?) -> Result {
        let client = CodexRPCClient(transport: CodexAccountTransport(executable: executable, accountHome: home, cancellation: cancellation))
        defer { client.close() }
        var authenticated = false
        do {
            try client.connect(timeout: startupTimeout)
            let account = try client.request("account/read", params: ["refreshToken": false])
            if accountUnavailable(account) != nil {
                let message = "Sign in with ChatGPT to show subscription limits. Your current Codex session provider stays unchanged."
                return Result(message: message, usageAccount: .init(state: .signInRequired,
                    message: message, signInCommand: signInCommand))
            }
            authenticated = true
            let limits = try client.request("account/rateLimits/read")
            let usage = CodexProtocol.usage(limits)
            let message = usage == nil ? "ChatGPT is connected, but Codex did not report subscription limits." : "ChatGPT subscription connected."
            return Result(usage: usage, message: usage == nil ? message : nil,
                usageAccount: .init(state: usage == nil ? .unavailable : .connected, message: message), authenticated: true)
        } catch {
            let message = "Codex subscription limits could not be refreshed. Check your connection and try again."
            return Result(message: message, usageAccount: .init(state: .failed, message: message,
                signInCommand: authenticated ? signInCommand : nil), authenticated: authenticated)
        }
    }

    static func accountUnavailable(_ response: [String: Any]) -> String? {
        if response["account"] is NSNull, response["requiresOpenaiAuth"] as? Bool == false {
            return "This Codex provider does not expose ChatGPT subscription quota. API usage is billed separately."
        }
        guard let account = response["account"] as? [String: Any],
              let type = account["type"] as? String else {
            return "Codex is not signed in. Sign in through the official Codex app or CLI."
        }
        if type == "apiKey" {
            return "Codex uses API-key authentication. Subscription quota is unavailable; API usage is billed separately."
        }
        guard type == "chatgpt" || type == "chatgptAuthTokens" else {
            return "This Codex account does not expose ChatGPT subscription quota."
        }
        return nil
    }
}

final class CodexAccountTransport: CodexRPCTransport {
    static let allowedMethods: Set<String> = ["initialize", "initialized", "account/read", "account/rateLimits/read"]
    private let executable: URL
    private let accountHome: URL?
    private let cancellation: CodexAccountCancellation?
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var buffered = Data()

    init(executable: URL, accountHome: URL? = nil, cancellation: CodexAccountCancellation? = nil) {
        self.executable = executable; self.accountHome = accountHome; self.cancellation = cancellation
    }
    deinit { close() }

    func connect() throws {
        close()
        guard cancellation?.isCancelled != true else { throw CodexTransportError.disconnected }
        let path = try CodexAccountSetup.validatedExecutable(executable)
        let task = Process(), toChild = Pipe(), fromChild = Pipe()
        task.executableURL = path
        task.arguments = CodexAccountSetup.arguments(command: ["app-server"], dedicated: accountHome != nil)
        task.environment = CodexAccountSetup.runtimeEnvironment(ProcessInfo.processInfo.environment, home: accountHome, executable: executable)
        if let accountHome { task.currentDirectoryURL = accountHome }
        task.standardInput = toChild; task.standardOutput = fromChild
        task.standardError = FileHandle.nullDevice
        try task.run()
        try? toChild.fileHandleForReading.close(); try? fromChild.fileHandleForWriting.close()
        process = task; input = toChild.fileHandleForWriting; output = fromChild.fileHandleForReading
        guard cancellation?.attach(task) != false else { close(); throw CodexTransportError.disconnected }
        _ = fcntl(toChild.fileHandleForWriting.fileDescriptor, F_SETFL, O_NONBLOCK)
        _ = fcntl(fromChild.fileHandleForReading.fileDescriptor, F_SETFL, O_NONBLOCK)
    }

    func send(_ value: [String: Any], timeout: TimeInterval) throws {
        guard let method = value["method"] as? String, Self.allowedMethods.contains(method),
              let fd = input?.fileDescriptor else { throw CodexTransportError.invalidMessage }
        var data = try JSONSerialization.data(withJSONObject: value)
        guard data.count <= 16_384 else { throw CodexTransportError.tooLarge }
        data.append(0x0a)
        let deadline = Date().addingTimeInterval(timeout)
        var offset = 0
        while offset < data.count {
            guard try wait(fd: fd, events: Int16(POLLOUT), deadline: deadline) else { throw CodexTransportError.timedOut }
            let count = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress!.advanced(by: offset), data.count - offset) }
            if count < 0 && (errno == EINTR || errno == EAGAIN) { continue }
            guard count > 0 else { throw CodexTransportError.disconnected }
            offset += count
        }
    }

    func receive(timeout: TimeInterval) throws -> [String: Any]? {
        guard let fd = output?.fileDescriptor else { throw CodexTransportError.disconnected }
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if let newline = buffered.firstIndex(of: 0x0a) {
                let line = Data(buffered[..<newline]); buffered.removeSubrange(...newline)
                if line.isEmpty { continue }
                guard let value = try JSONSerialization.jsonObject(with: line) as? [String: Any] else { throw CodexTransportError.invalidMessage }
                return value
            }
            guard try wait(fd: fd, events: Int16(POLLIN), deadline: deadline) else { return nil }
            var bytes = [UInt8](repeating: 0, count: 16_384)
            let count = Darwin.read(fd, &bytes, bytes.count)
            if count < 0 && (errno == EAGAIN || errno == EINTR) { continue }
            guard count > 0 else { throw CodexTransportError.disconnected }
            guard buffered.count + count <= CodexUnixWebSocket.maximumMessageBytes else { throw CodexTransportError.tooLarge }
            buffered.append(contentsOf: bytes.prefix(count))
        }
    }

    private func wait(fd: Int32, events: Int16, deadline: Date) throws -> Bool {
        var descriptor = pollfd(fd: fd, events: events, revents: 0)
        let result = poll(&descriptor, 1, Int32(max(0, min(30_000, deadline.timeIntervalSinceNow * 1000))))
        if result < 0 && errno == EINTR { return try wait(fd: fd, events: events, deadline: deadline) }
        guard result >= 0, descriptor.revents & Int16(POLLERR | POLLNVAL) == 0 else { throw CodexTransportError.disconnected }
        if descriptor.revents & events != 0 { return true }
        if descriptor.revents & Int16(POLLHUP) != 0 { throw CodexTransportError.disconnected }
        return false
    }

    func close() {
        try? input?.close(); input = nil
        try? output?.close(); output = nil
        if let process {
            cancellation?.detach(process)
            if process.isRunning { process.terminate() }
        }
        process = nil; buffered.removeAll()
    }
}
