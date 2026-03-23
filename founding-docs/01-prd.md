# Workshop Native — Product Requirements Document

## Overview

Workshop Native is a macOS desktop application for orchestrating multiple Claude Code terminal sessions into organized work tracks. It is built with Swift/AppKit and uses SwiftTerm (a pure-Swift VT100/Xterm terminal emulator library) for terminal rendering.

The app enables developers to drag a Linear ticket URL onto the window, automatically spawn a Claude Code session with full ticket context, and have Claude self-organize its work into tracks — all while providing native macOS notifications when Claude needs user attention.

This application is not a distributed product. It is a personal tool designed to be built by individual developers as part of a workshop demonstrating speckit-driven development. Every participant builds their own copy, customized to their workflow.

---

## Problem Statement

Developers running multiple concurrent Claude Code sessions face three problems:

1. **No centralized monitoring**: Each session runs in a separate terminal tab or tmux pane. There's no single view showing which sessions are active, thinking, or waiting for input. Developers must manually check each tab.

2. **No background notifications**: Terminal emulators don't fire OS-level notifications when a process is waiting for input. Developers must be looking at the correct tab to notice. This defeats the purpose of running agents in parallel.

3. **Manual session setup**: Starting a new Claude Code session requires opening a terminal, navigating to the repo directory, composing CLI flags, and manually providing context. There's no way to go from "I have a ticket" to "Claude is working on it" without multiple manual steps.

---

## Target User

A single developer running 3–10 concurrent Claude Code sessions across multiple projects or tickets on a macOS machine. They need to monitor which agents are active, be notified when any agent needs attention, and quickly spin up new agents from Linear tickets.

---

## Core Features

### F1: Native Terminal Rendering via SwiftTerm

**What**: Each Claude Code session renders in a SwiftTerm `LocalProcessTerminalView` — a native AppKit NSView that provides full VT100/Xterm terminal emulation with CoreText rendering.

**Why**: Eliminates the need for tmux, WebSocket bridges, or browser-based terminal emulators. SwiftTerm is a pure Swift Package — no external toolchain, no native compilation, no Zig or Metal setup. It is used in production by Secure Shellfish, La Terminal, and CodeEdit.

**Behavior**:
- Each terminal pane is a `LocalProcessTerminalView` (an NSView subclass) that owns its own PTY and child process
- Full terminal features: 24-bit color, 256-color palette, Unicode, emoji, grapheme clusters, mouse support, scrollback, text selection, bracketed paste
- Sixel and Kitty image protocol support
- Terminal size adapts automatically to pane dimensions via the `xterm-addon-fit` equivalent built into SwiftTerm
- PTY resize sends SIGWINCH to the child process group automatically
- CoreText rendering handles all glyph shaping and font fallback

**What SwiftTerm handles for us (we do NOT implement)**:
- PTY creation and lifecycle (`LocalProcessTerminalView` manages `forkpty()` internally)
- Terminal escape sequence parsing (VT100/VT220/xterm)
- Keyboard input encoding
- Mouse event encoding
- Scrollback buffer management
- Text selection and clipboard integration

### F2: Drag-and-Drop Linear Ticket Ingestion

**What**: Users drag a Linear ticket URL from their browser onto the Workshop window. The app fetches the ticket, shows a brief confirmation, and launches Claude Code with full ticket context.

**Why**: Reduces the workflow from manually creating a track and configuring a terminal to a single drag gesture.

**Behavior**:
1. User drags a URL matching `linear.app/*/issue/*` onto the app window — either the sidebar drop zone or any area of the window
2. App extracts the issue identifier (e.g., `ENG-123`) from the URL path using regex: `/issue/([A-Z]+-\d+)/`
3. App fetches issue details via Linear GraphQL API (`https://api.linear.app/graphql`):
   - Title, description (Markdown), priority, due date
   - Labels, project, team
   - Current state (todo, in progress, done, etc.)
   - Assignee
4. App presents a confirmation sheet (NSPanel or sheet on main window):
   - Pre-filled terminal name from ticket title
   - Repo path selector (dropdown of recently used repos from existing tracks, plus a "Browse…" button for NSOpenPanel directory picker)
   - Branch name field (auto-suggested from ticket identifier, e.g., `eng-123-fix-auth-refresh`)
   - "Start" / "Cancel" buttons
5. On confirm:
   - Creates a new work track (or matches existing by name)
   - Spawns a Claude Code terminal session with system prompt containing full ticket context
   - The new terminal tab appears in the sidebar under its track
6. The system prompt instructs Claude to begin working immediately

**Linear API key**: Stored in macOS Keychain under service `com.workshop-native`. First-time setup prompts in a Preferences window.

**Authentication**: Personal API key (format `lin_api_*`) passed as the `Authorization` header value directly (no "Bearer" prefix). Rate limit: 5,000 requests/hour.

### F3: Intelligent Waiting Detection & Native Notifications

