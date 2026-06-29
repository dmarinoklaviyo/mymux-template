import AppKit
import GRDB

// MARK: - Supporting Types

struct GitStatus {
    let isDirty: Bool
    let linesAdded: Int
    let linesRemoved: Int
    let commitsAhead: Int

    static let clean = GitStatus(isDirty: false, linesAdded: 0, linesRemoved: 0, commitsAhead: 0)
}

// MARK: - Delegate Protocol

protocol SidebarViewControllerDelegate: AnyObject {
    func sidebarDidSelectTerminal(_ terminalId: String?)
    func sidebarDidRequestNewConsole(inTrackId: String)
    func sidebarDidRequestNewTrack()
    func sidebarDidRequestDeleteTrack(_ trackId: String)
    func sidebarDidRequestDeleteConsole(_ terminalId: String)
    func sidebarDidRequestRestartConsole(_ terminalId: String)
    func sidebarDidRequestRenameConsole(_ terminalId: String, newName: String)
    func sidebarDidMoveTerminal(_ terminalId: String, toTrackId: String)
    func sidebarDidRequestSetLinearTicket(trackId: String, url: String?)
}

// MARK: - Cell Identifiers

private let trackCellIdentifier = NSUserInterfaceItemIdentifier("TrackCell")
private let terminalCellIdentifier = NSUserInterfaceItemIdentifier("TerminalCell")
private let linearCellIdentifier = NSUserInterfaceItemIdentifier("LinearCell")

// MARK: - SidebarViewController

final class SidebarViewController: NSViewController {
    // MARK: - Properties

    weak var delegate: SidebarViewControllerDelegate?
    private let sqliteStore: SQLiteStore

    var tracks: [WorkTrack] = []
    var terminalsByTrack: [String: [Terminal]] = [:]
    var displayStatuses: [String: DisplayStatus] = [:]
    var gitStatuses: [String: GitStatus] = [:]
    private var waitingCounts: [String: Int] = [:]

    private var outlineView: NSOutlineView!
    private var scrollView: NSScrollView!
    private var observation: AnyDatabaseCancellable?

    private let collapsedKey = "mymux.collapsedTrackIds"

