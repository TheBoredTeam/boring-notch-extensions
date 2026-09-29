// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Darwin

enum AgentBridgeInstaller {
    static let codexLabel = "theboringteam.boringnotch.boringagent.codex"

    static func stableHelper(executable: URL, directory: URL) throws -> URL {
        try AgentRelayStorage.prepare(directory: directory)
        let bin = directory.appendingPathComponent("bin")
        try ClaudeStorage.ensureDirectory(bin)
        let helper = bin.appendingPathComponent("boring-claude-bridge")
        if executable.standardizedFileURL != helper.standardizedFileURL {
            try ClaudeStorage.atomicWrite(ClaudeStorage.read(executable, limit: 40_000_000),
                to: helper, limit: 40_000_000)
            guard chmod(helper.path, 0o700) == 0 else { throw ClaudeStorageError.io }
        }
        return helper
    }

    static func codexAgent(home: URL) -> URL {
        home.appendingPathComponent("Library/LaunchAgents/\(codexLabel).plist")
    }

    static func installCodex(executable: URL, directory: URL, endpoint: URL? = nil,
                             accountExecutable: URL? = nil, launch: Bool = true,
                             home: URL = FileManager.default.homeDirectoryForCurrentUser) throws {
        let helper = try stableHelper(executable: executable, directory: directory)
        guard launch else { return }
        let agent = codexAgent(home: home)
        if !FileManager.default.fileExists(atPath: agent.deletingLastPathComponent().path) {
            try FileManager.default.createDirectory(at: agent.deletingLastPathComponent(), withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
        }
        if FileManager.default.fileExists(atPath: agent.path) {
            guard let existing = try PropertyListSerialization.propertyList(from: ClaudeStorage.read(agent), format: nil) as? [String: Any],
                  existing["Label"] as? String == codexLabel,
                  let arguments = existing["ProgramArguments"] as? [String], arguments.count >= 4,
                  arguments[0] == helper.path, arguments[1] == "codex-serve", arguments[2] == "--data-dir", arguments[3] == directory.path
            else { throw ClaudeStorageError.unsafePath }
        }
        var args = [helper.path, "codex-serve", "--data-dir", directory.path]
        if let endpoint { args += ["--codex-socket", endpoint.path] }
        if let accountExecutable { args += ["--codex-executable", accountExecutable.path] }
        let plist: [String: Any] = ["Label": codexLabel, "ProgramArguments": args, "RunAtLoad": true,
            "KeepAlive": ["SuccessfulExit": false], "ThrottleInterval": 10, "ProcessType": "Background"]
        try ClaudeStorage.atomicWrite(PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0), to: agent)
        if launch {
            _ = try? ClaudeInstaller.runLaunchctl(["bootout", "gui/\(getuid())/\(codexLabel)"])
            guard try ClaudeInstaller.runLaunchctl(["bootstrap", "gui/\(getuid())", agent.path]) == 0 else { throw ClaudeStorageError.io }
        }
    }

    static func uninstallCodex(directory: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser,
                               launch: Bool = true) throws {
        let agent = codexAgent(home: home)
        guard FileManager.default.fileExists(atPath: agent.path) else { return }
        guard let existing = try PropertyListSerialization.propertyList(from: ClaudeStorage.read(agent), format: nil) as? [String: Any],
              existing["Label"] as? String == codexLabel,
              let arguments = existing["ProgramArguments"] as? [String], arguments.count >= 4,
              arguments[0] == directory.appendingPathComponent("bin/boring-claude-bridge").path,
              arguments[1] == "codex-serve", arguments[2] == "--data-dir", arguments[3] == directory.path
        else { throw ClaudeStorageError.unsafePath }
        if launch { _ = try? ClaudeInstaller.runLaunchctl(["bootout", "gui/\(getuid())/\(codexLabel)"]) }
        try FileManager.default.removeItem(at: agent)
    }

    /// Produces an explicit per-launch MCP config. It never modifies global MCP
    /// settings, enables a channel in another session or accepts its confirmation.
    static func channelSetup(executable: URL, directory: URL) throws -> String {
        let helper = try stableHelper(executable: executable, directory: directory)
        let config = directory.appendingPathComponent("claude-channel.json")
        let value: [String: Any] = ["mcpServers": ["boringagent": ["command": helper.path,
            "args": ["channel", "--data-dir", directory.path]]]]
        try ClaudeStorage.atomicWrite(JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]), to: config)
        let modern = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/claude")
        let cli = FileManager.default.isExecutableFile(atPath: modern.path) ? ClaudeInstaller.shellQuote(modern.path) : "claude"
        return "\(cli) --mcp-config \(ClaudeInstaller.shellQuote(config.path)) --dangerously-load-development-channels server:boringagent"
    }
}
