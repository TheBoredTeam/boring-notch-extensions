// SPDX-License-Identifier: GPL-3.0-only
import AppKit

@MainActor
private final class PickerTestPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Offscreen AppKit integration checks. This executable never activates its
/// application or requests a key window and never touches real providers.
@main
@MainActor
struct SessionPickerTests {
    private static var assertions = 0

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        assertions += 1
        guard condition() else {
            throw NSError(domain: "SessionPickerTests", code: assertions,
                          userInfo: [NSLocalizedDescriptionKey: message])
        }
    }

    private static func settle(_ view: NSView) {
        view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        view.layoutSubtreeIfNeeded()
    }

    static func main() {
        do {
            _ = NSApplication.shared
            try nativePicker()
            print("Session picker tests passed: \(assertions) assertions; 1,000 rows, native reuse/search/keyboard, 50–132pt regions, no application activation.")
        } catch {
            FileHandle.standardError.write(Data("Session picker tests failed: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }

    private static func nativePicker() throws {
        let panel = PickerTestPanel(contentRect: NSRect(x: -10_000, y: -10_000, width: 324, height: 92),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = true
        let picker = BoringAgentSessionPickerView(frame: panel.contentLayoutRect)
        panel.contentView = picker
        panel.orderFront(nil)
        defer { picker.stop(); panel.contentView = nil; panel.close() }
        let previousKey = NSApp.keyWindow
        let rows = (0..<1_000).map { index in
            AgentSessionPickerRow(id: "session-\(index)", title: "Project \(index)",
                providerID: index.isMultiple(of: 2) ? "claude" : "codex",
                status: index.isMultiple(of: 5) ? .waiting : .working,
                accessibilityLabel: "Project \(index), test provider, working")
        }
        var queries: [String] = []
        var filters: [Bool] = []
        var selections: [String] = []
        var activations = 0
        var done = 0
        func update(_ visible: [AgentSessionPickerRow] = rows, selected: String? = "session-500",
                    query: String = "", waiting: Bool = false, compact: Bool = true, enabled: Bool = true) {
            picker.update(rows: visible, icons: [:], selectedID: selected, query: query,
                waitingOnly: waiting, waitingCount: 200, compact: compact, isEnabled: enabled,
                queryChanged: { queries.append($0) }, waitingChanged: { filters.append($0) },
                selectionChanged: { selections.append($0) }, activateSelection: { activations += 1 },
                done: { done += 1 })
            settle(picker)
        }
        update()
        try expect(picker.table.numberOfRows == 1_000, "All 1,000 session identities are represented")
        try expect(picker.table.selectedRow == 500 && selections.isEmpty,
                   "Programmatic selection preserves exact identity without selecting a provider again")
        try expect(!panel.isKeyWindow && NSApp.keyWindow === previousKey,
                   "Picker mount and reload never acquire key focus")
        var availableRows: [Int] = []
        picker.table.enumerateAvailableRowViews { _, row in availableRows.append(row) }
        try expect(!availableRows.isEmpty && availableRows.count < 20,
                   "Native table realizes only visible/reusable rows, not 1,000 views")
        try expect(picker.table.rowView(atRow: 999, makeIfNecessary: false) == nil,
                   "A distant session has no eager row view")
        try expect(picker.table.intercellSpacing.height == 0 && picker.table.rowHeight == 22,
                   "Native rows have a consistent 22pt pitch")
        try expect(picker.scrollView.frame.height == 66,
                   "A 92pt content region shows exactly three whole compact results")
        try expect(picker.searchField.frame.width >= 150 && !picker.waitingButton.isHidden && !picker.doneButton.isHidden,
                   "Compact native search, filter, and Done remain usable in one toolbar")

        for height: CGFloat in [50, 90, 92, 132] {
            panel.setContentSize(NSSize(width: 324, height: height))
            picker.frame.size = NSSize(width: 324, height: height)
            picker.needsLayout = true
            settle(picker)
            try expect(picker.scrollView.frame.height >= 22 && picker.scrollView.frame.maxY <= height,
                       "Each supported short region contains a complete scrollable row within its bounds")
            try expect(picker.scrollView.frame.height.truncatingRemainder(dividingBy: 22) == 0,
                       "Viewport boundaries start on whole row pitches")
            try expect(picker.searchField.frame.maxX <= picker.waitingButton.frame.minX &&
                       picker.waitingButton.frame.maxX <= picker.doneButton.frame.minX,
                       "Toolbar controls never overlap")
        }
        update(selected: "session-999")
        try expect(picker.table.selectedRow == 999 &&
                   picker.table.visibleRect.contains(picker.table.rect(ofRow: 999)),
                   "The final one of 1,000 sessions scrolls fully into view")
        let visibleBeforeUpdate = picker.scrollView.contentView.bounds.origin
        update(selected: "session-999")
        try expect(picker.scrollView.contentView.bounds.origin == visibleBeforeUpdate && selections.isEmpty,
                   "Unchanged live snapshots preserve scroll and do not emit selection callbacks")
        picker.tableViewSelectionDidChange(Notification(name: NSTableView.selectionDidChangeNotification, object: picker.table))
        try expect(selections.isEmpty, "A delayed programmatic selection notification cannot reselect the provider")
        update(Array(rows.suffix(500)), selected: "session-999")
        try expect(picker.table.selectedRow == 499 && picker.table.visibleRect.contains(picker.table.rect(ofRow: 499)),
                   "Filtering keeps an unchanged selected identity visible after its row index moves")

        update(selected: "session-10")
        picker.table.selectRowIndexes(IndexSet(integer: 11), byExtendingSelection: false)
        try expect(selections.last == "session-11" && activations == 0,
                   "Native selection browses a stable session without dismissing compact search")
        if let down = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: panel.windowNumber, context: nil, characters: "\u{f701}", charactersIgnoringModifiers: "\u{f701}",
            isARepeat: false, keyCode: 125) {
            panel.makeFirstResponder(picker.table)
            picker.table.keyDown(with: down)
        }
        try expect(picker.table.selectedRow == 12 && selections.last == "session-12" && activations == 0,
                   "Native Down-arrow navigation browses another row without confirming or closing")
        if let enter = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: panel.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r",
            isARepeat: false, keyCode: 36) {
            picker.table.keyDown(with: enter)
        }
        try expect(activations == 1, "Return explicitly confirms the selected row")
        picker.doneButton.performClick(nil)
        try expect(done == 1, "Native Done explicitly closes compact search")
        picker.waitingButton.performClick(nil)
        try expect(filters.last == true, "The native Waiting checkbox emits its on state")

        try expect(panel.makeFirstResponder(picker.searchField), "Native search can enter the field-editor responder chain")
        let editor = picker.searchField.currentEditor() as? NSTextView
        try expect(editor != nil, "NSSearchField uses AppKit's shared text editor")
        editor?.insertText("needle", replacementRange: NSRange(location: 0, length: 0))
        settle(picker)
        try expect(queries.last == "needle", "Native text editing emits live query changes")
        let queryCount = queries.count
        update(Array(rows.suffix(1)), selected: "session-999", query: "needle")
        try expect(queries.count == queryCount && picker.table.numberOfRows == 1,
                   "A filtered update does not replace the search editor or echo a query change")
        if let editor {
            _ = picker.control(picker.searchField, textView: editor,
                doCommandBy: #selector(NSResponder.moveDown(_:)))
            if panel.firstResponder !== picker.table {
                print("Picker navigation: responder=\(String(describing: panel.firstResponder.map { type(of: $0) })), accepts=\(picker.table.acceptsFirstResponder), tableAttached=\(picker.table.window === panel), enabled=\(picker.table.isEnabled)")
            }
            try expect(panel.firstResponder === picker.table, "Down from search reaches native result navigation")
        }
        update([], selected: nil, query: "missing")
        try expect(picker.table.numberOfRows == 0 && picker.table.selectedRow == -1,
                   "No matches has no stale row or selection")
        let activationsBeforeEmpty = activations
        if let editor {
            _ = picker.control(picker.searchField, textView: editor,
                doCommandBy: #selector(NSResponder.insertNewline(_:)))
        }
        try expect(activations == activationsBeforeEmpty, "Return cannot activate a disappeared result")

        for width: CGFloat in [155, 205] {
            for height: CGFloat in [92, 132] {
                panel.setContentSize(NSSize(width: width, height: height))
                picker.frame.size = NSSize(width: width, height: height)
                update(rows, selected: "session-0", compact: false)
                try expect(picker.searchField.frame.width == width && picker.waitingButton.frame.minY >= 22,
                           "Regular sidebars give search its full width and use a native filter row")
                try expect(picker.doneButton.isHidden && picker.scrollView.frame.height >= 22,
                           "Regular sidebars preserve results without an unnecessary Done button")
                if height == 92 {
                    try expect(picker.scrollView.frame.height == 44 &&
                               picker.table.visibleRect.contains(picker.table.rect(ofRow: 1)),
                               "A 92pt regular sidebar displays two complete results at both supported widths")
                }
            }
        }
        panel.setContentSize(NSSize(width: 155, height: 50))
        picker.frame.size = NSSize(width: 155, height: 50)
        update(rows, selected: "session-0", compact: false)
        try expect(picker.waitingButton.isHidden && picker.searchField.searchMenuTemplate != nil && picker.scrollView.frame.height == 22,
                   "A very short narrow sidebar keeps its filter in the native search menu and one full result")
        try expect(panel.makeFirstResponder(picker.searchField), "The narrow search field remains editable")
        let narrowEditor = picker.searchField.currentEditor() as? NSTextView
        if let narrowEditor {
            _ = picker.control(picker.searchField, textView: narrowEditor,
                doCommandBy: #selector(NSResponder.moveDown(_:)))
        }
        try expect(narrowEditor != nil && panel.firstResponder === picker.table && picker.table.selectedRow == 0,
                   "Search-to-Down reaches the visible result in a 155 by 50pt region")
        let narrowActivationCount = activations
        if let enter = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: panel.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r",
            isARepeat: false, keyCode: 36) {
            picker.table.keyDown(with: enter)
        }
        try expect(activations == narrowActivationCount + 1,
                   "Return confirms the narrow result after Down from search")
        try expect(!panel.isKeyWindow && NSApp.keyWindow === previousKey,
                   "Programmatic field editing and table navigation never activate the window")
        update(rows, selected: "session-0", query: "unchanged", compact: false, enabled: false)
        let callbacksBeforeDisable = (queries.count, done, activations)
        if let narrowEditor {
            let handled = picker.control(picker.searchField, textView: narrowEditor,
                doCommandBy: #selector(NSResponder.cancelOperation(_:)))
            try expect(!handled, "Disabled search declines keyboard actions")
        }
        try expect(queries.count == callbacksBeforeDisable.0 && done == callbacksBeforeDisable.1 && activations == callbacksBeforeDisable.2,
                   "Disabled controls cannot clear the query, confirm, or dismiss")
        picker.stop()
        let oldDone = done
        picker.doneButton.performClick(nil)
        try expect(done == oldDone, "A dismantled picker cannot call the host model")
    }
}