**What**: The app monitors each terminal's PTY output stream in real-time and sends macOS notifications when Claude Code transitions to a "waiting for input" state.

**Why**: This is the core value proposition. Without this, running multiple parallel agents is impractical — you'd have to manually check each one.

**Terminal display states**:

| State | Visual | Condition |
|-------|--------|-----------|
| Active | Green filled circle (●) | Terminal produced output within the last 1 second |
| Thinking | Blue pulsing circle | 1–3 seconds of silence, OR >3s silence with no prompt pattern detected |
| Waiting | Amber circle with ring + `[!]` badge | >3 seconds of silence AND a prompt pattern is visible in recent output |
| Suspended | Gray circle (◌) | Child process exited or was killed; can be restarted |
| Completed | Dim checkmark | Manually marked done by user |

**Detection mechanism**: Each terminal session has a `PTYOutputMonitor` that:
- Maintains a ring buffer (4096 bytes) of the most recent terminal output
- Tracks a `lastOutputTimestamp` updated on every byte received from the PTY
- Runs a timer (fires every 500ms) that evaluates state transitions based on silence duration
- When silence exceeds 3 seconds, strips ANSI escape codes from the ring buffer's last 512 bytes and matches against prompt patterns

**Prompt patterns** (matched after ANSI stripping):

| Pattern (regex) | What it matches |
|-----------------|-----------------|
| `^>\s*$` | Claude Code's standard input prompt |
| `^❯\s*$` | Unicode prompt |
| `^\$\s*$` | Shell prompt (after Claude exits) |
| `\(y\/n\)` | Confirmation dialog |
| `\[Y\/n\]` | Yes/no with default |
| `Do you want to` | Prose confirmation |
| `Allow .+\?` | Claude Code tool approval prompt |
| `Press Enter` | Continue prompt |

**OSC notification support**: The monitor also parses OSC escape sequences inline in the output stream. When detected, notifications fire immediately (no silence delay needed):
- OSC 9 (iTerm2): `ESC ] 9 ; message ST`
- OSC 99 (Kitty): `ESC ] 99 ; params ; message ST`
- OSC 777 (rxvt): `ESC ] 777 ; notify ; title ; body ST`

**Notification delivery on transition to Waiting**:
1. Sidebar tab gets an amber attention indicator and `[!]` badge
2. macOS notification fires via `UNUserNotificationCenter`: title "Workshop", body "[terminal name] is waiting for input"
3. Clicking the notification switches focus to that terminal
4. Dock icon badge shows count of all waiting terminals (`NSDockTile.badgeLabel`)
5. Debounce: only one notification per waiting→non-waiting cycle

**Notification delivery on transition away from Waiting**:
1. Decrement dock badge count
2. Remove attention indicator from sidebar tab

### F4: MCP Tools for Claude Self-Organization

**What**: Each Claude Code session receives MCP tools (via a Node.js MCP server running as a subprocess) that let it interact with the Workshop app — assigning itself to tracks, notifying the user, and requesting input via native dialogs.

**Why**: Makes Claude an active participant in orchestration rather than a passive terminal process. Claude can self-organize, report progress, and ask structured questions through native UI.

**Architecture**: The MCP server is a Node.js script bundled in the app's Resources. It communicates with Claude Code via stdio (standard MCP protocol) and with Workshop.app via a Unix domain socket at `/tmp/workshop-ipc.sock`.

**Tools**:

#### `log_activity(message: string)`
Records a timestamped activity entry in the SQLite database. Appears in the sidebar's activity feed for the terminal. Claude should use this frequently to record milestones, decisions, and blockers.

#### `set_terminal_title(title: string)`
Renames the terminal's tab in the sidebar. Claude updates this as its task evolves (e.g., from "Starting auth refactor" to "Testing auth refactor").

#### `assign_track(track_name_or_id: string, description?: string)`
Claude examines existing work tracks and either:
- Matches an existing track by name (fuzzy match using Levenshtein distance / substring matching) and assigns its terminal to it
- Creates a new track with the given name and description, then assigns itself

Response indicates `matched_existing` or `created_new`.

#### `notify_user(message: string, urgency?: "low" | "normal" | "critical")`
Sends a notification to the user:
- `low`: Sidebar badge only (no OS notification)
- `normal` (default): macOS notification + sidebar badge
- `critical`: macOS notification + sidebar badge + dock bounce (`NSApp.requestUserAttention(.criticalRequest)`)

#### `request_user_input(question: string, options?: string[])`
Presents a native macOS dialog (NSAlert sheet attached to the main window) and blocks until the user responds:
- If `options` provided: dialog shows buttons for each option
- If no `options`: dialog shows a text input field
- 5-minute timeout (returns error to Claude if no response)

When a `request_user_input` arrives:
1. The terminal's sidebar tab gets an attention indicator
2. A macOS notification fires to alert the user
3. The dialog appears as a sheet on the main window

### F5: Work Track Organization

