// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import Combine
import Darwin
import Foundation

@objc(BNClaudeCodeBundleAnchor)
final class ClaudeBundleAnchor: NSObject {}

enum ClaudePluginResources {
    // Bundle.main is the host. An Objective-C anchor resolves the independent
    // loaded image's resource bundle without a development-machine path.
    static let identifier = "theboringteam.boringnotch.claude-code"
    static let bundle: Bundle? = {
        let candidate = Bundle(for: ClaudeBundleAnchor.self)
        if candidate.bundleIdentifier == identifier { return candidate }
        // dlopen-loaded bundles are not always registered by Foundation.
        // Resolve this image's Mach-O header, never the host's Bundle.main.
        var image = Dl_info()
        guard dladdr(#dsohandle, &image) != 0, let filename = image.dli_fname else { return nil }
        let executable = URL(fileURLWithPath: String(cString: filename))
        let root = executable.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        guard let loaded = Bundle(url: root), loaded.bundleIdentifier == identifier else { return nil }
        return loaded
    }()
    static let helperURL: URL? = {
        guard let url = bundle?.bundleURL.appendingPathComponent("Contents/Helpers/boring-claude-bridge"),
              FileManager.default.isExecutableFile(atPath: url.path) else { return nil }
        return url
    }()
    static let logoPNG: Data? = {
        guard let url = bundle?.url(forResource: "ClaudeLogo", withExtension: "png"),
              let data = try? Data(contentsOf: url), data.count <= 12_288 else { return nil }
        return data
    }()
    static let logoPNGBase64 = logoPNG?.base64EncodedString()
    @MainActor static let logo: NSImage? = {
        guard let data = logoPNG, let image = NSImage(data: data) else { return nil }
        image.isTemplate = true
        return image
    }()
    static var setupCommand: String? {
        helperURL.map { shellQuote($0.path) + " install" }
    }
    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

extension SessionPhase {
    var label: String {
        switch self {
        case .working: return "Working"
        case .needsInput: return "Needs you"
        case .idle: return "Ready"
        case .ended: return "Ended"
        }
    }
    var symbol: String {
        switch self {
        case .working: return "circle.dotted"
        case .needsInput: return "bubble.left.and.exclamationmark.bubble.right"
        case .idle: return "pause.circle"
        case .ended: return "checkmark.circle"
        }
    }
}

@MainActor
final class ClaudePluginState: ObservableObject {
    @Published private(set) var sessions: [ClaudeSession] = []
    @Published private(set) var visibleSessions: [ClaudeSession] = []
    @Published private(set) var attentionSession: ClaudeSession?
    @Published private(set) var attentionCount = 0
    @Published private(set) var currentAttentionCount = 0
    @Published private(set) var workingCount = 0
    @Published private(set) var isActive = true
    @Published private(set) var connection: Connection = .disconnected
    @Published private(set) var directory: URL?
    @Published private(set) var actionMessage: String?
    @Published private(set) var accountUsage: ClaudeAccountUsageRecord?
    @Published private(set) var accountUsageError: String?
    @Published private(set) var accountUsageReadError: String?
    @Published private(set) var accountUsageRequestPending = false
    @Published private(set) var lastReadAt: Date?
    @Published private(set) var now = Date()
    @Published var selectedID: String?
    @Published var query = "" { didSet { filterSessions() } }
    @Published var waitingOnly = false { didSet { filterSessions() } }
    @Published var compactSearch = false

    enum Connection: Equatable {
        case disconnected, connecting, connected, failed(String)
        var label: String {
            switch self {
            case .disconnected: return "Connect your sessions"
            case .connecting: return "Connecting…"
            case .connected: return "Relay connected"
            case .failed: return "Relay needs attention"
            }
        }
    }

    var activitiesChanged: (() -> Void)?
    private var byID: [String: ClaudeSession] = [:]
    private var searchText: [String: String] = [:]
    private var visibleIDs: Set<String> = []
    private let io = DispatchQueue(label: "theboringteam.claude.actions", qos: .utility)
    private var monitor: ClaudeDirectoryMonitor?
    private var generation = UUID()
    private var focusGeneration = UUID()
    private var focusChecks: [DispatchWorkItem] = []
    private var scopedURL: URL?
    private var clock: Timer?
    private var panel: NSOpenPanel?
    private let preferences = UserDefaults(suiteName: ClaudePluginResources.identifier)
    private var started = false
    private var usageRequestID: UUID?

    var selectedSession: ClaudeSession? {
        if let selectedID, let value = byID[selectedID], visibleIDs.contains(selectedID) {
            return value
        }
        return visibleSessions.first
    }
    var isConnected: Bool { connection == .connected }
    var resumeCommand: String? { selectedSession.map { "claude --resume \($0.id)" } }

    func start(managesClock: Bool = true) {
        guard isActive, !started else { return }
        started = true
        // One low-frequency shared clock labels stale snapshots. No per-row or
        // hidden-view timer, and no periodic file/network polling.
        if managesClock {
            clock = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.isActive else { return }
                    self.updateClock(Date())
                }
            }
        }
        #if DEBUG
        if let path = ProcessInfo.processInfo.environment["BN_CLAUDE_TEST_DIRECTORY"], !path.isEmpty {
            connect(URL(fileURLWithPath: path, isDirectory: true), securityScoped: false)
            return
        }
        #endif
        guard let data = preferences?.data(forKey: "relayDirectoryBookmark") else { return }
        do {
            var stale = false
            let url = try URL(resolvingBookmarkData: data, options: [.withSecurityScope, .withoutUI],
                              relativeTo: nil, bookmarkDataIsStale: &stale)
            guard url.startAccessingSecurityScopedResource() else {
                connection = .failed("Folder access expired. Choose your relay folder again.")
                return
            }
            // Refresh failure must release the acquired scope before returning.
            do {
                if stale {
                    let refreshed = try url.bookmarkData(options: .withSecurityScope,
                        includingResourceValuesForKeys: nil, relativeTo: nil)
                    preferences?.set(refreshed, forKey: "relayDirectoryBookmark")
                }
            } catch {
                url.stopAccessingSecurityScopedResource()
                throw error
            }
            connect(url, securityScoped: true)
        } catch {
            connection = .failed("Saved folder access is unavailable. Choose your relay folder again.")
        }
    }

