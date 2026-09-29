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
                if ["--data-dir", "--settings"].contains(arguments[index]) {
                    guard arguments.indices.contains(index + 1), !arguments[index + 1].hasPrefix("--") else { throw ClaudeStorageError.invalidRecord }
                    index += 2
                } else if ["--no-launch-agent", "--once", "--no-ui"].contains(arguments[index]) { index += 1 }
                else { throw ClaudeStorageError.invalidRecord }
            }
            switch subcommand {
            case "hook":
                let bytes = try readInput()
                try? ClaudeRelay.ingest(bytes, directory: directory, origin: ClaudeOriginResolver.capture())
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
                if arguments.contains("--once") { try ClaudeStorage.prepare(directory: directory); broker.processPending() }
                else {
                    try broker.start()
                    withExtendedLifetime(broker) { RunLoop.main.run() }
                }
            case "help", "--help", "-h":
                print("""
                boring-claude-bridge hook|statusline|install|uninstall|serve
                  --data-dir PATH       Private relay folder (select the same folder in the extension)
                  --settings PATH       Claude settings.json, used by install/uninstall
                  --no-launch-agent     Install hooks without starting a login broker
                  --once --no-ui        Process one broker batch without opening apps (testing)

                Install/uninstall run only when you explicitly invoke them. Prompts and unrelated tool
                arguments are discarded; transcripts and credentials are never opened. Hooks never reply.
                """)
            default: throw ClaudeStorageError.invalidRecord
            }
        } catch {
            // Observational hooks must not leak input or interfere with the user's Claude session.
            if subcommand == "hook" || subcommand == "statusline" { exit(0) }
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
