# mymux — Product Requirements Document

## Overview

mymux is a macOS desktop application for orchestrating multiple Claude Code terminal sessions into organized work tracks. It is built with Swift/AppKit and uses SwiftTerm for terminal rendering.

The app enables developers to run many concurrent Claude Code sessions, organized into logical "work tracks," with real-time status detection, native notifications when Claude needs attention, and MCP-based tools that let Claude interact with the app itself.

This application is a personal developer tool built as part of a workshop demonstrating speckit-driven development. Every participant builds their own copy. The name "mymux" is used everywhere — app name, bundle, database path, socket path, etc.

---

## Problem Statement

Developers running multiple concurrent Claude Code sessions face three problems:

1. **No centralized monitoring.** Each session runs in a separate terminal tab. There is no single view showing which sessions are active, thinking, or waiting for input. Developers must manually check each tab.

2. **No background notifications.** Terminal emulators do not fire OS-level notifications when a process is waiting for input. Developers must be looking at the correct tab to notice. This defeats the purpose of running agents in parallel.

3. **No session continuity.** When the app or machine restarts, all Claude Code sessions are lost. There is no way to resume mid-task conversations without manual reconstruction.

---

## Target User

A single developer running 3-10 concurrent Claude Code sessions across multiple projects on a macOS machine. They need to monitor which agents are active, be notified when any agent needs attention, quickly organize sessions into logical work groups, and resume sessions after restarts.

---

## Core Features

### F1: Native Terminal Rendering via SwiftTerm

**What**: Each Claude Code session renders in a SwiftTerm `LocalProcessTerminalView` — a native AppKit NSView that provides full VT100/xterm terminal emulation with CoreText rendering.

**Why**: Eliminates the need for tmux, WebSocket bridges, or browser-based terminal emulators. SwiftTerm is a pure Swift Package with no external toolchain dependencies.

**Behavior**:
- Each terminal pane is a `LocalProcessTerminalView` (an NSView subclass) that owns its own PTY and child process
- Full terminal features: VT100/xterm support, 24-bit color, 256-color palette, Unicode, emoji, grapheme clusters, mouse support, scrollback buffer, text selection, bracketed paste
- Terminal size adapts automatically to pane dimensions; PTY resize sends SIGWINCH to the child process group automatically
- CoreText rendering handles all glyph shaping and font fallback

**What SwiftTerm handles internally (we do NOT implement)**:
- PTY creation and lifecycle (`LocalProcessTerminalView` manages `forkpty()` internally)
- Terminal escape sequence parsing (VT100/VT220/xterm)
- Keyboard input encoding
- Mouse event encoding
- Scrollback buffer management
- Text selection and clipboard integration

---

### F2: Work Track & Console Management

**What**: A sidebar organizes terminals into collapsible work track groups with full CRUD operations and drag-and-drop reorganization.

**Why**: Developers working on multiple features simultaneously need logical grouping to stay oriented across many concurrent sessions.

**Sidebar structure**:
- NSOutlineView with two levels: tracks (parent rows, collapsible sections) and terminals (child rows)
- Each track header shows: track name, an inline "+" button to add a new console to that track
- Each terminal row shows: status indicator dot, terminal name, git status info (when available)
- A "+" button at the top of the sidebar creates a new work track

**Work track creation** (via top-level "+" button):
- Presents a form with fields: Name, Repository Path (directory picker), Branch, Context Notes (free-form text)
- All fields except Name are optional

**Console creation** (via per-track "+" button):
- Adds a new Claude Code terminal session to the selected track
- Spawns `claude` CLI in the track's configured repository path
- The terminal gets a "worktree name" derived from its display name in kebab-case (e.g., "Auth Refactor" becomes `auth-refactor`). This worktree name is used for the `--worktree` CLI flag.

**Context menus** (right-click):
- On a terminal row: New Console, Delete Console, Restart (only shown for suspended terminals)
- On a track header: New Console, Delete Track
- Delete Track removes the track and all its terminals (with confirmation)
- Delete Console kills the terminal process and removes it

**Drag and drop**:
- Terminals can be dragged between tracks to reorganize
- Standard NSOutlineView drag-and-drop with visual insertion indicator

---

### F3: Intelligent Status Detection & Indicators

**What**: The app monitors each terminal's PTY output in real-time and classifies each session into one of five states, displayed as colored indicators in the sidebar.

