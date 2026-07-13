# Feature Specification: mymux — Multi-Session Claude Code Orchestrator

**Feature Branch**: `001-mymux-app`  
**Created**: 2026-06-29  
**Status**: Draft  
**Input**: User description: "read the founding docs in ./founding-docs and create a sepcification based on those documents"

## User Scenarios & Testing *(mandatory)*

### User Story 1 — Centralized Session Monitoring (Priority: P1)

A developer running 3–10 concurrent Claude Code sessions across multiple projects needs a single view showing the status of every session at a glance — without manually switching between terminal tabs. The sidebar displays all sessions grouped into named work tracks, with colored status indicators showing whether each session is active, thinking, waiting for input, suspended, or completed. Track headers show an attention badge count visible even when the track is collapsed.

**Why this priority**: Without centralized monitoring, the entire value proposition of running agents in parallel collapses. This is the foundational feature all others build on.

**Independent Test**: Can be tested by launching the app with zero prior data, creating a track, adding a console session, and observing the sidebar update live as the session's state changes.

**Acceptance Scenarios**:

1. **Given** the app is open with at least one active console, **When** the Claude Code session produces output, **Then** the sidebar shows a green indicator for that console within 1 second.
2. **Given** a session has been silent for several seconds and shows a prompt, **When** the developer looks at the sidebar, **Then** the console row shows an amber indicator and an attention badge.
3. **Given** two sessions in different tracks are both waiting for input, **When** the developer looks at the collapsed track headers, **Then** each track header shows its own waiting count badge without requiring expansion.
4. **Given** no console is selected, **When** the developer opens the app, **Then** the center area shows an instructional empty state.

---

### User Story 2 — Native Notifications When Sessions Need Attention (Priority: P2)

A developer working in another application is notified via macOS notifications and a dock badge whenever any Claude Code session transitions to the waiting state. Clicking a notification focuses the relevant session in the app. The dock badge shows the total count of all sessions currently awaiting input.

**Why this priority**: Without background notifications, developers must be watching the app continuously, defeating the purpose of parallel agent execution.

**Independent Test**: Can be tested by launching a console, switching focus to another application, observing that a macOS notification appears when the session reaches the waiting state, and verifying clicking the notification brings the correct session into focus.

**Acceptance Scenarios**:

1. **Given** a console transitions to the waiting state, **When** the app is in the background, **Then** a macOS notification appears with the session name and a message indicating it is waiting for input.
2. **Given** multiple sessions are waiting, **When** the developer looks at the dock, **Then** the dock icon shows a numeric badge equal to the count of waiting sessions.
3. **Given** a session stops waiting (user provides input), **When** the state transitions away from waiting, **Then** the dock badge count decreases accordingly.
4. **Given** the developer clicks a notification, **When** the app comes to the foreground, **Then** the relevant session is focused and visible in the terminal area.

---

### User Story 3 — Work Track & Console Management (Priority: P3)

A developer organizes Claude Code sessions into logical named groups ("work tracks") tied to a repository and optional branch. Within a track, consoles can be created, renamed, deleted, and reorganized. The sidebar shows all tracks and their consoles. Right-clicking a track or console presents contextual actions. Consoles can be dragged between tracks.

**Why this priority**: Without organization, 10+ sessions become unmanageable noise. Work tracks provide the mental model developers need.

**Independent Test**: Can be tested by creating a track, adding two consoles, right-clicking to rename one, dragging it to a new track, and deleting the original track to confirm all its consoles are removed.

**Acceptance Scenarios**:

1. **Given** the sidebar is empty, **When** the developer clicks the top "+" button and fills the form, **Then** a new named track appears in the sidebar.
2. **Given** a track exists, **When** the developer clicks the per-track "+" button, **Then** a new console session starts within that track.
3. **Given** a console exists in Track A, **When** the developer drags it to Track B, **Then** the console appears under Track B and disappears from Track A.
4. **Given** a track has multiple consoles, **When** the developer right-clicks the track header and selects "Delete Track," **Then** a confirmation appears, and confirming removes the track and all its consoles.
5. **Given** a console exists, **When** the developer right-clicks and selects "Delete Console," **Then** the session is terminated and the row is removed from the sidebar.

---

### User Story 4 — MCP Tool Integration (Priority: P4)

Each Claude Code session has access to five MCP tools that let it interact with the mymux app: reporting its working directory, logging activity milestones, updating its sidebar title, sending notifications, and requesting structured user input. Claude is instructed to call `set_working_directory` first on every startup.

**Why this priority**: MCP tools turn Claude from a passive process into an active orchestration participant, enabling activity logs, git status checks, and user input dialogs.

