# Tasks: mymux — Multi-Session Claude Code Orchestrator

**Input**: Design documents from `/specs/001-mymux-app/`  
**Prerequisites**: plan.md ✅, spec.md ✅, research.md ✅, data-model.md ✅, contracts/ ✅

**Tests**: Verification tasks are REQUIRED per constitution Principle II (Test Before Done). Every user story includes a live `swift run` verification step. Compilation alone is NOT sufficient — observable runtime behavior is required.

**Organization**: Tasks are grouped by user story to enable independent implementation and testing of each story.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependencies)
- **[Story]**: Which user story this task belongs to (e.g., US1, US2)
- Include exact file paths in descriptions

---

## Phase 1: Setup (Project Initialization)

**Purpose**: Create project scaffolding and install all dependencies before any implementation begins.

- [x] T001 Create `Mymux/` SPM project with `Package.swift` declaring `.executableTarget(name: "Mymux")` with SwiftTerm and GRDB.swift dependencies, macOS 14 platform, path "Sources"
- [x] T002 [P] Create all Swift source directory structure under `Mymux/Sources/`: `App/`, `Views/`, `Services/`, `Models/`, `Utilities/`, and `Mymux/Resources/hooks/`
- [x] T003 [P] Create `mcp-server/` with `package.json` (name: mymux-mcp-server, type: module, deps: @modelcontextprotocol/sdk, zod; devDeps: esbuild, typescript), `tsconfig.json`, and `src/index.ts` stub
- [x] T004 Install MCP server Node.js dependencies and build the ESM bundle: `cd mcp-server && npm install && npm run build` producing `Mymux/Resources/mymux-mcp-server.mjs`
- [x] T005 Verify initial build: `cd Mymux && swift build` with empty stubs — fix any package resolution errors before proceeding

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: Core infrastructure that MUST be complete before ANY user story can be implemented.

**⚠️ CRITICAL**: No user story work can begin until this phase is complete.

- [x] T006 [P] Create all enum types in `Mymux/Sources/Models/DisplayStatus.swift`: `DisplayStatus` (active/thinking/waiting/suspended/completed), `RuntimeStatus` (live/suspended/completed), `TrackStatus` (active/archived) — all `String, Codable`
- [x] T007 [P] Create `Mymux/Sources/Utilities/StringExtensions.swift` with `toKebabCase()` on String: lowercase → replace `[^a-z0-9]+` with `-` → trim leading/trailing `-`
- [x] T008 [P] Create `Mymux/Sources/Utilities/RingBuffer.swift`: fixed-capacity (default 4096) circular byte buffer with `write(_ data: ArraySlice<UInt8>)` and `lastBytes(_ n: Int) -> [UInt8]`
- [x] T009 [P] Create `Mymux/Sources/Utilities/ANSIStripper.swift`: three compiled NSRegularExpression patterns (CSI `\x1b\[[0-9;]*[a-zA-Z]`, OSC-BEL `\x1b\][^\x07]*\x07`, OSC-ST `\x1b\][^\x1b]*\x1b\\`) applied sequentially in `strip(_ input: String) -> String`
- [x] T010 [P] Create all five GRDB model types in `Mymux/Sources/Models/`: `WorkTrack.swift`, `Terminal.swift` (with `toKebabCase()` in init for worktreeName), `ActivityLogEntry.swift`, `ReferenceFile.swift`, `TrackKeyword.swift` — all `Codable, FetchableRecord, PersistableRecord, Identifiable` with UUID string IDs and ISO8601 timestamps
- [x] T011 Create `Mymux/Sources/Services/SQLiteStore.swift` with GRDB `DatabasePool` at `~/.mymux/mymux.db`, three migrations (001_baseSchema creating work_tracks/terminals/reference_files/activity_log/indexes, 002_trackKeywords creating track_keywords, 003_worktreeName adding worktreeName column), `eraseDatabaseOnSchemaChange = true` in DEBUG, and CRUD methods for all entities
- [x] T012 Create `Mymux/Sources/main.swift`: explicit entry point — `NSApplication.shared`, create `AppDelegate`, set delegate, call `app.setActivationPolicy(.regular)` (CRITICAL: must be before `app.run()`), call `app.run()`
- [x] T013 Create `Mymux/Sources/App/AppDelegate.swift`: stub conforming to `NSApplicationDelegate`; `applicationDidFinishLaunching` initializes `SQLiteStore`, guards `UNUserNotificationCenter` behind `Bundle.main.bundleIdentifier != nil`, then calls `windowManager.showMainWindow()`
- [x] T014 Verify foundational build: `cd Mymux && swift build` passes with no errors — all model types and utilities compile cleanly

