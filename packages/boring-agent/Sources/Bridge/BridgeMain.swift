// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Darwin

@main
struct BridgeMain {
    static func main() {
        signal(SIGPIPE, SIG_IGN)
        let arguments = Array(CommandLine.arguments.dropFirst())
        let subcommand = arguments.first ?? "help"
        func option(_ name: String) -> String? {
            guard let index = arguments.firstIndex(of: name), arguments.indices.contains(index + 1) else { return nil }
            return arguments[index + 1]
        }
        let directory = option("--data-dir").map { URL(fileURLWithPath: $0).standardizedFileURL } ?? ClaudeStorage.defaultDirectory
        let settings = option("--settings").map { URL(fileURLWithPath: $0).standardizedFileURL } ?? ClaudeInstaller.defaultSettings
        do {
            var index = 1
            while index < arguments.count {
                if ["--data-dir", "--settings", "--codex-socket", "--codex-executable"].contains(arguments[index]) {
                    guard arguments.indices.contains(index + 1), !arguments[index + 1].hasPrefix("--") else { throw ClaudeStorageError.invalidRecord }
                    index += 2
                } else if ["--no-launch-agent", "--once", "--no-ui"].contains(arguments[index]) { index += 1 }
                else { throw ClaudeStorageError.invalidRecord }
            }
            switch subcommand {
            case "hook":
                let bytes = try readInput()
                let origin = ClaudeOriginResolver.capture()
                try? ClaudeRelay.ingest(bytes, directory: directory, origin: origin)
                try? ClaudeMessagingStorage.noteHook(input: bytes, directory: directory, origin: origin)
            case "question":
                try ClaudeQuestionBridge.run(input: readInput(), directory: directory, origin: ClaudeOriginResolver.capture())
            case "channel":
                try ClaudeChannel.run(directory: directory)
            case "channel-setup":
                guard let executable = Bundle.main.executableURL else { throw ClaudeStorageError.io }
                let command = try AgentBridgeInstaller.channelSetup(executable: executable, directory: directory)
                print("Development channel prepared. Start a NEW Claude CLI session with:\n\(command)\nReview Claude's channel and MCP confirmations yourself. Existing sessions are unchanged. BoringAgent enables prompting only after Claude acknowledges this channel; some Claude accounts/builds may not support it.")
            case "codex-install":
                guard let executable = Bundle.main.executableURL else { throw ClaudeStorageError.io }
                try AgentBridgeInstaller.installCodex(executable: executable, directory: directory,
                    endpoint: option("--codex-socket").map { URL(fileURLWithPath: $0) },
                    accountExecutable: option("--codex-executable").map { URL(fileURLWithPath: $0) },
                    launch: !arguments.contains("--no-launch-agent"))
                print("Codex relay installed. Choose this folder in BoringAgent's Codex settings:\n\(directory.path)\nThe relay connects to your existing local Codex app-server and reads usage through your existing CLI sign-in. Private Desktop-only sessions may not expose control. API-key logins have no ChatGPT subscription quota.")
            case "codex-uninstall":
                try AgentBridgeInstaller.uninstallCodex(directory: directory)
                print("Codex relay stopped and removed. Private relay records remain in \(directory.path).")
            case "codex-login-usage":
                try CodexAccountSetup.login(executable: option("--codex-executable").map { URL(fileURLWithPath: $0) }, directory: directory)
            case "codex-logout-usage":
                try CodexAccountSetup.logout(executable: option("--codex-executable").map { URL(fileURLWithPath: $0) }, directory: directory)
            case "codex-serve":
                let codex = CodexBridgeService(directory: directory,
                    endpoint: option("--codex-socket").map { URL(fileURLWithPath: $0) },
                    accountExecutable: option("--codex-executable").map { URL(fileURLWithPath: $0) })
                try codex.start()
                withExtendedLifetime(codex) { RunLoop.main.run() }
            case "statusline":
                let forwarder = try ClaudeStatuslineForwarder(command: ClaudeInstaller.originalStatusCommand(directory: directory))
                var boundedInput: Data? = Data()
                while let chunk = try FileHandle.standardInput.read(upToCount: 16_384), !chunk.isEmpty {
                    forwarder.write(chunk)
                    if let count = boundedInput?.count {
                        if count + chunk.count <= ClaudeRelay.maximumInputBytes { boundedInput?.append(chunk) }
                        else { boundedInput = nil }
                    }
                }
                if let bytes = boundedInput { try? ClaudeRelay.ingest(bytes, directory: directory, statusline: true, origin: ClaudeOriginResolver.capture()) }
                exit(forwarder.finish())
            case "install":
                guard let executable = Bundle.main.executableURL else { throw ClaudeStorageError.io }
                try ClaudeInstaller.install(directory: directory, settings: settings, executable: executable,
                                             launchAgent: !arguments.contains("--no-launch-agent"))
                print("Claude relay installed. In BoringAgent’s Claude settings, select this private folder:\n\(directory.path)\nCurrent Claude Code sessions reload hooks automatically. Sessions appear after their next supported event; older versions may need a restart. Existing hooks and status-line output are preserved.")
            case "uninstall":
                try ClaudeInstaller.uninstall(directory: directory, settings: settings)
                print("Claude relay integration removed. Private session data remains in \(directory.path) for your review and deletion.")
            case "serve":
                let broker = ClaudeFocusBroker(directory: directory, allowUI: !arguments.contains("--no-ui"))
                let usage = ClaudeAccountUsageService(directory: directory, allowUI: !arguments.contains("--no-ui"))
                if arguments.contains("--once") {
                    try ClaudeStorage.prepare(directory: directory)
                    broker.processPending()
                    usage.processPending()
                    usage.stop()
                }
                else {
                    try broker.start()
                    do { try usage.start() }
                    catch {
                        FileHandle.standardError.write(Data("Account usage could not start. Session handoff remains available.\n".utf8))
                    }
                    withExtendedLifetime((broker, usage)) { RunLoop.main.run() }
                }
            case "help", "--help", "-h":
                print("""
                boring-claude-bridge install|uninstall|serve|codex-install|codex-uninstall|codex-serve|channel-setup
                boring-claude-bridge codex-login-usage|codex-logout-usage
                  --data-dir PATH       Private relay folder (select the same folder in the extension)
                  --settings PATH       Claude settings.json, used by install/uninstall
                  --no-launch-agent     Install hooks without starting a login broker
                  --once --no-ui        Process one broker batch without opening apps (testing)
                  --codex-socket PATH   Existing local Codex app-server control socket
                  --codex-executable PATH  Official Codex CLI for account-read-only broker

                Codex usage sign-in is an explicit official device-login flow. Its separate account
                home preserves your existing Codex login, provider and sessions.
                The background account reader never starts login or switches a session's provider.

                Install/uninstall run only when you explicitly invoke them. Prompts and unrelated tool
                arguments are discarded; transcripts are never opened. Inline Claude question replies
                require the separate opt-in in BoringAgent settings and a live connected host. Account usage
                is separate: only after Connect usage, the broker reads the Claude Code Keychain login
                and fetches plan limits from Anthropic. It never stores or refreshes your credentials.
                """)
            default: throw ClaudeStorageError.invalidRecord
            }
        } catch {
            // Observational hooks must not leak input or interfere with the user's Claude session.
            if ["hook", "statusline", "question"].contains(subcommand) { exit(0) }
            FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
            exit(1)
        }
    }

    static func readInput() throws -> Data {
        var result = Data()
        while let chunk = try FileHandle.standardInput.read(upToCount: 16_384), !chunk.isEmpty {
            guard result.count + chunk.count <= ClaudeRelay.maximumInputBytes else { throw ClaudeStorageError.tooLarge }
            result.append(chunk)
        }
        return result
    }
}