**Independent Test**: Can be tested by starting a console, waiting for Claude to call `set_working_directory`, and verifying git status indicators appear in the sidebar and the activity log reflects any `log_activity` calls.

**Acceptance Scenarios**:

1. **Given** a console starts, **When** Claude calls `set_working_directory`, **Then** git status indicators appear for that console's row in the sidebar.
2. **Given** Claude calls `log_activity` with a message, **When** the developer views the Activity Log Panel for that console, **Then** the message appears with a timestamp.
3. **Given** Claude calls `set_terminal_title`, **When** the sidebar updates, **Then** the console row shows the new title.
4. **Given** Claude calls `request_user_input` with a question and options, **When** the dialog appears, **Then** the user can select an option and Claude receives the response. If the user does not respond within 5 minutes, Claude receives a timeout error.
5. **Given** Claude calls `notify_user` with urgency "critical," **When** the notification fires, **Then** the dock bounces in addition to the macOS notification.

---

### User Story 5 — Activity Log Panel (Priority: P5)

A developer reviewing a console's progress can open the Activity Log Panel on the right side of the window. It shows a chronological, timestamped list of messages Claude has explicitly logged. The panel updates in real-time and switches content when the developer selects a different console.

**Why this priority**: The activity log provides a scannable progress record without requiring developers to read through dense terminal output.

**Independent Test**: Can be tested by selecting a console with logged activity and verifying entries appear, then switching to another console and verifying the log content changes.

**Acceptance Scenarios**:

1. **Given** a console has activity entries, **When** the developer selects that console, **Then** the activity panel shows all entries in chronological order with `HH:mm:ss` timestamps.
2. **Given** Claude logs a new activity entry while the panel is open, **When** the entry is written, **Then** it appears in the panel in real-time without a manual refresh.
3. **Given** no console is selected, **When** the developer looks at the activity panel, **Then** it shows "Select a console to see activity."
4. **Given** a console has no activity entries when selected, **Then** the panel shows "No activity logged yet."
5. **Given** the panel is visible, **When** the developer clicks the activity toggle button, **Then** the panel collapses without affecting the terminal or sidebar.

---

### User Story 6 — Git Dirty Indicators (Priority: P6)

Developers see inline git status indicators next to each console in the sidebar: amber text when there are uncommitted changes, a diff summary (lines added/removed), and an ahead count (commits not yet pushed). Indicators only appear for consoles whose working directory is known.

**Why this priority**: Developers managing multiple feature branches need to know which sessions have outstanding work at a glance without running git commands.

**Independent Test**: Can be tested by starting a console in a git repository, modifying a file, and verifying the sidebar shows dirty indicators for that console within the polling interval.

**Acceptance Scenarios**:

1. **Given** a console's working directory is known and the worktree has uncommitted changes, **When** the git status updates, **Then** the console name appears in amber.
2. **Given** a worktree has 42 lines added and 7 removed vs HEAD, **When** displayed in the sidebar, **Then** the indicator shows `+42 -7`.
3. **Given** a worktree has 3 commits ahead of the remote, **When** displayed, **Then** the indicator shows `3↑`.
4. **Given** a console's working directory is unknown, **When** the sidebar renders, **Then** no git indicator appears for that console.

---

### User Story 7 — Shell Terminal Panel (Priority: P7)

A developer can open a supplemental shell panel below the Claude Code terminal to run ad-hoc commands without interrupting the Claude session. The panel supports multiple tabbed shell sessions starting in the same worktree directory.

**Why this priority**: Developers routinely need a shell alongside their agent sessions; without it they must switch to a separate terminal application.

**Independent Test**: Can be tested by opening the shell panel for a console with a known working directory, running `pwd`, and verifying it matches the console's reported working directory.

**Acceptance Scenarios**:

1. **Given** a console with a known working directory is selected, **When** the developer clicks the shell toggle button, **Then** a shell panel opens below the terminal, starting in the console's working directory.
2. **Given** the shell panel is open, **When** the developer clicks "+", **Then** a new shell tab is added and becomes active.
3. **Given** the shell panel has one tab open, **When** the developer closes the last tab, **Then** the panel collapses automatically.
4. **Given** the shell panel is visible, **When** the developer hides it via the toolbar toggle, **Then** the running shell processes continue and reappear in the same state when shown again.

---

### User Story 8 — Session Persistence & Restart (Priority: P8)

After quitting and relaunching the app, all track and console metadata is restored from the database. Previously-live consoles appear as suspended with a Restart button. Clicking Restart resumes the Claude Code conversation from where it left off using `--continue` and the named worktree.

**Why this priority**: Loss of organizational structure on restart is a significant friction point when managing many parallel sessions.

