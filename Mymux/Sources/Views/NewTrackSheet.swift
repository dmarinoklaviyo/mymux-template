import AppKit

final class NewTrackSheet: NSViewController {
    private let sqliteStore: SQLiteStore
    /// When set, the sheet edits this existing track instead of creating one.
    private let editingTrack: WorkTrack?
    var onCreated: ((WorkTrack) -> Void)?
    /// Called after an edit is saved, with (old, updated) so callers can react
    /// to what changed (e.g. notify live sessions). Only fired in edit mode.
    var onEdited: ((WorkTrack, WorkTrack) -> Void)?

    private var isEditing: Bool { editingTrack != nil }

    // MARK: - UI Elements
    private let nameField = NSTextField()
    private let repoPathField = NSTextField()
    private let browseButton = NSButton(title: "Browse...", target: nil, action: nil)
    private let branchField = NSTextField()
    private let linearUrlField = NSTextField()
    private let contextNotesScrollView = NSScrollView()
    private let contextNotesView = NSTextView()
    private let createButton = NSButton(title: "Create", target: nil, action: nil)
    private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)

    // MARK: - Init

    init(sqliteStore: SQLiteStore, editingTrack: WorkTrack? = nil) {
        self.sqliteStore = sqliteStore
        self.editingTrack = editingTrack
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - View

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 480, height: 420))
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
    }

    private func setupUI() {
        let titleLabel = NSTextField(labelWithString: isEditing ? "Edit Work Track" : "New Work Track")
        titleLabel.font = NSFont.systemFont(ofSize: 16, weight: .semibold)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(titleLabel)

        // Name field
        let nameLabel = makeLabel("Name (required):")
        nameField.placeholderString = "e.g., Auth Refactor"
        nameField.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(nameLabel)
        view.addSubview(nameField)

        // Repo path field
        let repoLabel = makeLabel("Repository Path:")
        repoPathField.placeholderString = "/path/to/repo (optional)"
        repoPathField.translatesAutoresizingMaskIntoConstraints = false
        browseButton.target = self
        browseButton.action = #selector(browsePath)
        browseButton.translatesAutoresizingMaskIntoConstraints = false
        browseButton.setContentHuggingPriority(.required, for: .horizontal)
        view.addSubview(repoLabel)
        view.addSubview(repoPathField)
        view.addSubview(browseButton)

        // Branch field
        let branchLabel = makeLabel("Branch:")
        branchField.placeholderString = "main (optional)"
        branchField.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(branchLabel)
        view.addSubview(branchField)

        // Linear ticket URL
        let linearLabel = makeLabel("Linear Ticket:")
        linearUrlField.placeholderString = "https://linear.app/org/issue/TEAM-123 (optional)"
        linearUrlField.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(linearLabel)
        view.addSubview(linearUrlField)

        // Context notes
        let notesLabel = makeLabel("Context Notes:")
        contextNotesScrollView.hasVerticalScroller = true
        contextNotesScrollView.borderType = .bezelBorder
        contextNotesScrollView.translatesAutoresizingMaskIntoConstraints = false
        contextNotesView.isRichText = false
        contextNotesView.font = NSFont.systemFont(ofSize: 12)
        contextNotesScrollView.documentView = contextNotesView
        view.addSubview(notesLabel)
        view.addSubview(contextNotesScrollView)

        // Prefill when editing
        if let track = editingTrack {
            nameField.stringValue = track.name
            repoPathField.stringValue = track.repoPath
            branchField.stringValue = track.branch
            linearUrlField.stringValue = track.linearTicketUrl ?? ""
            contextNotesView.string = track.contextNotes
        }

        // Buttons
        createButton.title = isEditing ? "Save" : "Create"
        createButton.bezelStyle = .rounded
        createButton.keyEquivalent = "\r"
        createButton.target = self
        createButton.action = #selector(createTrack)
        createButton.translatesAutoresizingMaskIntoConstraints = false

        cancelButton.bezelStyle = .rounded
        cancelButton.keyEquivalent = "\u{1B}"
        cancelButton.target = self
        cancelButton.action = #selector(cancel)
        cancelButton.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(createButton)
        view.addSubview(cancelButton)

        // Layout
        let margin: CGFloat = 20
        let labelWidth: CGFloat = 130
        let fieldLeft = margin + labelWidth + 8

        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: view.topAnchor, constant: margin),
            titleLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: margin),

            // Name
            nameLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 20),
            nameLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: margin),
            nameLabel.widthAnchor.constraint(equalToConstant: labelWidth),

            nameField.centerYAnchor.constraint(equalTo: nameLabel.centerYAnchor),
            nameField.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: fieldLeft),
            nameField.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -margin),

            // Repo path
            repoLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 14),
            repoLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: margin),
            repoLabel.widthAnchor.constraint(equalToConstant: labelWidth),

            repoPathField.centerYAnchor.constraint(equalTo: repoLabel.centerYAnchor),
            repoPathField.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: fieldLeft),
            repoPathField.trailingAnchor.constraint(equalTo: browseButton.leadingAnchor, constant: -8),

            browseButton.centerYAnchor.constraint(equalTo: repoLabel.centerYAnchor),
            browseButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -margin),

            // Branch
            branchLabel.topAnchor.constraint(equalTo: repoLabel.bottomAnchor, constant: 14),
            branchLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: margin),
            branchLabel.widthAnchor.constraint(equalToConstant: labelWidth),

            branchField.centerYAnchor.constraint(equalTo: branchLabel.centerYAnchor),
            branchField.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: fieldLeft),
            branchField.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -margin),

            // Linear ticket
            linearLabel.topAnchor.constraint(equalTo: branchLabel.bottomAnchor, constant: 14),
            linearLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: margin),
            linearLabel.widthAnchor.constraint(equalToConstant: labelWidth),

            linearUrlField.centerYAnchor.constraint(equalTo: linearLabel.centerYAnchor),
            linearUrlField.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: fieldLeft),
            linearUrlField.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -margin),

            // Context notes
            notesLabel.topAnchor.constraint(equalTo: linearLabel.bottomAnchor, constant: 14),
            notesLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: margin),

            contextNotesScrollView.topAnchor.constraint(equalTo: notesLabel.bottomAnchor, constant: 6),
            contextNotesScrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: margin),
            contextNotesScrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -margin),
            contextNotesScrollView.heightAnchor.constraint(equalToConstant: 80),

            // Buttons
            createButton.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -margin),
            createButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -margin),

            cancelButton.centerYAnchor.constraint(equalTo: createButton.centerYAnchor),
            cancelButton.trailingAnchor.constraint(equalTo: createButton.leadingAnchor, constant: -8),
        ])
    }

    private func makeLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = NSFont.systemFont(ofSize: 12)
        label.textColor = .secondaryLabelColor
        label.alignment = .right
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }

    // MARK: - Actions

    @objc private func browsePath() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Select Repository"

        panel.begin { [weak self] response in
            if response == .OK, let url = panel.url {
                self?.repoPathField.stringValue = url.path
            }
        }
    }

    @objc private func createTrack() {
        let name = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            let alert = NSAlert()
            alert.messageText = "Name Required"
            alert.informativeText = "Please enter a name for the track."
            alert.runModal()
            return
        }

        let repoPath = repoPathField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let branch = branchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let linearUrl = linearUrlField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let contextNotes = contextNotesView.string.trimmingCharacters(in: .whitespacesAndNewlines)

        if let existing = editingTrack {
            // Edit: preserve id/createdAt/status, update the mutable fields.
            var updated = existing
            updated.name = name
            updated.repoPath = repoPath
            updated.branch = branch.isEmpty ? "main" : branch
            updated.linearTicketUrl = linearUrl.isEmpty ? nil : linearUrl
            updated.contextNotes = contextNotes

            do {
                try sqliteStore.updateTrack(updated)
                dismissSheet()
                onEdited?(existing, updated)
            } catch {
                let alert = NSAlert()
                alert.messageText = "Error Saving Track"
                alert.informativeText = error.localizedDescription
                alert.runModal()
            }
            return
        }

        let track = WorkTrack(
            name: name,
            repoPath: repoPath,
            branch: branch.isEmpty ? "main" : branch,
            linearTicketUrl: linearUrl.isEmpty ? nil : linearUrl,
            contextNotes: contextNotes
        )

        do {
            try sqliteStore.insertTrack(track)
            dismissSheet()
            onCreated?(track)
        } catch {
            let alert = NSAlert()
            alert.messageText = "Error Creating Track"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }

    @objc private func cancel() {
        dismissSheet()
    }

    private func dismissSheet() {
        if let presentingVC = presentingViewController {
            presentingVC.dismiss(self)
        } else {
            view.window?.close()
        }
    }
}