**Checkpoint**: Foundation ready — all user story phases can now begin.

---

## Phase 3: User Story 1 — Centralized Session Monitoring (Priority: P1) 🎯 MVP

**Goal**: Sidebar displays all sessions grouped by work tracks with live-updating colored status indicators. Developers can see the state of every session at a glance.

**Independent Test**: Launch app, create a track via the "+" button, add a console, type in the terminal, and observe the green active indicator. Stop typing and observe transition to thinking (blue pulse) within 3 seconds.

### Verification Tasks for US1 (REQUIRED — write verification criteria first)

- [x] T015 [US1] Document G1+G2 verification steps in `specs/001-mymux-app/checklists/requirements.md`: (1) `swift build` passes, (2) `swift run` shows window with sidebar+toolbar+terminal area, (3) creating a track via "+" shows it in sidebar, (4) adding a console starts a terminal session, (5) terminal output → green dot within 1s, (6) silence >3s → blue pulse or amber dot

### Implementation for US1

- [x] T016 [US1] Create `Mymux/Sources/Views/StatusDotView.swift`: custom NSView (12×12pt) rendering colored circles per `DisplayStatus` — green fill (active), blue fill with `sin(t*3)` alpha pulse at 30fps timer (thinking), amber fill + stroked ring (waiting), gray open circle (suspended), dim checkmark (completed)
- [x] T017 [US1] Create `Mymux/Sources/Services/PTYOutputMonitor.swift`: owns a `RingBuffer`, `lastOutputTimestamp`, and 500ms `DispatchSourceTimer` on a dedicated queue; `dataReceived(_ slice: ArraySlice<UInt8>)` updates ring buffer + timestamp; timer evaluates: any output within 1s → active, 1–3s silence → thinking, >3s silence + `ANSIStripper` + prompt regex match → waiting; `onStatusChanged: ((DisplayStatus) -> Void)?` fires on main thread on transitions
- [x] T018 [US1] Create `Mymux/Sources/Views/TerminalContainerView.swift` containing `MymuxTerminalView` (subclasses `LocalProcessTerminalView`, overrides `dataReceived(slice:)` to call `super` then `outputMonitor?.dataReceived(slice)`); `TerminalContainerView` is an NSView owning the terminal view and a `PTYOutputMonitor` instance
- [x] T019 [US1] Create `Mymux/Sources/Views/SidebarViewController.swift`: NSOutlineView with `.sourceList` style, no header, two-level data source (WorkTrack root items, Terminal children); each terminal row shows `StatusDotView` + name; each track header shows name + "⊕" button + attention badge count; `ValueObservation` on work_tracks + terminals drives `reloadData()`
- [x] T020 [US1] Create `Mymux/Sources/Services/SessionManager.swift`: holds `[String: TerminalContainerView]` for active sessions; `spawnSession(terminal:track:)` builds command via `ClaudeCommandBuilder` (stub for now), calls `terminalView.startProcess(executable:args:environment:execName:)`; wires `PTYOutputMonitor.onStatusChanged` to update in-memory status and call `sidebarDelegate?.statusChanged(terminalId:status:)`
- [x] T021 [US1] Create `Mymux/Sources/Views/MainSplitViewController.swift`: `NSSplitViewController` with two `NSSplitViewItem(viewController:)` items — sidebar (220–500px) and terminal area; terminal area uses constraint-based layout with `TerminalContainerView` filling center, activity panel placeholder at right (250px, togglable width), and `ToolbarButton` stubs for shell+activity toggles
- [x] T022 [US1] Create `Mymux/Sources/App/WindowManager.swift`: creates `NSWindow` (1200×800, titled/closable/miniaturizable/resizable), sets `contentViewController` to `MainSplitViewController`, calls `center()` + `makeKeyAndOrderFront(nil)`; `showMainWindow()` entry point called from `AppDelegate`
- [x] T023 [US1] Wire `AppDelegate.applicationDidFinishLaunching` to: init `SQLiteStore` → init `SessionManager` → init `WindowManager` → call `windowManager.showMainWindow()`; terminal area shows empty state ("Create a track and add a console to get started") when no terminal is selected

