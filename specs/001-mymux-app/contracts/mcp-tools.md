# Contract: MCP Tools (Claude Code → mymux)

**Feature**: 001-mymux-app  
**Date**: 2026-06-29

Five MCP tools are exposed to each Claude Code session via the bundled Node.js MCP server. All tools communicate with mymux.app over the IPC Unix domain socket (see `ipc-protocol.md`).

---

## Tool 1: set_working_directory

**Purpose**: Claude reports its actual working directory to mymux immediately on startup (before any other work). Enables git status polling and shell panel directory resolution.

**Parameters**:

| Name | Type | Required | Description |
|------|------|----------|-------------|
| path | string | yes | Absolute path to Claude's current working directory |

**Effect**:
- Updates `sessionManager.workingDirectories[terminalId]` in memory
- Triggers git status check for the terminal
- Provides the shell panel's starting directory

**IPC message sent**:
```json
{"type":"set_working_directory","path":"/absolute/path","req_id":"r1","terminal_id":"<uuid>"}
```

**Response**: standard `ack`

---

## Tool 2: log_activity

**Purpose**: Claude records a timestamped milestone or decision that appears in the Activity Log Panel.

**Parameters**:

| Name | Type | Required | Description |
|------|------|----------|-------------|
| message | string | yes | Human-readable activity description |

**Effect**:
- Inserts a row into `activity_log` table with current timestamp
- ActivityPanelView (via GRDB ValueObservation) displays the entry in real-time

**IPC message sent**:
```json
{"type":"log_activity","message":"Completed auth refactor","req_id":"r2","terminal_id":"<uuid>"}
```

**Response**: standard `ack`

---

## Tool 3: set_terminal_title

**Purpose**: Claude updates its sidebar display name to reflect its current task.

**Parameters**:

| Name | Type | Required | Description |
|------|------|----------|-------------|
| title | string | yes | New display name for the terminal |

**Effect**:
- Updates `terminal.name` in the database
- Re-derives `worktreeName` from the new title via `toKebabCase()`
- Sidebar row reflects the new name immediately

**IPC message sent**:
```json
{"type":"set_terminal_title","title":"Testing Auth Refactor","req_id":"r3","terminal_id":"<uuid>"}
```

**Response**: standard `ack`

---

## Tool 4: notify_user

**Purpose**: Claude proactively alerts the developer with an OS notification.

**Parameters**:

| Name | Type | Required | Default | Description |
|------|------|----------|---------|-------------|
| message | string | yes | — | Notification body text |
| urgency | enum | no | `"normal"` | `"low"`, `"normal"`, or `"critical"` |

**Urgency behavior**:

| Level | Sidebar Badge | OS Notification | Dock Bounce |
|-------|--------------|-----------------|-------------|
| `low` | ✅ | ❌ | ❌ |
| `normal` | ✅ | ✅ | ❌ |
| `critical` | ✅ | ✅ | ✅ (NSRequestUserAttention) |

**IPC message sent**:
```json
{"type":"notify_user","message":"Auth refactor complete","urgency":"normal","req_id":"r4","terminal_id":"<uuid>"}
```

**Response**: standard `ack`

---

## Tool 5: request_user_input

**Purpose**: Claude blocks and waits for a developer decision before proceeding.

**Parameters**:

| Name | Type | Required | Description |
|------|------|----------|-------------|
| question | string | yes | Question text shown in the dialog |
| options | string[] | no | If provided: dialog shows buttons (up to 3). If omitted: dialog shows a text field. |

**Effect**:
- App presents a native NSAlert sheet on the main window
- Terminal's sidebar row gets an attention indicator
- macOS notification fires (same as `notify_user` urgency `"normal"`)
- App blocks the IPC response until user answers or timeout (5 minutes)

**Timeout**: If no response in 5 minutes, app sends error response and dismisses the dialog.

**IPC message sent**:
```json
{"type":"request_user_input","question":"Which approach?","options":["Option A","Option B","Decide for me"],"req_id":"r5","terminal_id":"<uuid>"}
```

**Async response on answer**:
```json
{"type":"user_input_response","req_id":"r5","answer":"Option A"}
```

**Async response on timeout**:
```json
{"type":"user_input_response","req_id":"r5","error":"timeout","message":"User did not respond within 5 minutes"}
```

---

## MCP Config File (per terminal)

Location: `/tmp/mymux-mcp/mcp-<terminal-uuid>.json`  
Permissions: `0o600`

```json
{
  "mcpServers": {
    "mymux": {
      "command": "node",
      "args": ["<absolute-path-to>/mymux-mcp-server.mjs"],
      "env": {
        "MYMUX_TERMINAL_ID": "<terminal-uuid>",
        "MYMUX_SOCKET_PATH": "/tmp/mymux-ipc.sock"
      }
    }
  }
}
```

**MCP server path resolution order** (first match wins):
1. `Bundle.main.resourcePath + "/mymux-mcp-server.mjs"`
2. Relative to executable: `../.build/ → Resources/mymux-mcp-server.mjs`
3. `cwd/Resources/mymux-mcp-server.mjs`
4. `cwd/Mymux/Resources/mymux-mcp-server.mjs`

---

## System Prompt (injected into every session)

```
You are working on: <track.name>
Terminal purpose: <terminal.name>

Linear ticket: <track.linearTicketUrl>  (if present)

Context:
<track.contextNotes>  (if non-empty)

IMPORTANT — Mymux Tools:
You have access to Mymux MCP tools. Use them proactively:
- set_working_directory: CALL THIS FIRST — report your current working directory (pwd) immediately on startup
- log_activity: Log milestones frequently (features done, tests passing, blockers hit)
- set_terminal_title: Update your terminal name to reflect current task
- notify_user: Alert the user when you finish major work or hit a blocker
- request_user_input: Ask the user when you need a decision you cannot make from context

Begin by calling set_working_directory with your current working directory, then start working on this task.
```
