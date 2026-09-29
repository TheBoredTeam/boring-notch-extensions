// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Darwin

enum ClaudeInstaller {
    static let launchLabel = "theboringteam.boringnotch.claude-code.bridge"
    static let maximumSettingsBytes = 2_097_152
    static var defaultSettings: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/settings.json") }

    static func shellQuote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    static func readObject(_ url: URL) throws -> [String: Any] {
        if !FileManager.default.fileExists(atPath: url.path) { return [:] }
        guard let value = try JSONSerialization.jsonObject(with: ClaudeStorage.read(url, limit: maximumSettingsBytes)) as? [String: Any]
        else { throw ClaudeStorageError.invalidRecord }
        return value
    }

    static func writeObject(_ value: [String: Any], _ url: URL) throws {
        try ClaudeStorage.atomicWrite(JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]),
                                      to: url, limit: maximumSettingsBytes)
    }

    static func stateURL(_ directory: URL) -> URL { directory.appendingPathComponent(".integration.json") }
    static func launchAgentURL(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appendingPathComponent("Library/LaunchAgents/\(launchLabel).plist")
    }

    static func command(helper: URL, mode: String, directory: URL) -> String {
        shellQuote(helper.path) + " " + mode + " --data-dir " + shellQuote(directory.path)
    }

    static func install(directory: URL, settings: URL, executable: URL, launchAgent: Bool = true,
                        home: URL = FileManager.default.homeDirectoryForCurrentUser) throws {
        try ClaudeStorage.prepare(directory: directory)
        let settingsFolder = settings.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: settingsFolder.path) {
            try FileManager.default.createDirectory(at: settingsFolder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        try ClaudeStorage.checkDirectory(settingsFolder)
        try ClaudeStorage.locked(at: settingsFolder.appendingPathComponent(".boring-claude-settings.lock")) {
            try ClaudeStorage.locked(at: directory.appendingPathComponent(".installation.lock")) {
                var configuration = try readObject(settings)
                var state = try readObject(stateURL(directory))
                if !state.isEmpty && state["schemaVersion"] as? Int != 1 { throw ClaudeStorageError.invalidRecord }
                if let ownerSettings = state["settingsPath"] as? String, ownerSettings != settings.standardizedFileURL.path {
                    throw ClaudeStorageError.invalidRecord
                }
                let helper = try AgentBridgeInstaller.stableHelper(executable: executable, directory: directory)
                let hookCommand = command(helper: helper, mode: "hook", directory: directory)
                let questionCommand = command(helper: helper, mode: "question", directory: directory)
                let statusCommand = command(helper: helper, mode: "statusline", directory: directory)
                if state["schemaVersion"] == nil {
                    state["originalHadHooks"] = configuration["hooks"] != nil
                    state["originalEmptyHookEvents"] = (configuration["hooks"] as? [String: Any] ?? [:]).compactMap { key, value in
                        (value as? [Any])?.isEmpty == true ? key : nil
                    }.sorted()
                }
                if let status = configuration["statusLine"] {
                    guard let statusObject = status as? [String: Any], statusObject["type"] as? String == "command",
                          let existing = statusObject["command"] as? String, !existing.isEmpty else { throw ClaudeStorageError.invalidRecord }
                    if existing != statusCommand { state["originalStatusLine"] = statusObject }
                    else if state["schemaVersion"] == nil { throw ClaudeStorageError.invalidRecord }
                } else { state["originalStatusLine"] = NSNull() }
                var hooks: [String: Any] = [:]
                if let value = configuration["hooks"] {
                    guard let object = value as? [String: Any] else { throw ClaudeStorageError.invalidRecord }
                    hooks = object
                }
                for event in ClaudeRelay.hookEvents {
                    var groups: [[String: Any]] = []
                    if let value = hooks[event] {
                        guard let array = value as? [[String: Any]], array.allSatisfy({ $0["hooks"] is [[String: Any]] })
                        else { throw ClaudeStorageError.invalidRecord }
                        groups = array
                    }
                    let exists = groups.contains { group in
                        (group["hooks"] as? [[String: Any]] ?? []).contains { $0["command"] as? String == hookCommand }
                    }
                    if !exists { groups.append(["hooks": [["type": "command", "command": hookCommand, "timeout": 2]]]) }
                    hooks[event] = groups
                }
                var questionGroups = hooks["PreToolUse"] as? [[String: Any]] ?? []
                if !questionGroups.contains(where: { group in
                    (group["hooks"] as? [[String: Any]] ?? []).contains { $0["command"] as? String == questionCommand }
                }) {
                    questionGroups.append(["matcher": "AskUserQuestion", "hooks": [["type": "command", "command": questionCommand, "timeout": 95]]])
                }
                hooks["PreToolUse"] = questionGroups
                configuration["hooks"] = hooks
                var status = (configuration["statusLine"] as? [String: Any]) ?? ["type": "command"]
                status["command"] = statusCommand
                configuration["statusLine"] = status
                state["schemaVersion"] = 1
                state["settingsPath"] = settings.standardizedFileURL.path
                state["hookCommand"] = hookCommand
                state["questionCommand"] = questionCommand
                state["statusCommand"] = statusCommand
                state["launchAgent"] = launchAgent || (state["launchAgent"] as? Bool ?? false)
                if launchAgent { try validateLaunchAgent(helper: helper, directory: directory, home: home) }
                // Save recovery metadata before replacing user configuration. Uninstall removes only our nodes.
                try writeObject(state, stateURL(directory))
                try writeObject(configuration, settings)
                if launchAgent { try installLaunchAgent(helper: helper, directory: directory, home: home) }
            }
        }
    }

    static func uninstall(directory: URL, settings: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser,
                          launchctl: Bool = true) throws {
        try ClaudeStorage.checkDirectory(directory)
        let state = try readObject(stateURL(directory))
        guard !state.isEmpty else { return }
        guard state["settingsPath"] as? String == settings.standardizedFileURL.path,
              let hookCommand = state["hookCommand"] as? String, let statusCommand = state["statusCommand"] as? String
        else { throw ClaudeStorageError.invalidRecord }
        try ClaudeStorage.locked(at: settings.deletingLastPathComponent().appendingPathComponent(".boring-claude-settings.lock")) {
            try ClaudeStorage.locked(at: directory.appendingPathComponent(".installation.lock")) {
                var configuration = try readObject(settings)
                if var hooks = configuration["hooks"] as? [String: Any] {
                    for event in ClaudeRelay.hookEvents {
                        guard let groups = hooks[event] as? [[String: Any]] else { continue }
                        let remaining = groups.compactMap { group -> [String: Any]? in
                            guard let items = group["hooks"] as? [[String: Any]] else { return group }
                            let kept = items.filter { item in
                                guard let command = item["command"] as? String else { return true }
                                return command != hookCommand && command != state["questionCommand"] as? String
                            }
                            if kept.count == items.count { return group }
                            if kept.isEmpty { return nil }
                            var copy = group; copy["hooks"] = kept; return copy
                        }
                        if remaining.isEmpty && !(state["originalEmptyHookEvents"] as? [String] ?? []).contains(event) { hooks.removeValue(forKey: event) }
                        else { hooks[event] = remaining }
                    }
                    if hooks.isEmpty && state["originalHadHooks"] as? Bool != true { configuration.removeValue(forKey: "hooks") }
                    else { configuration["hooks"] = hooks }
                }
                if (configuration["statusLine"] as? [String: Any])?["command"] as? String == statusCommand {
                    if let original = state["originalStatusLine"], !(original is NSNull) { configuration["statusLine"] = original }
                    else { configuration.removeValue(forKey: "statusLine") }
                }
                try writeObject(configuration, settings)
                if state["launchAgent"] as? Bool == true {
                    let agent = launchAgentURL(home: home)
                    // Only remove our own plist with this exact data directory, not an unrelated replacement.
                    if let data = try? ClaudeStorage.read(agent),
                       let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                       let arguments = plist["ProgramArguments"] as? [String], arguments.last == directory.path {
                        if launchctl { _ = try? runLaunchctl(["bootout", "gui/\(getuid())", agent.path]) }
                        try FileManager.default.removeItem(at: agent)
                    }
                }
                try FileManager.default.removeItem(at: stateURL(directory))
                // Keep private observations and the stable binary for explicit user cleanup/reconnection.
            }
        }
    }

    static func originalStatusCommand(directory: URL) throws -> String? {
        let state = try readObject(stateURL(directory))
        return (state["originalStatusLine"] as? [String: Any])?["command"] as? String
    }

    static func forwardStatusline(_ data: Data, directory: URL) throws -> Int32 {
        let forwarder = try ClaudeStatuslineForwarder(command: originalStatusCommand(directory: directory))
        forwarder.write(data)
        return forwarder.finish()
    }

    static func installLaunchAgent(helper: URL, directory: URL, home: URL) throws {
        let target = launchAgentURL(home: home)
        if !FileManager.default.fileExists(atPath: target.deletingLastPathComponent().path) {
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        }
        let plist: [String: Any] = ["Label": launchLabel,
            "ProgramArguments": [helper.path, "serve", "--data-dir", directory.path],
            "RunAtLoad": true, "KeepAlive": ["SuccessfulExit": false], "ThrottleInterval": 10,
            "ProcessType": "Background"]
        try ClaudeStorage.atomicWrite(PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0), to: target)
        _ = try? runLaunchctl(["bootout", "gui/\(getuid())/\(launchLabel)"])
        guard try runLaunchctl(["bootstrap", "gui/\(getuid())", target.path]) == 0 else { throw ClaudeStorageError.io }
    }

    static func validateLaunchAgent(helper: URL, directory: URL, home: URL) throws {
        let target = launchAgentURL(home: home)
        guard FileManager.default.fileExists(atPath: target.path) else { return }
        let bytes = try ClaudeStorage.read(target)
        guard let existing = try PropertyListSerialization.propertyList(from: bytes, format: nil) as? [String: Any],
              existing["Label"] as? String == launchLabel,
              existing["ProgramArguments"] as? [String] == [helper.path, "serve", "--data-dir", directory.path]
        else { throw ClaudeStorageError.unsafePath }
    }

    @discardableResult static func runLaunchctl(_ arguments: [String]) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run(); process.waitUntilExit()
        return process.terminationStatus
    }
}

/// Streams the original bytes through, even when the relay's bounded decoder rejects a large payload.
/// Output and errors remain attached to Claude's status line; no raw input is written to disk.
final class ClaudeStatuslineForwarder {
    private var process: Process?
    private var input: Pipe?

    init(command: String?) throws {
        guard let command, !command.isEmpty else { return }
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sh")
        child.arguments = ["-c", command]
        let pipe = Pipe()
        child.standardInput = pipe
        child.standardOutput = FileHandle.standardOutput
        child.standardError = FileHandle.standardError
        try child.run()
        process = child; input = pipe
    }

    func write(_ data: Data) {
        // Commands may intentionally exit before consuming stdin. Keep their original exit status.
        try? input?.fileHandleForWriting.write(contentsOf: data)
    }

    func finish() -> Int32 {
        try? input?.fileHandleForWriting.close()
        guard let process else { return 0 }
        process.waitUntilExit()
        return process.terminationReason == .exit ? process.terminationStatus : 128 + process.terminationStatus
    }
}