**Checkpoint**: G1 + G2 pass. Create a track, add a console — status dot cycles through active/thinking/waiting as Claude types and pauses. Sidebar is live. This is the MVP.

---

## Phase 4: User Story 2 — Native Notifications (Priority: P2)

**Goal**: macOS notifications fire when any session enters waiting state. Dock badge shows total waiting count. Clicking a notification focuses the relevant session.

**Independent Test**: Create a console, switch focus to another app, wait for the session to reach waiting state, observe macOS notification and dock badge, click notification, verify the correct session is focused in mymux.

### Verification Tasks for US2

- [x] T024 [US2] Add G4 verification step to checklists/requirements.md: (1) status dot → waiting fires a macOS notification visible in Notification Center, (2) dock badge shows count of waiting sessions, (3) clicking notification brings window to front with correct session selected, (4) session transitions out of waiting → badge count decreases

### Implementation for US2

- [x] T025 [US2] Create `Mymux/Sources/Services/NotificationManager.swift`: `canSendNotifications` guard (`Bundle.main.bundleIdentifier != nil`); `requestAuthorization` in `AppDelegate`; `terminalBecameWaiting(terminalId:terminalName:)` fires `UNNotificationRequest` with id `waiting-<terminalId>` (once per waiting cycle — debounced via `notifiedTerminals: Set<String>`); `terminalStoppedWaiting(terminalId:)` removes from both sets; `updateDockBadge()` sets `NSApp.dockTile.badgeLabel`; `sendCustomNotification(message:urgency:terminalId:)` for `notify_user` MCP tool
- [x] T026 [US2] Wire `PTYOutputMonitor.onStatusChanged` → `NotificationManager` in `SessionManager`: when status → `.waiting`, call `notificationManager.terminalBecameWaiting`; when status leaves `.waiting`, call `notificationManager.terminalStoppedWaiting`
- [x] T027 [US2] Implement `UNUserNotificationCenterDelegate.userNotificationCenter(_:didReceive:withCompletionHandler:)` in `AppDelegate`: extract `terminalId` from `userInfo`, call `windowManager.focusTerminal(id:)` which selects the terminal in the sidebar and brings window to front
- [x] T028 [US2] Wire `AppDelegate.applicationDidFinishLaunching` to call `notificationManager.requestAuthorization()` (guarded by bundle ID check); implement `focusTerminal(id:)` in `WindowManager` to select the terminal row in `SidebarViewController` and make window key

**Checkpoint**: G2 + G4 pass. Notifications fire on waiting transitions, dock badge is accurate, notification click focuses session.

---

## Phase 5: User Story 3 — Work Track & Console Management (Priority: P3)

**Goal**: Full CRUD for tracks and consoles. Drag-and-drop between tracks. Context menus. "Restart" for suspended terminals.

**Independent Test**: Create a track with name+repo path, add two consoles, right-click to rename one, drag one to a new track, delete the original track and confirm all its consoles are removed.

### Verification Tasks for US3

- [x] T029 [US3] Add US3 verification steps to checklists/requirements.md: (1) "+" top button → NewTrackSheet appears → fill name+path → track in sidebar, (2) per-track "⊕" → new console row, (3) right-click console → "Delete Console" → row removed + process killed, (4) right-click track → "Delete Track" → confirmation → track + all consoles removed, (5) drag console to another track → console moves

### Implementation for US3