**Why**: This is the core value proposition. Without centralized status at a glance, running multiple parallel agents is impractical.

**Detection mechanism — PTYOutputMonitor**:
Each terminal session has a `PTYOutputMonitor` instance that:
- Maintains a **ring buffer of 4096 bytes** containing the most recent terminal output
- Tracks a `lastOutputTimestamp` updated on every byte received from the PTY
- Runs a **DispatchSourceTimer firing every 500ms** that evaluates state transitions based on silence duration
- When evaluating for prompt detection, **strips ANSI escape codes** from the ring buffer's trailing bytes and matches against prompt patterns using regex

**Five display states**:

| State | Visual Indicator | Condition |
|-------|-----------------|-----------|
| Active | Green filled circle (●) | Terminal produced output recently (within last ~1 second) |
| Thinking | Blue pulsing circle | Silence detected, but no prompt pattern found in recent output |
| Waiting | Amber circle + `[!]` badge | Silence detected AND a prompt pattern is visible in recent output |
| Suspended | Gray circle (◌) | Child process exited, was killed, or was marked suspended on app quit |
| Completed | Dim checkmark (✓) | Terminal task finished successfully |

**StatusDotView**:
- A custom NSView subclass that renders a colored circle corresponding to the current state
- Used in every terminal row in the sidebar
- For the "thinking" state, the circle pulses (animated opacity or scale) using Core Animation

**Prompt patterns** (matched after ANSI stripping via regex):

| Pattern | What it matches |
|---------|-----------------|
| `>\s*$` | Claude Code's standard input prompt |
| `❯\s*$` | Unicode prompt |
| `\$\s*$` | Shell prompt |
| `\(y/n\)` | Confirmation dialog |
| `\[Y/n\]` | Yes/no with default |
| `Do you want to` | Prose confirmation |
| `Allow .+\?` | Claude Code tool approval prompt |
| `Press Enter` | Continue prompt |

**Track header badge**:
- Each track header shows an attention badge count indicating how many of its child consoles are in the "waiting" state
- This badge is visible even when the track is collapsed, so users can see at a glance which tracks need attention without expanding them

**Notification behavior on transition to Waiting**:
1. Sidebar terminal row gets amber indicator and `[!]` badge
2. macOS notification fires via `UNUserNotificationCenter`
3. Dock icon badge shows total count of all waiting terminals

---

### F4: MCP Tools for Claude Self-Organization

**What**: Each Claude Code session receives MCP tools (via a bundled Node.js MCP server) that let Claude interact with the mymux app — reporting its working directory, logging activity, updating its title, notifying the user, and requesting structured input.

**Why**: Makes Claude an active participant in orchestration rather than a passive terminal process.

**Architecture**:
- The MCP server is a **single JavaScript file** produced by esbuild bundling, output as **ESM format** (to support top-level `await`)
- It is bundled in the app's Resources directory
- Claude Code communicates with the MCP server via stdio (standard MCP transport)
- The MCP server communicates with mymux.app via a **Unix domain socket** using **POSIX sockets** (NOT Network.framework)
- Socket path: `/tmp/mymux-ipc.sock` (single shared socket for all terminals)
- Wire protocol: **NDJSON** (newline-delimited JSON) with a `hello` handshake on connection, then request/response pairs with `req_id` correlation

**IPC protocol detail**:
1. On connection, the MCP server sends `{"type":"hello","terminal_id":"<uuid>","version":1}`
2. The app responds with `{"type":"hello_ack","status":"ok"}`
3. All subsequent messages have a `type` field and `req_id` for correlation
4. App responds with `{"type":"ack","req_id":"...","status":"ok"}` or specific response types
5. Each message is a single line of JSON terminated by `\n`

**MCP Tools (exactly 5)**:

#### `set_working_directory(path: string)`
Claude reports its actual worktree directory to the app on startup. This is the FIRST tool Claude should call — the system prompt instructs this. The reported path is stored and used for git status checks (F6) and shell terminal working directory (F7).

#### `log_activity(message: string)`
Records a timestamped activity entry in the SQLite database for this terminal. The entry appears in the Activity Log Panel (F5). Claude should call this frequently to record milestones, decisions, and blockers.

#### `set_terminal_title(title: string)`
Updates the terminal's display name in the sidebar. Claude can update this as its task evolves (e.g., from "Starting auth refactor" to "Testing auth refactor"). The worktree name is also re-derived from the new title in kebab-case.

