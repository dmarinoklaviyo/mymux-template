import AppKit

// SessionManager owns all active TerminalContainerViews.
// It coordinates between: SQLiteStore, SidebarViewController (for status updates),
// IPCListener (working directories), ClaudeCommandBuilder, MCPConfigGenerator
final class SessionManager {
    private(set) var activeSessions: [String: TerminalContainerView] = [:]
    var workingDirectories: [String: String] = [:]
    var displayStatuses: [String: DisplayStatus] = [:]

    weak var sidebarViewController: SidebarViewController?
    weak var terminalAreaViewController: TerminalAreaViewController?

    private let sqliteStore: SQLiteStore
    private var notificationManager: NotificationManager?
    private let gitStatusChecker = GitStatusChecker()

    init(sqliteStore: SQLiteStore) {
        self.sqliteStore = sqliteStore
        setupGitStatusChecker()
        gitStatusChecker.start()
    }

    func setNotificationManager(_ nm: NotificationManager) {
        self.notificationManager = nm
    }

    // MARK: - Session Lifecycle

    func spawnSession(terminal: Terminal, track: WorkTrack) {
        if let existing = activeSessions[terminal.id] {
            existing.removeFromSuperview()
            activeSessions.removeValue(forKey: terminal.id)
        }

        let container = TerminalContainerView(frame: .zero)
        container.terminalId = terminal.id
        container.delegate = self
        activeSessions[terminal.id] = container

        let executable = "/bin/zsh"
        let args: [String]
        let environment: [String]

        if let mcpConfigPath = try? MCPConfigGenerator.writeConfig(terminalId: terminal.id) {
            // If this terminal already owns a conversation on disk (e.g. a
            // rehydrated track), resume it; otherwise assign a fresh id that we
            // control so we can always resume exactly this terminal later.
            let mode: ClaudeCommandBuilder.SessionMode
            if let sid = terminal.claudeSessionId, !sid.isEmpty,
               transcriptExists(sessionId: sid, repoPath: track.repoPath) {
                mode = .resume(sessionId: sid)
            } else {
                let newId = UUID().uuidString.lowercased()
                try? sqliteStore.updateTerminalClaudeSessionId(id: terminal.id, sessionId: newId)
                mode = .fresh(sessionId: newId)
            }
            let command = ClaudeCommandBuilder.buildCommand(
                terminal: terminal,
                track: track,
                sessionMode: mode,
                mcpConfigPath: mcpConfigPath
            )
            args = ["-l", "-c", command]
            environment = ClaudeCommandBuilder.buildEnvironment(terminalId: terminal.id)
        } else {
            args = ["-l", "-c", "echo 'mymux session started'; exec $SHELL -l"]
            environment = buildFallbackEnvironment(terminalId: terminal.id)
        }

        container.startProcess(executable: executable, args: args, environment: environment)

        try? sqliteStore.updateTerminalRuntimeStatus(id: terminal.id, status: .live)

        displayStatuses[terminal.id] = .active
        sidebarViewController?.updateStatus(terminalId: terminal.id, status: .active)
    }

    func removeSession(terminalId: String) {
        if let container = activeSessions[terminalId] {
            container.removeFromSuperview()
            activeSessions.removeValue(forKey: terminalId)
        }
        displayStatuses.removeValue(forKey: terminalId)
        workingDirectories.removeValue(forKey: terminalId)
        gitStatusChecker.removePath(terminalId: terminalId)
        MCPConfigGenerator.removeConfig(terminalId: terminalId)
        try? sqliteStore.updateTerminalRuntimeStatus(id: terminalId, status: .suspended)
        notificationManager?.terminalStoppedWaiting(terminalId: terminalId)
    }

    func restartSession(terminalId: String) {
        guard let terminal = try? sqliteStore.fetchTerminal(id: terminalId),
              let track = try? sqliteStore.fetchTrack(id: terminal.trackId) else {
            return
        }

        if let existing = activeSessions[terminalId] {
            existing.removeFromSuperview()
            activeSessions.removeValue(forKey: terminalId)
        }

        let container = TerminalContainerView(frame: .zero)
        container.terminalId = terminalId
        container.delegate = self
        activeSessions[terminalId] = container

        let executable = "/bin/zsh"
        let mcpConfigPath = (try? MCPConfigGenerator.writeConfig(terminalId: terminalId)) ?? ""
        // Resume this terminal's exact conversation only if its transcript
        // actually exists on disk; otherwise fall back to --continue so a stale
        // or missing id never hard-fails the launch.
        let mode: ClaudeCommandBuilder.SessionMode
        if let sid = terminal.claudeSessionId, !sid.isEmpty,
           transcriptExists(sessionId: sid, repoPath: track.repoPath) {
            mode = .resume(sessionId: sid)
        } else {
            mode = .continueRecent
        }
        let command = ClaudeCommandBuilder.buildCommand(
            terminal: terminal,
            track: track,
            sessionMode: mode,
            mcpConfigPath: mcpConfigPath
        )
        let args = ["-l", "-c", command]
        let environment = ClaudeCommandBuilder.buildEnvironment(terminalId: terminalId)

        container.startProcess(executable: executable, args: args, environment: environment)

        try? sqliteStore.updateTerminalRuntimeStatus(id: terminalId, status: .live)
        displayStatuses[terminalId] = .active
        sidebarViewController?.updateStatus(terminalId: terminalId, status: .active)

        terminalAreaViewController?.showTerminal(container)
    }