- [x] T030 [US3] Create `Mymux/Sources/Views/NewTrackSheet.swift`: `NSViewController` presented as sheet on main window; form with NSTextField (Name, required), NSTextField+NSButton (Repository Path, with directory picker using `NSOpenPanel`), NSTextField (Branch, optional), NSTextView (Context Notes, optional); "Create" button writes to `SQLiteStore.insertTrack()` and dismisses
- [x] T031 [US3] Add context menu support to `SidebarViewController` via `NSMenuDelegate`: track header right-click shows "New Console", "Delete Track"; terminal row right-click shows "New Console", "Delete Console", "Restart" (only when suspended); "Delete Track" presents `NSAlert` confirmation before calling `SQLiteStore.deleteTrack(id:)` (cascade deletes terminals); "Delete Console" calls `SessionManager.removeSession(terminalId:)` + `SQLiteStore.deleteTerminal(id:)`
- [x] T032 [US3] Add drag-and-drop to `SidebarViewController`: register `NSOutlineView` for `.string` drag type; `outlineView(_:pasteboardWriterForItem:)` writes terminal ID string; `outlineView(_:validateDrop:proposedItem:proposedChildIndex:)` accepts drop onto track items only; `outlineView(_:acceptDrop:item:childIndex:)` calls `SQLiteStore.updateTerminalTrack(terminalId:newTrackId:)` and refreshes sidebar
- [x] T033 [US3] Add "⊕" per-track button action in `SidebarViewController`: creates `Terminal` record in `SQLiteStore` with name "Console", worktreeName = "console", then calls `SessionManager.spawnSession(terminal:track:)`; add "+" top-level button action to present `NewTrackSheet` as sheet

**Checkpoint**: Full CRUD working. Track creation, console creation, drag-and-drop, delete with confirmation all verified in live app.

---

## Phase 6: User Story 4 — MCP Tool Integration (Priority: P4)

**Goal**: Each Claude Code session receives 5 MCP tools via the bundled Node.js server. Claude can log activity, update its title, notify the user, set its working directory, and request user input via native dialogs.

**Independent Test**: Start a console, let Claude's system prompt trigger `set_working_directory`, observe git status appearing in the sidebar within 10s, then verify `log_activity` produces an entry in the Activity Log Panel.

### Verification Tasks for US4

- [x] T034 [US4] Add G3+G5 verification steps to checklists/requirements.md: (1) spawning a console → MCP server connects → `hello` sent → `hello_ack` logged, (2) Claude calls `set_working_directory` → git status appears in sidebar, (3) Claude calls `log_activity` → entry visible in Activity Log Panel, (4) `request_user_input` → NSAlert sheet appears on main window within 500ms

### Implementation for US4