**Independent Test**: Can be tested by creating tracks and consoles, quitting the app, relaunching, verifying tracks appear with suspended consoles, then clicking Restart and verifying the session resumes.

**Acceptance Scenarios**:

1. **Given** the app has tracks and live consoles, **When** the app is quit, **Then** all previously-live consoles are marked suspended in the database.
2. **Given** the app is relaunched, **When** the sidebar loads, **Then** all tracks and their consoles appear with suspended consoles showing gray indicators.
3. **Given** a suspended console is selected, **When** the center area renders, **Then** a "Session Suspended" placeholder with a prominent "Restart" button appears instead of a terminal.
4. **Given** the developer clicks "Restart," **When** the session launches, **Then** the Claude Code session resumes the previous conversation and reports its working directory automatically.

---

### Edge Cases

- What happens when the `claude` CLI is not installed on the machine? Console creation must fail gracefully with a clear message.
- What happens when a track's repository path no longer exists at app restart? The track persists in the sidebar but git status checks are skipped for its consoles.
- What happens when `request_user_input` arrives but the user never responds? A 5-minute timeout returns an error to Claude and the dialog is dismissed.
- What happens when multiple MCP connections send a hello with the same terminal ID? Only the first connection is associated with that terminal; subsequent connections with the same ID are ignored.
- What happens when the last shell tab is closed? The shell panel collapses automatically.
- What happens when notification permission is not granted? The dock badge still updates; only OS-level notifications are suppressed.
- What happens when a console's process exits unexpectedly mid-task? The console transitions to the suspended state.

## Requirements *(mandatory)*

### Functional Requirements

**Session Management**

- **FR-001**: App MUST allow users to create named work tracks with an optional repository path, branch name, and free-form context notes.
- **FR-002**: App MUST allow users to add multiple Claude Code console sessions to any work track, each starting in the track's configured repository directory.
- **FR-003**: App MUST allow users to delete console sessions; deletion MUST terminate the running process and remove the row from the sidebar.
- **FR-004**: App MUST allow users to delete entire tracks; deletion MUST require confirmation and remove all child consoles.
- **FR-005**: App MUST allow consoles to be dragged and dropped between tracks to reorganize sessions.
- **FR-006**: App MUST render full-featured terminal emulation per console, supporting VT100/xterm escape sequences, 24-bit color, Unicode including emoji, and mouse events.
- **FR-007**: App MUST automatically resize each terminal to match its pane dimensions and notify the running process of size changes.

**Status Detection**

- **FR-008**: App MUST classify each console into exactly one of five display states: active, thinking, waiting, suspended, completed.
- **FR-009**: App MUST transition a console to active within 1 second of it producing any terminal output.
- **FR-010**: App MUST transition a console to thinking after approximately 1–3 seconds of silence without a recognizable prompt.
- **FR-011**: App MUST transition a console to waiting when silence exceeds 3 seconds AND a prompt pattern is detected in recent output.
- **FR-012**: App MUST transition a console to suspended when its child process exits.
- **FR-013**: App MUST display a colored status indicator per console row in the sidebar reflecting its current state.
- **FR-014**: App MUST display an attention badge count on each track header showing the number of child consoles in the waiting state, visible even when the track is collapsed.

**Notifications**

- **FR-015**: App MUST fire a macOS notification when a console transitions to the waiting state, including the console name in the notification body.
- **FR-016**: App MUST NOT fire duplicate notifications for a console that remains in the waiting state; a new notification fires only when the console re-enters waiting after leaving it.
- **FR-017**: App MUST update the dock badge to reflect the total count of all consoles currently in the waiting state; the badge MUST clear when no consoles are waiting.
- **FR-018**: App MUST focus the relevant console when the developer clicks a waiting notification.
- **FR-019**: App MUST request macOS notification authorization at first launch.

**MCP Tools**

- **FR-020**: App MUST expose exactly 5 MCP tools to each Claude Code session via a Unix domain socket: `set_working_directory`, `log_activity`, `set_terminal_title`, `notify_user`, and `request_user_input`.
- **FR-021**: App MUST inject a system prompt into every new Claude Code session instructing Claude to call `set_working_directory` first and use the remaining tools proactively.
- **FR-022**: App MUST communicate with MCP server subprocesses via newline-delimited JSON over a Unix domain socket.
- **FR-023**: The `request_user_input` tool MUST present a native dialog with either selectable button options (when options provided) or a free-text field (when no options provided).
- **FR-024**: The `request_user_input` tool MUST return a timeout error to Claude if the user does not respond within 5 minutes.
- **FR-025**: The `notify_user` tool MUST support three urgency levels: low (sidebar badge only), normal (OS notification + sidebar badge), and critical (OS notification + sidebar badge + dock bounce).