    func chooseDirectory() {
        guard isActive, panel == nil else { return }
        let selection = NSOpenPanel()
        selection.title = "Connect Claude Code"
        selection.message = "Choose the private relay folder printed by boring-claude-bridge install."
        selection.prompt = "Connect"
        selection.canChooseDirectories = true
        selection.canChooseFiles = false
        selection.allowsMultipleSelection = false
        selection.canCreateDirectories = false
        panel = selection
        selection.begin { [weak self, weak selection] result in
            guard let self, self.isActive else { return }
            self.panel = nil
            guard result == .OK, let url = selection?.url else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            do {
                let data = try url.bookmarkData(options: .withSecurityScope,
                    includingResourceValuesForKeys: nil, relativeTo: nil)
                self.preferences?.set(data, forKey: "relayDirectoryBookmark")
                self.connect(url, securityScoped: scoped)
            } catch {
                if scoped { url.stopAccessingSecurityScopedResource() }
                self.connection = .failed("Could not save folder access. Please choose the relay folder again.")
            }
        }
    }

    private func connect(_ url: URL, securityScoped: Bool) {
        guard isActive else { return }
        disconnect(clearBookmark: false)
        directory = url
        if securityScoped { scopedURL = url }
        connection = .connecting
        let current = generation
        monitor = ClaudeDirectoryMonitor(directory: url, receiveUsage: { [weak self] result in
            DispatchQueue.main.async { [weak self] in
                guard let self, self.isActive, self.generation == current else { return }
                switch result {
                case .success(let record):
                    self.accountUsageReadError = nil
                    if record?.lastRequestID == self.usageRequestID?.uuidString, self.usageRequestID != nil {
                        self.accountUsageRequestPending = false
                        self.accountUsageError = nil
                    }
                    if record != self.accountUsage {
                        self.accountUsage = record
                    }
                case .failure:
                    self.accountUsageReadError = "Cannot read account usage. Check the relay folder or reconnect it."
                    self.accountUsageRequestPending = false
                }
            }
        }) { [weak self] result in
            DispatchQueue.main.async { [weak self] in
                guard let self, self.isActive, self.generation == current else { return }
                switch result {
                case .success(let sessions): self.apply(sessions)
                case .failure:
                    self.connection = .failed("Cannot read the relay folder. Check access or reconnect it.")
                    self.replaceSessions([])
                }
            }
        }
    }