- [x] T035 [US4] Implement the full MCP server in `mcp-server/src/index.ts`: UDS client using `net.createConnection` to `MYMUX_SOCKET_PATH`; `hello` handshake on connect; exponential backoff reconnect (1s → 10s max); `sendIPCAndWait()` with `req_id` correlation and 30s timeout; all 5 MCP tools (`set_working_directory`, `log_activity`, `set_terminal_title`, `notify_user`, `request_user_input`) wired to IPC messages; `await server.connect(new StdioServerTransport())` — rebuild with `npm run build` in mcp-server/
- [x] T036 [US4] Create `Mymux/Sources/Services/IPCListener.swift`: POSIX `socket`/`bind`/`listen` (NOT Network.framework); `unlink()` before `bind()` and in `stop()`; `DispatchSource.makeReadSource` for server FD (accept) and each client FD (read); `connectionBuffers: [Int32: String]` for NDJSON partial-line accumulation; split on `\n`, call `processLine(_:fromFD:)`; first-wins `hello` association (`connections[terminalId] = fd` only if nil); `writeJSON(_:toFD:)` serializes with trailing `\n`; `var onMessage: ((String, [String: Any]) -> [String: Any]?)?`
- [x] T037 [US4] Create `Mymux/Sources/Services/IPCMessageHandler.swift`: handles `log_activity` (writes to `SQLiteStore`), `set_terminal_title` (updates `Terminal.name` + `worktreeName` in DB), `set_working_directory` (posts to `SessionManager.workingDirectories`), `notify_user` (calls `NotificationManager.sendCustomNotification`), `request_user_input` (presents `NSAlert` sheet on main thread, 5-min timeout via `DispatchWorkItem`, posts `NSNotification("IPCResponse")` on answer/timeout)
- [x] T038 [US4] Create `Mymux/Sources/Services/MCPConfigGenerator.swift`: writes per-terminal JSON config to `/tmp/mymux-mcp/mcp-<uuid>.json` with permissions `0o600`; resolves `mymux-mcp-server.mjs` path (bundle → relative to exe → cwd/Resources → cwd/Mymux/Resources); `removeConfig(terminalId:)` and `removeAllConfigs()` for cleanup
- [x] T039 [US4] Create `Mymux/Sources/Services/ClaudeCommandBuilder.swift`: builds `cd "<repoPath>" && claude [--continue] --worktree "<worktreeName>" --mcp-config "<configPath>" --allowedTools "mcp__mymux__*" --system-prompt "<prompt>"`; `buildEnvironment(terminalId:)` returns `["HOME=...", "PATH=...", "TERM=xterm-256color", "COLORTERM=truecolor", "MYMUX_TERMINAL_ID=<uuid>", "MYMUX_SOCKET_PATH=/tmp/mymux-ipc.sock"]`; `buildSystemPrompt(track:terminal:)` builds the full system prompt from template; `shellEscape()` double-quotes with `\ " $ \`` escaping
- [x] T040 [US4] Create `Mymux/Resources/hooks/session-start.sh`: reads Claude's stdin JSON with `python3 -c "import sys,json; print(json.load(sys.stdin).get('cwd',''))"`, sends `set_working_directory` IPC message via Python3 socket connection using `MYMUX_TERMINAL_ID` and `MYMUX_SOCKET_PATH` env vars; exit 0 always
- [x] T041 [US4] Wire full IPC pipeline in `AppDelegate`: init `IPCListener` → set `onMessage` to `ipcMessageHandler.handleMessage`; observe `NSNotification("IPCResponse")` → call `ipcListener.sendResponse(terminalId:message:)`; call `ipcListener.start()`; call `installSessionStartHook()` (reads+merges `~/.claude/settings.json`, adds `SessionStart` hook with `startup` and `resume` matchers pointing to `session-start.sh`; CRITICAL: merge, do NOT overwrite)
- [x] T042 [US4] Update `SessionManager.spawnSession` to use `ClaudeCommandBuilder` + `MCPConfigGenerator`: generate MCP config → build command → start terminal process with full environment; verify MCP config file exists at `/tmp/mymux-mcp/mcp-<uuid>.json` before spawning

**Checkpoint**: G3 pass. Spawning a console triggers MCP server connection, `hello`/`hello_ack` handshake completes, `set_working_directory` effect is visible.

---

## Phase 7: User Story 5 — Activity Log Panel (Priority: P5)

**Goal**: Right-side panel shows chronological timestamped log entries for the selected console, updating in real-time as Claude calls `log_activity`.

**Independent Test**: Select a console with logged entries, verify entries appear with `HH:mm:ss` timestamps. Switch to another console, verify log switches. Have Claude call `log_activity` while panel is open and verify the entry appears without a manual refresh.

### Verification Tasks for US5

- [x] T043 [US5] Add G5 verification steps to checklists/requirements.md: (1) `log_activity` IPC message → entry appears in Activity Log Panel in real-time, (2) switching selected console → panel shows that console's entries, (3) no console selected → "Select a console to see activity" shown, (4) console with no entries → "No activity logged yet" shown, (5) panel toggle button hides/shows panel without affecting terminal

### Implementation for US5

