# Workshop Native — Technical Specification

## 1. System Architecture

### 1.1 High-Level Component Diagram

```
┌─────────────────────────────────────────────────────────────┐
│                     Workshop.app                            │
│                                                             │
│  ┌──────────────┐  ┌──────────────┐  ┌───────────────────┐ │
│  │ AppDelegate   │  │ WindowManager│  │ NotificationMgr   │ │
│  └──────┬───────┘  └──────┬───────┘  └───────┬───────────┘ │
│         │                 │                   │             │
│  ┌──────┴───────┐  ┌──────┴───────┐  ┌───────┴──────────┐ │
│  │ SidebarView   │  │ TerminalArea │  │ LinearDropView   │ │
│  │ (NSOutline)   │  │ (SwiftTerm)  │  │ (drag target)    │ │
│  └──────┬───────┘  └──────┬───────┘  └───────┬──────────┘ │
│         │                 │                   │             │
│  ┌──────┴───────┐  ┌──────┴───────┐  ┌───────┴──────────┐ │
│  │ TrackCtrl     │  │ PTYOutput    │  │ LinearAPIClient  │ │
│  └──────┬───────┘  │ Monitor      │  └──────────────────┘ │
│         │          └──────────────┘                        │
│  ┌──────┴───────┐                    ┌──────────────────┐  │
│  │ SQLiteStore   │                   │ IPCListener      │  │
│  │ (GRDB.swift)  │                   │ (Unix socket)    │  │
│  └──────────────┘                    └────────┬─────────┘  │
│                                                │           │
└────────────────────────────────────────────────┼───────────┘
                                                 │
                                    /tmp/workshop-ipc.sock
                                                 │
                                    ┌────────────┴─────────┐
                                    │   MCP Server (Node)   │
                                    │   stdio ↔ Claude Code │
                                    │   UDS  ↔ Workshop.app │
                                    └────────────┬─────────┘
                                                 │
                                    ┌────────────┴─────────┐
                                    │   Claude Code CLI     │
                                    │   (child of PTY)      │
                                    └──────────────────────┘
```

### 1.2 Process Model