    func disconnect(clearBookmark: Bool = true) {
        generation = UUID()
        cancelFocusFeedback()
        monitor?.stop()
        monitor = nil
        if let scopedURL { scopedURL.stopAccessingSecurityScopedResource() }
        scopedURL = nil
        directory = nil
        lastReadAt = nil
        connection = .disconnected
        actionMessage = nil
        accountUsage = nil
        accountUsageError = nil
        accountUsageReadError = nil
        accountUsageRequestPending = false
        usageRequestID = nil
        replaceSessions([])
        if clearBookmark { preferences?.removeObject(forKey: "relayDirectoryBookmark") }
    }

    func refresh() {
        guard isActive else { return }
        now = Date()
        refreshActivityEligibility()
        monitor?.refresh()
    }

    /// Only a sanitized command crosses into the separately running helper.
    /// The helper owns opt-in, Keychain access, HTTP, and account observations.
    func requestAccountUsage(_ operation: ClaudeAccountUsageOperation) {
        guard isActive, let directory, accountUsage != nil else { return }
        let current = generation
        let requestID = UUID()
        usageRequestID = requestID
        accountUsageRequestPending = true
        accountUsageError = nil
        let request = ClaudeAccountUsageRequest(id: requestID.uuidString, operation: operation,
                                               createdAt: Date().timeIntervalSince1970)
        io.async { [weak self] in
            let result = Result { try ClaudeStorage.requestAccountUsage(request, directory: directory) }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.isActive, self.generation == current, self.usageRequestID == requestID else { return }
                if case .failure = result {
                    self.accountUsageError = "Could not contact the account usage helper. Reconnect the relay folder."
                    self.accountUsageRequestPending = false
                }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
            guard let self, self.isActive, self.generation == current,
                  self.usageRequestID == requestID, self.accountUsageRequestPending else { return }
            self.accountUsageRequestPending = false
            self.accountUsageError = "The usage helper did not respond. Run the relay setup command again."
        }
    }

    /// A containing dashboard can provide its single shared clock without
    /// starting a second timer inside this provider's existing backend.
    func updateClock(_ date: Date) {
        guard isActive else { return }
        now = date
        refreshActivityEligibility()
    }

    private func apply(_ values: [ClaudeSession]) {
        connection = .connected
        lastReadAt = Date()
        now = Date()
        replaceSessions(values)
        ClaudeTelemetry.write("state.loaded", ["sessionCount": sessions.count,
            "visibleCount": visibleSessions.count, "attentionCount": attentionCount,
            "selectedID": selectedID ?? "", "selectedQuestionPresent": selectedSession?.question != nil])
    }

