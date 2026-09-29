// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import SwiftUI

/// The observer token is immutable and only removed through NotificationCenter's
/// thread-safe API. Its lifetime may end outside the view's main-actor isolation.
private final class AgentComposerObservation: @unchecked Sendable {
    private let token: NSObjectProtocol

    init(_ token: NSObjectProtocol) { self.token = token }

    deinit { NotificationCenter.default.removeObserver(token) }
}

/// An explicit composer action may take keyboard focus; mounting a tab may not.
/// Each request is consumed once and applies only to this view's attached window.
@MainActor
struct AgentComposerKeyboardFocus: NSViewRepresentable {
    let requestID: UUID?
    let didAcquireKey: (UUID) -> Void

    func makeNSView(context: Context) -> BoringAgentComposerKeyView {
        BoringAgentComposerKeyView(frame: .zero)
    }

    func updateNSView(_ view: BoringAgentComposerKeyView, context: Context) {
        view.request(requestID, didAcquireKey: didAcquireKey)
    }

    static func dismantleNSView(_ view: BoringAgentComposerKeyView, coordinator: ()) {
        view.cancel()
    }
}

@MainActor
@objc(BNBoringAgentComposerKeyView)
final class BoringAgentComposerKeyView: NSView {
    private var requestedID: UUID?
    private var attemptedID: UUID?
    private var expiresAt: ContinuousClock.Instant?
    private var didAcquireKey: ((UUID) -> Void)?
    private var task: Task<Void, Never>?
    private var visibilityObservers: [AgentComposerObservation] = []

    func request(_ id: UUID?, didAcquireKey: @escaping (UUID) -> Void) {
        if requestedID != id {
            task?.cancel()
            task = nil
            removeVisibilityObservers()
            requestedID = id
            expiresAt = id == nil ? nil : .now.advanced(by: .seconds(3))
        }
        self.didAcquireKey = didAcquireKey
        acquireKeyIfRequested()
    }

    func cancel() {
        task?.cancel()
        task = nil
        removeVisibilityObservers()
        attemptedID = requestedID
        requestedID = nil
        expiresAt = nil
        didAcquireKey = nil
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if window !== newWindow {
            task?.cancel()
            task = nil
            removeVisibilityObservers()
            if window != nil { attemptedID = requestedID }
        }
        super.viewWillMove(toWindow: newWindow)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        acquireKeyIfRequested()
    }

    private func acquireKeyIfRequested() {
        guard task == nil, let id = requestedID, id != attemptedID, let window else { return }
        guard let expiresAt, expiresAt > .now else {
            attemptedID = id
            removeVisibilityObservers()
            return
        }
        task = Task { @MainActor [weak self, weak window] in
            // AppKit attaches popover content before ordering its window on
            // screen. Continue after that attachment transaction completes.
            await Task.yield()
            guard !Task.isCancelled, let self, let window,
                  self.window === window, self.requestedID == id else { return }
            self.task = nil
            guard NSApp.isActive, let expiresAt = self.expiresAt, expiresAt > .now else {
                self.attemptedID = id
                self.removeVisibilityObservers()
                return
            }
            guard window.isVisible else {
                self.observeVisibility(of: window)
                return
            }
            self.attemptedID = id
            self.removeVisibilityObservers()
            window.makeKey()
            guard window.isKeyWindow else { return }
            self.didAcquireKey?(id)
        }
    }

    private func observeVisibility(of window: NSWindow) {
        guard visibilityObservers.isEmpty else { return }
        for name in [NSWindow.didUpdateNotification, NSWindow.didChangeOcclusionStateNotification] {
            visibilityObservers.append(AgentComposerObservation(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) {
                [weak self, weak window] _ in
                MainActor.assumeIsolated {
                    guard let self, let window, self.window === window else { return }
                    self.acquireKeyIfRequested()
                }
            }))
        }
    }

    private func removeVisibilityObservers() {
        visibilityObservers.removeAll()
    }

    deinit {
        task?.cancel()
    }
}
