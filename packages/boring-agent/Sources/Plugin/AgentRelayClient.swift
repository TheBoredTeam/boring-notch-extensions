// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import Foundation
import Darwin

@MainActor
final class AgentMessageClient {
    private var tasks: [String: Task<Void, Never>] = [:]
    private var generation = UUID()

    func send(_ command: AgentMessageCommand, directory: URL,
              completion: @escaping @MainActor (AgentMessageReceipt) -> Void) {
        guard tasks[command.id] == nil, tasks.count < 16 else {
            completion(AgentMessageReceipt(id: command.id, sessionID: command.sessionID,
                state: .rejected, message: "Another message is pending. Wait for delivery before sending again.")); return
        }
        let lifetime = generation
        tasks[command.id] = Task { [weak self] in
            guard !Task.isCancelled else { return }
            let worker = Task.detached(priority: .userInitiated) {
                do {
                    try Task.checkCancellation()
                    try AgentRelayStorage.submit(command, directory: directory, shouldSubmit: { !Task.isCancelled })
                    for _ in 0..<120 {
                        try Task.checkCancellation()
                        if let result = try AgentRelayStorage.receipt(id: command.id, directory: directory),
                           result.sessionID == command.sessionID, result.state != .pending { return result }
                        try await Task.sleep(nanoseconds: 250_000_000)
                    }
                    return AgentMessageReceipt(id: command.id, sessionID: command.sessionID, state: .unknown,
                        message: "Delivery could not be confirmed. Check the session before sending again.")
                } catch {
                    return AgentMessageReceipt(id: command.id, sessionID: command.sessionID, state: .unknown,
                        message: "The relay could not confirm delivery. Check the session before sending again.")
                }
            }
            let receipt = await withTaskCancellationHandler {
                await worker.value
            } onCancel: { worker.cancel() }
            guard !Task.isCancelled, let self, self.generation == lifetime else { return }
            self.tasks[command.id] = nil
            completion(receipt)
        }
    }

    func stop() {
        generation = UUID()
        tasks.values.forEach { $0.cancel() }
        tasks.removeAll()
    }
}

/// Observes one bounded provider report, regardless of session/view count.
final class AgentRelayObserver: @unchecked Sendable {
    private let queue = DispatchQueue(label: "theboringteam.boringagent.reports", qos: .utility)
    private let directory: URL
    private let providerID: String
    private let receive: @Sendable (Result<AgentProviderReport?, Error>) -> Void
    private var sources: [DispatchSourceFileSystemObject] = []
    private var work: DispatchWorkItem?
    private var stopped = false
    private var watchingReports = false

    init(directory: URL, providerID: String,
         receive: @escaping @Sendable (Result<AgentProviderReport?, Error>) -> Void) {
        self.directory = directory; self.providerID = providerID; self.receive = receive
        queue.async { [self] in _ = watch(directory); reload() }
    }

    func refresh() { queue.async { [self] in reload() } }
    func stop() {
        queue.async { [self] in
            stopped = true; work?.cancel(); work = nil
            sources.forEach { $0.cancel() }; sources.removeAll()
        }
    }

    private func watch(_ url: URL) -> Bool {
        let descriptor = open(url.path, O_EVTONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { return false }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor,
            eventMask: [.write, .rename, .delete, .revoke], queue: queue)
        source.setEventHandler { [weak self, weak source] in
            guard let self, !self.stopped else { return }
            if let flags = source?.data, !flags.intersection([.rename, .delete, .revoke]).isEmpty {
                self.sources.forEach { $0.cancel() }; self.sources.removeAll()
                self.watchingReports = false; _ = self.watch(self.directory)
            }
            self.reload()
        }
        source.setCancelHandler { close(descriptor) }
        sources.append(source); source.resume(); return true
    }

    private func reload() {
        guard !stopped else { return }
        if !watchingReports { watchingReports = watch(directory.appendingPathComponent("providers")) }
        work?.cancel()
        let next = DispatchWorkItem { [weak self] in
            guard let self, !self.stopped else { return }
            let result = Result { try AgentRelayStorage.report(providerID: self.providerID, directory: self.directory) }
            guard !self.stopped else { return }
            self.receive(result)
        }
        work = next
        queue.asyncAfter(deadline: .now() + .milliseconds(100), execute: next)
    }
}

/// Reusable native boundary for helpers publishing the normalized report.
/// The host reads no provider credentials or transcript directories.
@MainActor
final class RelayAgentProviderAdapter: AgentProviderAdapter {
    let descriptor: AgentProviderDescriptor
    private(set) var snapshot: AgentProviderSnapshot
    var onChange: (() -> Void)?
    private let preferences = UserDefaults(suiteName: ClaudePluginResources.identifier)
    private let messages = AgentMessageClient()
    private var observer: AgentRelayObserver?
    private var directory: URL?
    private var scopedURL: URL?
    private var panel: NSOpenPanel?
    private var report: AgentProviderReport?
    private var generation = UUID()
    private var isActive = true
    private var started = false
    private var usageRefreshTask: Task<Void, Never>?
    private var usageRefreshRequestID: String?
    private var usageRefreshAwaitingAcknowledgment = false
    private var bookmarkKey: String { "\(descriptor.id)RelayDirectoryBookmark" }