The app runs as a single macOS process. Each terminal session creates:
- One `LocalProcessTerminalView` (SwiftTerm NSView subclass that owns a PTY pair and child process internally)
- One `PTYOutputMonitor` instance (idle detection, taps into SwiftTerm's `TerminalViewDelegate`)
- Claude Code runs as the child process inside SwiftTerm's PTY

Claude Code in turn spawns its own MCP server subprocess (stdio-based Node.js script). The MCP server connects back to the app via Unix domain socket for IPC.

```
Workshop.app (PID 1000)
  ├── SwiftTerm LocalProcessTerminalView
  │     └── PTY pair (managed by SwiftTerm)
  │           └── claude (PID 1001)
  │                 ├── mcp-server.js (PID 1002)
  │                 │     └── UDS → /tmp/workshop-ipc.sock
  │                 └── (other claude subprocesses)
  ├── SwiftTerm LocalProcessTerminalView
  │     └── PTY pair (managed by SwiftTerm)
  │           └── claude (PID 1003)
  │                 └── mcp-server.js (PID 1004)
  │                       └── UDS → /tmp/workshop-ipc.sock
  └── NWListener on /tmp/workshop-ipc.sock
        ├── connection from PID 1002 (terminal abc)
        └── connection from PID 1004 (terminal def)
```

---

## 2. Terminal Rendering Layer

### 2.1 SwiftTerm Integration

SwiftTerm is added as a Swift Package dependency via its GitHub URL: `https://github.com/migueldeicaza/SwiftTerm`. It provides:

- **Terminal emulation**: VT100/VT220/xterm escape sequence parsing and state management, tested against the esctest compliance suite
- **CoreText rendering**: GPU-composited text rendering via `CALayer`-backed NSView using CoreText for glyph shaping, font fallback, and ligature support
- **Input handling**: Keyboard encoding (legacy xterm, CSI u), mouse events, IME, bracketed paste
- **Scrollback**: Configurable scrollback buffer
- **Image protocols**: Sixel graphics and Kitty image protocol
- **OSC support**: Window title (OSC 0/2), color changes, clipboard (OSC 52), progress notifications (OSC 9;4)
- **Unicode**: Full Unicode 15.0 support including emoji, combining characters, grapheme clusters, and bidirectional text

### 2.2 Terminal View Architecture

SwiftTerm provides two key classes for macOS:
- `TerminalView`: A bare NSView that requires manual PTY wiring
- `LocalProcessTerminalView`: A subclass of `TerminalView` that handles PTY creation, process spawning, and I/O bridging automatically

**We use `LocalProcessTerminalView` for each terminal session.** It eliminates all manual PTY management.

```swift
// Conceptual structure — not implementation code
TerminalSession {
    terminalView: LocalProcessTerminalView   // SwiftTerm NSView — owns PTY + child process
    outputMonitor: PTYOutputMonitor          // idle detection — receives output via delegate
    terminalId: UUID                         // unique identifier for this session
    trackId: UUID                            // parent work track
    name: String                             // display name in sidebar
    runtimeStatus: RuntimeStatus             // .live, .suspended, .completed
}
```

### 2.3 Launching a Process in SwiftTerm

`LocalProcessTerminalView` provides a `startProcess()` method:

```swift
let terminalView = LocalProcessTerminalView(frame: containerView.bounds)
terminalView.processDelegate = self  // notified on process exit
terminalView.terminalDelegate = self // notified on output, title changes, etc.

// Font configuration
terminalView.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
// Or: terminalView.font = NSFont(name: "JetBrains Mono", size: 13)

// Colors — SwiftTerm uses its own color model
terminalView.installColors(defaultForeground: .white, defaultBackground: .black)

// Start the child process
terminalView.startProcess(
    executable: "/bin/zsh",              // shell to run
    args: ["-l", "-c", claudeCommand],   // login shell executing claude command
    environment: environmentVars,         // [String] of "KEY=VALUE" pairs
    execName: nil                         // defaults to executable basename
)

// SwiftTerm automatically:
// - Creates a PTY pair via forkpty()
// - Forks the child process
// - Connects PTY slave to child's stdin/stdout/stderr
// - Reads PTY master on a background thread
// - Renders output via CoreText
// - Handles resize (SIGWINCH) when the view resizes
```

### 2.4 Data Flow

**Output (Claude → screen)**:
1. Claude Code writes to stdout/stderr (PTY slave side)
2. SwiftTerm reads bytes from PTY master on its internal I/O thread
3. SwiftTerm parses escape sequences, updates internal terminal state
4. SwiftTerm renders text via CoreText on the NSView's backing layer
5. SwiftTerm calls `TerminalViewDelegate.dataReceived(slice: ArraySlice<UInt8>)` — our `PTYOutputMonitor` hooks here

**Input (user → Claude)**:
1. User presses key in `LocalProcessTerminalView`
2. SwiftTerm encodes the key event per terminal protocol
3. SwiftTerm writes encoded bytes to PTY master fd
4. Claude Code reads from stdin (PTY slave side)

**Resize**:
1. NSView frame changes (window resize, etc.)
2. SwiftTerm calculates new cols/rows from view size and font metrics
3. SwiftTerm calls `ioctl(ptyMasterFD, TIOCSWINSZ, &winsize)` on the PTY
4. SIGWINCH is delivered to the child process group automatically

### 2.5 Accessing Terminal Content for Idle Detection

SwiftTerm's `Terminal` class (accessed via `terminalView.getTerminal()`) provides:
- `getScrollbackLines(startLine:count:)` — retrieve lines from scrollback buffer
- `getCharacter(col:row:)` — read individual characters from the visible buffer
- `buffer.rows` / `buffer.cols` — current terminal dimensions
- `delegate.hostCurrentDirectoryUpdated()` — fired on OSC 7 (working directory change)
- `delegate.setTerminalTitle()` — fired on OSC 0/2 (title change)

The `TerminalViewDelegate` protocol includes `dataReceived(slice:)` which fires for every chunk of raw bytes received from the PTY — this is the primary feed for the `PTYOutputMonitor`.

### 2.6 Terminal Configuration

SwiftTerm configuration is done programmatically (no config file):

```swift
// Font
terminalView.font = NSFont(name: "SF Mono", size: 13) ?? .monospacedSystemFont(ofSize: 13, weight: .regular)

// Colors: set individual palette entries
let terminal = terminalView.getTerminal()
// terminal.foregroundColor, terminal.backgroundColor are set via installColors()

// Scrollback
// Set via Terminal initializer: Terminal(delegate: self, options: TerminalOptions(scrollback: 10000))
// LocalProcessTerminalView uses a default of 10000 lines

// Cursor
terminalView.cursorStyleChanged(source: terminal, newStyle: .blinkBlock)

// TERM environment variable: set "xterm-256color" in the process environment
```

### 2.7 Process Exit Handling

Implement `LocalProcessTerminalViewDelegate.processTerminated(_:exitCode:)`:

```swift
func processTerminated(_ source: LocalProcessTerminalView, exitCode: Int32?) {
    DispatchQueue.main.async {
        self.handleTerminalExit(terminalId: self.terminalId, exitCode: exitCode)
    }
}
```

This fires when the child process (Claude Code) exits for any reason. The app updates the terminal's runtime status to `suspended` and updates the sidebar.

---

## 3. PTY Management

### 3.1 PTY Lifecycle — SwiftTerm Handles It

Unlike the GhosttyKit approach, **we do NOT manually create PTY pairs**. SwiftTerm's `LocalProcessTerminalView.startProcess()` internally calls `forkpty()` and manages the master/slave file descriptors. Our code never touches `openpty()`, `forkpty()`, or raw file descriptors.

What we do control:
- **Which executable to run** and its arguments
- **Environment variables** for the child process
- **Working directory** — set via `Process.currentDirectoryPath` or by wrapping in `cd <path> && <command>`
- **Process exit handling** via the delegate

### 3.2 PTY Lifecycle States

```
              startProcess()
                   │
                   ▼
               ┌───────┐
        ┌──────│ live  │──────┐
        │      └───┬───┘      │
        │          │          │
    app quit/  processTermi  user clicks
    SIGHUP     nated()       "Complete"
        │          │          │
        ▼          ▼          ▼
  ┌───────────┐ ┌─────────────────┐
  │ suspended │ │   completed     │
  └─────┬─────┘ └─────────────────┘
        │
    user clicks
    "Restart"
        │
        ▼
  startProcess() with
  claude --continue
        │
        ▼
    ┌───────┐
    │ live  │
    └───────┘
```

### 3.3 Child Process Environment

Environment variables passed to `startProcess()` as a `[String]` of `"KEY=VALUE"` entries:

| Variable | Value | Purpose |
|----------|-------|---------|
| `TERM` | `xterm-256color` | Terminal type for escape sequence support |
| `WORKSHOP_TERMINAL_ID` | UUID string | Identifies this terminal to the MCP server |
| `WORKSHOP_SOCKET_PATH` | `/tmp/workshop-ipc.sock` | MCP server connects here for IPC |
| `LANG` | Inherited from `ProcessInfo.processInfo.environment` | Locale for Unicode |
| `HOME` | Inherited | User's home directory |
| `PATH` | Inherited | Must include paths to `node`, `claude` |
| `COLORTERM` | `truecolor` | Signals 24-bit color support |

### 3.4 Claude Code Launch Command

The shell command passed to `startProcess()` via `/bin/zsh -l -c "<command>"`:

**New session**:
```bash
cd "{track.repoPath}" && claude \
  --worktree \
  --mcp-config "/tmp/workshop-mcp/mcp-{terminalId}.json" \
  --allowedTools "mcp__workshop__*" \
  --append-system-prompt "{escapedSystemPrompt}"
```

**Restarting a suspended session**:
```bash
cd "{track.repoPath}" && claude \
  --continue \
  --worktree \
  --mcp-config "/tmp/workshop-mcp/mcp-{terminalId}.json" \
  --allowedTools "mcp__workshop__*"
```

Note: `--append-system-prompt` (not `--system-prompt`) is used to preserve Claude Code's built-in instructions while adding our context. On restart with `--continue`, the system prompt is already in the conversation history and does not need to be re-passed.

### 3.5 Process Cleanup

**Normal quit** (`Cmd+Q`):
1. For each live terminal: get child PID from SwiftTerm (if accessible) or send SIGHUP to the process group
2. Wait up to 2 seconds for graceful exit
3. Force-kill any remaining child processes
4. Mark all terminals as `suspended` in SQLite
5. Remove IPC socket file
6. Clean up MCP config files from `/tmp/workshop-mcp/`

**App crash / force quit**:
- Child processes become orphans (reparented to launchd)
- They exit when they try to read from the PTY slave (now invalid)
- On next launch: all terminals previously marked `live` are set to `suspended` (no PID checking needed — processes cannot survive app restart since SwiftTerm owns the PTY)

---

## 4. IPC System (MCP Server ↔ App)

### 4.1 Transport: Unix Domain Socket

The app listens on a Unix domain socket at `/tmp/workshop-ipc.sock`. Each MCP server instance (one per Claude Code session) connects to this socket.

**Why UDS**:
- No macOS firewall "accept incoming connections?" dialog (unlike TCP)
- No port conflicts
- Fast local IPC, bidirectional
- Socket file permissions (`0600`) restrict access to the current user

### 4.2 Protocol: Newline-Delimited JSON (NDJSON)

Each message is a single JSON object terminated by `\n`. No framing headers.

**Connection handshake** — first message from MCP server identifies its terminal:
```json
{"type":"hello","terminal_id":"abc-123","version":1}
```

App responds:
```json
{"type":"hello_ack","status":"ok"}
```

### 4.3 Message Types

#### App-bound messages (MCP Server → App)

**log_activity**:
```json
{"type":"log_activity","terminal_id":"abc-123","message":"Fixed authentication token refresh bug","req_id":"r1"}
```
Response: `{"type":"ack","req_id":"r1","status":"ok"}`

**set_terminal_title**:
```json
{"type":"set_terminal_title","terminal_id":"abc-123","title":"Fix Auth Token Refresh","req_id":"r2"}
```
Response: `{"type":"ack","req_id":"r2","status":"ok"}`

**assign_track**:
```json
{"type":"assign_track","terminal_id":"abc-123","track_name_or_id":"Auth Refactor","description":"Refactoring auth middleware","req_id":"r3"}
```
Response: `{"type":"ack","req_id":"r3","status":"ok","track_id":"track-456","track_name":"Auth Refactor","action":"matched_existing"}`

The `action` field: `matched_existing`, `created_new`, or `error`.

**notify_user**:
```json
{"type":"notify_user","terminal_id":"abc-123","message":"Auth refactor complete","urgency":"normal","req_id":"r4"}
```
Response: `{"type":"ack","req_id":"r4","status":"ok"}`

**request_user_input**:
```json
{"type":"request_user_input","terminal_id":"abc-123","question":"Which approach?","options":["JWT","Session","OAuth2"],"req_id":"r5"}
```
Response (after user interaction):
```json
{"type":"user_input_response","req_id":"r5","answer":"JWT"}
```
Or on timeout (5 minutes):
```json
{"type":"user_input_response","req_id":"r5","error":"timeout","message":"User did not respond within 5 minutes"}
```

### 4.4 Connection Management

- `IPCListener` uses `Network.framework` (`NWListener` with `NWParameters` configured for Unix domain sockets)
- Each incoming connection is mapped to a terminal ID after the `hello` handshake
- Connections stored in a dictionary: `[String: NWConnection]` keyed by terminal ID
- If a connection drops, the MCP server reconnects with exponential backoff (max 10s)
- Stale socket file is removed on app launch before binding

### 4.5 Concurrency Model

- `NWListener` runs on a dedicated serial `DispatchQueue("com.workshop.ipc")`
- JSON parsing happens on the listener queue
- UI-affecting operations (show dialog, update sidebar) dispatch to `DispatchQueue.main`
- SQLite writes go through GRDB's serialized writer queue (`DatabasePool.write`)
- `request_user_input` responses are sent back on the listener queue after the main thread dialog completes

---

## 5. Idle Detection & Waiting State

### 5.1 PTYOutputMonitor Design

Each terminal session has a dedicated `PTYOutputMonitor` that receives raw PTY output via SwiftTerm's `TerminalViewDelegate.dataReceived(slice:)` callback.

**Components**:
- **Ring buffer** (4096 bytes): stores most recent terminal output for prompt pattern matching
- **Last output timestamp** (`Date`): updated on every `dataReceived` call
- **Timer** (`DispatchSourceTimer`, fires every 500ms): evaluates state transitions
- **ANSI stripper**: regex-based removal of `\x1b\[[0-9;]*[a-zA-Z]` and other escape sequences
- **State** (`enum DisplayStatus`): `.active`, `.thinking`, `.waiting`, `.suspended`, `.completed`
- **Callback** (`onStatusChanged: (DisplayStatus) -> Void`): fires on state transitions

### 5.2 State Machine

```
                    dataReceived() called
                           │
              ┌────────────┼────────────┐
              │            │            │
              ▼            ▼            ▼
         ┌────────┐  ┌─────────┐  ┌─────────┐
    ┌────│ active │  │thinking │  │ waiting │
    │    └────┬───┘  └────┬────┘  └────┬────┘
    │         │           │            │
    │    silence>1s  silence>3s   dataReceived()
    │         │      +prompt?      called
    │         │      ┌──┴──┐         │
    │         ▼      ▼     ▼         ▼
    │    ┌─────────┐ Y     N    ┌────────┐
    │    │thinking │ │     │    │ active │
    │    └─────────┘ ▼     ▼    └────────┘
    │           ┌────────┐┌─────────┐
    │           │waiting ││thinking │
    │           └────────┘└─────────┘
    │
    └── Any dataReceived() → immediately back to "active"
```

### 5.3 Prompt Pattern Matching

When silence exceeds 3 seconds, the monitor:
1. Extracts the last 512 bytes from the ring buffer
2. Strips ANSI escape codes via regex: `\x1b\[[0-9;]*[a-zA-Z]` and `\x1b\][^\x07]*\x07`
3. Splits into lines and tests each against prompt patterns
4. If any pattern matches → transition to `.waiting`
5. If no pattern matches → stay in `.thinking`

Patterns (applied to ANSI-stripped text):

```swift
let promptPatterns: [NSRegularExpression] = [
    try! NSRegularExpression(pattern: #"^>\s*$"#, options: .anchorsMatchLines),
    try! NSRegularExpression(pattern: #"^❯\s*$"#, options: .anchorsMatchLines),
    try! NSRegularExpression(pattern: #"^\$\s*$"#, options: .anchorsMatchLines),
    try! NSRegularExpression(pattern: #"\(y/n\)"#),
    try! NSRegularExpression(pattern: #"\[Y/n\]"#),
    try! NSRegularExpression(pattern: #"Do you want to"#),
    try! NSRegularExpression(pattern: #"Allow .+\?"#),
    try! NSRegularExpression(pattern: #"Press Enter"#),
]
```

### 5.4 OSC Notification Parsing

The `PTYOutputMonitor` also scans the raw byte stream for OSC notification sequences:

- **OSC 9**: `\x1b]9;{message}\x07` — iTerm2 notification
- **OSC 99**: `\x1b]99;{params};{message}\x07` — Kitty notification
- **OSC 777**: `\x1b]777;notify;{title};{body}\x07` — rxvt notification

When detected, the app fires a macOS notification immediately — no silence delay needed. This is parsed from raw bytes before ANSI stripping, using a simple state machine that looks for `\x1b]` start and `\x07` or `\x1b\\` terminator.

### 5.5 Notification Delivery

On transition to `.waiting`:
1. Update the terminal's sidebar row — show amber indicator and `[!]` badge
2. Increment dock badge count: `NSApp.dockTile.badgeLabel = String(waitingCount)`
3. Fire macOS notification via `UNUserNotificationCenter`:
   ```swift
   let content = UNMutableNotificationContent()
   content.title = "Workshop"
   content.body = "\(terminalName) is waiting for input"
   content.sound = .default
   content.userInfo = ["terminalId": terminalId.uuidString]
   let request = UNNotificationRequest(
       identifier: "waiting-\(terminalId)",
       content: content,
       trigger: UNTimeIntervalNotificationTrigger(timeInterval: 0.1, repeats: false)
   )
   UNUserNotificationCenter.current().add(request)
   ```
4. Clicking the notification → `UNUserNotificationCenterDelegate.didReceive` → switch to that terminal
5. **Debounce**: only fire one notification per waiting→non-waiting cycle. Use a `Set<UUID>` tracking terminals that have already been notified in their current waiting period.

On transition away from `.waiting`:
1. Decrement dock badge count (set to `nil` if zero)
2. Remove attention indicator from sidebar
3. Remove terminal from the "already notified" set

---

## 6. MCP Server

### 6.1 Overview

The MCP server is a Node.js script bundled in the app at `Workshop.app/Contents/Resources/workshop-mcp-server.js`. It uses `@modelcontextprotocol/sdk` for MCP protocol handling and `net` for Unix domain socket IPC with the app.

It communicates with Claude Code via stdio (standard MCP protocol) and with Workshop.app via UDS.

### 6.2 MCP Config Generation

For each terminal session, the app generates a JSON config at `/tmp/workshop-mcp/mcp-{terminalId}.json`:

```json
{
  "mcpServers": {
    "workshop": {
      "command": "node",
      "args": ["/path/to/Workshop.app/Contents/Resources/workshop-mcp-server.js"],
      "env": {
        "WORKSHOP_TERMINAL_ID": "abc-123",
        "WORKSHOP_SOCKET_PATH": "/tmp/workshop-ipc.sock"
      }
    }
  }
}
```

The path to the MCP server script is resolved at runtime via `Bundle.main.resourcePath`.

MCP config files are created with `FileManager` and permissions set to `0600`:
```swift
FileManager.default.createFile(atPath: path, contents: data, attributes: [.posixPermissions: 0o600])
```

### 6.3 MCP Server Implementation

```javascript
#!/usr/bin/env node

import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { z } from "zod";
import net from "net";

const TERMINAL_ID = process.env.WORKSHOP_TERMINAL_ID;
const SOCKET_PATH = process.env.WORKSHOP_SOCKET_PATH;

// IPC connection to Workshop.app
let ipcSocket = null;
let pendingRequests = new Map(); // req_id → {resolve, reject, timeout}
let reqCounter = 0;

function connectIPC() {
    ipcSocket = net.createConnection(SOCKET_PATH, () => {
        sendIPC({ type: "hello", terminal_id: TERMINAL_ID, version: 1 });
    });

    let buffer = "";
    ipcSocket.on("data", (data) => {
        buffer += data.toString();
        const lines = buffer.split("\n");
        buffer = lines.pop(); // keep incomplete line
        for (const line of lines) {
            if (!line.trim()) continue;
            const msg = JSON.parse(line);
            if (msg.req_id && pendingRequests.has(msg.req_id)) {
                const pending = pendingRequests.get(msg.req_id);
                clearTimeout(pending.timeout);
                pendingRequests.delete(msg.req_id);
                pending.resolve(msg);
            }
        }
    });

    ipcSocket.on("error", () => {
        setTimeout(connectIPC, Math.min(1000 * Math.pow(2, reconnectAttempts++), 10000));
    });
}

function sendIPC(msg) {
    if (ipcSocket && !ipcSocket.destroyed) {
        ipcSocket.write(JSON.stringify(msg) + "\n");
    }
}

function sendIPCAndWait(msg, timeoutMs = 30000) {
    return new Promise((resolve, reject) => {
        const req_id = `r${++reqCounter}`;
        msg.req_id = req_id;
        msg.terminal_id = TERMINAL_ID;
        const timeout = setTimeout(() => {
            pendingRequests.delete(req_id);
            reject(new Error("IPC timeout"));
        }, timeoutMs);
        pendingRequests.set(req_id, { resolve, reject, timeout });
        sendIPC(msg);
    });
}

// MCP server setup
const server = new McpServer({
    name: "workshop-tools",
    version: "1.0.0",
});

server.tool("log_activity",
    { message: z.string().describe("Activity description") },
    async ({ message }) => {
        const resp = await sendIPCAndWait({ type: "log_activity", message });
        return { content: [{ type: "text", text: `Activity logged: ${message}` }] };
    }
);

server.tool("set_terminal_title",
    { title: z.string().describe("New terminal title") },
    async ({ title }) => {
        const resp = await sendIPCAndWait({ type: "set_terminal_title", title });
        return { content: [{ type: "text", text: `Title updated to: ${title}` }] };
    }
);

server.tool("assign_track",
    {
        track_name_or_id: z.string().describe("Name or ID of the target work track"),
        description: z.string().optional().describe("Description for a new track"),
    },
    async ({ track_name_or_id, description }) => {
        const resp = await sendIPCAndWait({
            type: "assign_track",
            track_name_or_id,
            description: description || "",
        });
        return {
            content: [{
                type: "text",
                text: `Assigned to track "${resp.track_name}" (${resp.action})`,
            }],
        };
    }
);

server.tool("notify_user",
    {
        message: z.string().describe("Notification message"),
        urgency: z.enum(["low", "normal", "critical"]).optional().describe("low=sidebar, normal=OS notif, critical=dock bounce"),
    },
    async ({ message, urgency }) => {
        const resp = await sendIPCAndWait({
            type: "notify_user",
            message,
            urgency: urgency || "normal",
        });
        return { content: [{ type: "text", text: `User notified: ${message}` }] };
    }
);

server.tool("request_user_input",
    {
        question: z.string().describe("Question to ask the user"),
        options: z.array(z.string()).optional().describe("Button options; omit for text input"),
    },
    async ({ question, options }) => {
        const resp = await sendIPCAndWait(
            { type: "request_user_input", question, options: options || null },
            5 * 60 * 1000 // 5 minute timeout
        );
        if (resp.error) {
            return { content: [{ type: "text", text: `Error: ${resp.message}` }], isError: true };
        }
        return { content: [{ type: "text", text: `User answered: ${resp.answer}` }] };
    }
);

// Start
connectIPC();
const transport = new StdioServerTransport();
await server.connect(transport);
```

### 6.4 System Prompt Construction

When launching Claude Code, the app assembles the `--append-system-prompt` value:

```
You are working on: {track.name}
Terminal purpose: {terminal.name}

{if track.linearTicketUrl}
Linear ticket: {track.linearTicketUrl}
Ticket: {linearIssue.identifier} — {linearIssue.title}
Description:
{linearIssue.description}
Labels: {linearIssue.labels joined with ", "}
State: {linearIssue.state}
{/if}

{if track.contextNotes is not empty}
Context:
{track.contextNotes}
{/if}

{if track.referenceFiles is not empty}
Reference files:
{for each file}
- {file.filePath} — "{file.description}"
{/for}
{/if}

IMPORTANT — Workshop Tools:
You have access to Workshop MCP tools. Use them proactively:
- log_activity: Log milestones frequently (features done, tests passing, blockers hit)
- set_terminal_title: Update your terminal name to reflect current task
- assign_track: Assign yourself to a work track based on your task context
- notify_user: Alert the user when you finish major work or hit a blocker
- request_user_input: Ask the user when you need a decision you cannot make from context

Begin working on this task immediately. Start by reading the relevant code and planning your approach.
```

---

## 7. Data Layer

### 7.1 SQLite Database

Location: `~/.workshop/workshop.db`

Created on first launch. Directory `~/.workshop/` is created if it doesn't exist.

ORM: **GRDB.swift** (~> 7.0) — provides migrations via `DatabaseMigrator`, `Codable` record mapping, thread-safe `DatabasePool`, and `ValueObservation` for reactive UI updates.

### 7.2 Schema

```sql
-- Migration 1: Base schema
CREATE TABLE work_tracks (
    id TEXT PRIMARY KEY,                          -- UUID string
    name TEXT NOT NULL,
    repo_path TEXT NOT NULL,
    branch TEXT NOT NULL,
    linear_ticket_url TEXT,
    context_notes TEXT DEFAULT '',
    status TEXT NOT NULL DEFAULT 'active',         -- 'active' or 'archived'
    created_at TEXT NOT NULL,                      -- ISO 8601
    updated_at TEXT NOT NULL                       -- ISO 8601
);

CREATE TABLE terminals (
    id TEXT PRIMARY KEY,                           -- UUID string
    track_id TEXT NOT NULL REFERENCES work_tracks(id),
    name TEXT NOT NULL,
    runtime_status TEXT NOT NULL DEFAULT 'live',   -- 'live', 'suspended', 'completed'
    created_at TEXT NOT NULL,                      -- ISO 8601
    last_accessed_at TEXT                          -- ISO 8601, updated on focus
);

CREATE INDEX idx_terminals_track ON terminals(track_id);
CREATE INDEX idx_terminals_status ON terminals(runtime_status);

CREATE TABLE reference_files (
    id TEXT PRIMARY KEY,                           -- UUID string
    track_id TEXT NOT NULL REFERENCES work_tracks(id) ON DELETE CASCADE,
    file_path TEXT NOT NULL,
    description TEXT DEFAULT '',
    sort_order INTEGER NOT NULL DEFAULT 0
);

CREATE TABLE activity_log (
    id TEXT PRIMARY KEY,                           -- UUID string
    terminal_id TEXT NOT NULL REFERENCES terminals(id) ON DELETE CASCADE,
    message TEXT NOT NULL,
    created_at TEXT NOT NULL                       -- ISO 8601
);

CREATE INDEX idx_activity_log_terminal ON activity_log(terminal_id);

-- Migration 2: Track matching metadata (for fuzzy assign_track)
CREATE TABLE track_keywords (
    id TEXT PRIMARY KEY,
    track_id TEXT NOT NULL REFERENCES work_tracks(id) ON DELETE CASCADE,
    keyword TEXT NOT NULL
);
```

### 7.3 GRDB Record Types

Each table maps to a Swift struct conforming to `Codable`, `FetchableRecord`, `PersistableRecord`:

```swift
struct WorkTrack: Codable, FetchableRecord, PersistableRecord, Identifiable {
    var id: String           // UUID().uuidString
    var name: String
    var repoPath: String
    var branch: String
    var linearTicketUrl: String?
    var contextNotes: String
    var status: String       // "active" | "archived"
    var createdAt: String    // ISO 8601
    var updatedAt: String    // ISO 8601
    
    static let databaseTableName = "work_tracks"
}

struct Terminal: Codable, FetchableRecord, PersistableRecord, Identifiable {
    var id: String
    var trackId: String
    var name: String
    var runtimeStatus: String  // "live" | "suspended" | "completed"
    var createdAt: String
    var lastAccessedAt: String?
    
    static let databaseTableName = "terminals"
}

struct ReferenceFile: Codable, FetchableRecord, PersistableRecord, Identifiable {
    var id: String
    var trackId: String
    var filePath: String
    var description: String
    var sortOrder: Int
    
    static let databaseTableName = "reference_files"
}

struct ActivityLogEntry: Codable, FetchableRecord, PersistableRecord, Identifiable {
    var id: String
    var terminalId: String
    var message: String
    var createdAt: String
    
    static let databaseTableName = "activity_log"
}
```

### 7.4 Reactive UI Updates

GRDB's `ValueObservation` observes database changes and updates the UI:

```swift
// Observe all tracks with terminal counts — drives the sidebar
let observation = ValueObservation.tracking { db in
    try WorkTrack
        .filter(Column("status") == "active")
        .order(Column("updated_at").desc)
        .fetchAll(db)
}
observation.start(in: dbPool, onError: { error in
    print("DB observation error: \(error)")
}, onChange: { [weak self] tracks in
    self?.updateSidebar(with: tracks)
})
```

Observations that drive the UI:
- Sidebar track list: observes `work_tracks` + `terminals` (grouped by track with count by status)
- Activity feed: observes `activity_log` filtered by selected terminal
- Terminal name: observes `terminals.name` for the focused terminal

---

## 8. Linear Integration

### 8.1 API Client

Uses Linear's GraphQL API at `https://api.linear.app/graphql`.

**Authentication**: Personal API key (format `lin_api_*`) stored in macOS Keychain:

```swift
struct KeychainHelper {
    static let service = "com.workshop-native"
    
    static func save(key: String, value: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecAttrService as String: service,
            kSecValueData as String: value.data(using: .utf8)!,
        ]
        SecItemDelete(query as CFDictionary)
        return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
    }
    
    static func load(key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
```

### 8.2 Issue Query

```graphql
query GetIssue($id: String!) {
    issue(id: $id) {
        id
        identifier
        title
        description
        url
        priority
        priorityLabel
        dueDate
        state { name type }
        labels { nodes { name } }
        project { name }
        team { name key }
        assignee { name }
    }
}
```

### 8.3 URL Parsing

```swift
struct LinearURLParser {
    // Matches: https://linear.app/{workspace}/issue/{TEAM-123}/{optional-slug}
    static let pattern = try! NSRegularExpression(pattern: #"/issue/([A-Z]+-\d+)"#)
    
    static func extractIdentifier(from url: URL) -> String? {
        let path = url.path
        guard let match = pattern.firstMatch(in: path, range: NSRange(path.startIndex..., in: path)),
              let range = Range(match.range(at: 1), in: path) else { return nil }
        return String(path[range])
    }
}
```

### 8.4 HTTP Client

Raw `URLSession` — no third-party GraphQL library needed:

```swift
class LinearAPIClient {
    let apiKey: String
    
    func fetchIssue(identifier: String) async throws -> LinearIssue {
        var request = URLRequest(url: URL(string: "https://api.linear.app/graphql")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "Authorization") // No "Bearer" prefix
        
        let body: [String: Any] = [
            "query": Self.issueQuery,
            "variables": ["id": identifier]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw LinearError.requestFailed
        }
        
        let result = try JSONDecoder().decode(GraphQLResponse<IssueData>.self, from: data)
        return result.data.issue
    }
}
```

### 8.5 Drag-and-Drop

The sidebar's drop zone (or the entire window) registers for URL drag types:

```swift
class LinearDropView: NSView {
    var onIssueDrop: ((String) -> Void)? // callback with issue identifier
    
    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.URL, .string])
    }
    
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard extractLinearURL(from: sender) != nil else { return [] }
        // Show visual feedback — highlight border, change background
        return .copy
    }
    
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let url = extractLinearURL(from: sender),
              let identifier = LinearURLParser.extractIdentifier(from: url) else { return false }
        onIssueDrop?(identifier)
        return true
    }
    
    private func extractLinearURL(from sender: NSDraggingInfo) -> URL? {
        if let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self]) as? [URL] {
            return urls.first(where: { $0.host?.contains("linear.app") == true })
        }
        if let string = sender.draggingPasteboard.string(forType: .string),
           let url = URL(string: string), url.host?.contains("linear.app") == true {
            return url
        }
        return nil
    }
}
```

---

## 9. Application Lifecycle

### 9.1 Launch Sequence

1. Initialize `SQLiteStore` — open/create `~/.workshop/workshop.db`, run pending `DatabaseMigrator` migrations
2. Start `IPCListener` — remove stale socket at `/tmp/workshop-ipc.sock`, bind new `NWListener`
3. Reconcile terminals — set all terminals with `runtime_status = 'live'` to `suspended` (processes cannot survive app restart)
4. Load work tracks and terminals from database
5. Create main `NSWindow` with `NSSplitViewController` — sidebar + terminal area
6. Request notification permission: `UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])`
7. Set `UNUserNotificationCenter.current().delegate = self` to handle notifications while app is frontmost

### 9.2 Shutdown Sequence

1. Stop `IPCListener` — close all `NWConnection`s, cancel `NWListener`, remove socket file
2. For each live terminal:
   a. The `LocalProcessTerminalView` will send SIGHUP to the child process group when deallocated
   b. Alternatively, explicitly terminate: SwiftTerm handles cleanup
3. Mark all terminals as `suspended` in SQLite
4. Close `SQLiteStore` database connection (GRDB handles WAL checkpointing)
5. Clean up MCP config files: `rm /tmp/workshop-mcp/mcp-*.json`

### 9.3 State Restoration

On relaunch after quit or crash:
- All terminals are marked `suspended` (step 3 of launch sequence)
- Suspended terminals show in sidebar with gray indicator and "Restart" button
- Restarting launches `claude --continue --worktree` to resume conversation and worktree
- Track metadata, activity logs, and reference files are fully preserved in SQLite

---

## 10. Security Considerations

| Concern | Mitigation |
|---------|-----------|
| Linear API key storage | macOS Keychain (`SecItemAdd`/`SecItemCopyMatching`), not plaintext |
| IPC socket permissions | Created with mode `0600` (owner read/write only) |
| MCP config files | Written to `/tmp/workshop-mcp/` with mode `0600`, cleaned up on shutdown |
| Process isolation | Each Claude Code runs in its own PTY with its own environment |
| No network listeners | Unix domain socket only — no TCP ports, no firewall prompts |

---

## 11. Dependencies & Build

### 11.1 Swift Package Dependencies

| Package | URL | Version | Purpose |
|---------|-----|---------|---------|
| SwiftTerm | `https://github.com/migueldeicaza/SwiftTerm` | ~> 1.11 | Terminal emulation + CoreText rendering |
| GRDB.swift | `https://github.com/groue/GRDB.swift` | ~> 7.0 | SQLite ORM, migrations, reactive observation |

**No other Swift package dependencies.** Keychain access uses the Security framework directly (see §8.1).

### 11.2 System Frameworks

| Framework | Purpose |
|-----------|---------|
| AppKit | UI, window management, drag-and-drop, NSOutlineView |
| Network | Unix domain socket listener (`NWListener`, `NWConnection`) |
| UserNotifications | macOS notification center (`UNUserNotificationCenter`) |
| UniformTypeIdentifiers | Drag-and-drop type identification |
| Security | Keychain access (`SecItemAdd`, `SecItemCopyMatching`) |

### 11.3 Runtime Requirements

| Requirement | Why |
|-------------|-----|
| macOS 14+ (Sonoma) | Modern Network.framework, UNUserNotificationCenter features |
| Node.js 20+ | MCP server runtime (also required by Claude Code itself) |
| `claude` CLI | Claude Code — the thing we're orchestrating |
| npm packages: `@modelcontextprotocol/sdk`, `zod` | MCP server dependencies — installed during build |

### 11.4 MCP Server Build Step

The MCP server (`workshop-mcp-server.js`) needs its npm dependencies. Add a build phase or setup script:

```bash
cd Resources/mcp-server
npm install --production
# or bundle with esbuild:
npx esbuild src/index.ts --bundle --platform=node --outfile=../workshop-mcp-server.js
```

For workshop simplicity, bundle a single-file output via esbuild so attendees don't need to run `npm install` separately.

### 11.5 Build Configuration

- Xcode project with Swift Package Manager integration
- Deployment target: macOS 14.0
- Hardened runtime: enabled (required for notarization, though not distributing)
- App Sandbox: **disabled** (PTY access requires it)
- No entitlements beyond default

---

## 12. File Structure

```
Workshop/
├── Workshop.xcodeproj
├── Package.swift                          # SPM manifest (SwiftTerm, GRDB)
├── Sources/
│   ├── App/
│   │   ├── AppDelegate.swift              # Launch/shutdown, notification delegate
│   │   ├── WindowManager.swift            # Main window creation, NSSplitViewController
│   │   └── PreferencesWindowController.swift  # Linear API key setup
│   ├── Models/
│   │   ├── WorkTrack.swift                # GRDB record
│   │   ├── Terminal.swift                 # GRDB record
│   │   ├── ReferenceFile.swift            # GRDB record
│   │   ├── ActivityLogEntry.swift         # GRDB record
│   │   ├── LinearIssue.swift              # Codable struct for API response
│   │   └── DisplayStatus.swift            # enum: active, thinking, waiting, suspended, completed
│   ├── Views/
│   │   ├── MainSplitViewController.swift  # NSSplitViewController (sidebar + terminal)
│   │   ├── SidebarViewController.swift    # NSOutlineView with tracks/terminals
│   │   ├── TerminalContainerView.swift    # Hosts the active LocalProcessTerminalView
│   │   ├── StatusDotView.swift            # Colored circle indicator NSView
│   │   ├── LinearDropView.swift           # Drag-and-drop target for Linear URLs
│   │   ├── NewTrackSheet.swift            # Sheet for manual track creation
│   │   ├── LinearConfirmSheet.swift       # Confirmation sheet after drag-and-drop
│   │   ├── UserInputSheet.swift           # NSAlert sheet for request_user_input
│   │   └── TrackContextEditor.swift       # Editing track metadata (future enhancement)
│   ├── Services/
│   │   ├── SQLiteStore.swift              # GRDB DatabasePool, migrations, queries
│   │   ├── SessionManager.swift           # Creates/destroys TerminalSessions, holds active sessions
│   │   ├── PTYOutputMonitor.swift         # Ring buffer + timer + prompt matching
│   │   ├── IPCListener.swift              # NWListener on Unix domain socket
│   │   ├── IPCMessageHandler.swift        # Parses NDJSON, dispatches to handlers
│   │   ├── LinearAPIClient.swift          # GraphQL client for Linear issue fetching
│   │   ├── NotificationManager.swift      # UNUserNotificationCenter wrapper, dock badge
│   │   ├── MCPConfigGenerator.swift       # Writes /tmp/workshop-mcp/mcp-{id}.json
│   │   └── ClaudeCommandBuilder.swift     # Assembles claude CLI flags and system prompt
│   └── Utilities/
│       ├── RingBuffer.swift               # Fixed-size circular byte buffer
│       ├── ANSIStripper.swift             # Regex-based ANSI escape code removal
│       ├── FuzzyMatcher.swift             # Levenshtein distance for assign_track matching
│       ├── KeychainHelper.swift           # Security framework wrapper
│       └── LinearURLParser.swift          # URL → issue identifier extraction
├── Resources/
│   ├── workshop-mcp-server.js             # Bundled MCP server (esbuild single-file output)
│   └── Assets.xcassets                    # App icon, status indicator images
├── mcp-server/                            # MCP server source (TypeScript)
│   ├── package.json
│   ├── tsconfig.json
│   └── src/
│       └── index.ts                       # MCP server implementation
└── Tests/
    ├── PTYOutputMonitorTests.swift
    ├── ANSIStripperTests.swift
    ├── FuzzyMatcherTests.swift
    ├── LinearURLParserTests.swift
    ├── IPCProtocolTests.swift
    └── SQLiteStoreTests.swift
```