- [x] T044 [US5] Create `Mymux/Sources/Views/ActivityPanelView.swift`: NSView (250px default width) containing an NSTableView or NSScrollView+NSStackView for log entries; each entry row shows `HH:mm:ss` timestamp label + message text (auto-growing height for long messages); uses GRDB `ValueObservation` filtered by current `terminalId` ordered by `createdAt ASC` limit 100 for real-time updates; empty state labels for "Select a console" and "No activity logged yet"
- [x] T045 [US5] Wire `ActivityPanelView` into `MainSplitViewController`/`TerminalAreaViewController`: right-side constraint-based layout at 250px; `panelWidthConstraint` animates between 250 and 0 on toggle; toolbar toggle button calls `toggleActivityPanel()`; panel switches `terminalId` when `SidebarViewController` selection changes
- [ ] T046 [US5] Verify `IPCMessageHandler.handleMessage(log_activity)` writes `ActivityLogEntry` to `SQLiteStore` and the `ValueObservation` in `ActivityPanelView` fires; confirm real-time update in live `swift run` session

**Checkpoint**: G5 pass. `log_activity` call produces visible entry in panel in real-time.

---

## Phase 8: User Story 6 — Git Dirty Indicators (Priority: P6)

**Goal**: Sidebar shows amber terminal name, `+N -M` diff summary, and `N↑` ahead count for terminals with known working directories and uncommitted changes.

**Independent Test**: Start a console in a git repository, wait for `set_working_directory` to be called, modify a tracked file, observe the amber indicator and diff summary appear in the sidebar within 10 seconds.

### Verification Tasks for US6

- [x] T047 [US6] Add US6 verification steps to checklists/requirements.md: (1) working directory known + dirty worktree → console name turns amber within 10s, (2) `+N -M` diff shown inline, (3) `N↑` shown when commits ahead of upstream, (4) clean worktree → no indicators shown, (5) unknown working directory → no git indicators shown at all

### Implementation for US6

- [x] T048 [US6] Create `Mymux/Sources/Models/` `GitStatus.swift` struct: `isDirty: Bool`, `linesAdded: Int`, `linesRemoved: Int`, `commitsAhead: Int`; static `clean` constant — defined in `SidebarViewController.swift` (file-scope, accessible across module)
- [x] T049 [US6] Create `Mymux/Sources/Services/GitStatusChecker.swift`: `.utility` QoS `DispatchQueue`; `DispatchSourceTimer` firing every 10s; `setPath(terminalId:path:)` / `removePath(terminalId:)` API; for each terminal: runs `git status --porcelain`, `git diff --numstat HEAD`, `git rev-list --count @{u}..HEAD`; `onStatusUpdate: ((String, GitStatus) -> Void)?` fires on main thread per-terminal
- [x] T050 [US6] Wire `GitStatusChecker` into `SessionManager`: `updateWorkingDirectory` calls `gitStatusChecker.setPath(terminalId:path:)`; `onStatusUpdate` calls `sidebarViewController.updateGitStatus(terminalId:status:)` and `terminalAreaViewController.updateShellDirectoryIfCurrent(terminalId:path:)`
- [x] T051 [US6] Update `SidebarViewController` terminal row rendering to show git indicators: amber `NSColor.systemOrange` for dirty terminal name; `+N -M` label; `N↑` label; `updateGitStatus(terminalId:status:)` public method added

**Checkpoint**: Git indicators appear within 10s of a file change for terminals with known working directories.

---

## Phase 9: User Story 7 — Shell Terminal Panel (Priority: P7)

**Goal**: Tabbed shell panel below the Claude terminal, starting in the console's working directory. Closing the last tab auto-collapses the panel. Hidden panel preserves running shells.

**Independent Test**: Select a console with a known working directory, click the shell toggle button, observe the shell panel open with a shell running in the correct directory (`pwd` returns the worktree path), add a second tab, close both tabs and observe auto-collapse.

### Verification Tasks for US7

- [x] T052 [US7] Add US7 verification steps to checklists/requirements.md: (1) shell toggle opens panel with tab bar + shell running in worktree directory, (2) "+" button adds new shell tab, (3) "×" button closes tab → last tab → panel auto-collapses, (4) hide panel → shell continues running → show panel → same shell state, (5) shell panel button is a no-op when working directory is unknown

### Implementation for US7

