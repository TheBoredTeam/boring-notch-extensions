// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Darwin

/// Only the explicit login/logout helper commands use this type's interactive
/// path. The observational app-server transport never permits login methods.
enum CodexAccountSetup {
    static var accountHome: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/BoringAgent/CodexAccount")
    }

    static func arguments(command: [String], dedicated: Bool) -> [String] {
        var result = ["-c", "model_provider=\"openai\""]
        if dedicated { result += ["-c", "cli_auth_credentials_store=\"file\""] }
        return result + command
    }

    static func environment(_ source: [String: String], home: URL?) -> [String: String] {
        var result = source
        // These can select an API credential/provider instead of an existing
        // ChatGPT login. Preserve TLS trust/proxy settings and unrelated env.
        let explicit = Set(["OPENAI_API_KEY", "OPENAI_BASE_URL", "OPENAI_API_BASE", "OPENAI_ORG_ID",
            "OPENAI_ORGANIZATION", "OPENAI_PROJECT", "OPENAI_PROJECT_ID", "CODEX_API_KEY",
            "CODEX_ACCESS_TOKEN", "CODEX_SESSION_ID", "CODEX_THREAD_ID"])
        for key in result.keys where explicit.contains(key) || key.hasPrefix("AZURE_OPENAI_") {
            result.removeValue(forKey: key)
        }
        if let home { result["CODEX_HOME"] = home.path }
        return result
    }

    static func validatedExecutable(_ executable: URL) throws -> URL {
        let path = executable.resolvingSymlinksInPath().standardizedFileURL
        var info = stat()
        guard lstat(path.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == getuid() || info.st_uid == 0, (info.st_mode & 0o022) == 0,
              FileManager.default.isExecutableFile(atPath: path.path) else { throw CodexTransportError.unavailable }
        return path
    }

    static func runtimeEnvironment(_ source: [String: String], home: URL?, executable: URL,
                                   usableNode: (URL) -> Bool = { (try? validatedExecutable($0)) != nil }) -> [String: String] {
        var result = environment(source, home: home)
        guard executable.resolvingSymlinksInPath().pathExtension == "js" else { return result }
        let originalPath = source["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        let candidates = [executable.deletingLastPathComponent().path, "/opt/homebrew/bin", "/usr/local/bin"] +
            originalPath.split(separator: ":").map(String.init)
        // npm Codex uses /usr/bin/env node. Resolve that runtime inside this
        // child only, without relying on a user's interactive shell startup.
        if let node = candidates.lazy.filter({ $0.hasPrefix("/") }).map({ URL(fileURLWithPath: $0).appendingPathComponent("node") }).first(where: usableNode) {
            result["PATH"] = node.deletingLastPathComponent().path + ":" + originalPath
        }
        return result
    }

    static func signInCommand(helper: URL, directory: URL, executable: URL?) -> String {
        func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        var parts = [quote(helper.path), "codex-login-usage", "--data-dir", quote(directory.path)]
        if let executable { parts += ["--codex-executable", quote(executable.path)] }
        return parts.joined(separator: " ")
    }

    static func login(executable: URL? = nil, directory: URL) throws {
        try interactive(command: ["login", "--device-auth"], executable: executable)
        try requestRefresh(directory: directory)
        print("Codex subscription sign-in completed. BoringAgent will refresh usage. Your existing Codex provider and login are unchanged.")
    }

    static func logout(executable: URL? = nil, directory: URL) throws {
        try interactive(command: ["logout"], executable: executable)
        try requestRefresh(directory: directory)
        print("BoringAgent's separate Codex usage login was removed. Your existing Codex provider and login are unchanged.")
    }

    private static func interactive(command: [String], executable: URL?) throws {
        guard let executable = executable ?? CodexAccountBroker.defaultExecutable else { throw CodexTransportError.unavailable }
        try ClaudeStorage.ensureDirectory(accountHome)
        let process = Process()
        process.executableURL = try validatedExecutable(executable)
        process.arguments = arguments(command: command, dedicated: true)
        process.environment = runtimeEnvironment(ProcessInfo.processInfo.environment, home: accountHome, executable: executable)
        process.currentDirectoryURL = accountHome
        // Official CLI owns the browser/device challenge and credential writes.
        // No tokens are read, echoed, captured, or copied by BoringAgent.
        process.standardInput = FileHandle.standardInput
        process.standardOutput = FileHandle.standardOutput
        process.standardError = FileHandle.standardError
        try process.run(); process.waitUntilExit()
        guard process.terminationReason == .exit && process.terminationStatus == 0 else { throw CodexTransportError.unavailable }
    }

    static func requestRefresh(directory: URL) throws {
        try AgentRelayStorage.requestUsageRefresh(providerID: "codex", directory: directory)
    }
}