#### `notify_user(message: string, urgency?: "low" | "normal" | "critical")`
Sends a notification to the user:
- `low`: Sidebar badge only (no OS notification)
- `normal` (default): macOS notification via `UNUserNotificationCenter` + sidebar badge
- `critical`: macOS notification + sidebar badge + dock bounce (`NSApp.requestUserAttention(.criticalRequest)`)

#### `request_user_input(question: string, options?: string[])`
Presents a native macOS dialog (NSAlert presented as a sheet on the main window) and blocks until the user responds:
- If `options` provided: dialog shows buttons for each option (up to 3 buttons per NSAlert)
- If no `options`: dialog shows a text input field (NSTextField as accessory view)
- **5-minute timeout**: if the user does not respond, returns an error to Claude
- When the request arrives, the terminal's sidebar row gets an attention indicator and a macOS notification fires

**System prompt**:
Every Claude Code session launched by mymux receives a system prompt (via `--system-prompt` CLI flag) that instructs Claude to:
1. Call `set_working_directory` FIRST with its actual working directory
2. Use `log_activity` to record progress milestones
3. Use `notify_user` when it completes significant work or encounters blockers
4. Use `request_user_input` when it needs decisions that cannot be inferred

---

### F5: Activity Log Panel

**What**: A right-side panel showing a chronological activity log for the currently focused console.

**Why**: Provides a persistent, scannable record of what Claude has been doing without having to read through terminal output.

**Layout**:
- Panel width: ~250px, positioned on the right side of the window
- Toggle button in the toolbar to show/hide the panel
- Toggling does not affect the terminal or sidebar — only the activity panel's visibility

**Content**:
- Each entry displays: timestamp in `HH:mm:ss` format + message text
- Entries are specific to the currently focused console — switching consoles switches the displayed log
- Real-time updates: new entries appear immediately as they are logged, powered by **GRDB ValueObservation** on the activity log table
- Rows auto-grow in height for long messages (multi-line support)

**Empty states**:
- When a console is selected but has no activity entries: "No activity logged yet"
- When no console is selected: "Select a console to see activity"

**Data source**: Activity entries are stored in SQLite (via GRDB) and written by the `log_activity` MCP tool (F4). The panel reads from the database using ValueObservation for reactive updates.

---

### F6: Git Dirty Indicators

**What**: The sidebar shows git status information next to each terminal — whether the worktree has uncommitted changes, a diff summary, and how many commits are ahead of the remote.

**Why**: Developers need to know at a glance which sessions have uncommitted work, especially before switching context or restarting sessions.

**Detection mechanism — GitStatusChecker**:
- A background service that polls git status every **10 seconds** on a background dispatch queue
- Only checks terminals where the **actual worktree directory is known** (i.e., `set_working_directory` has been called via MCP). Does NOT fall back to the track's configured repo root — if the worktree directory is unknown, no git status is shown for that terminal.
- Runs standard git CLI commands in the reported worktree directory:
  - `git status --porcelain` — detects dirty/clean state
  - `git diff --numstat HEAD` — counts lines added and removed
  - `git rev-list --count @{u}..HEAD` — counts commits ahead of upstream

**Display in sidebar**:
- **Dirty indicator**: Terminal name text turns amber when the worktree has uncommitted changes
- **Diff summary**: Shown next to the terminal name, format: `+42 -7` (lines added, lines removed vs HEAD)
- **Ahead count**: Shown next to the terminal name, format: `3↑` (commits ahead of origin)
- When the worktree is clean with no commits ahead, no extra indicators are shown

---

### F7: Shell Terminal Panel

**What**: A panel below the Claude Code terminal area that provides one or more interactive shell sessions in the same worktree directory.

**Why**: Developers frequently need to run ad-hoc commands (git operations, tests, file inspection) alongside Claude without interrupting the Claude Code session.

**Activation**:
- A button in the toolbar opens the shell panel below the Claude Code terminal
- The panel appears below the main terminal with a VS Code-style tab bar at the top of the shell panel area

**Shell behavior**:
- Each shell tab runs the system default shell (`$SHELL` environment variable, falling back to `/bin/zsh`)
- The shell starts in the worktree directory reported by `set_working_directory` (if known), otherwise in the track's configured repo path
- Each shell is a separate SwiftTerm `LocalProcessTerminalView` instance with its own PTY

