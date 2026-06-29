import AppKit
import UserNotifications

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var sqliteStore: SQLiteStore?
    private var windowManager: WindowManager?
    private var sessionManager: SessionManager?
    private var notificationManager: NotificationManager?
    private var ipcListener: IPCListener?
    private var ipcMessageHandler: IPCMessageHandler?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 0. Force dark appearance (matches terminal emulator default)
        NSApp.appearance = NSAppearance(named: .darkAqua)

        // Build main menu (required for SPM executables — no bundle provides one)
        setupMainMenu()

        // 1. Initialize SQLiteStore
        let store: SQLiteStore
        do {
            store = try SQLiteStore()
            sqliteStore = store
        } catch {
            let alert = NSAlert()
            alert.messageText = "Database Error"
            alert.informativeText = "Failed to initialize the database: \(error.localizedDescription)\n\nThe application will quit."
            alert.alertStyle = .critical
            alert.runModal()
            NSApp.terminate(nil)
            return
        }

        // 2. Mark all previously-live terminals as suspended
        do {
            try store.markAllLiveTerminalsAsSuspended()
        } catch {
            print("Warning: Failed to mark terminals as suspended: \(error)")
        }

        // 3. Initialize NotificationManager
        let nm = NotificationManager()
        notificationManager = nm

        // 4. Guard UNUserNotificationCenter behind bundle identifier check
        if Bundle.main.bundleIdentifier != nil {
            let center = UNUserNotificationCenter.current()
            center.delegate = self
            nm.requestAuthorization()
        } else {
            print("No bundle identifier — skipping UNUserNotificationCenter setup")
        }

        // 5. Initialize SessionManager
        let sm = SessionManager(sqliteStore: store)
        sm.setNotificationManager(nm)
        sessionManager = sm

        // 6. Initialize IPCListener and IPCMessageHandler
        let ipcListener = IPCListener()
        self.ipcListener = ipcListener

        let handler = IPCMessageHandler(
            sqliteStore: store,
            notificationManager: nm,
            sessionManager: sm
        )
        ipcMessageHandler = handler

        // 7. Wire IPC pipeline
        ipcListener.onMessage = { [weak handler] terminalId, payload in
            return handler?.handleMessage(terminalId, payload: payload)
        }

        handler.onWorkingDirectorySet = { [weak sm] terminalId, path in
            sm?.updateWorkingDirectory(terminalId: terminalId, path: path)
        }

        // 8. Observe IPCResponse notifications for async request_user_input
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(ipcResponseReceived(_:)),
            name: NSNotification.Name("IPCResponse"),
            object: nil
        )

        // 9. Start IPC listener
        do {
            try ipcListener.start()
        } catch {
            print("Warning: Failed to start IPC listener: \(error)")
        }

        // 10. Initialize WindowManager and show main window
        let wm = WindowManager()
        windowManager = wm
        wm.showMainWindow(sqliteStore: store, sessionManager: sm)

        // Wire sidebar delegate
        if let sidebarVC = wm.mainSplitVC?.sidebarVC {
            sidebarVC.delegate = self
            sm.sidebarViewController = sidebarVC
        }

        // Wire terminal area (needed for suspended state and shell panel)
        sm.terminalAreaViewController = wm.mainSplitVC?.terminalAreaVC

        // 11. Install SessionStart hook
        installSessionStartHook()
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Mark all live terminals as suspended
        try? sqliteStore?.markAllLiveTerminalsAsSuspended()

        // Stop IPC listener (closes + unlinks socket)
        ipcListener?.stop()

        // Remove all MCP config files
        MCPConfigGenerator.removeAllConfigs()

        // Clear dock badge
        NSApp.dockTile.badgeLabel = nil
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    // MARK: - IPC Response Handler

    @objc private func ipcResponseReceived(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let terminalId = userInfo["terminalId"] as? String,
              let response = userInfo["response"] as? [String: Any] else { return }
        ipcListener?.sendResponse(terminalId: terminalId, message: response)
    }

    // MARK: - SessionStart Hook Installation

    private func installSessionStartHook() {
        // Find hook script path
        let hookPath = resolveHookScriptPath()
        guard let hookScriptPath = hookPath else {
            print("Warning: Could not find session-start.sh hook script")
            return
        }

        let settingsPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/settings.json")

        // Read existing settings (merge, do NOT overwrite)
        var settings: [String: Any] = [:]
        if let data = try? Data(contentsOf: settingsPath),
           let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            settings = existing
        }

        // Build hook config
        let hookEntry: [String: Any] = [
            "type": "command",
            "command": hookScriptPath,
            "timeout": 10
        ]
        let startupMatcher: [String: Any] = ["matcher": "startup", "hooks": [hookEntry]]
        let resumeMatcher: [String: Any] = ["matcher": "resume", "hooks": [hookEntry]]

        // Merge — preserve other hook types
        var hooks = settings["hooks"] as? [String: Any] ?? [:]
        hooks["SessionStart"] = [startupMatcher, resumeMatcher]
        settings["hooks"] = hooks

        // Write back
        do {
            // Ensure directory exists
            let settingsDir = settingsPath.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: settingsDir, withIntermediateDirectories: true)

            let data = try JSONSerialization.data(withJSONObject: settings, options: .prettyPrinted)
            try data.write(to: settingsPath)
            print("Installed SessionStart hook at \(hookScriptPath)")
        } catch {
            print("Warning: Failed to install SessionStart hook: \(error)")
        }
    }

    private func setupMainMenu() {
        let mainMenu = NSMenu()

        // App menu
        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu()
        appMenuItem.submenu = appMenu
        appMenu.addItem(NSMenuItem(title: "About mymux", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: ""))
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(title: "Hide mymux", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h"))
        let hideOthers = NSMenuItem(title: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(hideOthers)
        appMenu.addItem(NSMenuItem(title: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: ""))
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(title: "Quit mymux", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        // File menu
        let fileMenuItem = NSMenuItem()
        mainMenu.addItem(fileMenuItem)
        let fileMenu = NSMenu(title: "File")
        fileMenuItem.submenu = fileMenu
        fileMenu.addItem(NSMenuItem(title: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"))

        // Window menu
        let windowMenuItem = NSMenuItem()
        mainMenu.addItem(windowMenuItem)
        let windowMenu = NSMenu(title: "Window")
        windowMenuItem.submenu = windowMenu
        windowMenu.addItem(NSMenuItem(title: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m"))
        windowMenu.addItem(NSMenuItem(title: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: ""))
        windowMenu.addItem(.separator())
        windowMenu.addItem(NSMenuItem(title: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: ""))
        NSApp.windowsMenu = windowMenu

        NSApp.mainMenu = mainMenu
    }

    private func resolveHookScriptPath() -> String? {
        // 1. Bundle resource path
        if let resourcePath = Bundle.main.resourcePath {
            let path = (resourcePath as NSString).appendingPathComponent("hooks/session-start.sh")
            if FileManager.default.fileExists(atPath: path) { return path }
        }

        // 2. Relative to executable
        if let execURL = Bundle.main.executableURL {
            let candidates = [
                execURL.deletingLastPathComponent()
                    .appendingPathComponent("Resources/hooks/session-start.sh"),
                execURL.deletingLastPathComponent()
                    .deletingLastPathComponent()
                    .deletingLastPathComponent()
                    .appendingPathComponent("Resources/hooks/session-start.sh"),
                execURL.deletingLastPathComponent()
                    .deletingLastPathComponent()
                    .deletingLastPathComponent()
                    .appendingPathComponent("Mymux/Resources/hooks/session-start.sh"),
            ]
            for candidate in candidates {
                if FileManager.default.fileExists(atPath: candidate.path) { return candidate.path }
            }
        }

        // 3. cwd-relative
        let cwd = FileManager.default.currentDirectoryPath
        let cwdCandidates = [
            (cwd as NSString).appendingPathComponent("Resources/hooks/session-start.sh"),
            (cwd as NSString).appendingPathComponent("Mymux/Resources/hooks/session-start.sh"),
        ]
        for path in cwdCandidates {
            if FileManager.default.fileExists(atPath: path) { return path }
        }

        return nil
    }
}

// MARK: - SidebarViewControllerDelegate

extension AppDelegate: SidebarViewControllerDelegate {
    func sidebarDidSelectTerminal(_ terminalId: String?) {
        guard let terminalId = terminalId else {
            windowManager?.mainSplitVC?.terminalAreaVC.showEmptyState()
            return
        }

        let terminalAreaVC = windowManager?.mainSplitVC?.terminalAreaVC

        if let container = sessionManager?.activeSessions[terminalId] {
            terminalAreaVC?.showTerminal(container)
        } else {
            // force: true because user explicitly navigated to this terminal
            terminalAreaVC?.showSuspendedState(terminalId: terminalId, force: true) { [weak self] in
                self?.sessionManager?.restartSession(terminalId: terminalId)
            }
        }

        // Update activity panel and shell directory for the newly selected terminal
        terminalAreaVC?.updateActivityPanel(terminalId: terminalId)
        if let path = sessionManager?.workingDirectories[terminalId] {
            terminalAreaVC?.setCurrentWorkingDirectory(path)
        }
    }

    func sidebarDidRequestNewConsole(inTrackId trackId: String) {
        guard let store = sqliteStore,
              let sm = sessionManager,
              let track = try? store.fetchTrack(id: trackId) else { return }

        let existingCount = (try? store.fetchTerminals(forTrackId: trackId))?.count ?? 0
        let consoleName = existingCount == 0 ? "Console" : "Console \(existingCount + 1)"

        let terminal = Terminal(trackId: trackId, name: consoleName)
        do {
            try store.insertTerminal(terminal)
            sm.spawnSession(terminal: terminal, track: track)

            // Select the new terminal in sidebar
            windowManager?.mainSplitVC?.sidebarVC.selectTerminal(id: terminal.id)

            // Show in terminal area
            if let container = sm.activeSessions[terminal.id] {
                windowManager?.mainSplitVC?.terminalAreaVC.showTerminal(container)
            }
        } catch {
            print("Failed to create console: \(error)")
        }
    }

    func sidebarDidRequestNewTrack() {
        guard let store = sqliteStore,
              windowManager?.mainSplitVC?.view.window != nil else { return }

        let sheet = NewTrackSheet(sqliteStore: store)
        sheet.onCreated = { [weak self] track in
            print("Created track: \(track.name)")
            _ = self // silence unused warning
        }
        windowManager?.mainSplitVC?.presentAsSheet(sheet)
    }

    func sidebarDidRequestDeleteTrack(_ trackId: String) {
        guard let store = sqliteStore, let sm = sessionManager else { return }

        // Kill all active sessions for this track
        if let terminals = try? store.fetchTerminals(forTrackId: trackId) {
            for terminal in terminals {
                sm.removeSession(terminalId: terminal.id)
            }
        }

        do {
            try store.deleteTrack(id: trackId)
        } catch {
            print("Failed to delete track: \(error)")
        }
    }

    func sidebarDidRequestDeleteConsole(_ terminalId: String) {
        guard let store = sqliteStore, let sm = sessionManager else { return }
        sm.removeSession(terminalId: terminalId)
        do {
            try store.deleteTerminal(id: terminalId)
        } catch {
            print("Failed to delete terminal: \(error)")
        }
        windowManager?.mainSplitVC?.terminalAreaVC.showEmptyState()
    }

    func sidebarDidRequestRestartConsole(_ terminalId: String) {
        sessionManager?.restartSession(terminalId: terminalId)
    }

    func sidebarDidRequestRenameConsole(_ terminalId: String, newName: String) {
        do {
            try sqliteStore?.updateTerminalName(id: terminalId, name: newName)
        } catch {
            print("Failed to rename console: \(error)")
        }
    }

    func sidebarDidMoveTerminal(_ terminalId: String, toTrackId: String) {
        do {
            try sqliteStore?.updateTerminalTrack(terminalId: terminalId, newTrackId: toTrackId)
        } catch {
            print("Failed to move terminal: \(error)")
        }
    }

    func sidebarDidRequestSetLinearTicket(trackId: String, url: String?) {
        guard var track = try? sqliteStore?.fetchTrack(id: trackId) else { return }
        track.linearTicketUrl = url
        do {
            try sqliteStore?.updateTrack(track)
        } catch {
            print("Failed to update linear ticket: \(error)")
        }
    }
}

// MARK: - UNUserNotificationCenterDelegate

extension AppDelegate: UNUserNotificationCenterDelegate {
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        if let terminalId = userInfo["terminalId"] as? String {
            DispatchQueue.main.async { [weak self] in
                self?.windowManager?.focusTerminal(id: terminalId)
            }
        }
        completionHandler()
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}
