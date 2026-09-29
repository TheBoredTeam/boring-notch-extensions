// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import SwiftUI

@MainActor
private final class ComposerTestPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
private final class ComposerFocusProbe: ObservableObject {
    @Published var isPresented = false
    @Published var text = ""
    let requestID = UUID()
    var acquired = 0
}

@MainActor
private struct ComposerFocusFixture: View {
    @ObservedObject var probe: ComposerFocusProbe
    @FocusState private var editorFocused: Bool

    var body: some View {
        TextEditor(text: $probe.text)
            .focused($editorFocused)
            .frame(width: 280, height: 100)
            .padding(12)
            .background {
                AgentComposerKeyboardFocus(requestID: probe.requestID) { _ in
                    probe.acquired += 1
                    editorFocused = true
                }
                .frame(width: 0, height: 0)
                .allowsHitTesting(false)
            }
    }
}

@MainActor
private struct ComposerFocusAnchor: View {
    @ObservedObject var probe: ComposerFocusProbe

    var body: some View {
        Button("Open test composer") { probe.isPresented = true }
            .popover(isPresented: $probe.isPresented, arrowEdge: .bottom) {
                ComposerFocusFixture(probe: probe)
            }
            .frame(width: 320, height: 80)
    }
}

/// GUI integration test. It opens disposable native windows, briefly takes
/// keyboard focus, and restores the previous application. No providers, user
/// sessions, preferences, relay files, or network services are involved.
@main
@MainActor
struct ComposerFocusTests {
    private static var assertions = 0

    private static func expect(_ condition: @autoclosure () -> Bool, _ description: String) throws {
        assertions += 1
        guard condition() else {
            throw NSError(domain: "ComposerFocusTests", code: assertions,
                          userInfo: [NSLocalizedDescriptionKey: description])
        }
    }