**Tab bar** (VS Code-style):
- Click a tab to switch the visible shell
- "+" button at the end of the tab bar to add a new shell tab
- "x" button on each tab to close it (kills the shell process)
- Tab naming convention: `zsh`, `zsh (2)`, `zsh (3)`, etc. (using the shell name, not a custom name)

**Toggle behavior**:
- The toolbar button toggles the shell panel visibility
- Hiding the panel does NOT kill the running shell processes — they continue in the background
- Showing the panel again reveals the same shells in the same state

**Auto-collapse**:
- When the last shell tab is closed (via the "x" button), the shell panel collapses automatically

**Persistence**:
- Shell sessions are **ephemeral** — they are NOT persisted to the database
- On app quit, shell processes are terminated naturally via PTY teardown
- On app restart, the shell panel starts empty

---

### F8: Session Persistence & Restart

**What**: All track and terminal metadata is persisted to SQLite so that the sidebar state survives app restarts. Suspended sessions can be resumed using Claude Code's `--continue` flag combined with named worktrees.

**Why**: Developers should not lose their organizational structure or Claude Code conversation history when they quit the app or restart their machine.

**Database**:
- SQLite database located at `~/.mymux/mymux.db`
- Managed via **GRDB.swift** ORM
- Stores: tracks (name, repo path, branch, context notes), terminals (name, worktree name, track association, status, working directory), activity log entries (terminal ID, timestamp, message)

**App quit behavior**:
- On `applicationWillTerminate`: all terminals currently in any live state (active, thinking, waiting) are marked `suspended` in the database
- Child processes receive SIGHUP via natural PTY teardown

**App restart behavior**:
- On launch, the sidebar is populated from the database
- All previously-live terminals appear with the `suspended` state (gray circle indicator)
- Clicking a suspended terminal shows a **"Session Suspended" placeholder view** in the terminal area (not a terminal) with a prominent "Restart" button

**Restart mechanism**:
- Clicking "Restart" launches a new Claude Code session with:
  - `claude --continue` — resumes from the last conversation state
  - `--worktree "worktree-name"` — the kebab-case worktree name derived from the terminal's display name
  - `--system-prompt "..."` — the same system prompt as the original session (including MCP tool instructions)
- Named worktrees (`--worktree` flag) are the key to reliable session resumption — Claude Code uses the worktree name to locate and resume the correct conversation

**SessionStart hook**:
- mymux installs a hook configuration in `~/.claude/settings.json` that causes Claude Code to report its worktree directory on both fresh startup and session resume
- This ensures `set_working_directory` is called automatically even on resumed sessions, enabling git status checks and shell directory resolution

---

## User Interface

### Main Window Layout

```
+---sidebar (280px)---+----terminal area (constraint-based)----+--activity (250px)--+
| [+ New Track]       | [shell btn] [activity btn]             |  Activity           |
|                     | ┌──────────────────────────────────┐   |  HH:mm:ss          |
| ▼ Track Name    ⊕   | │ Claude Code terminal              │   |  message...         |
|   ● console-1  +7-0 | │ (SwiftTerm LocalProcessTerminal)  │   |                    |
|   ◌ console-2       | │                                    │   |  HH:mm:ss          |
|                     | └──────────────────────────────────┘   |  message...         |
| ▼ Track 2       ⊕   | ┌──tab bar: [zsh ×] [zsh(2) ×] [+]─┐   |                    |
|   ● console-3  (1)  | │ Shell terminal                      │   |                    |
|                     | └──────────────────────────────────┘   |                    |
+---------------------+----------------------------------------+--------------------+
```

**Window structure**: The main window uses NSSplitViewController (or constraint-based layout) with three columns:
- **Left sidebar** (280px default): NSOutlineView for tracks/terminals, "+" button for new tracks
- **Center terminal area** (flexible, fills remaining space): Toolbar with shell toggle and activity toggle buttons, the focused Claude Code terminal (SwiftTerm `LocalProcessTerminalView`), and optionally the shell panel below it
- **Right activity panel** (250px, togglable): Activity log for the focused console

**When no terminal is selected**: The center area shows an empty state with instructions (e.g., "Create a track and add a console to get started").

**When a suspended terminal is selected**: The center area shows the "Session Suspended" view with a Restart button instead of a terminal.

### Status Indicators in Sidebar

| State | Visual |
|-------|--------|
| Active | Green filled circle (●) |
| Thinking | Blue pulsing circle |
| Waiting | Amber circle + `[!]` badge |
| Suspended | Gray circle (◌) |
| Completed | Dim checkmark (✓) |

