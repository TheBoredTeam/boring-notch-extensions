// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Darwin

@main
struct BridgeTests {
    static var assertions = 0
    static func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        assertions += 1
        if try !condition() { throw NSError(domain: "BridgeTests", code: assertions, userInfo: [NSLocalizedDescriptionKey: message]) }
    }
    static func rejects(_ message: String, _ operation: () throws -> Void) throws {
        do { try operation() } catch { assertions += 1; return }
        try expect(false, message)
    }
    static func payload(_ event: String, _ additions: [String: Any] = [:], id: String = "session-test") throws -> Data {
        var object: [String: Any] = ["session_id": id, "cwd": "/Users/example/Test Project", "hook_event_name": event]
        object.merge(additions) { _, right in right }
        return try JSONSerialization.data(withJSONObject: object)
    }

    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("boring-claude-tests-\(UUID().uuidString)")
        try ClaudeStorage.ensureDirectory(root)
        defer { try? FileManager.default.removeItem(at: root) }
        let relay = root.appendingPathComponent("relay")
        let now = Date().timeIntervalSince1970
        try ClaudeRelay.ingest(payload("SessionStart"), directory: relay, now: now)
        try expect(ClaudeStorage.loadSessions(directory: relay).count == 1, "SessionStart registers one session")
        try ClaudeRelay.ingest(payload("UserPromptSubmit", ["prompt": "SECRET-PROMPT-NEVER-STORE"]), directory: relay, now: now + 1)
        try expect(ClaudeStorage.session(id: "session-test", directory: relay)?.phase == .working, "Prompt starts work")
        let question = try payload("PreToolUse", ["tool_name": "AskUserQuestion", "tool_input": [
            "questions": [["question": "Which environment?", "options": [["label": "Staging"], ["label": "Production"]]]],
            "unrecognized": "SECRET-ARGUMENT"]])
        try ClaudeRelay.ingest(question, directory: relay, now: now + 2)
        let statusline = try payload("", ["rate_limits": ["five_hour": ["used_percentage": 30, "resets_at": now + 3600],
            "seven_day": ["used_percentage": 60]], "context_window": ["remaining_percentage": 75], "api_key": "SECRET-TOKEN"])
        try ClaudeRelay.ingest(statusline, directory: relay, statusline: true, now: now + 3)
        var session = try ClaudeStorage.session(id: "session-test", directory: relay)!
        try expect(session.phase == .needsInput && session.question == "Which environment?", "Usage cannot clear question")
        try expect(session.questionOptions == ["Staging", "Production"], "Only bounded option labels retained")
        try expect(session.usage?.fiveHour?.remainingPercent == 70 && session.usage?.sevenDay?.remainingPercent == 40, "Quota percentages converted")
        try expect(session.usage?.contextRemaining == 75, "Context is separate")
        try ClaudeRelay.ingest(payload("PostToolUse", ["tool_name": "Read"]), directory: relay)
        try expect(ClaudeStorage.session(id: "session-test", directory: relay)?.phase == .needsInput, "Unrelated tool cannot resolve question")
        try ClaudeRelay.ingest(payload("PermissionRequest", ["tool_name": "AskUserQuestion", "tool_input": ["secret": "NO"]]), directory: relay)
        try expect(ClaudeStorage.session(id: "session-test", directory: relay)?.question == "Which environment?", "Permission signal preserves real question")

        let failureLock = NSLock()
        var failures = 0
        DispatchQueue.concurrentPerform(iterations: 80) { index in
            do {
                try ClaudeRelay.ingest(index.isMultiple(of: 2) ? question : statusline,
                    directory: relay, statusline: !index.isMultiple(of: 2), now: now + 4 + Double(index))
            } catch { failureLock.lock(); failures += 1; failureLock.unlock() }
        }
        session = try ClaudeStorage.session(id: "session-test", directory: relay)!
        try expect(failures == 0 && session.phase == .needsInput && session.usage?.fiveHour?.remainingPercent == 70, "Concurrent updates merge atomically")
        try ClaudeRelay.ingest(payload("Stop", ["agent_id": "subagent", "last_assistant_message": "SECRET-REPLY"]), directory: relay)
        try expect(ClaudeStorage.session(id: "session-test", directory: relay)?.phase == .needsInput, "Subagent does not overwrite primary session")
        let stored = String(decoding: try ClaudeStorage.read(ClaudeStorage.sessionURL(id: "session-test", directory: relay)), as: UTF8.self)
        try expect(!stored.contains("SECRET") && !stored.contains("transcript"), "Secrets prompts arguments and transcripts are absent")
        try ClaudeRelay.ingest(payload("PostToolUse", ["tool_name": "AskUserQuestion"]), directory: relay)
        try expect(ClaudeStorage.session(id: "session-test", directory: relay)?.question == nil, "Answered question clears")
        try ClaudeRelay.ingest(payload("PermissionRequest", ["tool_name": "Bash", "tool_input": ["command": "SECRET-COMMAND"]]), directory: relay)
        try expect(ClaudeStorage.session(id: "session-test", directory: relay)?.question == "Claude needs permission to use Bash.", "Permission uses safe tool name")
        try ClaudeRelay.ingest(payload("StopFailure", ["error": "rate_limit", "error_details": "SECRET-ERROR"]), directory: relay)
        try expect(ClaudeStorage.session(id: "session-test", directory: relay)?.question == "Claude reached a usage limit.", "API failure reported without raw detail")
        try ClaudeRelay.ingest(payload("SessionEnd"), directory: relay)
        try expect(ClaudeStorage.session(id: "session-test", directory: relay)?.phase == .ended, "Session end retained explicitly")
        try ClaudeRelay.ingest(payload("", ["context_window": ["remaining_percentage": 12]]), directory: relay, statusline: true)
        session = try ClaudeStorage.session(id: "session-test", directory: relay)!
        try expect(session.usage?.fiveHour == nil && session.usage?.contextRemaining == 12, "Unavailable quotas never fabricated")
        try expect(ClaudeValidation.percentage(true) == nil && ClaudeValidation.percentage(101) == nil, "Invalid quota rejected")
        try rejects("Oversized input rejected") { try ClaudeRelay.ingest(Data(repeating: 65, count: ClaudeRelay.maximumInputBytes + 1), directory: relay) }
        try rejects("Traversal rejected") { try ClaudeRelay.ingest(payload("SessionStart", id: "../escape"), directory: relay) }
        try rejects("Malformed JSON rejected") { try ClaudeRelay.ingest(Data("[]".utf8), directory: relay) }
        try ClaudeStorage.atomicWrite(Data("invalid".utf8), to: relay.appendingPathComponent("sessions/corrupt.json"))
        try expect(ClaudeStorage.loadSessions(directory: relay).count == 1, "Malformed individual record skipped")
        try FileManager.default.createSymbolicLink(at: relay.appendingPathComponent("sessions/link.json"), withDestinationURL: relay.appendingPathComponent("sessions/session-test.json"))
        try expect(ClaudeStorage.loadSessions(directory: relay).count == 1, "Symlink record skipped")
        try rejects("Unknown focus target rejected") { try ClaudeStorage.requestFocus(sessionID: "unknown", directory: relay) }
        try ClaudeStorage.requestFocus(sessionID: "session-test", directory: relay)
        ClaudeFocusBroker(directory: relay, allowUI: false).processPending()
        try expect(ClaudeStorage.focusReceipt(sessionID: "session-test", directory: relay)?.status == "unavailable", "Broker emits honest no-UI receipt")
        try expect(!ClaudeOriginResolver.validTTY("/dev/ttys0\" & do shell script"), "TTY injection rejected")
        try expect(!ClaudeValidation.remoteID("session_good/../../evil"), "Remote URL path injection rejected")
        try expect(ClaudeOriginResolver.looksLikeClaude("/Users/example/.local/share/claude/versions/2.1.283"), "Native version-named binary recognized")
        try expect(!ClaudeOriginResolver.looksLikeClaude("/tmp/boring-claude-bridge"), "Bridge cannot impersonate Claude origin")
        try expect(ClaudeOriginResolver.capture(environment: ["CLAUDE_PID": "1", "CLAUDE_CODE_BRIDGE_SESSION_ID": "session_example"]).claudePID == nil, "Foreign/system PID not accepted")

        try installationTests(root: root)
        try codexInstallationTests(root: root)
        try capacityTests(root: root)
        print("Bridge tests passed: \(assertions) assertions, including 80 concurrent updates.")
    }

    static func codexInstallationTests(root: URL) throws {
        let relay = root.appendingPathComponent("codex relay")
        let home = root.appendingPathComponent("codex home")
        let executable = root.appendingPathComponent("codex source helper")
        try ClaudeStorage.atomicWrite(Data("fixture-helper".utf8), to: executable)
        try AgentBridgeInstaller.installCodex(executable: executable, directory: relay, launch: false, home: home)
        let agent = AgentBridgeInstaller.codexAgent(home: home)
        try expect(!FileManager.default.fileExists(atPath: agent.path), "No-launch option creates no persistent login item")
        let helper = relay.appendingPathComponent("bin/boring-claude-bridge")
        try expect(FileManager.default.isExecutableFile(atPath: helper.path), "Standalone setup prepares its own stable helper")
        try FileManager.default.createDirectory(at: agent.deletingLastPathComponent(), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        var plist: [String: Any] = ["Label": AgentBridgeInstaller.codexLabel,
            "ProgramArguments": ["/different/helper", "codex-serve", "--data-dir", relay.path]]
        try ClaudeStorage.atomicWrite(PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0), to: agent)
        try rejects("Uninstall cannot remove another executable's login item") {
            try AgentBridgeInstaller.uninstallCodex(directory: relay, home: home, launch: false)
        }
        try expect(FileManager.default.fileExists(atPath: agent.path), "Rejected replacement remains intact")
        plist["ProgramArguments"] = [helper.path, "codex-serve", "--data-dir", relay.path]
        try ClaudeStorage.atomicWrite(PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0), to: agent)
        try AgentBridgeInstaller.uninstallCodex(directory: relay, home: home, launch: false)
        try expect(!FileManager.default.fileExists(atPath: agent.path), "Uninstall removes only the exact owned login item")
        try expect(FileManager.default.fileExists(atPath: helper.path), "Uninstall preserves private helper/data for review")
    }

    static func installationTests(root: URL) throws {
        let relay = root.appendingPathComponent("installer relay's data")
        let settings = root.appendingPathComponent("settings.json")
        let executable = root.appendingPathComponent("source-helper")
        try ClaudeStorage.atomicWrite(Data("test executable".utf8), to: executable)
        let received = root.appendingPathComponent("received-input")
        let original: [String: Any] = ["unrelated": ["keep": true],
            "hooks": ["Stop": [["matcher": "", "hooks": [["type": "command", "command": "printf existing-hook"]]]]],
            "statusLine": ["type": "command", "command": "cat > \(ClaudeInstaller.shellQuote(received.path)); exit 7", "padding": 3, "refreshInterval": 10]]
        try ClaudeInstaller.writeObject(original, settings)
        try ClaudeInstaller.install(directory: relay, settings: settings, executable: executable, launchAgent: false)
        let installed = try ClaudeStorage.read(settings, limit: ClaudeInstaller.maximumSettingsBytes)
        let lock = NSLock()
        var failed = false
        DispatchQueue.concurrentPerform(iterations: 12) { _ in
            do { try ClaudeInstaller.install(directory: relay, settings: settings, executable: executable, launchAgent: false) }
            catch { lock.lock(); failed = true; lock.unlock() }
        }
        try expect(!failed, "Concurrent installers serialize")
        try expect(ClaudeStorage.read(settings, limit: ClaudeInstaller.maximumSettingsBytes) == installed, "Install is idempotent")
        let input = Data("{\"arbitrary\":\"exact stdin\\nwith whitespace\"}\n".utf8)
        try expect(ClaudeInstaller.forwardStatusline(input, directory: relay) == 7, "Existing status command exit code preserved")
        try expect(ClaudeStorage.read(received) == input, "Existing status command receives exact bytes")
        try ClaudeInstaller.uninstall(directory: relay, settings: settings, launchctl: false)
        try expect(NSDictionary(dictionary: ClaudeInstaller.readObject(settings)).isEqual(to: original), "Uninstall restores original settings exactly")
        try ClaudeInstaller.install(directory: relay, settings: settings, executable: executable, launchAgent: false)
        var changed = try ClaudeInstaller.readObject(settings)
        changed["newUserKey"] = "preserve"
        changed["statusLine"] = ["type": "command", "command": "printf user-replacement"]
        var hooks = changed["hooks"] as! [String: Any]
        var groups = hooks["Stop"] as! [[String: Any]]
        groups.append(["hooks": [["type": "command", "command": "printf new-user-hook"]]])
        hooks["Stop"] = groups; changed["hooks"] = hooks
        try ClaudeInstaller.writeObject(changed, settings)
        try ClaudeInstaller.uninstall(directory: relay, settings: settings, launchctl: false)
        let uninstalled = try ClaudeInstaller.readObject(settings)
        try expect(uninstalled["newUserKey"] as? String == "preserve", "User changes survive uninstall")
        try expect((uninstalled["statusLine"] as? [String: Any])?["command"] as? String == "printf user-replacement", "New status command survives uninstall")
        try expect((((uninstalled["hooks"] as? [String: Any])?["Stop"]) as? [[String: Any]])?.count == 2, "New user hooks survive uninstall")
        try ClaudeStorage.atomicWrite(Data("{broken".utf8), to: settings)
        try rejects("Malformed settings not overwritten") { try ClaudeInstaller.install(directory: relay, settings: settings, executable: executable, launchAgent: false) }
        try expect(String(decoding: ClaudeStorage.read(settings), as: UTF8.self) == "{broken", "Malformed config bytes preserved")
        let emptyHooks: [String: Any] = ["hooks": ["Stop": []], "preserved": 42]
        try ClaudeInstaller.writeObject(emptyHooks, settings)
        try ClaudeInstaller.install(directory: relay, settings: settings, executable: executable, launchAgent: false)
        try ClaudeInstaller.uninstall(directory: relay, settings: settings, launchctl: false)
        try expect(NSDictionary(dictionary: ClaudeInstaller.readObject(settings)).isEqual(to: emptyHooks), "Empty preexisting hook collections preserved")
    }

    static func capacityTests(root: URL) throws {
        let directory = root.appendingPathComponent("capacity")
        try ClaudeStorage.prepare(directory: directory)
        let now = Date().timeIntervalSince1970
        for index in 0..<ClaudeStorage.maximumSessions {
            let value = ClaudeSession(id: "capacity-\(index)", project: "Fixture", directory: "/tmp/fixture",
                                      phase: index == 0 ? .ended : .working, createdAt: now, updatedAt: now)
            try JSONEncoder().encode(value).write(to: ClaudeStorage.sessionURL(id: value.id, directory: directory))
        }
        try ClaudeRelay.ingest(payload("SessionStart", id: "new-session"), directory: directory)
        try expect(ClaudeStorage.loadSessions(directory: directory).count == ClaudeStorage.maximumSessions, "Storage stays bounded at capacity")
        try expect(ClaudeStorage.session(id: "capacity-0", directory: directory) == nil, "Oldest ended session gives way to new work")
        try expect(ClaudeStorage.session(id: "new-session", directory: directory) != nil, "Capacity is not a lifetime session quota")
        try rejects("Active sessions are never evicted") {
            try ClaudeRelay.ingest(payload("SessionStart", id: "overflow-session"), directory: directory)
        }
    }
}
