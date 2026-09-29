// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import SwiftUI

struct AgentSessionPickerRow: Equatable {
    enum Status: Equatable { case working, waiting, inactive, stale }
    let id: String
    let title: String
    let providerID: String
    let status: Status
    let accessibilityLabel: String
}

struct AgentSessionPickerIcon {
    let image: NSImage
    let isTemplate: Bool
}

/// The picker uses native search, filtering, selection, and scrolling controls.
/// AppKit realizes only visible table cells; session data never creates a view
/// until its row is on screen. Updating or mounting never requests key status.
@MainActor
struct AgentSessionPicker: NSViewRepresentable {
    let rows: [AgentSessionPickerRow]
    let icons: [String: AgentSessionPickerIcon]
    let selectedID: String?
    let query: String
    let waitingOnly: Bool
    let waitingCount: Int
    let compact: Bool
    let isEnabled: Bool
    let queryChanged: (String) -> Void
    let waitingChanged: (Bool) -> Void
    let selectionChanged: (String) -> Void
    let activateSelection: () -> Void
    let done: () -> Void

    func makeNSView(context: Context) -> BoringAgentSessionPickerView {
        BoringAgentSessionPickerView(frame: .zero)
    }

    func updateNSView(_ view: BoringAgentSessionPickerView, context: Context) {
        view.update(rows: rows, icons: icons, selectedID: selectedID, query: query,
            waitingOnly: waitingOnly, waitingCount: waitingCount, compact: compact, isEnabled: isEnabled,
            queryChanged: queryChanged, waitingChanged: waitingChanged,
            selectionChanged: selectionChanged, activateSelection: activateSelection, done: done)
    }

    static func dismantleNSView(_ view: BoringAgentSessionPickerView, coordinator: ()) {
        view.stop()
    }
}

@MainActor
@objc(BNBoringAgentSessionTable)
final class BoringAgentSessionTable: NSTableView {
    var activateSelection: (() -> Void)?
    var cancelSelection: (() -> Void)?

    // A result list accepts keyboard navigation after the user clicks it or
    // moves down from search. Eligibility itself never changes window focus.
    override var acceptsFirstResponder: Bool { isEnabled }
    override var needsPanelToBecomeKey: Bool { isEnabled }

    override func keyDown(with event: NSEvent) {
        guard isEnabled else { return }
        switch event.keyCode {
        case 36, 76: activateSelection?()
        case 53: cancelSelection?()
        default: super.keyDown(with: event)
        }
    }
}

@MainActor
@objc(BNBoringAgentSessionCell)
private final class BoringAgentSessionCell: NSTableCellView {
    private let statusImage = NSImageView()
    private let providerImage = NSImageView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.lineBreakMode = .byTruncatingMiddle
        label.maximumNumberOfLines = 1
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        textField = label
        statusImage.image = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: nil)
        statusImage.imageScaling = .scaleProportionallyDown
        providerImage.imageScaling = .scaleProportionallyDown
        for view in [statusImage, label, providerImage] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            statusImage.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            statusImage.centerYAnchor.constraint(equalTo: centerYAnchor),
            statusImage.widthAnchor.constraint(equalToConstant: 5),
            statusImage.heightAnchor.constraint(equalToConstant: 5),
            label.leadingAnchor.constraint(equalTo: statusImage.trailingAnchor, constant: 6),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.trailingAnchor.constraint(equalTo: providerImage.leadingAnchor, constant: -6),
            providerImage.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            providerImage.centerYAnchor.constraint(equalTo: centerYAnchor),
            providerImage.widthAnchor.constraint(equalToConstant: 12),
            providerImage.heightAnchor.constraint(equalToConstant: 12)
        ])
    }

    required init?(coder: NSCoder) { nil }

    func configure(_ row: AgentSessionPickerRow, icon: AgentSessionPickerIcon?) {
        textField?.stringValue = row.title
        switch row.status {
        case .working: statusImage.contentTintColor = .systemGreen
        case .waiting: statusImage.contentTintColor = .systemOrange
        case .inactive, .stale: statusImage.contentTintColor = .tertiaryLabelColor
        }
        providerImage.image = icon?.image
        providerImage.contentTintColor = icon?.isTemplate == true ? .secondaryLabelColor : nil
        toolTip = row.accessibilityLabel
        setAccessibilityLabel(row.accessibilityLabel)
        setAccessibilityIdentifier("boring-agent-session-\(row.id)")
    }
}

