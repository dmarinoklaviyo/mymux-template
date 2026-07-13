import AppKit

// MARK: - TerminalAreaViewController

final class TerminalAreaViewController: NSViewController {
    // MARK: - Subviews
    private var terminalContainer: NSView!
    private var activityPanel: ActivityPanelView!
    private var shellPanel: ShellTerminalPanelView!
    private var emptyStateLabel: NSTextField!
    private var suspendedStateView: NSView?

    // MARK: - Constraints
    private var panelWidthConstraint: NSLayoutConstraint!
    private var shellPanelHeightConstraint: NSLayoutConstraint!
    private var terminalBottomToRoot: NSLayoutConstraint!
    private var terminalBottomToShell: NSLayoutConstraint!

    // MARK: - State
    private var activityPanelVisible = false
    private var shellPanelVisible = false
    private var currentTerminalView: TerminalContainerView?
    private var currentTerminalId: String?

    // MARK: - Init

    private let sqliteStore: SQLiteStore

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
        view.wantsLayer = true
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        setupLayout()
    }

    private func setupLayout() {
        // Terminal container (center area)
        terminalContainer = NSView()
        terminalContainer.wantsLayer = true
        terminalContainer.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(terminalContainer)

        // Activity panel (right side) — real implementation backed by SQLiteStore
        activityPanel = ActivityPanelView(sqliteStore: sqliteStore)
        activityPanel.isHidden = true
        activityPanel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(activityPanel)

        // Shell panel (bottom) — tabbed LocalProcessTerminalView
        shellPanel = ShellTerminalPanelView()
        shellPanel.translatesAutoresizingMaskIntoConstraints = false
        shellPanel.onAllTabsClosed = { [weak self] in
            self?.collapseShellPanel(animated: true)
        }
        view.addSubview(shellPanel)

        // Toolbar area (top-right buttons)
        setupToolbar()

        // Empty state label
        emptyStateLabel = NSTextField(labelWithString: "Create a track and add a console to get started")
        emptyStateLabel.font = NSFont.systemFont(ofSize: 16, weight: .light)
        emptyStateLabel.textColor = NSColor.secondaryLabelColor
        emptyStateLabel.alignment = .center
        emptyStateLabel.translatesAutoresizingMaskIntoConstraints = false
        terminalContainer.addSubview(emptyStateLabel)
        NSLayoutConstraint.activate([
            emptyStateLabel.centerXAnchor.constraint(equalTo: terminalContainer.centerXAnchor),
            emptyStateLabel.centerYAnchor.constraint(equalTo: terminalContainer.centerYAnchor),
        ])

        // Panel width constraint (togglable)
        panelWidthConstraint = activityPanel.widthAnchor.constraint(equalToConstant: 0)

        // Shell panel height constraint (togglable)
        shellPanelHeightConstraint = shellPanel.heightAnchor.constraint(equalToConstant: 0)

        // Terminal bottom constraints (mutually exclusive)
        terminalBottomToRoot = terminalContainer.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        terminalBottomToShell = terminalContainer.bottomAnchor.constraint(equalTo: shellPanel.topAnchor, constant: -1)

        // Activate layout
        NSLayoutConstraint.activate([
            // Terminal container
            terminalContainer.topAnchor.constraint(equalTo: view.topAnchor),
            terminalContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            terminalContainer.trailingAnchor.constraint(equalTo: activityPanel.leadingAnchor),
            terminalBottomToRoot,

            // Activity panel
            activityPanel.topAnchor.constraint(equalTo: view.topAnchor),
            activityPanel.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            activityPanel.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            panelWidthConstraint,

            // Shell panel
            shellPanel.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            shellPanel.trailingAnchor.constraint(equalTo: activityPanel.leadingAnchor),
            shellPanel.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            shellPanelHeightConstraint,
        ])
    }

    private func setupToolbar() {
        let shellButton = NSButton(title: "⌨ Shell", target: self, action: #selector(toggleShellPanel))
        shellButton.bezelStyle = .inline
        shellButton.isBordered = false
        shellButton.font = NSFont.systemFont(ofSize: 11)
        shellButton.translatesAutoresizingMaskIntoConstraints = false

        let activityButton = NSButton(title: "📋 Activity", target: self, action: #selector(toggleActivityPanel))
        activityButton.bezelStyle = .inline
        activityButton.isBordered = false
        activityButton.font = NSFont.systemFont(ofSize: 11)
        activityButton.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(shellButton)
        view.addSubview(activityButton)

        NSLayoutConstraint.activate([
            activityButton.topAnchor.constraint(equalTo: view.topAnchor, constant: 4),
            activityButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),

            shellButton.topAnchor.constraint(equalTo: view.topAnchor, constant: 4),
            shellButton.trailingAnchor.constraint(equalTo: activityButton.leadingAnchor, constant: -8),
        ])
    }

    // MARK: - Public API

    func showTerminal(_ containerView: TerminalContainerView) {
        suspendedStateView?.removeFromSuperview()
        suspendedStateView = nil

        if let current = currentTerminalView {
            current.removeFromSuperview()
        }

        currentTerminalView = containerView
        currentTerminalId = containerView.terminalId
        emptyStateLabel.isHidden = true

        containerView.translatesAutoresizingMaskIntoConstraints = false
        terminalContainer.addSubview(containerView)
        NSLayoutConstraint.activate([
            containerView.topAnchor.constraint(equalTo: terminalContainer.topAnchor),
            containerView.bottomAnchor.constraint(equalTo: terminalContainer.bottomAnchor),
            containerView.leadingAnchor.constraint(equalTo: terminalContainer.leadingAnchor),
            containerView.trailingAnchor.constraint(equalTo: terminalContainer.trailingAnchor),
        ])
    }

    /// Shows the suspended placeholder.
    /// Pass force: true when called from explicit user navigation (sidebar click), so the
    /// guard comparing to currentTerminalId does not block a fresh selection.
    func showSuspendedState(terminalId: String, force: Bool = false, onRestart: @escaping () -> Void) {
        guard force || terminalId == currentTerminalId else { return }

        currentTerminalId = terminalId

        if let current = currentTerminalView {
            current.removeFromSuperview()
            currentTerminalView = nil
        }

        suspendedStateView?.removeFromSuperview()

        let suspendedView = NSView()
        suspendedView.translatesAutoresizingMaskIntoConstraints = false
        terminalContainer.addSubview(suspendedView)
        suspendedStateView = suspendedView

        let label = NSTextField(labelWithString: "Session Suspended")
        label.font = NSFont.systemFont(ofSize: 18, weight: .medium)
        label.textColor = NSColor.secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false

        let restartButton = NSButton(title: "Restart", target: nil, action: nil)
        restartButton.bezelStyle = .rounded
        restartButton.keyEquivalent = "\r"
        restartButton.translatesAutoresizingMaskIntoConstraints = false
        restartButton.onAction { onRestart() }

        suspendedView.addSubview(label)
        suspendedView.addSubview(restartButton)

        NSLayoutConstraint.activate([
            suspendedView.topAnchor.constraint(equalTo: terminalContainer.topAnchor),
            suspendedView.bottomAnchor.constraint(equalTo: terminalContainer.bottomAnchor),
            suspendedView.leadingAnchor.constraint(equalTo: terminalContainer.leadingAnchor),
            suspendedView.trailingAnchor.constraint(equalTo: terminalContainer.trailingAnchor),

            label.centerXAnchor.constraint(equalTo: suspendedView.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: suspendedView.centerYAnchor, constant: -20),

            restartButton.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 16),
            restartButton.centerXAnchor.constraint(equalTo: suspendedView.centerXAnchor),
        ])
    }

    func showEmptyState() {
        currentTerminalView?.removeFromSuperview()
        currentTerminalView = nil
        currentTerminalId = nil
        suspendedStateView?.removeFromSuperview()
        suspendedStateView = nil
        emptyStateLabel.isHidden = false
        activityPanel.clear()
    }

    /// Switch the activity panel to show entries for the given terminal.
    func updateActivityPanel(terminalId: String) {
        activityPanel.show(terminalId: terminalId)
    }

    /// Pass the known working directory for the currently selected terminal into the shell panel.
    func setCurrentWorkingDirectory(_ path: String) {
        shellPanel.setWorkingDirectory(path)
    }

    /// Called by SessionManager when a working directory update arrives for a terminal.
    /// Only propagates to the shell panel when the terminal is currently visible.
    func updateShellDirectoryIfCurrent(terminalId: String, path: String) {
        guard terminalId == currentTerminalId else { return }
        shellPanel.setWorkingDirectory(path)
    }

    // MARK: - Toggle Actions

    @objc private func toggleActivityPanel() {
        activityPanelVisible.toggle()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            ctx.allowsImplicitAnimation = true
            self.panelWidthConstraint.animator().constant = self.activityPanelVisible ? 250 : 0
            self.activityPanel.animator().isHidden = !self.activityPanelVisible
        }
    }

    @objc private func toggleShellPanel() {
        if !shellPanelVisible {
            // T055: Guard against unknown working directory
            if shellPanel.workingDirectory == nil {
                let alert = NSAlert()
                alert.messageText = "No Working Directory"
                alert.informativeText = "Select a console with a known working directory to open the shell panel."
                alert.alertStyle = .informational
                alert.runModal()
                return
            }
            shellPanel.ensureTabOpen()
        }

        shellPanelVisible.toggle()

        if shellPanelVisible {
            terminalBottomToRoot.isActive = false
            terminalBottomToShell.isActive = true
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.2
                ctx.allowsImplicitAnimation = true
                self.shellPanelHeightConstraint.animator().constant = 250
            }
        } else {
            collapseShellPanel(animated: true)
        }
    }

    private func collapseShellPanel(animated: Bool) {
        shellPanelVisible = false
        terminalBottomToShell.isActive = false
        terminalBottomToRoot.isActive = true
        if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.2
                ctx.allowsImplicitAnimation = true
                self.shellPanelHeightConstraint.animator().constant = 0
            }
        } else {
            shellPanelHeightConstraint.constant = 0
        }
    }
}

