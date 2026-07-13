import AppKit
import SwiftTerm

// CRITICAL: LocalProcessTerminalView already conforms to TerminalViewDelegate internally.
// Do NOT conform TerminalContainerView to TerminalViewDelegate.
// Use .processDelegate (LocalProcessTerminalViewDelegate) instead.
// dataReceived override MUST call super FIRST.
// processTerminated uses source: TerminalView (NOT LocalProcessTerminalView)
// hostCurrentDirectoryUpdate uses source: TerminalView (NOT LocalProcessTerminalView)

protocol TerminalContainerViewDelegate: AnyObject {
    func terminalDidChangeStatus(_ container: TerminalContainerView, status: DisplayStatus)
    func terminalDidUpdateWorkingDirectory(_ container: TerminalContainerView, path: String)
    func terminalDidExit(_ container: TerminalContainerView)
}

final class MymuxTerminalView: LocalProcessTerminalView {
    var outputMonitor: PTYOutputMonitor?

    override func dataReceived(slice: ArraySlice<UInt8>) {
        super.dataReceived(slice: slice)  // MUST call super first
        outputMonitor?.dataReceived(slice)
    }

}

final class TerminalContainerView: NSView {
    let terminalView: MymuxTerminalView
    private let outputMonitor: PTYOutputMonitor
    weak var delegate: TerminalContainerViewDelegate?

    var currentStatus: DisplayStatus = .suspended
    var terminalId: String = ""

    /// Local event monitor that swallows mouseMoved events when the terminal
    /// process has enabled anyEvent mouse mode (\x1b[?1003h).  Claude Code
    /// turns this mode on for its interactive confirm/reject prompts; without
    /// the guard, hovering over a choice sends a motion event the process
    /// interprets as cursor movement and auto-selects the hovered option.
    /// Clicks and all other mouse events are unaffected.
    private var mouseMoveMonitor: Any?

    override init(frame frameRect: NSRect) {
        terminalView = MymuxTerminalView(frame: frameRect)
        outputMonitor = PTYOutputMonitor()
        super.init(frame: frameRect)
        setupView()
        installMouseMoveGuard()
    }

    required init?(coder: NSCoder) {
        terminalView = MymuxTerminalView(frame: .zero)
        outputMonitor = PTYOutputMonitor()
        super.init(coder: coder)
        setupView()
        installMouseMoveGuard()
    }

    deinit {
        if let monitor = mouseMoveMonitor {
            NSEvent.removeMonitor(monitor)
        }
    }

    private func installMouseMoveGuard() {
        mouseMoveMonitor = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { [weak self] event in
            guard let self = self,
                  self.terminalView.terminal.mouseMode == .anyEvent,
                  let window = self.window,
                  event.window === window else { return event }
            let locationInView = self.convert(event.locationInWindow, from: nil)
            // Swallow the event only when the pointer is actually over this view
            return self.bounds.contains(locationInView) ? nil : event
        }
    }

    private func setupView() {
        // Suppress SwiftTerm's "Info: Unhandled DEC Private Mode" noise in debug builds
        terminalView.terminal.silentLog = true

        // Wire outputMonitor to terminal view
        terminalView.outputMonitor = outputMonitor

        // Set font
        terminalView.font = NSFont(name: "SF Mono", size: 13)
            ?? NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)

        // Set process delegate (NOT TerminalViewDelegate)
        terminalView.processDelegate = self

        // Wire status changes
        outputMonitor.onStatusChanged = { [weak self] status in
            guard let self = self else { return }
            self.currentStatus = status
            self.delegate?.terminalDidChangeStatus(self, status: status)
        }

        // Add terminal view as subview with auto-layout
        terminalView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(terminalView)
        NSLayoutConstraint.activate([
            terminalView.topAnchor.constraint(equalTo: topAnchor),
            terminalView.bottomAnchor.constraint(equalTo: bottomAnchor),
            terminalView.leadingAnchor.constraint(equalTo: leadingAnchor),
            terminalView.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    func startProcess(executable: String = "/bin/zsh", args: [String] = ["-l"], environment: [String]? = nil) {
        terminalView.startProcess(
            executable: executable,
            args: args,
            environment: environment,
            execName: nil
        )
    }
}

// MARK: - LocalProcessTerminalViewDelegate

extension TerminalContainerView: LocalProcessTerminalViewDelegate {
    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {
        // No-op — handled internally
    }

    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        // Can be handled by delegate if desired
    }

    // NOTE: source type is TerminalView NOT LocalProcessTerminalView
    func processTerminated(source: TerminalView, exitCode: Int32?) {
        outputMonitor.processTerminated()
        currentStatus = .suspended
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.delegate?.terminalDidExit(self)
        }
    }

    // NOTE: source type is TerminalView NOT LocalProcessTerminalView
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        guard let dir = directory else { return }
        let path: String
        if dir.hasPrefix("file://") {
            path = URL(string: dir)?.path ?? dir
        } else {
            path = dir
        }
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.delegate?.terminalDidUpdateWorkingDirectory(self, path: path)
        }
    }
}