    init(descriptor: AgentProviderDescriptor) {
        self.descriptor = descriptor
        snapshot = AgentProviderSnapshot(descriptor: descriptor, connection: .disconnected,
            setupCommand: Self.setupCommand(descriptor.id))
    }

    private static func setupCommand(_ id: String) -> String? {
        ClaudePluginResources.helperURL.map {
            "'" + $0.path.replacingOccurrences(of: "'", with: "'\\''") + "' \(id)-install"
        }
    }

    func start() {
        guard isActive, !started else { return }; started = true
        #if DEBUG
        if let path = ProcessInfo.processInfo.environment["BN_\(descriptor.id.uppercased())_TEST_DIRECTORY"] {
            attach(URL(fileURLWithPath: path), scoped: false); return
        }
        // ABI fixtures must never fall through to a saved real provider.
        if ProcessInfo.processInfo.environment["BN_CLAUDE_TEST_DIRECTORY"] != nil { return }
        #endif
        guard let data = preferences?.data(forKey: bookmarkKey) else { return }
        do {
            var stale = false
            let url = try URL(resolvingBookmarkData: data, options: [.withSecurityScope, .withoutUI],
                              relativeTo: nil, bookmarkDataIsStale: &stale)
            guard url.startAccessingSecurityScopedResource() else { throw ClaudeStorageError.unsafePath }
            do {
                if stale { preferences?.set(try url.bookmarkData(options: .withSecurityScope,
                    includingResourceValuesForKeys: nil, relativeTo: nil), forKey: bookmarkKey) }
            } catch { url.stopAccessingSecurityScopedResource(); throw error }
            attach(url, scoped: true)
        } catch { fail("Folder access expired. Choose the relay folder again.") }
    }

    func connect() {
        guard isActive, panel == nil else { return }
        let picker = NSOpenPanel()
        picker.title = "Connect \(descriptor.title)"
        picker.message = "Choose the private folder printed by the BoringAgent relay setup command."
        picker.prompt = "Connect"; picker.canChooseDirectories = true; picker.canChooseFiles = false
        picker.canCreateDirectories = false; picker.allowsMultipleSelection = false; panel = picker
        picker.begin { [weak self, weak picker] response in
            guard let self, self.isActive else { return }; self.panel = nil
            guard response == .OK, let url = picker?.url else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            do {
                self.preferences?.set(try url.bookmarkData(options: .withSecurityScope,
                    includingResourceValuesForKeys: nil, relativeTo: nil), forKey: self.bookmarkKey)
                self.attach(url, scoped: scoped)
            } catch {
                if scoped { url.stopAccessingSecurityScopedResource() }
                self.fail("Could not save folder access. Choose the relay folder again.")
            }
        }
    }

    private func attach(_ url: URL, scoped: Bool) {
        detach(); directory = url; scopedURL = scoped ? url : nil
        snapshot.relayDirectory = url.path
        let current = generation
        observer = AgentRelayObserver(directory: url, providerID: descriptor.id) { [weak self] result in
            Task { @MainActor in
                guard let self, self.isActive, self.generation == current else { return }
                switch result {
                case .success(let report):
                    self.report = report
                    self.snapshot.connection = report?.connected == true ? .connected : .failed(report?.message ?? "Start the relay with the setup command.")
                    self.snapshot.sessions = report?.sessions ?? []
                    self.snapshot.usage = report?.usage
                    self.snapshot.usageAccount = report?.usageAccount
                    self.reconcileUsageRefresh()
                    self.snapshot.message = report?.message
                case .failure: self.fail("The relay report could not be read. Check the folder and reconnect."); return
                }
                self.onChange?()
            }
        }
    }

    private func detach() {
        generation = UUID(); observer?.stop(); observer = nil; messages.stop()
        usageRefreshTask?.cancel(); usageRefreshTask = nil
        usageRefreshRequestID = nil; usageRefreshAwaitingAcknowledgment = false
        snapshot.usageIsRefreshing = false; snapshot.usageRefreshError = nil
        scopedURL?.stopAccessingSecurityScopedResource(); scopedURL = nil; directory = nil; report = nil
    }

    private func fail(_ message: String) {
        snapshot.connection = .failed(message)
        snapshot.sessions = snapshot.sessions.map { value in var result = value; result.control = nil; return result }
        if snapshot.usageIsRefreshing {
            usageRefreshTask?.cancel(); usageRefreshTask = nil
            usageRefreshAwaitingAcknowledgment = false
            snapshot.usageIsRefreshing = false
            snapshot.usageRefreshError = "The usage relay is unavailable. Try refreshing after it restarts."
        }
        snapshot.message = message; onChange?()
    }