    private func replaceSessions(_ values: [ClaudeSession]) {
        sessions = values
        byID = Dictionary(values.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        searchText = Dictionary(values.map { session in
            (session.id, [session.project, session.directory, session.id, session.model ?? ""].joined(separator: " ").lowercased())
        }, uniquingKeysWith: { first, _ in first })
        attentionCount = values.reduce(0) { $0 + ($1.phase == .needsInput ? 1 : 0) }
        refreshActivityEligibility()
        filterSessions()
    }

    /// Hook state is a last report, not proof that a process still exists. A
    /// single clock marks old reports stale; questions remain in the tab until
    /// a resolving event arrives, but old reports stop claiming notch urgency.
    func isStale(_ session: ClaudeSession) -> Bool {
        session.phase != .ended && now.timeIntervalSince1970 - session.updatedAt > 600
    }

    func statusLabel(_ session: ClaudeSession) -> String {
        isStale(session) ? "Status stale" : session.phase.label
    }

    func statusDescription(_ session: ClaudeSession) -> String {
        if isStale(session) {
            let minutes = max(1, Int((now.timeIntervalSince1970 - session.updatedAt) / 60))
            let age = minutes < 60 ? "\(minutes)m" : "\(minutes / 60)h"
            return "Last seen \(age) ago. Open the session to check its status."
        }
        switch session.phase {
        case .working: return "Latest report: Claude is working"
        case .needsInput: return "Claude is waiting for your input"
        case .idle: return "Your session is ready"
        case .ended: return "This session has ended"
        }
    }

    private func refreshActivityEligibility() {
        let previous = currentAttentionCount
        currentAttentionCount = sessions.reduce(0) { $0 + ($1.phase == .needsInput && !isStale($1) ? 1 : 0) }
        workingCount = sessions.reduce(0) { $0 + ($1.phase == .working && !isStale($1) ? 1 : 0) }
        attentionSession = sessions.first { $0.phase == .needsInput && !isStale($0) }
        if previous != currentAttentionCount { activitiesChanged?() }
    }

    private func filterSessions() {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        visibleSessions = sessions.filter { session in
            (!waitingOnly || session.phase == .needsInput) &&
                (term.isEmpty || (searchText[session.id]?.contains(term) ?? false))
        }
        visibleIDs = Set(visibleSessions.map(\.id))
        if selectedID.map({ !visibleIDs.contains($0) }) ?? true {
            selectedID = visibleSessions.first?.id
        }
        ClaudeTelemetry.write("state.search", ["visibleCount": visibleSessions.count,
            "selectedID": selectedID ?? "", "selectedQuestionPresent": selectedSession?.question != nil])
    }

    func select(_ id: String) {
        guard isActive, byID[id] != nil else { return }
        cancelFocusFeedback()
        selectedID = id
        actionMessage = nil
    }

    func moveSelection(_ delta: Int) {
        guard isActive, !visibleSessions.isEmpty else { return }
        let index = visibleSessions.firstIndex { $0.id == selectedID } ?? 0
        let target = min(max(0, index + delta), visibleSessions.count - 1)
        select(visibleSessions[target].id)
    }

    func openSession(_ session: ClaudeSession) {
        guard isActive, byID[session.id] != nil else { return }
        cancelFocusFeedback()
        if let remote = session.origin.remoteSessionID,
           remote.range(of: "^session_[A-Za-z0-9_-]{1,128}$", options: .regularExpression) != nil,
           let url = URL(string: "https://claude.ai/code/\(remote)") {
            actionMessage = NSWorkspace.shared.open(url) ? "Opened Remote Control. Reply in your session." : "Could not open Remote Control. Copy the resume command below."
            return
        }
        guard let directory else { return }
        let current = generation
        let id = session.id
        let requestedAt = Date().timeIntervalSince1970
        let request = focusGeneration
        actionMessage = "Focus requested. The relay will bring your session forward."
        io.async { [weak self] in
            let result = Result { try ClaudeStorage.requestFocus(sessionID: id, directory: directory) }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.isActive, self.generation == current, self.focusGeneration == request else { return }
                if case .failure = result {
                    self.actionMessage = "Could not request focus. Open the app or copy the resume command."
                } else {
                    self.checkFocus(id: id, directory: directory, requestedAt: requestedAt,
                                    generation: current, request: request, delay: 1)
                    self.checkFocus(id: id, directory: directory, requestedAt: requestedAt,
                                    generation: current, request: request, delay: 5)
                }
            }
        }
    }