**Activity Log**

- **FR-026**: App MUST persist all `log_activity` messages with timestamps to the local database, associated with the originating console.
- **FR-027**: App MUST display the activity log for the currently-selected console in a right-side panel, ordered chronologically with `HH:mm:ss` timestamps.
- **FR-028**: App MUST update the activity panel in real-time as new entries are written, without requiring a manual refresh.
- **FR-029**: App MUST switch the activity panel content when the developer selects a different console.
- **FR-030**: App MUST allow the developer to toggle the activity panel visibility via a toolbar button; hiding the panel MUST NOT affect the terminal or sidebar.

**Git Status**

- **FR-031**: App MUST poll git status every 10 seconds for each console whose working directory is known.
- **FR-032**: App MUST display a dirty indicator (amber console name) when the console's worktree has uncommitted changes.
- **FR-033**: App MUST display a diff summary in the format `+N -M` (lines added, lines removed vs HEAD) next to the console name.
- **FR-034**: App MUST display a commits-ahead count in the format `N↑` next to the console name when the worktree is ahead of its upstream.
- **FR-035**: App MUST NOT display git indicators for consoles whose working directory has not been reported via MCP.

**Shell Panel**

- **FR-036**: App MUST provide an optional tabbed shell panel below the Claude Code terminal area for each selected console.
- **FR-037**: Shell tabs MUST start in the console's reported working directory; if unknown, they start in the track's repository path.
- **FR-038**: App MUST support adding and closing shell tabs; closing the last tab MUST auto-collapse the panel.
- **FR-039**: Hiding the shell panel via the toolbar toggle MUST NOT terminate running shell processes; they MUST resume in the same state when the panel is shown again.

**Persistence**

- **FR-040**: App MUST persist all work track and console metadata (names, repository paths, worktree identifiers, runtime status) to a local SQLite database.
- **FR-041**: App MUST mark all live consoles as suspended in the database when the app quits.
- **FR-042**: App MUST restore all tracks and consoles from the database on app launch, showing previously-live consoles with a suspended indicator.
- **FR-043**: App MUST present a "Session Suspended" placeholder with a Restart button for suspended consoles instead of a terminal view.
- **FR-044**: Clicking Restart MUST resume the Claude Code session using `--continue` and the console's named worktree identifier.
- **FR-045**: App MUST install a Claude Code SessionStart hook in the user's Claude settings (merging with existing configuration) that automatically reports the working directory to the app on both startup and resume.

**Platform**

- **FR-046**: App MUST run natively on macOS 14 (Sonoma) and later, supporting both Apple Silicon and Intel architectures.
- **FR-047**: App MUST NOT use App Sandbox (direct PTY access is required).

### Key Entities

- **Work Track**: A named logical group representing a feature or project context. Attributes: name, optional repository path, optional branch name, optional free-form context notes, active/archived status. Contains zero or more console sessions.
- **Console / Terminal**: An individual Claude Code session belonging to a work track. Attributes: display name, kebab-case worktree identifier (for session resumption), runtime status (live, suspended, completed), optional last-accessed timestamp.
- **Activity Log Entry**: A timestamped text message explicitly logged by a Claude Code session. Attributes: message text, creation timestamp. Associated with exactly one console.
- **Git Status**: A transient, in-memory snapshot of a console's worktree state. Attributes: dirty flag, lines added vs HEAD, lines removed vs HEAD, commits-ahead count. Refreshed every 10 seconds; not persisted to the database.
- **Display Status**: The runtime classification of a console derived from output monitoring. Values: active, thinking, waiting, suspended, completed. Not persisted; derived at runtime from PTY output patterns and process state.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: A developer can determine the current state of all concurrent Claude Code sessions from a single window without switching terminal tabs or running any commands.
- **SC-002**: The app notifies the developer within 1 second of any session transitioning to the waiting state, regardless of whether the app is in the foreground.
- **SC-003**: The app supports 10 or more simultaneous terminal sessions without perceptible input lag (no more than one frame delay at 60fps).
- **SC-004**: After quitting and relaunching the app, all tracks and consoles are restored to the sidebar and a previously-live session can be restarted and connected within 30 seconds.
- **SC-005**: A developer can respond to a Claude Code session's native input dialog without first locating or switching to the session's terminal manually.
- **SC-006**: Git status indicators in the sidebar reflect the actual state of the worktree within 10 seconds of any file change.
- **SC-007**: Shell panel sessions open in the correct worktree directory without requiring manual navigation by the developer.
- **SC-008**: No work track or console data is lost across normal app restarts.