- [x] T053 [US7] Create `Mymux/Sources/Views/ShellTerminalPanelView.swift`: NSView with 28px tab bar at top and content area below; tab bar contains NSSegmentedControl (tabs) + "+" add button + "×" close button; each tab owns a `LocalProcessTerminalView` spawned with `$SHELL -l`, `cd "<path>" && clear\n` on open; `onAllTabsClosed: (() -> Void)?` fires when last tab closed
- [x] T054 [US7] Wire `ShellTerminalPanelView` into `TerminalAreaViewController` constraint-based layout: `shellPanelHeightConstraint` animates 0 ↔ 250; two mutually exclusive bottom constraints; `onAllTabsClosed` collapses panel automatically
- [x] T055 [US7] Guard shell panel open against unknown working directory: alert shown if `shellPanel.workingDirectory == nil`; `ensureTabOpen()` opens first tab on initial show

**Checkpoint**: Shell panel opens in correct directory, tabs work, auto-collapse on last tab close confirmed in live app.

---

## Phase 10: User Story 8 — Session Persistence & Restart (Priority: P8)

**Goal**: All tracks and terminals survive app restarts. Suspended terminals show a Restart button. Restart resumes Claude with `--continue` and the named worktree.

**Independent Test**: Create a track and two consoles, let them reach active state, quit the app, relaunch, observe both consoles appear as suspended (gray circles), click Restart on one, observe the session resume with a new Claude Code conversation using `--continue`.

### Verification Tasks for US8

- [x] T056 [US8] Add G6 verification steps to checklists/requirements.md: (1) quit app with active terminals → all appear suspended on relaunch, (2) selecting suspended terminal → shows "Session Suspended" placeholder with "Restart" button, (3) "Restart" → new Claude Code process starts with `--continue`, (4) restarted session calls `set_working_directory` automatically (via SessionStart hook), (5) IPC socket and MCP config files cleaned up on shutdown

### Implementation for US8

- [x] T057 [US8] Add `markAllLiveTerminalsAsSuspended()` to `SQLiteStore`: `UPDATE terminals SET runtimeStatus = 'suspended' WHERE runtimeStatus = 'live'`; call from `AppDelegate.applicationDidFinishLaunching` before populating sidebar
- [x] T058 [US8] Fix `showSuspendedState` guard: added `force: Bool = false` parameter; AppDelegate passes `force: true` for explicit user navigation; SessionManager uses default `force: false` (only shows if terminal is currently visible)
- [x] T059 [US8] Implement `AppDelegate.applicationWillTerminate`: set `runtimeStatus = .suspended` for all live terminals in `SQLiteStore`; call `ipcListener.stop()` (closes + unlinks socket); call `MCPConfigGenerator.removeAllConfigs()` (removes `/tmp/mymux-mcp/`); clear dock badge (`NSApp.dockTile.badgeLabel = nil`)
- [x] T060 [US8] Populate sidebar from database on app launch in `SidebarViewController`'s initial `ValueObservation` start — all persisted tracks and terminals appear; suspended terminals show `DisplayStatus.suspended` (gray open circle) without trying to start a process; `SessionManager` does NOT spawn processes for suspended terminals on launch

**Checkpoint**: G6 pass. Quit + relaunch shows all tracks and terminals with suspended state. Restart resumes conversation.

---

## Final Phase: Polish & Cross-Cutting Concerns

**Purpose**: Final wiring, edge cases, cleanup, and end-to-end validation.

- [x] T061 [P] Add track collapse/expand state persistence in `SidebarViewController`: save expanded track IDs to `UserDefaults`, restore on launch
- [x] T062 [P] Wire `Mymux/Sources/Utilities/FuzzyMatcher.swift` (Levenshtein + substring): implement if needed for future console search; stub out now to satisfy compilation
- [x] T063 [P] Ensure IPC socket cleanup: verify `IPCListener.stop()` calls `unlink(socketPath)` and that stale sockets from crashed runs are removed by `unlink()` at startup in `IPCListener.start()`
- [x] T064 Add proper empty state to `TerminalAreaViewController` when no terminal is selected: centered NSLabel "Create a track and add a console to get started"
- [ ] T065 Run full end-to-end validation using `quickstart.md` steps: build MCP server (`npm run build`), `swift build` (G1), `swift run` (G2), create track+console (G3 IPC handshake + `set_working_directory`), observe status dot (G4), check activity log (G5), quit+relaunch+restart (G6) — all six gates must pass