**What**: A sidebar organizes terminals into collapsible work track groups.

**Behavior**:
- Sidebar shows work tracks as collapsible sections (NSOutlineView)
- Each track shows: name, terminal count by status, collapse/expand toggle
- Each terminal within a track shows: name, status indicator (colored dot), git branch
- Terminals can be dragged between tracks to reorganize
- Right-click context menu on tracks: Rename, Archive, Delete
- Right-click context menu on terminals: Rename, Complete, Restart (if suspended), Delete
- Clicking a terminal in the sidebar focuses it in the main terminal area

**Track metadata** (editable via a context editor panel):
- Name
- Repository path (local absolute path)
- Branch name
- Linear ticket URL (optional)
- Context notes (free-form text, feeds into system prompt)
- Reference files (list of file paths with descriptions)

**Track creation**:
- From sidebar "+" button: manual form with all fields
- From Linear drag-and-drop: auto-populated from ticket
- From Claude MCP tool: Claude calls `assign_track` to create/match

### F6: Session Persistence & Recovery

**What**: Terminal session definitions survive app restarts. If Claude Code was mid-task when the app quit, users can resume.

**Behavior**:
- All track and terminal metadata is persisted to SQLite at `~/.workshop/workshop.db`
- On app quit: child processes receive SIGHUP (natural PTY teardown). All terminals are marked `suspended` in the database.
- On next launch: terminals previously in any live state are checked — they're always marked `suspended` after a restart since processes don't survive.
- Suspended terminals show in the sidebar with a gray indicator and a "Restart" button
- Clicking "Restart" launches a new Claude Code session with `--continue` flag (resumes from last conversation state) plus `--worktree` (restores the git worktree)
- The last 500 lines of terminal output before shutdown are captured via SwiftTerm's `getTerminal().getScrollbackLines()` and stored in the database for display before the session reconnects

---

## User Interface

### Main Window Layout

```
+---sidebar (250px)---+--------terminal area---------+
| [+ New Track]       |                              |
|                     |   ┌────────────────────────┐ |
| ▼ Auth Refactor     |   │                        │ |
|   ● fix-token  [!]  |   │   SwiftTerm             │ |
|   ◌ add-tests       |   │   LocalProcessTerminal  │ |
|                     |   │   View                   │ |
| ▼ Billing Feature   |   │   (focused terminal)    │ |
|   ● migrate-db      |   │                        │ |
|   ● update-api      |   └────────────────────────┘ |
|                     |                              |
| ▶ Archived (3)      |                              |
|                     |                              |
|                     |                              |
| ┌─────────────────┐ |                              |
| │ Drop Linear URL │ |                              |
| │     here        │ |                              |
| └─────────────────┘ |                              |
+---------------------+------------------------------+
```

The main window is an NSSplitViewController with two panes:
- **Left**: Sidebar (250px default, resizable) containing NSOutlineView for tracks/terminals, a "+" button for new tracks, and a drop zone for Linear URLs
- **Right**: Terminal area showing the currently focused terminal. When no terminal is selected, shows an empty state with instructions.

### Status Indicators
- Green filled circle (●): active — producing output
- Blue pulsing circle: thinking — silent but no prompt detected
- Amber circle with ring: waiting — needs user attention
- Gray circle (◌): suspended — process dead, can restart
- Dim checkmark: completed — manually marked done
- `[!]` badge: unread notification or waiting for input

### Keyboard Shortcuts

| Shortcut | Action |
|----------|--------|
| `Cmd+T` | New terminal in current track |
| `Cmd+N` | New work track |
| `Cmd+Shift+U` | Jump to most recent waiting terminal |
| `Cmd+1–9` | Switch to terminal by sidebar position |
| `Cmd+W` | Close/complete current terminal |
| `Cmd+[` / `Cmd+]` | Previous/next terminal |

---

## Non-Functional Requirements

### Performance
- Support 10+ simultaneous terminal sessions without UI lag
- Terminal input latency under 16ms (one frame at 60fps)
- Idle detection response within 500ms of state change

### Platform
- macOS 14 (Sonoma) or later
- Apple Silicon and Intel
- Native .app bundle — no sandbox required (PTY access)

### Dependencies (must already be installed by workshop attendee)
- Xcode (for building the project)
- Node.js 20+ (for MCP server subprocess; also required by Claude Code)
- `claude` CLI (Claude Code itself)

### Dependencies (pulled automatically by Xcode/SPM)
- SwiftTerm (terminal emulator, Swift Package)
- GRDB.swift (SQLite, Swift Package)

---

## Out of Scope (v1)

- Split panes / multi-terminal grid view within the terminal area (single focused terminal for v1)
- Cross-platform support (macOS only)
- Multi-user / team collaboration
- Integration with ticket systems other than Linear
- AI-generated terminal activity summaries
- Terminal role templates
- Auto-branching and PR creation (Claude Code handles this via its own tools)
