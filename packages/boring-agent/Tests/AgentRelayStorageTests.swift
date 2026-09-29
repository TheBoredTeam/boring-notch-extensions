// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Darwin

/// Exercises real files only beneath one disposable directory. No provider,
/// credentials, user configuration, helper process or app session is opened.
@main
@MainActor
struct AgentRelayStorageTests {
    static var assertions = 0

    static func expect(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
        assertions += 1
        guard try value() else {
            throw NSError(domain: "AgentRelayStorageTests", code: assertions,
                          userInfo: [NSLocalizedDescriptionKey: message])
        }
    }

    static func expectFailure(_ message: String, _ action: () throws -> Void) throws {
        var failed = false
        do { try action() } catch { failed = true }
        try expect(failed, message)
    }

    static func command(provider: String = "claude", session: String = "session-one",
                        revision: String = "owner-one", age: TimeInterval = 0) -> AgentMessageCommand {
        AgentMessageCommand(providerID: provider, sessionID: session, revision: revision,
            createdAt: Date().addingTimeInterval(-age).timeIntervalSince1970, text: "Synthetic message only")
    }

    static func messageURL(_ command: AgentMessageCommand, _ root: URL) -> URL {
        root.appendingPathComponent("messages/\(command.id).json")
    }

    static func mode(_ url: URL) throws -> mode_t {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { throw ClaudeStorageError.io }
        return info.st_mode & 0o777
    }

    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("boring-agent-relay-tests-\(UUID().uuidString)")
        try ClaudeStorage.ensureDirectory(root)
        defer { try? FileManager.default.removeItem(at: root) }
        try exactOnceAndPermissions(root.appendingPathComponent("exact-once"))
        try filteredClaims(root.appendingPathComponent("filters"))
        try expiredCapacity(root.appendingPathComponent("capacity"))
        try cancelledSubmissions(root.appendingPathComponent("cancel"))
        try unsafePaths(root.appendingPathComponent("paths"))
        try reportValidation(root.appendingPathComponent("reports"))
        print("Agent relay storage tests passed: \(assertions) assertions; isolated private-file fixtures only.")
    }

    static func exactOnceAndPermissions(_ root: URL) throws {
        let value = command()
        try AgentRelayStorage.submit(value, directory: root)
        try expect(try mode(root) == 0o700, "Relay root is private")
        for folder in ["providers", "messages", "message-receipts"] {
            try expect(try mode(root.appendingPathComponent(folder)) == 0o700, "Relay subdirectories are private")
        }
        try expect(try mode(messageURL(value, root)) == 0o600, "A queued prompt is owner-readable only")
        try expect(try mode(root.appendingPathComponent(".messages.lock")) == 0o600, "The queue lock is private")
        try expectFailure("An identical UUID cannot be submitted twice before claim") {
            try AgentRelayStorage.submit(value, directory: root)
        }
        let claimed = try AgentRelayStorage.takeCommands(providerID: value.providerID, directory: root)
        try expect(claimed == [value], "Claim preserves the exact command identity and payload")
        try expect(!FileManager.default.fileExists(atPath: messageURL(value, root).path), "Claim removes prompt text from the queue")
        let pending = try AgentRelayStorage.receipt(id: value.id, directory: root)
        try expect(pending?.state == .pending && pending?.sessionID == value.sessionID,
                   "A matching pending receipt is durable before dispatch")
        try expect(try mode(root.appendingPathComponent("message-receipts/\(value.id).json")) == 0o600,
                   "Receipts have private file permissions")
        try expect(try AgentRelayStorage.takeCommands(providerID: value.providerID, directory: root).isEmpty,
                   "A second claim never replays the first command")
        try expectFailure("A claimed UUID is fenced while delivery is pending") {
            try AgentRelayStorage.submit(value, directory: root)
        }
        let accepted = AgentMessageReceipt(id: value.id, sessionID: value.sessionID, state: .accepted, message: "Accepted")
        try AgentRelayStorage.writeReceipt(accepted, directory: root)
        try expect(try AgentRelayStorage.receipt(id: value.id, directory: root) == accepted, "Terminal receipt round-trips exactly")
        try expectFailure("A terminal receipt prevents resubmitting the same UUID") {
            try AgentRelayStorage.submit(value, directory: root)
        }
        // Simulate a queue file surviving the claim's receipt write before a crash.
        try ClaudeStorage.atomicWrite(JSONEncoder().encode(value), to: messageURL(value, root))
        try expect(try AgentRelayStorage.takeCommands(providerID: value.providerID, directory: root).isEmpty,
                   "Crash recovery with an existing receipt discards the command without replay")
        try expect(try AgentRelayStorage.receipt(id: value.id, directory: root) == accepted,
                   "Duplicate cleanup does not rewrite the accepted result")
    }

    static func filteredClaims(_ root: URL) throws {
        let own = command(age: 1)
        let otherProvider = command(provider: "codex")
        let otherSession = command(session: "session-two")
        let otherOwner = command(revision: "owner-two")
        for value in [own, otherProvider, otherSession, otherOwner] { try AgentRelayStorage.submit(value, directory: root) }
        let selected = try AgentRelayStorage.takeCommands(providerID: "claude", sessionID: "session-one",
            revision: "owner-one", directory: root)
        try expect(selected == [own], "Provider, native session and owner revision must all match")
        for value in [otherProvider, otherSession, otherOwner] {
            try expect(FileManager.default.fileExists(atPath: messageURL(value, root).path), "Unmatched commands stay available to their owners")
            try expect(try AgentRelayStorage.receipt(id: value.id, directory: root) == nil,
                       "Filtering cannot claim another owner's command")
        }
        try expect(try AgentRelayStorage.takeCommands(providerID: "codex", directory: root) == [otherProvider],
                   "Another provider can claim its own message independently")
        let remaining = try AgentRelayStorage.takeCommands(providerID: "claude", directory: root)
        try expect(Set(remaining.map(\.id)) == Set([otherSession.id, otherOwner.id]),
                   "Omitted session/revision filters allow the provider to claim its remaining commands")
        try expectFailure("A provider identifier cannot traverse out of the relay") {
            _ = try AgentRelayStorage.takeCommands(providerID: "../outside", directory: root)
        }
    }

    static func expiredCapacity(_ root: URL) throws {
        try AgentRelayStorage.prepare(directory: root)
        let values = (0..<AgentRelayStorage.maximumCommands).map { command(session: "queued-\($0)") }
        for value in values { try ClaudeStorage.atomicWrite(JSONEncoder().encode(value), to: messageURL(value, root)) }
        try expectFailure("A full queue rejects new work without overwriting existing prompts") {
            try AgentRelayStorage.submit(command(), directory: root)
        }
        for value in values {
            var expired = value; expired.createdAt = Date().addingTimeInterval(-180).timeIntervalSince1970
            try ClaudeStorage.atomicWrite(JSONEncoder().encode(expired), to: messageURL(value, root))
        }
        let fresh = command(provider: "codex", session: "new-session")
        try AgentRelayStorage.submit(fresh, directory: root)
        try expect(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("messages").path).count == 1,
                   "Submitting prunes all 128 expired records and recovers queue capacity")
        for value in values {
            try expect(try AgentRelayStorage.receipt(id: value.id, directory: root)?.state == .rejected,
                       "Expired work gets an explicit non-delivery receipt")
        }
        let expiredOtherOwner = command(provider: "claude", revision: "retired-owner", age: 180)
        let future = command(provider: "claude", age: -30)
        for value in [expiredOtherOwner, future] {
            try ClaudeStorage.atomicWrite(JSONEncoder().encode(value), to: messageURL(value, root))
        }
        try expect(try AgentRelayStorage.takeCommands(providerID: "codex", sessionID: fresh.sessionID,
            revision: fresh.revision, directory: root) == [fresh], "A fresh owner receives only its live command")
        for value in [expiredOtherOwner, future] {
            try expect(!FileManager.default.fileExists(atPath: messageURL(value, root).path),
                       "Claim-time cleanup also removes expired or implausibly future work for retired owners")
        }
    }

    static func cancelledSubmissions(_ root: URL) throws {
        let early = command()
        var wasCancelled = false
        do { try AgentRelayStorage.submit(early, directory: root, shouldSubmit: { false }) }
        catch is CancellationError { wasCancelled = true }
        try expect(wasCancelled && !FileManager.default.fileExists(atPath: messageURL(early, root).path),
                   "Cancellation at the queue lock writes no prompt")
        let late = command()
        var checks = 0
        wasCancelled = false
        do {
            try AgentRelayStorage.submit(late, directory: root, shouldSubmit: {
                checks += 1
                return checks == 1
            })
        } catch is CancellationError { wasCancelled = true }
        try expect(wasCancelled && checks == 2 && !FileManager.default.fileExists(atPath: messageURL(late, root).path),
                   "Cancellation immediately before atomic write also leaves no queued prompt")
        try expect(try AgentRelayStorage.receipt(id: late.id, directory: root) == nil,
                   "A cancelled, never-submitted command cannot look delivered")
    }

    static func unsafePaths(_ root: URL) throws {
        try ClaudeStorage.ensureDirectory(root)
        let external = root.appendingPathComponent("outside")
        try ClaudeStorage.ensureDirectory(external)
        let linkedRoot = root.appendingPathComponent("linked-root")
        try FileManager.default.createSymbolicLink(at: linkedRoot, withDestinationURL: external)
        try expectFailure("A symlink cannot become a relay root") { try AgentRelayStorage.prepare(directory: linkedRoot) }
        let linkedChild = root.appendingPathComponent("linked-child")
        try ClaudeStorage.ensureDirectory(linkedChild)
        try FileManager.default.createSymbolicLink(at: linkedChild.appendingPathComponent("messages"), withDestinationURL: external)
        try expectFailure("A symlink cannot redirect the message directory") { try AgentRelayStorage.submit(command(), directory: linkedChild) }
        try expect(try FileManager.default.contentsOfDirectory(atPath: external.path).isEmpty, "Rejected symlinks do not write outside the relay")
        let shared = root.appendingPathComponent("shared")
        try ClaudeStorage.ensureDirectory(shared)
        guard chmod(shared.path, 0o755) == 0 else { throw ClaudeStorageError.io }
        try expectFailure("Submitting refuses a relay directory readable by other users") { try AgentRelayStorage.submit(command(), directory: shared) }
        guard chmod(shared.path, 0o700) == 0 else { throw ClaudeStorageError.io }

        let safe = root.appendingPathComponent("safe")
        try AgentRelayStorage.prepare(directory: safe)
        let receiptID = UUID().uuidString
        let source = external.appendingPathComponent("receipt.json")
        let receipt = AgentMessageReceipt(id: receiptID, sessionID: "session", state: .accepted, message: "Synthetic")
        try ClaudeStorage.atomicWrite(JSONEncoder().encode(receipt), to: source)
        let linkedFile = safe.appendingPathComponent("message-receipts/\(receiptID).json")
        try FileManager.default.createSymbolicLink(at: linkedFile, withDestinationURL: source)
        try expectFailure("Receipt reads refuse symlink files") { _ = try AgentRelayStorage.receipt(id: receiptID, directory: safe) }
        try FileManager.default.removeItem(at: linkedFile)
        guard link(source.path, linkedFile.path) == 0 else { throw ClaudeStorageError.io }
        try expectFailure("Receipt reads refuse hard-linked files") { _ = try AgentRelayStorage.receipt(id: receiptID, directory: safe) }
    }

    static func reportValidation(_ root: URL) throws {
        let now = Date().timeIntervalSince1970
        let session = AgentSession(providerID: "codex", nativeID: "native-one", project: "Fixture", directory: "/fixture",
            phase: .working, createdAt: now, updatedAt: now)
        let valid = AgentProviderReport(providerID: "codex", connected: true, sessions: [session])
        try AgentRelayStorage.writeReport(valid, directory: root)
        try expect(try AgentRelayStorage.report(providerID: "codex", directory: root) == valid, "A normalized provider report round-trips")
        try expect(try mode(root.appendingPathComponent("providers/codex.json")) == 0o600, "Session reports are private")
        var invalid = valid; invalid.sessions = [session, session]
        try expectFailure("Reports reject duplicate native session identities") { try AgentRelayStorage.writeReport(invalid, directory: root) }
        invalid = valid; invalid.sessions[0].providerID = "claude"
        try expectFailure("Reports cannot claim sessions from another provider") { try AgentRelayStorage.writeReport(invalid, directory: root) }
        invalid = valid; invalid.sessions = (0...2000).map { index in var value = session; value.nativeID = "session-\(index)"; return value }
        try expectFailure("Reports reject more than 2,000 sessions") { try AgentRelayStorage.writeReport(invalid, directory: root) }
        invalid = valid; invalid.message = String(repeating: "x", count: 1025)
        try expectFailure("Report diagnostic text has a bounded size") { try AgentRelayStorage.writeReport(invalid, directory: root) }
        invalid = valid; invalid.updatedAt = .infinity
        try expectFailure("Nonfinite report clocks are invalid") { try AgentRelayStorage.writeReport(invalid, directory: root) }
        var oversized = valid
        oversized.sessions = (0..<1100).map { index in
            var value = session; value.nativeID = "large-\(index)"; value.question = String(repeating: "x", count: 4096); return value
        }
        try expect(oversized.isValid, "The byte-limit fixture has otherwise valid bounded sessions")
        try expectFailure("The encoded report has an independent 4 MiB bound") { try AgentRelayStorage.writeReport(oversized, directory: root) }
        try expect(try AgentRelayStorage.report(providerID: "codex", directory: root) == valid,
                   "Failed report replacement preserves the previous valid report")
        try ClaudeStorage.atomicWrite(Data(repeating: 32, count: AgentRelayStorage.maximumReportBytes + 1),
            to: root.appendingPathComponent("providers/codex.json"), limit: AgentRelayStorage.maximumReportBytes + 1)
        try expectFailure("Report reads reject oversized files before decoding") { _ = try AgentRelayStorage.report(providerID: "codex", directory: root) }
    }
}