    private var collapsedTrackIds: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: collapsedKey) ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: collapsedKey) }
    }

    // MARK: - Init

    init(sqliteStore: SQLiteStore) {
        self.sqliteStore = sqliteStore
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - View Lifecycle

    override func loadView() {
        view = NSView()
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        setupOutlineView()
        setupValueObservation()
    }

    private func setupOutlineView() {
        outlineView = NSOutlineView()
        outlineView.style = .sourceList
        outlineView.headerView = nil
        outlineView.rowSizeStyle = .small
        if #available(macOS 12.0, *) {
            outlineView.style = .sourceList
        } else {
            outlineView.selectionHighlightStyle = .sourceList
        }
        outlineView.floatsGroupRows = false
        outlineView.allowsEmptySelection = true

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("main"))
        column.title = ""
        column.resizingMask = .autoresizingMask
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column

        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.menu = NSMenu()
        outlineView.menu?.delegate = self

        // Drag and drop
        outlineView.registerForDraggedTypes([.string])
        outlineView.setDraggingSourceOperationMask(.move, forLocal: true)

        scrollView = NSScrollView()
        scrollView.documentView = outlineView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        // Footer button to create a new track
        let newTrackButton = NSButton(title: "+ New Track", target: self, action: #selector(newTrackClicked))
        newTrackButton.bezelStyle = .inline
        newTrackButton.isBordered = false
        newTrackButton.font = NSFont.systemFont(ofSize: 12)
        newTrackButton.contentTintColor = .secondaryLabelColor
        newTrackButton.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(scrollView)
        view.addSubview(newTrackButton)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: newTrackButton.topAnchor),

            newTrackButton.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            newTrackButton.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -8),
            newTrackButton.heightAnchor.constraint(equalToConstant: 24),
        ])
    }

    private func setupValueObservation() {
        let obs = ValueObservation.tracking { db -> ([WorkTrack], [Terminal]) in
            let tracks = try WorkTrack.order(Column("updatedAt").desc).fetchAll(db)
            let terminals = try Terminal.order(Column("createdAt").asc).fetchAll(db)
            return (tracks, terminals)
        }

        observation = obs.start(
            in: sqliteStore.dbPool,
            onError: { error in
                print("Sidebar observation error: \(error)")
            },
            onChange: { [weak self] (tracks, terminals) in
                guard let self = self else { return }
                self.tracks = tracks
                self.terminalsByTrack = Dictionary(grouping: terminals, by: \.trackId)
                self.recomputeWaitingCounts()
                self.outlineView.reloadData()
                let collapsed = self.collapsedTrackIds
                for track in tracks {
                    if collapsed.contains(track.id) {
                        self.outlineView.collapseItem(track.id)
                    } else {
                        self.outlineView.expandItem(track.id)
                    }
                }
            }
        )
    }

    private func recomputeWaitingCounts() {
        var counts: [String: Int] = [:]
        for (trackId, terminals) in terminalsByTrack {
            let waitingCount = terminals.filter { displayStatuses[$0.id] == .waiting }.count
            counts[trackId] = waitingCount
        }
        waitingCounts = counts
    }

    // MARK: - Public API

    func updateStatus(terminalId: String, status: DisplayStatus) {
        displayStatuses[terminalId] = status
        recomputeWaitingCounts()

        // Find which track this terminal belongs to and refresh its row
        for track in tracks {
            if let terminals = terminalsByTrack[track.id],
               terminals.contains(where: { $0.id == terminalId }) {
                // Reload the terminal row
                let rowIndex = outlineView.row(forItem: terminalId)
                if rowIndex >= 0 {
                    let colIndex = 0
                    outlineView.reloadData(forRowIndexes: IndexSet(integer: rowIndex),
                                          columnIndexes: IndexSet(integer: colIndex))
                }
                // Also reload track row for badge update
                let trackRowIndex = outlineView.row(forItem: track.id)
                if trackRowIndex >= 0 {
                    outlineView.reloadData(forRowIndexes: IndexSet(integer: trackRowIndex),
                                          columnIndexes: IndexSet(integer: 0))
                }
                break
            }
        }
    }

    func selectTerminal(id: String) {
        let row = outlineView.row(forItem: id)
        if row >= 0 {
            outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            outlineView.scrollRowToVisible(row)
        }
    }

    func updateGitStatus(terminalId: String, status: GitStatus) {
        gitStatuses[terminalId] = status
        let rowIndex = outlineView.row(forItem: terminalId)
        if rowIndex >= 0 {
            outlineView.reloadData(forRowIndexes: IndexSet(integer: rowIndex),
                                   columnIndexes: IndexSet(integer: 0))
        }
    }

    func addConsole(toTrackId trackId: String) {
        delegate?.sidebarDidRequestNewConsole(inTrackId: trackId)
    }

    // MARK: - Linear Item Helpers

    private func isLinearItem(_ itemId: String) -> Bool {
        itemId.hasPrefix("linear:")
    }

    private func trackIdFromLinearItem(_ itemId: String) -> String? {
        guard isLinearItem(itemId) else { return nil }
        return String(itemId.dropFirst("linear:".count))
    }

    @objc private func newTrackClicked() {
        delegate?.sidebarDidRequestNewTrack()
    }
}

// MARK: - NSOutlineViewDataSource

extension SidebarViewController: NSOutlineViewDataSource {
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if item == nil {
            return tracks.count
        }
        if let trackId = item as? String, let track = tracks.first(where: { $0.id == trackId }) {
            let terminalCount = terminalsByTrack[trackId]?.count ?? 0
            let linearCount = track.linearTicketUrl != nil ? 1 : 0
            return terminalCount + linearCount
        }
        return 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if item == nil {
            return tracks[index].id
        }
        if let trackId = item as? String, let track = tracks.first(where: { $0.id == trackId }) {
            let hasLinear = track.linearTicketUrl != nil
            if hasLinear {
                if index == 0 { return "linear:\(trackId)" }
                return terminalsByTrack[trackId]?[index - 1].id ?? ""
            } else {
                return terminalsByTrack[trackId]?[index].id ?? ""
            }
        }
        return ""
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        if let trackId = item as? String {
            return tracks.contains(where: { $0.id == trackId })
        }
        return false
    }

    // MARK: - Drag Source

    func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
        guard let itemId = item as? String else { return nil }
        // Only allow dragging terminal items (not tracks or linear items)
        let isTerminal = tracks.allSatisfy { $0.id != itemId } && !isLinearItem(itemId)
        guard isTerminal else { return nil }

        let pbItem = NSPasteboardItem()
        pbItem.setString(itemId, forType: .string)
        return pbItem
    }

    func outlineView(_ outlineView: NSOutlineView, validateDrop info: NSDraggingInfo, proposedItem item: Any?, proposedChildIndex index: Int) -> NSDragOperation {
        guard let targetId = item as? String,
              tracks.contains(where: { $0.id == targetId }) else {
            return []
        }
        return .move
    }

    func outlineView(_ outlineView: NSOutlineView, acceptDrop info: NSDraggingInfo, item: Any?, childIndex index: Int) -> Bool {
        guard let targetTrackId = item as? String,
              tracks.contains(where: { $0.id == targetTrackId }),
              let terminalId = info.draggingPasteboard.string(forType: .string) else {
            return false
        }

        delegate?.sidebarDidMoveTerminal(terminalId, toTrackId: targetTrackId)
        return true
    }
}

