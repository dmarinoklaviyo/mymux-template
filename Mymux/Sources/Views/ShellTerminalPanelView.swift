import AppKit
import SwiftTerm

// Tabbed shell panel shown below the Claude terminal.
// Each tab runs an independent $SHELL -l session, cd'd to the working directory on open.
final class ShellTerminalPanelView: NSView {
    var onAllTabsClosed: (() -> Void)?
    private(set) var workingDirectory: String?

    private var tabs: [(id: String, terminal: LocalProcessTerminalView)] = []
    private var currentIndex: Int = -1

    private let tabBar = NSView()
    private let tabSegment = NSSegmentedControl()
    private let addButton = NSButton()
    private let closeButton = NSButton()
    private let terminalContainer = NSView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupViews()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupViews()
    }

    // MARK: - Public API

    func setWorkingDirectory(_ path: String) {
        workingDirectory = path
    }

    /// Opens a new tab in the working directory. Returns false if no working directory is set.
    @discardableResult
    func ensureTabOpen() -> Bool {
        guard let dir = workingDirectory else { return false }
        if tabs.isEmpty {
            openTab(in: dir)
        }
        return true
    }

    // MARK: - Tab Management

    private func openTab(in directory: String) {
        let tv = LocalProcessTerminalView(frame: terminalContainer.bounds)
        tv.font = NSFont(name: "SF Mono", size: 12) ?? NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)

        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let env = buildEnvironment()

        tv.startProcess(executable: shell, args: ["-l"], environment: env, execName: nil)

        // cd to the working directory after the shell starts
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            tv.send(txt: "cd \"\(directory)\" && clear\n")
        }

        let tabId = UUID().uuidString
        let idx = tabs.count
        tabs.append((id: tabId, terminal: tv))

        rebuildTabBar()
        showTab(at: idx)
    }

    private func closeCurrentTab() {
        guard currentIndex >= 0, currentIndex < tabs.count else { return }

        let tab = tabs[currentIndex]
        tab.terminal.removeFromSuperview()
        tabs.remove(at: currentIndex)

        if tabs.isEmpty {
            currentIndex = -1
            rebuildTabBar()
            onAllTabsClosed?()
            return
        }

        let nextIdx = min(currentIndex, tabs.count - 1)
        rebuildTabBar()
        showTab(at: nextIdx)
    }

    private func showTab(at index: Int) {
        guard index >= 0, index < tabs.count else { return }

        // Remove previously shown terminal
        if currentIndex >= 0, currentIndex < tabs.count {
            tabs[currentIndex].terminal.removeFromSuperview()
        }

        currentIndex = index
        tabSegment.selectedSegment = index

        let tv = tabs[index].terminal
        tv.translatesAutoresizingMaskIntoConstraints = false
        terminalContainer.addSubview(tv)
        NSLayoutConstraint.activate([
            tv.topAnchor.constraint(equalTo: terminalContainer.topAnchor),
            tv.bottomAnchor.constraint(equalTo: terminalContainer.bottomAnchor),
            tv.leadingAnchor.constraint(equalTo: terminalContainer.leadingAnchor),
            tv.trailingAnchor.constraint(equalTo: terminalContainer.trailingAnchor),
        ])
    }

    private func rebuildTabBar() {
        tabSegment.segmentCount = tabs.count
        for (i, _) in tabs.enumerated() {
            tabSegment.setLabel("shell \(i + 1)", forSegment: i)
            tabSegment.setWidth(0, forSegment: i)  // auto width
        }
        closeButton.isEnabled = !tabs.isEmpty
    }

    // MARK: - Actions

    @objc private func tabSegmentChanged() {
        showTab(at: tabSegment.selectedSegment)
    }

    @objc private func addTabClicked() {
        guard let dir = workingDirectory else { return }
        openTab(in: dir)
    }

    @objc private func closeTabClicked() {
        closeCurrentTab()
    }

    // MARK: - Setup

    private func setupViews() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.underPageBackgroundColor.cgColor

        // Top separator
        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        addSubview(separator)

        // Tab bar
        tabBar.wantsLayer = true
        tabBar.layer?.backgroundColor = NSColor.underPageBackgroundColor.cgColor
        tabBar.translatesAutoresizingMaskIntoConstraints = false
        addSubview(tabBar)

        tabSegment.segmentStyle = .capsule
        tabSegment.trackingMode = .selectOne
        tabSegment.segmentCount = 0
        tabSegment.target = self
        tabSegment.action = #selector(tabSegmentChanged)
        tabSegment.translatesAutoresizingMaskIntoConstraints = false
        tabBar.addSubview(tabSegment)

        addButton.title = "+"
        addButton.bezelStyle = .inline
        addButton.isBordered = false
        addButton.font = NSFont.systemFont(ofSize: 14, weight: .light)
        addButton.target = self
        addButton.action = #selector(addTabClicked)
        addButton.translatesAutoresizingMaskIntoConstraints = false
        tabBar.addSubview(addButton)

        closeButton.title = "×"
        closeButton.bezelStyle = .inline
        closeButton.isBordered = false
        closeButton.font = NSFont.systemFont(ofSize: 14, weight: .light)
        closeButton.target = self
        closeButton.action = #selector(closeTabClicked)
        closeButton.isEnabled = false
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        tabBar.addSubview(closeButton)

        // Terminal content area
        terminalContainer.wantsLayer = true
        terminalContainer.translatesAutoresizingMaskIntoConstraints = false
        addSubview(terminalContainer)

        NSLayoutConstraint.activate([
            separator.topAnchor.constraint(equalTo: topAnchor),
            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            separator.heightAnchor.constraint(equalToConstant: 1),

            tabBar.topAnchor.constraint(equalTo: separator.bottomAnchor),
            tabBar.leadingAnchor.constraint(equalTo: leadingAnchor),
            tabBar.trailingAnchor.constraint(equalTo: trailingAnchor),
            tabBar.heightAnchor.constraint(equalToConstant: 28),

            tabSegment.centerYAnchor.constraint(equalTo: tabBar.centerYAnchor),
            tabSegment.leadingAnchor.constraint(equalTo: tabBar.leadingAnchor, constant: 8),

            addButton.centerYAnchor.constraint(equalTo: tabBar.centerYAnchor),
            addButton.leadingAnchor.constraint(equalTo: tabSegment.trailingAnchor, constant: 6),
            addButton.widthAnchor.constraint(equalToConstant: 20),

            closeButton.centerYAnchor.constraint(equalTo: tabBar.centerYAnchor),
            closeButton.trailingAnchor.constraint(equalTo: tabBar.trailingAnchor, constant: -8),
            closeButton.widthAnchor.constraint(equalToConstant: 20),

            terminalContainer.topAnchor.constraint(equalTo: tabBar.bottomAnchor),
            terminalContainer.leadingAnchor.constraint(equalTo: leadingAnchor),
            terminalContainer.trailingAnchor.constraint(equalTo: trailingAnchor),
            terminalContainer.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    private func buildEnvironment() -> [String] {
        var env: [String] = []
        for key in ["HOME", "PATH", "LANG", "USER", "SHELL", "EDITOR"] {
            if let value = ProcessInfo.processInfo.environment[key] {
                env.append("\(key)=\(value)")
            }
        }
        env.append("TERM=xterm-256color")
        env.append("COLORTERM=truecolor")
        return env
    }
}