@MainActor
@objc(BNBoringAgentSessionPickerView)
final class BoringAgentSessionPickerView: NSView, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    static let rowHeight: CGFloat = 22
    let searchField = NSSearchField()
    let table = BoringAgentSessionTable()
    let scrollView = NSScrollView()
    let waitingButton = NSButton(checkboxWithTitle: "Waiting", target: nil, action: nil)
    let doneButton = NSButton(title: "Done", target: nil, action: nil)
    private let countLabel = NSTextField(labelWithString: "")
    private let emptyLabel = NSTextField(labelWithString: "No matching sessions")
    private let filterMenu = NSMenu(title: "Session filters")
    private let waitingMenuItem = NSMenuItem(title: "Waiting for input", action: nil, keyEquivalent: "")
    private var rows: [AgentSessionPickerRow] = []
    private var icons: [String: AgentSessionPickerIcon] = [:]
    private var selectedID: String?
    private var compact = false
    private var isStopped = false
    private var isUpdating = false
    private var pendingScrollToSelection = false
    private var queryChanged: ((String) -> Void)?
    private var waitingChanged: ((Bool) -> Void)?
    private var selectionChanged: ((String) -> Void)?
    private var activateSelection: (() -> Void)?
    private var done: (() -> Void)?

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
        searchField.controlSize = .small
        searchField.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        searchField.placeholderString = "Search sessions"
        searchField.sendsSearchStringImmediately = true
        searchField.sendsWholeSearchString = false
        searchField.delegate = self
        searchField.setAccessibilityLabel("Search agent sessions")
        searchField.setAccessibilityIdentifier("boring-agent-session-search")
        waitingButton.controlSize = .small
        waitingButton.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        waitingButton.target = self
        waitingButton.action = #selector(toggleWaiting(_:))
        waitingButton.setAccessibilityIdentifier("boring-agent-waiting-filter")
        doneButton.controlSize = .small
        doneButton.bezelStyle = .rounded
        doneButton.target = self
        doneButton.action = #selector(finishPicking(_:))
        doneButton.setAccessibilityIdentifier("boring-agent-close-search")
        doneButton.toolTip = "Close session search"
        countLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        countLabel.textColor = .secondaryLabelColor
        countLabel.lineBreakMode = .byTruncatingTail
        emptyLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.alignment = .center
        emptyLabel.lineBreakMode = .byTruncatingTail
        waitingMenuItem.target = self
        waitingMenuItem.action = #selector(toggleWaiting(_:))
        filterMenu.addItem(waitingMenuItem)

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("session"))
        column.minWidth = 0
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.style = .plain
        table.rowHeight = Self.rowHeight
        table.intercellSpacing = .zero
        table.usesAutomaticRowHeights = false
        table.allowsMultipleSelection = false
        table.allowsEmptySelection = true
        table.allowsTypeSelect = true
        table.backgroundColor = .clear
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.delegate = self
        table.dataSource = self
        table.target = self
        table.action = #selector(rowClicked(_:))
        table.activateSelection = { [weak self] in self?.activateCurrentSelection() }
        table.cancelSelection = { [weak self] in self?.cancelPicking() }
        table.setAccessibilityIdentifier("boring-agent-session-list")
        scrollView.documentView = table
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.contentView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        scrollView.verticalScrollElasticity = .none
        scrollView.horizontalScrollElasticity = .none
        for view in [searchField, waitingButton, doneButton, countLabel, scrollView, emptyLabel] { addSubview(view) }
    }

    required init?(coder: NSCoder) { nil }

    func update(rows: [AgentSessionPickerRow], icons: [String: AgentSessionPickerIcon], selectedID: String?,
                query: String, waitingOnly: Bool, waitingCount: Int, compact: Bool, isEnabled: Bool,
                queryChanged: @escaping (String) -> Void, waitingChanged: @escaping (Bool) -> Void,
                selectionChanged: @escaping (String) -> Void, activateSelection: @escaping () -> Void,
                done: @escaping () -> Void) {
        guard !isStopped else { return }
        isUpdating = true
        defer { isUpdating = false }
        self.queryChanged = queryChanged
        self.waitingChanged = waitingChanged
        self.selectionChanged = selectionChanged
        self.activateSelection = activateSelection
        self.done = done
        self.compact = compact
        self.icons = icons
        let selectionMoved = self.selectedID != selectedID
        let previousSelectedRow = self.selectedID.flatMap { id in self.rows.firstIndex { $0.id == id } }
        self.selectedID = selectedID
        if searchField.stringValue != query { searchField.stringValue = query }
        waitingButton.state = waitingOnly ? .on : .off
        waitingMenuItem.state = waitingButton.state
        waitingButton.toolTip = "Show only sessions waiting for input (\(waitingCount))"
        waitingButton.setAccessibilityLabel("Waiting for input, \(waitingCount) sessions")
        countLabel.stringValue = "\(rows.count) \(rows.count == 1 ? "session" : "sessions")"
        table.setAccessibilityLabel("\(countLabel.stringValue). Use arrow keys to browse and Return to choose.")
        searchField.setAccessibilityHelp(countLabel.stringValue)
        for control in [searchField, waitingButton, doneButton, table] { control.isEnabled = isEnabled }
        waitingMenuItem.isEnabled = isEnabled

        let rowsChanged = self.rows != rows
        if rowsChanged {
            self.rows = rows
            table.reloadData()
        }
        let selectedRow = selectedID.flatMap { id in rows.firstIndex { $0.id == id } }
        if let selectedRow {
            if table.selectedRow != selectedRow { table.selectRowIndexes(IndexSet(integer: selectedRow), byExtendingSelection: false) }
        } else if table.selectedRow != -1 {
            table.deselectAll(nil)
        }
        if selectionMoved || (rowsChanged && previousSelectedRow != selectedRow) { pendingScrollToSelection = true }
        // Provider artwork can change without changing any session descriptor.
        // Refresh only realized cells; hidden rows remain unallocated.
        table.enumerateAvailableRowViews { [self] _, row in
            guard rows.indices.contains(row),
                  let cell = table.view(atColumn: 0, row: row, makeIfNecessary: false) as? BoringAgentSessionCell else { return }
            cell.configure(rows[row], icon: icons[rows[row].providerID])
        }
        emptyLabel.isHidden = !rows.isEmpty
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let width = max(0, bounds.width)
        let height = max(0, bounds.height)
        let controlHeight: CGFloat = 22
        let filterHeight: CGFloat = 18
        let gap: CGFloat = 4
        // Compact has enough width for one toolbar. Narrow regular sidebars
        // use a second filter row; very short sidebars expose it in the native
        // search menu so at least one complete result remains reachable.
        let secondHeader = !compact && height >= 74
        let menuFilter = !compact && !secondHeader
        waitingButton.isHidden = menuFilter
        doneButton.isHidden = !compact
        countLabel.isHidden = !secondHeader
        searchField.searchMenuTemplate = menuFilter ? filterMenu : nil
        if compact {
            let doneWidth: CGFloat = 44
            let waitingWidth: CGFloat = 70
            doneButton.frame = NSRect(x: max(0, width - doneWidth), y: 0, width: doneWidth, height: controlHeight)
            waitingButton.frame = NSRect(x: max(0, width - doneWidth - gap - waitingWidth), y: 0,
                                         width: waitingWidth, height: controlHeight)
            searchField.frame = NSRect(x: 0, y: 0, width: max(0, width - doneWidth - waitingWidth - gap * 2), height: controlHeight)
        } else {
            searchField.frame = NSRect(x: 0, y: 0, width: width, height: controlHeight)
            if secondHeader {
                waitingButton.frame = NSRect(x: 0, y: controlHeight + gap, width: 75, height: filterHeight)
                countLabel.frame = NSRect(x: 81, y: controlHeight + gap + (filterHeight - 16) / 2,
                                         width: max(0, width - 81), height: 16)
            }
        }
        searchField.nextKeyView = menuFilter ? table : waitingButton
        waitingButton.nextKeyView = compact ? doneButton : table
        doneButton.nextKeyView = table
        table.nextKeyView = searchField
        let listTop = (secondHeader ? controlHeight + filterHeight + gap : controlHeight) + gap
        let viewportHeight = floor(max(0, height - listTop) / Self.rowHeight) * Self.rowHeight
        scrollView.frame = NSRect(x: 0, y: listTop, width: width, height: viewportHeight)
        scrollView.tile()
        table.frame.size.width = max(0, scrollView.contentSize.width)
        table.tableColumns.first?.width = table.frame.width
        emptyLabel.frame = NSRect(x: 4, y: listTop, width: max(0, width - 8), height: min(Self.rowHeight, viewportHeight))
        if pendingScrollToSelection, table.selectedRow >= 0, viewportHeight > 0 {
            table.scrollRowToVisible(table.selectedRow)
            pendingScrollToSelection = false
        }
    }

    func stop() {
        isStopped = true
        for control in [searchField, waitingButton, doneButton, table] { control.isEnabled = false }
        queryChanged = nil
        waitingChanged = nil
        selectionChanged = nil
        activateSelection = nil
        done = nil
        searchField.delegate = nil
        table.delegate = nil
        table.dataSource = nil
        table.activateSelection = nil
        table.cancelSelection = nil
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard rows.indices.contains(row) else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("agent-session")
        let cell = (tableView.makeView(withIdentifier: identifier, owner: nil) as? BoringAgentSessionCell)
            ?? BoringAgentSessionCell(frame: .zero)
        cell.identifier = identifier
        cell.configure(rows[row], icon: icons[rows[row].providerID])
        return cell
    }

    func tableView(_ tableView: NSTableView, typeSelectStringFor tableColumn: NSTableColumn?, row: Int) -> String? {
        rows.indices.contains(row) ? rows[row].title : nil
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !isUpdating, table.isEnabled, rows.indices.contains(table.selectedRow) else { return }
        let id = rows[table.selectedRow].id
        guard id != selectedID else { return }
        selectedID = id
        selectionChanged?(id)
    }

    func controlTextDidChange(_ notification: Notification) {
        guard !isUpdating, searchField.isEnabled else { return }
        queryChanged?(searchField.stringValue)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard !isStopped, searchField.isEnabled, table.isEnabled else { return false }
        if commandSelector == #selector(NSResponder.moveDown(_:)) {
            guard !rows.isEmpty else { return true }
            window?.makeFirstResponder(table)
            if table.selectedRow < 0 { table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false) }
            table.scrollRowToVisible(table.selectedRow)
            return true
        }
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            activateCurrentSelection()
            return true
        }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            if !searchField.stringValue.isEmpty {
                searchField.stringValue = ""
                queryChanged?("")
            } else { cancelPicking() }
            return true
        }
        return false
    }

    @objc private func toggleWaiting(_ sender: Any?) {
        guard waitingButton.isEnabled else { return }
        let enabled = sender is NSMenuItem ? waitingButton.state != .on : waitingButton.state == .on
        waitingChanged?(enabled)
    }

    @objc private func finishPicking(_ sender: Any?) { if doneButton.isEnabled { done?() } }

    @objc private func rowClicked(_ sender: Any?) {
        guard table.clickedRow >= 0 else { return }
        activateCurrentSelection()
    }

    private func activateCurrentSelection() {
        guard table.isEnabled, rows.indices.contains(table.selectedRow) else { return }
        activateSelection?()
    }

    private func cancelPicking() {
        guard !isStopped, table.isEnabled else { return }
        if compact { done?() }
        else { window?.makeFirstResponder(searchField) }
    }
}