    func updateWorkingDirectory(terminalId: String, path: String) {
        workingDirectories[terminalId] = path
        gitStatusChecker.setPath(terminalId: terminalId, path: path)
        // Update shell panel directory if this terminal is currently shown
        terminalAreaViewController?.updateShellDirectoryIfCurrent(terminalId: terminalId, path: path)
    }

    /// Injects a one-line message into every live Claude session belonging to a
    /// track, followed by Enter, so Claude receives it as if the user typed it.
    /// Used to inform running sessions when track settings change.
    func broadcastToTrackSessions(trackId: String, message: String) {
        guard let terminals = try? sqliteStore.fetchTerminals(forTrackId: trackId) else { return }
        // Single-line only: embedded newlines would submit prematurely in
        // Claude's TUI. Callers must pass a newline-free string.
        let line = message.replacingOccurrences(of: "\n", with: " ") + "\r"
        for terminal in terminals {
            guard let container = activeSessions[terminal.id] else { continue }
            container.terminalView.send(txt: line)
        }
    }

    // MARK: - Private

    /// Claude stores transcripts at ~/.claude/projects/<encoded-cwd>/<sessionId>.jsonl,
    /// where the cwd is encoded by replacing `/` and `.` with `-`. Sessions are
    /// launched with cwd = the track's repoPath (or home when empty).
    private func transcriptExists(sessionId: String, repoPath: String) -> Bool {
        let path = repoPath.isEmpty
            ? FileManager.default.homeDirectoryForCurrentUser.path
            : repoPath
        let encoded = path
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ".", with: "-")
        let transcript = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects/\(encoded)/\(sessionId).jsonl")
        return FileManager.default.fileExists(atPath: transcript.path)
    }

    private func setupGitStatusChecker() {
        gitStatusChecker.onStatusUpdate = { [weak self] terminalId, gitStatus in
            self?.sidebarViewController?.updateGitStatus(terminalId: terminalId, status: gitStatus)
        }
    }

    private func buildFallbackEnvironment(terminalId: String) -> [String] {
        var env: [String] = []
        let inherited = ["HOME", "PATH", "LANG", "USER", "SHELL"]
        for key in inherited {
            if let value = ProcessInfo.processInfo.environment[key] {
                env.append("\(key)=\(value)")
            }
        }
        env.append("TERM=xterm-256color")
        env.append("COLORTERM=truecolor")
        env.append("MYMUX_TERMINAL_ID=\(terminalId)")
        env.append("MYMUX_SOCKET_PATH=/tmp/mymux-ipc.sock")
        return env
    }
}

// MARK: - TerminalContainerViewDelegate

extension SessionManager: TerminalContainerViewDelegate {
    func terminalDidChangeStatus(_ container: TerminalContainerView, status: DisplayStatus) {
        let terminalId = container.terminalId
        let previousStatus = displayStatuses[terminalId]
        displayStatuses[terminalId] = status

        sidebarViewController?.updateStatus(terminalId: terminalId, status: status)

        if let nm = notificationManager {
            if status == .waiting {
                if let terminal = try? sqliteStore.fetchTerminal(id: terminalId) {
                    nm.terminalBecameWaiting(terminalId: terminalId, terminalName: terminal.name)
                }
            } else if previousStatus == .waiting {
                nm.terminalStoppedWaiting(terminalId: terminalId)
            }
        }
    }

    func terminalDidUpdateWorkingDirectory(_ container: TerminalContainerView, path: String) {
        updateWorkingDirectory(terminalId: container.terminalId, path: path)
    }

    func terminalDidExit(_ container: TerminalContainerView) {
        let terminalId = container.terminalId
        displayStatuses[terminalId] = .suspended
        sidebarViewController?.updateStatus(terminalId: terminalId, status: .suspended)
        try? sqliteStore.updateTerminalRuntimeStatus(id: terminalId, status: .suspended)

        // Show suspended placeholder only if this terminal is currently visible (force: false)
        terminalAreaViewController?.showSuspendedState(terminalId: terminalId) { [weak self] in
            self?.restartSession(terminalId: terminalId)
        }
    }
}