    func updateClock(_ now: Date) {
        guard isActive, let report, now.timeIntervalSince1970 - report.updatedAt > 120,
              snapshot.connection.isConnected else { return }
        fail("The relay stopped updating. Reconnect before sending messages.")
    }
    func refresh() { if isActive { observer?.refresh() } }
    func refreshUsage() {
        guard isActive, let directory, snapshot.usageAccount != nil, !snapshot.usageIsRefreshing else { return }
        let lifetime = generation
        let providerID = descriptor.id
        snapshot.usageIsRefreshing = true; snapshot.usageRefreshError = nil
        onChange?()
        usageRefreshTask = Task { [weak self] in
            guard !Task.isCancelled else { return }
            let worker = Task.detached(priority: .utility) { () -> String? in
                do {
                    try Task.checkCancellation()
                    return try AgentRelayStorage.requestUsageRefresh(providerID: providerID, directory: directory)
                } catch { return nil }
            }
            let requestID = await withTaskCancellationHandler {
                await worker.value
            } onCancel: { worker.cancel() }
            guard !Task.isCancelled, let self, self.isActive, self.generation == lifetime else { return }
            self.usageRefreshTask = nil
            guard let requestID else {
                self.snapshot.usageIsRefreshing = false
                self.snapshot.usageRefreshError = "Could not request subscription usage. Check the relay folder."
                self.onChange?(); return
            }
            self.usageRefreshRequestID = requestID
            self.usageRefreshAwaitingAcknowledgment = true
            self.reconcileUsageRefresh()
            self.observer?.refresh(); self.onChange?()
            DispatchQueue.main.asyncAfter(deadline: .now() + 35) { [weak self] in
                guard let self, self.isActive, self.generation == lifetime,
                      self.usageRefreshRequestID == requestID, self.usageRefreshAwaitingAcknowledgment else { return }
                self.usageRefreshAwaitingAcknowledgment = false
                self.snapshot.usageIsRefreshing = false
                self.snapshot.usageRefreshError = "The usage helper did not acknowledge the refresh. Check the relay and try again."
                self.onChange?()
            }
        }
    }

    private func reconcileUsageRefresh() {
        let account = snapshot.usageAccount
        if let requestID = usageRefreshRequestID, account?.refreshRequestID == requestID {
            usageRefreshAwaitingAcknowledgment = false
            snapshot.usageRefreshError = nil
        }
        snapshot.usageIsRefreshing = usageRefreshTask != nil || usageRefreshAwaitingAcknowledgment || account?.isRefreshing == true
    }

    func disconnect() {
        guard isActive else { return }; detach(); preferences?.removeObject(forKey: bookmarkKey)
        snapshot = AgentProviderSnapshot(descriptor: descriptor, connection: .disconnected,
            setupCommand: Self.setupCommand(descriptor.id)); onChange?()
    }
    func copySetupCommand() { copy(snapshot.setupCommand) }
    func copyUsageSignInCommand() -> Bool {
        guard isActive, let command = snapshot.usageAccount?.signInCommand else { return false }
        NSPasteboard.general.clearContents()
        return NSPasteboard.general.setString(command, forType: .string)
    }
    func copyResumeCommand(nativeID: String) {
        guard descriptor.id == "codex", UUID(uuidString: nativeID) != nil else { return }
        copy("codex resume \(nativeID)")
    }
    private func copy(_ value: String?) {
        guard isActive, let value else { return }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(value, forType: .string)
        snapshot.message = "Command copied."; onChange?()
    }
    func openSession(nativeID: String) { openOriginApp(nativeID: nativeID) }
    func openOriginApp(nativeID: String) {
        guard isActive, snapshot.sessions.contains(where: { $0.nativeID == nativeID }),
              let id = descriptor.applicationBundleID,
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return }
        let lifetime = generation
        NSWorkspace.shared.openApplication(at: url, configuration: .init()) { [weak self] _, error in
            Task { @MainActor in
                guard let self, self.isActive, self.generation == lifetime else { return }
                self.snapshot.message = error == nil ? "Opened \(self.descriptor.shortName). Select the session there." : "The original app could not be opened."
                self.onChange?()
            }
        }
    }
    func sendMessage(_ command: AgentMessageCommand,
                     completion: @escaping @MainActor (AgentMessageReceipt) -> Void) {
        guard isActive, let directory, snapshot.connection.isConnected,
              let session = snapshot.sessions.first(where: { $0.nativeID == command.sessionID }),
              let control = session.control, command.matches(control) else {
            completion(AgentMessageReceipt(id: command.id, sessionID: command.sessionID,
                state: .rejected, message: "The session changed. Refresh and review it before sending.")); return
        }
        messages.send(command, directory: directory, completion: completion)
    }
    func stop() {
        guard isActive else { return }; isActive = false; onChange = nil
        panel?.cancel(nil); panel = nil; detach()
    }
}