// MARK: - NSOutlineViewDelegate

extension SidebarViewController: NSOutlineViewDelegate {
    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let itemId = item as? String else { return nil }

        // Check if this is a track item
        if let track = tracks.first(where: { $0.id == itemId }) {
            return makeTrackCell(for: track, outlineView: outlineView)
        }

        // Check if this is a linear ticket item
        if isLinearItem(itemId),
           let trackId = trackIdFromLinearItem(itemId),
           let track = tracks.first(where: { $0.id == trackId }),
           let url = track.linearTicketUrl {
            return makeLinearCell(trackId: trackId, url: url, outlineView: outlineView)
        }

        // Check if this is a terminal item
        for track in tracks {
            if let terminals = terminalsByTrack[track.id],
               let terminal = terminals.first(where: { $0.id == itemId }) {
                return makeTerminalCell(for: terminal, outlineView: outlineView)
            }
        }

        return nil
    }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        guard let itemId = item as? String else { return false }
        // Only allow selecting terminal items (not tracks or linear ticket rows)
        return !tracks.contains(where: { $0.id == itemId }) && !isLinearItem(itemId)
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        let row = outlineView.selectedRow
        if row < 0 {
            delegate?.sidebarDidSelectTerminal(nil)
            return
        }
        guard let itemId = outlineView.item(atRow: row) as? String else {
            delegate?.sidebarDidSelectTerminal(nil)
            return
        }
        // Only forward terminal selections
        if !tracks.contains(where: { $0.id == itemId }) {
            delegate?.sidebarDidSelectTerminal(itemId)
        }
    }

    func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool {
        return false
    }

    func outlineViewItemDidCollapse(_ notification: Notification) {
        guard let itemId = notification.userInfo?["NSObject"] as? String else { return }
        var collapsed = collapsedTrackIds
        collapsed.insert(itemId)
        collapsedTrackIds = collapsed
    }

    func outlineViewItemDidExpand(_ notification: Notification) {
        guard let itemId = notification.userInfo?["NSObject"] as? String else { return }
        var collapsed = collapsedTrackIds
        collapsed.remove(itemId)
        collapsedTrackIds = collapsed
    }

    // MARK: - Cell Construction

    private func makeTrackCell(for track: WorkTrack, outlineView: NSOutlineView) -> NSView {
        let cell = outlineView.makeView(withIdentifier: trackCellIdentifier, owner: self)
            as? TrackTableCellView ?? TrackTableCellView()
        cell.identifier = trackCellIdentifier
        cell.configure(track: track, badgeCount: waitingCounts[track.id] ?? 0) { [weak self] in
            self?.delegate?.sidebarDidRequestNewConsole(inTrackId: track.id)
        }
        return cell
    }

    private func makeLinearCell(trackId: String, url: String, outlineView: NSOutlineView) -> NSView {
        let cell = outlineView.makeView(withIdentifier: linearCellIdentifier, owner: self)
            as? LinearTicketCellView ?? LinearTicketCellView()
        cell.identifier = linearCellIdentifier
        cell.configure(url: url) {
            if let nsUrl = URL(string: url) {
                NSWorkspace.shared.open(nsUrl)
            }
        }
        return cell
    }

    private func makeTerminalCell(for terminal: Terminal, outlineView: NSOutlineView) -> NSView {
        let cell = outlineView.makeView(withIdentifier: terminalCellIdentifier, owner: self)
            as? TerminalTableCellView ?? TerminalTableCellView()
        cell.identifier = terminalCellIdentifier
        let status = displayStatuses[terminal.id] ?? .suspended
        let git = gitStatuses[terminal.id]
        cell.configure(terminal: terminal, status: status, gitStatus: git)
        return cell
    }
}

// MARK: - NSMenuDelegate (Context Menu)