    private func cancelFocusFeedback() {
        focusGeneration = UUID()
        focusChecks.forEach { $0.cancel() }
        focusChecks.removeAll()
    }

    private func checkFocus(id: String, directory: URL, requestedAt: Double,
                            generation: UUID, request: UUID, delay: Double) {
        let work = DispatchWorkItem { [weak self] in
            let receipt = try? ClaudeStorage.focusReceipt(sessionID: id, directory: directory)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.isActive, self.generation == generation, self.focusGeneration == request else { return }
                guard let receipt, receipt.updatedAt >= requestedAt - 0.1 else {
                    if delay >= 5 {
                        self.actionMessage = "Relay did not confirm focus. Open the app or copy the resume command."
                    }
                    return
                }
                switch receipt.status {
                case "focused": self.actionMessage = "Opened your session. Reply in Claude."
                case "appOpened": self.actionMessage = "Opened the app. Choose your session there."
                default: self.actionMessage = ClaudeValidation.text(receipt.message, limit: 512)
                    ?? "Session unavailable. Open the app or copy the resume command."
                }
                self.focusChecks.forEach { $0.cancel() }
                self.focusChecks.removeAll()
            }
        }
        focusChecks.append(work)
        io.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// Explicit fallback, never an invented per-session desktop deep link.
    func openOriginApp(_ session: ClaudeSession) {
        guard isActive, byID[session.id] != nil else { return }
        cancelFocusFeedback()
        let current = generation
        let request = focusGeneration
        let allowed = ["com.anthropic.claudefordesktop", "com.apple.Terminal", "com.googlecode.iterm2",
                       "com.todesktop.230313mzl4w4u92", "com.microsoft.VSCode", "dev.warp.Warp-Stable", "com.mitchellh.ghostty"]
        guard let id = session.origin.appBundleID, allowed.contains(id),
              let application = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else {
            actionMessage = "Original app unavailable. Copy the resume command to continue in a terminal."
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: application, configuration: configuration) { [weak self] _, error in
            DispatchQueue.main.async { [weak self] in
                guard let self, self.isActive, self.generation == current, self.focusGeneration == request else { return }
                self.actionMessage = error == nil ? "Opened the app. Choose your session there." : "Could not open the original app. Copy the resume command."
            }
        }
    }

    func copy(_ value: String, message: String) {
        guard isActive else { return }
        cancelFocusFeedback()
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
        actionMessage = message
    }

    func copySetupCommand() {
        guard let command = ClaudePluginResources.setupCommand else {
            actionMessage = "The bundled relay is missing. Reinstall the complete BoringAgent extension package."
            return
        }
        copy(command, message: "Setup command copied. Run it in your terminal.")
    }

    func stop() {
        guard isActive else { return }
        isActive = false
        activitiesChanged = nil
        clock?.invalidate()
        clock = nil
        panel?.cancel(nil)
        panel = nil
        disconnect(clearBookmark: false)
    }
}

enum ClaudeTelemetry {
    static func write(_ event: String, _ fields: [String: Any] = [:]) {
        #if DEBUG
        guard let path = ProcessInfo.processInfo.environment["BN_CLAUDE_TEST_LOG"], !path.isEmpty else { return }
        var object = fields
        object["event"] = event
        object["time"] = Date().timeIntervalSince1970
        object["pid"] = ProcessInfo.processInfo.processIdentifier
        guard var data = try? JSONSerialization.data(withJSONObject: object, options: .sortedKeys) else { return }
        data.append(0x0a)
        // Test-only bounded events, no session text or identifiers are logged.
        let descriptor = open(path, O_WRONLY | O_CREAT | O_APPEND | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { return }
        data.withUnsafeBytes { buffer in
            if let base = buffer.baseAddress { _ = Darwin.write(descriptor, base, buffer.count) }
        }
        close(descriptor)
        #endif
    }
}
