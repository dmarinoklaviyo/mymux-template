import AppKit

/// Lists archived tracks and lets the user rehydrate or permanently delete them.
final class ArchivedTracksSheet: NSViewController {
    private let archiveService: ArchiveService

    /// Called with the trackId when the user rehydrates an archive.
    var onRehydrate: ((String) -> Void)?

    private var archives: [ArchiveService.ArchiveSummary] = []

    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private let emptyLabel = NSTextField(labelWithString: "No archived tracks.")
    private let rehydrateButton = NSButton(title: "Rehydrate", target: nil, action: nil)
    private let deleteButton = NSButton(title: "Delete…", target: nil, action: nil)
    private let closeButton = NSButton(title: "Close", target: nil, action: nil)

    init(archiveService: ArchiveService) {
        self.archiveService = archiveService
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 560, height: 380))
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
        reload()
    }

    private func setupUI() {
        let titleLabel = NSTextField(labelWithString: "Archived Tracks")
        titleLabel.font = NSFont.systemFont(ofSize: 16, weight: .semibold)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(titleLabel)

        // Columns
        let nameCol = NSTableColumn(identifier: .init("name"))
        nameCol.title = "Track"
        nameCol.width = 200
        let dateCol = NSTableColumn(identifier: .init("date"))
        dateCol.title = "Archived"
        dateCol.width = 150
        let sizeCol = NSTableColumn(identifier: .init("size"))
        sizeCol.title = "Size"
        sizeCol.width = 80
        let branchCol = NSTableColumn(identifier: .init("branch"))
        branchCol.title = "Branch"
        branchCol.width = 100
        tableView.addTableColumn(nameCol)
        tableView.addTableColumn(dateCol)
        tableView.addTableColumn(sizeCol)
        tableView.addTableColumn(branchCol)
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.dataSource = self
        tableView.delegate = self
        tableView.doubleAction = #selector(rehydrateClicked)
        tableView.target = self

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scrollView)

        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.alignment = .center
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyLabel.isHidden = true
        view.addSubview(emptyLabel)

        rehydrateButton.bezelStyle = .rounded
        rehydrateButton.keyEquivalent = "\r"
        rehydrateButton.target = self
        rehydrateButton.action = #selector(rehydrateClicked)
        rehydrateButton.translatesAutoresizingMaskIntoConstraints = false

        deleteButton.bezelStyle = .rounded
        deleteButton.target = self
        deleteButton.action = #selector(deleteClicked)
        deleteButton.translatesAutoresizingMaskIntoConstraints = false

        closeButton.bezelStyle = .rounded
        closeButton.keyEquivalent = "\u{1B}"
        closeButton.target = self
        closeButton.action = #selector(closeClicked)
        closeButton.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(rehydrateButton)
        view.addSubview(deleteButton)
        view.addSubview(closeButton)

        let margin: CGFloat = 20
        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: view.topAnchor, constant: margin),
            titleLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: margin),

            scrollView.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 12),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: margin),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -margin),
            scrollView.bottomAnchor.constraint(equalTo: closeButton.topAnchor, constant: -16),

            emptyLabel.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),

            closeButton.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -margin),
            closeButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -margin),

            rehydrateButton.centerYAnchor.constraint(equalTo: closeButton.centerYAnchor),
            rehydrateButton.trailingAnchor.constraint(equalTo: closeButton.leadingAnchor, constant: -8),

            deleteButton.centerYAnchor.constraint(equalTo: closeButton.centerYAnchor),
            deleteButton.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: margin),
        ])
    }

    private func reload() {
        archives = archiveService.listArchives()
        tableView.reloadData()
        let empty = archives.isEmpty
        emptyLabel.isHidden = !empty
        rehydrateButton.isEnabled = !empty
        deleteButton.isEnabled = !empty
    }

    private var selectedArchive: ArchiveService.ArchiveSummary? {
        let row = tableView.selectedRow
        guard row >= 0, row < archives.count else { return nil }
        return archives[row]
    }

    // MARK: - Actions

    @objc private func rehydrateClicked() {
        guard let archive = selectedArchive else { return }
        do {
            try archiveService.rehydrate(trackId: archive.trackId)
            onRehydrate?(archive.trackId)
            reload()
        } catch {
            presentError("Rehydrate Failed", error.localizedDescription)
        }
    }

    @objc private func deleteClicked() {
        guard let archive = selectedArchive else { return }
        let alert = NSAlert()
        alert.messageText = "Delete Archive"
        alert.informativeText = "Permanently delete the archive of \"\(archive.trackName)\"? This cannot be undone."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try archiveService.deleteArchive(trackId: archive.trackId)
            reload()
        } catch {
            presentError("Delete Failed", error.localizedDescription)
        }
    }

    @objc private func closeClicked() {
        if let presentingVC = presentingViewController {
            presentingVC.dismiss(self)
        } else {
            view.window?.close()
        }
    }

    private func presentError(_ title: String, _ message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .critical
        alert.runModal()
    }
}

// MARK: - Table data source / delegate

extension ArchivedTracksSheet: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        return archives.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < archives.count, let column = tableColumn else { return nil }
        let archive = archives[row]

        let text: String
        switch column.identifier.rawValue {
        case "name":
            text = archive.trackName
        case "date":
            text = Self.displayDate(archive.archivedAt)
        case "size":
            text = ByteCountFormatter.string(fromByteCount: archive.sizeBytes, countStyle: .file)
        case "branch":
            text = archive.branch.isEmpty ? "—" : archive.branch
        default:
            text = ""
        }

        let identifier = column.identifier
        let cell: NSTextField
        if let reused = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTextField {
            cell = reused
        } else {
            cell = NSTextField(labelWithString: "")
            cell.identifier = identifier
            cell.lineBreakMode = .byTruncatingTail
        }
        cell.stringValue = text
        cell.toolTip = column.identifier.rawValue == "name" ? archive.repoPath : nil
        return cell
    }

    private static func displayDate(_ iso: String) -> String {
        let parser = ISO8601DateFormatter()
        guard let date = parser.date(from: iso) else { return iso }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}