// MARK: - NSButton Action Helper

private extension NSButton {
    func onAction(_ action: @escaping () -> Void) {
        let helper = ActionHelper(action: action)
        objc_setAssociatedObject(self, &AssociatedKeys.helper, helper, .OBJC_ASSOCIATION_RETAIN)
        target = helper
        self.action = #selector(ActionHelper.executeAction)
    }
}

private enum AssociatedKeys {
    static var helper = "ActionHelper"
}

private class ActionHelper: NSObject {
    private let action: () -> Void
    init(action: @escaping () -> Void) { self.action = action }
    @objc func executeAction() { action() }
}

// MARK: - MainSplitViewController

final class MainSplitViewController: NSSplitViewController {
    let sidebarVC: SidebarViewController
    let terminalAreaVC: TerminalAreaViewController

    init(sqliteStore: SQLiteStore) {
        sidebarVC = SidebarViewController(sqliteStore: sqliteStore)
        terminalAreaVC = TerminalAreaViewController(sqliteStore: sqliteStore)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        // CRITICAL: Use NSSplitViewItem(viewController:) NOT sidebarWithViewController
        let sidebarItem = NSSplitViewItem(viewController: sidebarVC)
        sidebarItem.minimumThickness = 220
        sidebarItem.maximumThickness = 500
        sidebarItem.holdingPriority = NSLayoutConstraint.Priority(251)

        let terminalItem = NSSplitViewItem(viewController: terminalAreaVC)
        terminalItem.minimumThickness = 400

        addSplitViewItem(sidebarItem)
        addSplitViewItem(terminalItem)

        splitView.dividerStyle = .thin
        splitView.setPosition(280, ofDividerAt: 0)
    }
}