    private static func settle(_ condition: () -> Bool = { false }, seconds: TimeInterval = 0.15) {
        let deadline = Date(timeIntervalSinceNow: seconds)
        repeat {
            // Activation and key-window transitions arrive as AppKit events;
            // pumping CFRunLoop alone does not dispatch those application events.
            if let event = NSApp.nextEvent(matching: .any, until: Date(timeIntervalSinceNow: 0.01),
                                          inMode: .default, dequeue: true) {
                NSApp.sendEvent(event)
            }
            NSApp.updateWindows()
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.001))
        } while !condition() && Date() < deadline
    }

    private static func panel() -> ComposerTestPanel {
        let panel = ComposerTestPanel(contentRect: NSRect(x: 40, y: 40, width: 320, height: 80),
            styleMask: [.borderless, .nonactivatingPanel, .utilityWindow, .hudWindow],
            backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isFloatingPanel = true
        return panel
    }

    static func main() {
        do { try run() }
        catch {
            FileHandle.standardError.write(Data("Composer focus tests failed: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }

    private static func run() throws {
        let previous = NSWorkspace.shared.frontmostApplication
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.finishLaunching()
        app.activate(ignoringOtherApps: true)
        settle({ app.isActive }, seconds: 3)
        defer {
            app.deactivate()
            if previous?.processIdentifier != ProcessInfo.processInfo.processIdentifier {
                previous?.activate(options: [])
            }
        }
        try expect(app.isActive, "Native focus tests require an active graphical macOS session")
        try requestLifecycle()
        try nativePopoverKeyboardDelivery()
        print("Composer focus tests passed: \(assertions) assertions; native popover key window and real key-event delivery.")
    }

    private static func requestLifecycle() throws {
        let panel = panel()
        let root = NSView(frame: panel.contentLayoutRect)
        panel.contentView = root
        panel.orderFront(nil)
        defer { panel.contentView = nil; panel.close() }
        panel.resignKey()
        let previousKey = NSApp.keyWindow

        let passive = BoringAgentComposerKeyView(frame: .zero)
        root.addSubview(passive)
        var callbacks = 0
        passive.request(nil) { _ in callbacks += 1 }
        settle()
        try expect(!panel.isKeyWindow && NSApp.keyWindow === previousKey && callbacks == 0,
                   "A passive mount never takes keyboard focus")

        let detached = BoringAgentComposerKeyView(frame: .zero)
        root.addSubview(detached)
        detached.request(UUID()) { _ in callbacks += 1 }
        detached.removeFromSuperview()
        settle()
        try expect(!panel.isKeyWindow && callbacks == 0, "Detachment fences queued focus and callbacks")
        root.addSubview(detached)
        settle()
        try expect(!panel.isKeyWindow && callbacks == 0, "Reattachment cannot replay a consumed request")

        let cancelled = BoringAgentComposerKeyView(frame: .zero)
        root.addSubview(cancelled)
        cancelled.request(UUID()) { _ in callbacks += 1 }
        cancelled.cancel()
        settle()
        try expect(!panel.isKeyWindow && callbacks == 0, "Dismantling cancels pending focus")

        let hiddenPanel = self.panel()
        let hidden = BoringAgentComposerKeyView(frame: .zero)
        var hiddenCallbacks = 0
        hiddenPanel.contentView = hidden
        hidden.request(UUID()) { _ in hiddenCallbacks += 1 }
        settle()
        try expect(!hiddenPanel.isKeyWindow && hiddenCallbacks == 0, "Hidden content cannot take focus")
        hiddenPanel.orderFront(nil)
        hiddenPanel.update()
        settle({ hiddenPanel.isKeyWindow && hiddenCallbacks == 1 }, seconds: 2)
        try expect(hiddenPanel.isKeyWindow && hiddenCallbacks == 1,
                   "A request attached before visibility acquires key once its own window is ordered on screen")
        hidden.cancel()
        hiddenPanel.contentView = nil
        hiddenPanel.close()

        let requestID = UUID()
        passive.request(requestID) { id in
            if id == requestID { callbacks += 1 }
        }
        settle({ panel.isKeyWindow && callbacks == 1 }, seconds: 2)
        try expect(panel.isKeyWindow && NSApp.keyWindow === panel && callbacks == 1,
                   "One explicit request makes this attached nonactivating panel key")
        panel.resignKey()
        passive.request(requestID) { _ in callbacks += 1 }
        settle()
        try expect(!panel.isKeyWindow && callbacks == 1, "Ordinary redraws do not repeat key acquisition")
        passive.request(nil) { _ in callbacks += 1 }
        passive.request(requestID) { _ in callbacks += 1 }
        settle()
        try expect(!panel.isKeyWindow && callbacks == 1, "A withdrawn request cannot revive on a passive update")
        passive.cancel()
        detached.cancel()
    }

    private static func nativePopoverKeyboardDelivery() throws {
        let panel = panel()
        let probe = ComposerFocusProbe()
        panel.contentView = NSHostingView(rootView: ComposerFocusAnchor(probe: probe))
        panel.orderFront(nil)
        defer {
            probe.isPresented = false
            settle()
            panel.contentView = nil
            panel.close()
        }
        panel.resignKey()
        settle()
        try expect(!panel.isKeyWindow && probe.acquired == 0, "Mounting the source tab remains passive")
        probe.isPresented = true
        settle({ probe.acquired == 1 && NSApp.keyWindow?.firstResponder is NSTextView }, seconds: 3)
        let keyWindow = NSApp.keyWindow
        let popup = panel.childWindows?.first(where: \.isVisible)
        if keyWindow == nil || popup?.isKeyWindow != true || probe.acquired != 1 {
            print("Focus diagnostic: active=\(NSApp.isActive), presented=\(probe.isPresented), acquired=\(probe.acquired)")
            for window in NSApp.windows {
                print("Window \(type(of: window)): visible=\(window.isVisible), canKey=\(window.canBecomeKey), key=\(window.isKeyWindow), parent=\(window === panel), responder=\(String(describing: window.firstResponder.map { type(of: $0) }))")
            }
        }
        try expect(keyWindow != nil && popup?.isKeyWindow == true && probe.acquired == 1,
                   "The explicitly opened SwiftUI popover acquires native key ownership")
        // AppKit may report the parent as NSApp.keyWindow while the popover
        // also reports key and its editor serves as their shared first responder.
        let editor = keyWindow?.firstResponder as? NSTextView
        try expect(editor != nil && editor?.window === popup,
                   "The application's key window routes to the actual popover's text editor")
        guard let popup, let keyWindow else { return }
        guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: keyWindow.windowNumber,
            context: nil, characters: "x", charactersIgnoringModifiers: "x", isARepeat: false, keyCode: 7) else {
            throw NSError(domain: "ComposerFocusTests", code: 100, userInfo: [NSLocalizedDescriptionKey: "Could not create a native key event"])
        }
        NSApp.sendEvent(event)
        settle({ probe.text == "x" }, seconds: 1)
        try expect(probe.text == "x", "A native key event routes through the key popover to its editor")
        try expect(probe.isPresented && popup.isVisible && popup.isKeyWindow,
                   "Typing preserves the active composer and its key window")
    }
}
