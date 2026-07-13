import AppKit
import GRDB

final class ActivityPanelView: NSView {
    private let sqliteStore: SQLiteStore
    private var currentTerminalId: String?
    private var entries: [ActivityLogEntry] = []
    private var observation: AnyDatabaseCancellable?

    private let headerLabel = NSTextField(labelWithString: "ACTIVITY")
    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private let emptyLabel = NSTextField(labelWithString: "No activity logged yet")
    private let selectLabel = NSTextField(labelWithString: "Select a console to see activity")

    init(sqliteStore: SQLiteStore) {
        self.sqliteStore = sqliteStore
        super.init(frame: .zero)
        setupViews()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Public API

    func show(terminalId: String) {
        currentTerminalId = terminalId
        selectLabel.isHidden = true
        startObservation(terminalId: terminalId)
    }

    func clear() {
        currentTerminalId = nil
        observation = nil
        entries = []
        tableView.reloadData()
        selectLabel.isHidden = false
        emptyLabel.isHidden = true
    }

    // MARK: - Private

    private func startObservation(terminalId: String) {
        let obs = ValueObservation.tracking { db -> [ActivityLogEntry] in
            try ActivityLogEntry
                .filter(Column("terminalId") == terminalId)
                .order(Column("createdAt").asc)
                .limit(200)
                .fetchAll(db)
        }
        observation = obs.start(
            in: sqliteStore.dbPool,
            onError: { error in print("ActivityPanel observation error: \(error)") },
            onChange: { [weak self] newEntries in
                guard let self = self else { return }
                self.entries = newEntries
                self.tableView.reloadData()
                self.emptyLabel.isHidden = !newEntries.isEmpty
                if !newEntries.isEmpty {
                    self.tableView.scrollRowToVisible(newEntries.count - 1)
                }
            }
        )
    }

    private func setupViews() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        // Header
        headerLabel.font = NSFont.systemFont(ofSize: 10, weight: .semibold)
        headerLabel.textColor = .secondaryLabelColor
        headerLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(headerLabel)

        // "Select a console" label (initial state)
        selectLabel.font = NSFont.systemFont(ofSize: 12)
        selectLabel.textColor = .tertiaryLabelColor
        selectLabel.alignment = .center
        selectLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(selectLabel)

        // "No activity" label (console selected but no entries)
        emptyLabel.font = NSFont.systemFont(ofSize: 12)
        emptyLabel.textColor = .tertiaryLabelColor
        emptyLabel.alignment = .center
        emptyLabel.isHidden = true
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(emptyLabel)

        // Table view
        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("entry"))
        col.resizingMask = .autoresizingMask
        tableView.addTableColumn(col)
        tableView.headerView = nil
        tableView.rowSizeStyle = .custom
        tableView.rowHeight = 38
        tableView.dataSource = self
        tableView.delegate = self
        tableView.selectionHighlightStyle = .none

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)

        NSLayoutConstraint.activate([
            headerLabel.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            headerLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),

            scrollView.topAnchor.constraint(equalTo: headerLabel.bottomAnchor, constant: 4),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),

            selectLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            selectLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            emptyLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }
}

// MARK: - NSTableViewDataSource / NSTableViewDelegate

extension ActivityPanelView: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        return entries.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let entry = entries[row]
        let id = NSUserInterfaceItemIdentifier("ActivityCell")
        let cell = tableView.makeView(withIdentifier: id, owner: self) as? ActivityCellView ?? ActivityCellView()
        cell.identifier = id
        cell.configure(entry: entry)
        return cell
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        return 38
    }
}

// MARK: - ActivityCellView

private final class ActivityCellView: NSTableCellView {
    private let timeLabel = NSTextField(labelWithString: "")
    private let messageLabel = NSTextField(labelWithString: "")

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    private static let isoFormatter = ISO8601DateFormatter()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        timeLabel.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
        timeLabel.textColor = .tertiaryLabelColor
        timeLabel.translatesAutoresizingMaskIntoConstraints = false
        timeLabel.setContentHuggingPriority(.required, for: .horizontal)

        messageLabel.font = NSFont.systemFont(ofSize: 11)
        messageLabel.textColor = .labelColor
        messageLabel.lineBreakMode = .byTruncatingTail
        messageLabel.translatesAutoresizingMaskIntoConstraints = false

        addSubview(timeLabel)
        addSubview(messageLabel)

        NSLayoutConstraint.activate([
            timeLabel.topAnchor.constraint(equalTo: topAnchor, constant: 5),
            timeLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),

            messageLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            messageLabel.topAnchor.constraint(equalTo: timeLabel.bottomAnchor, constant: 2),
            messageLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
        ])
    }

    func configure(entry: ActivityLogEntry) {
        if let date = ActivityCellView.isoFormatter.date(from: entry.createdAt) {
            timeLabel.stringValue = ActivityCellView.timeFormatter.string(from: date)
        } else {
            timeLabel.stringValue = String(entry.createdAt.prefix(8))
        }
        messageLabel.stringValue = entry.message
    }
}