Track headers show an attention badge count (e.g., `(2)`) indicating how many child consoles are in the waiting state. This badge is visible even when the track section is collapsed.

Terminal rows show git information inline: amber text when dirty, `+N -M` diff summary, `N↑` ahead count.

---

## Non-Functional Requirements

### Performance
- Support **10+ simultaneous terminal sessions** without UI lag
- Terminal input latency **under 16ms** (one frame at 60fps)
- Status detection response within 500ms of state change (timer interval)

### Platform
- **macOS 14 (Sonoma)** or later
- **Apple Silicon and Intel** support
- Native .app bundle — **no App Sandbox** (PTY access required)

### Dependencies (Swift Package Manager)
- **SwiftTerm ~>1.11** — terminal emulation
- **GRDB.swift ~>7.0** — SQLite ORM

### Runtime Dependencies (must be installed on the machine)
- **Node.js 20+** — runs the MCP server subprocess
- **`claude` CLI** — Claude Code itself

---

## Out of Scope

These features are explicitly excluded:

- **Split panes / multi-terminal grid**: The app shows a single focused terminal plus the optional shell panel. No side-by-side terminal splits.
- **Cross-platform support**: macOS only.
- **Linear integration / ticket systems**: No drag-and-drop ticket ingestion, no Linear API, no ticket metadata.
- **AI-generated activity summaries**: Activity log shows only what Claude explicitly logs via `log_activity`.
- **Auto-branching / PR creation**: Claude Code handles git operations via its own tools.

---

## Data Model

### work_tracks Table
| Column | Type | Description |
|--------|------|-------------|
| id | TEXT (UUID) | Primary key |
| name | TEXT | Display name |
| repoPath | TEXT | Absolute path to repository |
| branch | TEXT | Git branch name |
| contextNotes | TEXT | Free-form context for system prompt (default empty) |
| status | TEXT | "active" or "archived" (default "active") |
| createdAt | TEXT | ISO 8601 timestamp |
| updatedAt | TEXT | ISO 8601 timestamp |

### terminals Table
| Column | Type | Description |
|--------|------|-------------|
| id | TEXT (UUID) | Primary key |
| trackId | TEXT | Foreign key to work_tracks (cascade delete) |
| name | TEXT | Display name |
| worktreeName | TEXT | Kebab-case name for `--worktree` flag |
| runtimeStatus | TEXT | "live", "suspended", or "completed" (default "live") |
| createdAt | TEXT | ISO 8601 timestamp |
| lastAccessedAt | TEXT | ISO 8601 timestamp (nullable) |

### activity_log Table
| Column | Type | Description |
|--------|------|-------------|
| id | TEXT (UUID) | Primary key |
| terminalId | TEXT | Foreign key to terminals (cascade delete) |
| message | TEXT | Activity message from Claude |
| createdAt | TEXT | ISO 8601 timestamp |

Note: `workingDirectory` is tracked in memory (SessionManager.workingDirectories dict), not persisted to the database. Display status (active/thinking/waiting) is derived at runtime by PTYOutputMonitor, not stored — only `runtimeStatus` (live/suspended/completed) is persisted.

---

## Claude Code Launch Configuration

When mymux spawns a new Claude Code session, it runs:

```
cd "<repoPath>" && claude --worktree "<worktree-name>" \
  --mcp-config "/tmp/mymux-mcp/mcp-<terminal-id>.json" \
  --allowedTools "mcp__mymux__*" \
  --system-prompt "<system-prompt>"
```

When restarting a suspended session:

```
cd "<repoPath>" && claude --continue --worktree "<worktree-name>" \
  --mcp-config "/tmp/mymux-mcp/mcp-<terminal-id>.json" \
  --allowedTools "mcp__mymux__*" \
  --system-prompt "<system-prompt>"
```

The MCP config JSON is generated per-terminal at `/tmp/mymux-mcp/mcp-<terminal-id>.json` pointing to the bundled Node.js MCP server with `MYMUX_TERMINAL_ID` and `MYMUX_SOCKET_PATH` environment variables.

The system prompt includes:
1. Instructions to call `set_working_directory` as the FIRST action
2. Track name and terminal purpose
3. Track context notes (if any)
4. Instructions for using `log_activity`, `notify_user`, `set_terminal_title`, and `request_user_input`