---

## Dependencies & Execution Order

### Phase Dependencies

- **Phase 1 (Setup)**: No dependencies — start immediately
- **Phase 2 (Foundational)**: Depends on Phase 1 completion — BLOCKS all user stories
- **Phase 3–10 (User Stories)**: All depend on Phase 2 completion; can proceed in priority order
- **Final Phase (Polish)**: Depends on all user story phases being complete

### User Story Dependencies

| Story | Depends On | Integration Notes |
|-------|-----------|-------------------|
| US1 — Monitoring | Foundational only | Core — all other stories layer on top |
| US2 — Notifications | US1 (status transitions needed) | Adds notification side-effects to US1 status changes |
| US3 — CRUD | US1 (sidebar + session spawning) | Enriches existing sidebar with full CRUD |
| US4 — MCP Tools | US1 (session spawning), US3 (titles via set_terminal_title) | Requires IPCListener wired before MCP config written |
| US5 — Activity Log | US4 (log_activity IPC message must arrive) | Purely additive panel |
| US6 — Git Status | US4 (set_working_directory IPC message must arrive) | Purely additive sidebar decoration |
| US7 — Shell Panel | US4 (working directory needed for shell cwd) | Independent panel, no story cross-dependency |
| US8 — Persistence | All stories (persists state across restarts) | Restart requires ClaudeCommandBuilder from US4 |

### Within Each User Story

- Verification criteria documented BEFORE implementation begins
- Models before services, services before UI wiring
- Each story tested in live `swift run` before proceeding to next

---

## Parallel Opportunities

### Phase 1 (Setup)
T002, T003 can run in parallel after T001.

### Phase 2 (Foundational)
T006, T007, T008, T009, T010 can all run in parallel (different files). T011 (SQLiteStore) depends on T010 models. T012+T013+T014 depend on T011.

### Phase 6 (MCP Tools — largest phase)
T035 (MCP server TypeScript) is fully independent — write and build while working on T036+T037+T038+T039+T040 in Swift.

```bash
# Parallel launch for Phase 6:
Agent A: Implement mcp-server/src/index.ts (T035) — pure TypeScript, no Swift deps
Agent B: Implement IPCListener.swift (T036) — pure POSIX socket, no MCP deps
Agent C: Implement ClaudeCommandBuilder.swift (T039) + MCPConfigGenerator.swift (T038)
```

---

## Implementation Strategy

### MVP First (User Story 1 Only)

1. Complete Phase 1: Setup (T001–T005)
2. Complete Phase 2: Foundational (T006–T014)
3. Complete Phase 3: User Story 1 (T015–T023)
4. **STOP and VALIDATE**: G1 + G2 pass, status dots cycle in sidebar
5. This alone delivers the core value proposition

### Incremental Delivery

1. Setup + Foundational → skeleton app runs
2. US1 → MVP: centralized monitoring (status dots live)
3. US2 → notifications + dock badge
4. US3 → full CRUD management
5. US4 → MCP tools + IPC (enables US5 + US6)
6. US5 → activity log panel
7. US6 → git dirty indicators
8. US7 → shell panel
9. US8 → persistence + restart

---

## Notes

- `[P]` tasks = different files, no blocking dependencies — safe to parallelize
- `[Story]` label maps each task to a user story for traceability
- Every user story has a **verification** task (T015, T024, T029, T034, T043, T047, T052, T056) — write these BEFORE implementing
- `swift build` after every non-trivial change; `swift run` at every phase checkpoint
- Never declare a task complete without live observable behavior confirmed in `swift run`
- Key CRITICAL notes from research.md: `@main` → use explicit `main.swift`; `setActivationPolicy(.regular)` before `app.run()`; bundle ID guard on `UNUserNotificationCenter`; POSIX sockets NOT Network.framework; `NSSplitViewItem(viewController:)` NOT `sidebarWithViewController`; constraint layout inside terminal area NOT nested NSSplitView; ESM format (`--format=esm`) for MCP server build