extension SidebarViewController: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let clickedRow = outlineView.clickedRow
        guard clickedRow >= 0,
              let itemId = outlineView.item(atRow: clickedRow) as? String else {
            return
        }

        // Track item context menu
        if let track = tracks.first(where: { $0.id == itemId }) {
            let newConsole = NSMenuItem(title: "New Console", action: #selector(menuNewConsole(_:)), keyEquivalent: "")
            newConsole.representedObject = itemId
            newConsole.target = self
            menu.addItem(newConsole)

            menu.addItem(.separator())

            if let _ = track.linearTicketUrl {
                let openLinear = NSMenuItem(title: "Open Linear Ticket", action: #selector(menuOpenLinearTicket(_:)), keyEquivalent: "")
                openLinear.representedObject = itemId
                openLinear.target = self
                menu.addItem(openLinear)

                let changeTicket = NSMenuItem(title: "Change Linear Ticket…", action: #selector(menuSetLinearTicket(_:)), keyEquivalent: "")
                changeTicket.representedObject = itemId
                changeTicket.target = self
                menu.addItem(changeTicket)

                let removeTicket = NSMenuItem(title: "Remove Linear Ticket", action: #selector(menuRemoveLinearTicket(_:)), keyEquivalent: "")
                removeTicket.representedObject = itemId
                removeTicket.target = self
                menu.addItem(removeTicket)
            } else {
                let setTicket = NSMenuItem(title: "Set Linear Ticket…", action: #selector(menuSetLinearTicket(_:)), keyEquivalent: "")
                setTicket.representedObject = itemId
                setTicket.target = self
                menu.addItem(setTicket)
            }

            menu.addItem(.separator())

            let deleteTrack = NSMenuItem(title: "Delete Track", action: #selector(menuDeleteTrack(_:)), keyEquivalent: "")
            deleteTrack.representedObject = itemId
            deleteTrack.target = self
            menu.addItem(deleteTrack)
            return
        }

        // Linear ticket item context menu
        if isLinearItem(itemId),
           let trackId = trackIdFromLinearItem(itemId),
           let track = tracks.first(where: { $0.id == trackId }),
           let _ = track.linearTicketUrl {
            let open = NSMenuItem(title: "Open in Browser", action: #selector(menuOpenLinearTicket(_:)), keyEquivalent: "")
            open.representedObject = trackId
            open.target = self
            menu.addItem(open)

            menu.addItem(.separator())

            let change = NSMenuItem(title: "Change Ticket…", action: #selector(menuSetLinearTicket(_:)), keyEquivalent: "")
            change.representedObject = trackId
            change.target = self
            menu.addItem(change)

            let remove = NSMenuItem(title: "Remove Ticket", action: #selector(menuRemoveLinearTicket(_:)), keyEquivalent: "")
            remove.representedObject = trackId
            remove.target = self
            menu.addItem(remove)
            return
        }

        // Terminal item context menu
        // Find which track owns this terminal
        var ownerTrackId: String?
        var isSuspended = false
        for track in tracks {
            if let terminals = terminalsByTrack[track.id],
               terminals.contains(where: { $0.id == itemId }) {
                ownerTrackId = track.id
                let status = displayStatuses[itemId] ?? .suspended
                isSuspended = (status == .suspended)
                break
            }
        }

        if let trackId = ownerTrackId {
            let newConsole = NSMenuItem(title: "New Console", action: #selector(menuNewConsole(_:)), keyEquivalent: "")
            newConsole.representedObject = trackId
            newConsole.target = self
            menu.addItem(newConsole)

            menu.addItem(.separator())

            let rename = NSMenuItem(title: "Rename…", action: #selector(menuRenameConsole(_:)), keyEquivalent: "")
            rename.representedObject = itemId
            rename.target = self
            menu.addItem(rename)

            let deleteConsole = NSMenuItem(title: "Delete Console", action: #selector(menuDeleteConsole(_:)), keyEquivalent: "")
            deleteConsole.representedObject = itemId
            deleteConsole.target = self
            menu.addItem(deleteConsole)

            if isSuspended {
                let restart = NSMenuItem(title: "Restart", action: #selector(menuRestartConsole(_:)), keyEquivalent: "")
                restart.representedObject = itemId
                restart.target = self
                menu.addItem(restart)
            }
        }
    }

    @objc private func menuNewConsole(_ sender: NSMenuItem) {
        guard let trackId = sender.representedObject as? String else { return }
        delegate?.sidebarDidRequestNewConsole(inTrackId: trackId)
    }

    @objc private func menuDeleteTrack(_ sender: NSMenuItem) {
        guard let trackId = sender.representedObject as? String,
              let track = tracks.first(where: { $0.id == trackId }) else { return }

        let alert = NSAlert()
        alert.messageText = "Delete Track"
        alert.informativeText = "Are you sure you want to delete \"\(track.name)\"? This will also delete all consoles in this track."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            delegate?.sidebarDidRequestDeleteTrack(trackId)
        }
    }

    @objc private func menuRenameConsole(_ sender: NSMenuItem) {
        guard let terminalId = sender.representedObject as? String else { return }

        // Find current name
        var currentName = ""
        for track in tracks {
            if let terminal = terminalsByTrack[track.id]?.first(where: { $0.id == terminalId }) {
                currentName = terminal.name
                break
            }
        }

        let alert = NSAlert()
        alert.messageText = "Rename Console"
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = currentName
        field.placeholderString = "Console name"
        alert.accessoryView = field

        // Pre-select the text so the user can start typing immediately
        alert.window.initialFirstResponder = field

        if alert.runModal() == .alertFirstButtonReturn {
            let newName = field.stringValue.trimmingCharacters(in: .whitespaces)
            guard !newName.isEmpty, newName != currentName else { return }
            delegate?.sidebarDidRequestRenameConsole(terminalId, newName: newName)
        }
    }

    @objc private func menuDeleteConsole(_ sender: NSMenuItem) {
        guard let terminalId = sender.representedObject as? String else { return }
        delegate?.sidebarDidRequestDeleteConsole(terminalId)
    }

    @objc private func menuRestartConsole(_ sender: NSMenuItem) {
        guard let terminalId = sender.representedObject as? String else { return }
        delegate?.sidebarDidRequestRestartConsole(terminalId)
    }

    @objc private func menuSetLinearTicket(_ sender: NSMenuItem) {
        guard let trackId = sender.representedObject as? String,
              let track = tracks.first(where: { $0.id == trackId }) else { return }

        let alert = NSAlert()
        alert.messageText = "Set Linear Ticket"
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 340, height: 24))
        field.stringValue = track.linearTicketUrl ?? ""
        field.placeholderString = "https://linear.app/org/issue/TEAM-123"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field

        if alert.runModal() == .alertFirstButtonReturn {
            let url = field.stringValue.trimmingCharacters(in: .whitespaces)
            delegate?.sidebarDidRequestSetLinearTicket(trackId: trackId, url: url.isEmpty ? nil : url)
        }
    }

    @objc private func menuOpenLinearTicket(_ sender: NSMenuItem) {
        guard let trackId = sender.representedObject as? String,
              let track = tracks.first(where: { $0.id == trackId }),
              let urlString = track.linearTicketUrl,
              let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func menuRemoveLinearTicket(_ sender: NSMenuItem) {
        guard let trackId = sender.representedObject as? String else { return }
        delegate?.sidebarDidRequestSetLinearTicket(trackId: trackId, url: nil)
    }
}

// MARK: - Custom Cell Views

private final class TrackTableCellView: NSTableCellView {
    private let nameLabel = NSTextField(labelWithString: "")
    private let addButton = NSButton()
    private let badgeLabel = NSTextField(labelWithString: "")
    private var addAction: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupViews()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupViews()
    }

    private func setupViews() {
        nameLabel.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        nameLabel.textColor = .labelColor
        nameLabel.translatesAutoresizingMaskIntoConstraints = false

        addButton.title = "⊕"
        addButton.bezelStyle = .inline
        addButton.isBordered = false
        addButton.font = NSFont.systemFont(ofSize: 13)
        addButton.target = self
        addButton.action = #selector(addButtonClicked)
        addButton.translatesAutoresizingMaskIntoConstraints = false
        addButton.setContentHuggingPriority(.required, for: .horizontal)

        badgeLabel.font = NSFont.systemFont(ofSize: 10, weight: .medium)
        badgeLabel.textColor = .white
        badgeLabel.backgroundColor = NSColor.systemOrange
        badgeLabel.alignment = .center
        badgeLabel.wantsLayer = true
        badgeLabel.layer?.cornerRadius = 7
        badgeLabel.layer?.masksToBounds = true
        badgeLabel.isHidden = true
        badgeLabel.translatesAutoresizingMaskIntoConstraints = false
        badgeLabel.setContentHuggingPriority(.required, for: .horizontal)

        addSubview(nameLabel)
        addSubview(addButton)
        addSubview(badgeLabel)

        NSLayoutConstraint.activate([
            nameLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            nameLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            nameLabel.trailingAnchor.constraint(lessThanOrEqualTo: badgeLabel.leadingAnchor, constant: -4),

            badgeLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            badgeLabel.trailingAnchor.constraint(equalTo: addButton.leadingAnchor, constant: -4),
            badgeLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 14),
            badgeLabel.heightAnchor.constraint(equalToConstant: 14),

            addButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            addButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
        ])
    }

    func configure(track: WorkTrack, badgeCount: Int, addAction: @escaping () -> Void) {
        nameLabel.stringValue = track.name
        self.addAction = addAction

        if badgeCount > 0 {
            badgeLabel.stringValue = String(badgeCount)
            badgeLabel.isHidden = false
        } else {
            badgeLabel.isHidden = true
        }
    }

    @objc private func addButtonClicked() {
        addAction?()
    }
}

private final class LinearTicketCellView: NSTableCellView {
    private let linkButton = NSButton()
    private var onClick: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupViews()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupViews()
    }

    private func setupViews() {
        linkButton.bezelStyle = .inline
        linkButton.isBordered = false
        linkButton.imagePosition = .imageLeading
        linkButton.alignment = .left
        linkButton.target = self
        linkButton.action = #selector(handleClick)
        linkButton.translatesAutoresizingMaskIntoConstraints = false
        linkButton.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        addSubview(linkButton)
        NSLayoutConstraint.activate([
            linkButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            linkButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            linkButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
        ])
    }

    func configure(url: String, onClick: @escaping () -> Void) {
        self.onClick = onClick
        let ticketId = extractTicketId(from: url) ?? url

        let config = NSImage.SymbolConfiguration(pointSize: 10, weight: .regular)
        linkButton.image = NSImage(systemSymbolName: "link", accessibilityDescription: "Linear ticket")?
            .withSymbolConfiguration(config)
        linkButton.title = ticketId
        linkButton.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        linkButton.contentTintColor = NSColor.systemBlue
    }

    @objc private func handleClick() {
        onClick?()
    }

    private func extractTicketId(from urlString: String) -> String? {
        guard let range = urlString.range(of: "[A-Z][A-Z0-9]*-[0-9]+", options: .regularExpression) else {
            return nil
        }
        return String(urlString[range])
    }
}

private final class TerminalTableCellView: NSTableCellView {
    private let statusDot = StatusDotView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let gitLabel = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupViews()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupViews()
    }

    private func setupViews() {
        statusDot.translatesAutoresizingMaskIntoConstraints = false

        nameLabel.font = NSFont.systemFont(ofSize: 12)
        nameLabel.textColor = .labelColor
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        gitLabel.font = NSFont.systemFont(ofSize: 10)
        gitLabel.textColor = NSColor.systemOrange
        gitLabel.alignment = .right
        gitLabel.isHidden = true
        gitLabel.translatesAutoresizingMaskIntoConstraints = false
        gitLabel.setContentHuggingPriority(.required, for: .horizontal)

        addSubview(statusDot)
        addSubview(nameLabel)
        addSubview(gitLabel)

        NSLayoutConstraint.activate([
            statusDot.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            statusDot.centerYAnchor.constraint(equalTo: centerYAnchor),
            statusDot.widthAnchor.constraint(equalToConstant: 12),
            statusDot.heightAnchor.constraint(equalToConstant: 12),

            nameLabel.leadingAnchor.constraint(equalTo: statusDot.trailingAnchor, constant: 6),
            nameLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            nameLabel.trailingAnchor.constraint(lessThanOrEqualTo: gitLabel.leadingAnchor, constant: -4),

            gitLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            gitLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
        ])
    }

    func configure(terminal: Terminal, status: DisplayStatus, gitStatus: GitStatus?) {
        statusDot.status = status

        let isDirty = gitStatus?.isDirty ?? false
        if isDirty {
            nameLabel.textColor = NSColor.systemOrange
        } else {
            nameLabel.textColor = NSColor.labelColor
        }
        nameLabel.stringValue = terminal.name

        if let git = gitStatus, git.isDirty {
            var parts: [String] = []
            if git.linesAdded > 0 { parts.append("+\(git.linesAdded)") }
            if git.linesRemoved > 0 { parts.append("-\(git.linesRemoved)") }
            if git.commitsAhead > 0 { parts.append("\(git.commitsAhead)↑") }
            gitLabel.stringValue = parts.joined(separator: " ")
            gitLabel.isHidden = parts.isEmpty
        } else {
            gitLabel.isHidden = true
        }
    }
}
