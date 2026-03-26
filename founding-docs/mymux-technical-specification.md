# mymux -- Technical Specification

This document contains every implementation detail required to build mymux from scratch. It is written for an AI agent using speckit to one-shot implement the entire application. Every gotcha discovered during development is marked with **CRITICAL**.

---

## 1. System Architecture

### 1.1 Process Model

```
mymux.app (single macOS process)
  |
  +-- SwiftTerm LocalProcessTerminalView (one per terminal)
  |     |
  |     +-- PTY pair (managed internally by SwiftTerm)
  |           |
  |           +-- /bin/zsh -l -c "cd <repo> && claude <flags>"
  |                 |
  |                 +-- mymux-mcp-server.mjs (Node.js, spawned by claude as MCP subprocess)
  |                       |
  |                       +-- UDS connection --> /tmp/mymux-ipc.sock
  |
  +-- IPCListener (POSIX socket server on /tmp/mymux-ipc.sock)
  |     |
  |     +-- DispatchSource.makeReadSource (accept new clients)
  |     +-- Per-client DispatchSourceRead (read NDJSON messages)
  |
  +-- SessionManager (owns active TerminalContainerView instances)
  +-- SQLiteStore (GRDB DatabasePool at ~/.mymux/mymux.db)
  +-- GitStatusChecker (utility-priority dispatch queue, polls every 10s)
  +-- NotificationManager (UNUserNotificationCenter + dock badge)
```

### 1.2 Data Flow: Claude --> App

```
Claude Code
  --> stdio --> MCP Server (Node.js)
    --> UDS (NDJSON) --> IPCListener
      --> IPCMessageHandler
        --> SQLiteStore (persist activity log, title changes)
        --> NotificationManager (notify_user)
        --> SessionManager (working directory updates)
```

### 1.3 Data Flow: App --> Claude

The app does not send commands to Claude. Communication is one-directional from Claude's MCP tools to the app, except for `request_user_input` which returns a response through the same IPC socket.

### 1.4 Component List

| Component | Role |
|-----------|------|
| `main.swift` | Entry point, creates NSApp, sets activation policy |
| `AppDelegate` | Lifecycle, wires IPC/SessionManager/WindowManager |
| `WindowManager` | Creates NSWindow, owns MainSplitViewController |
| `MainSplitViewController` | NSSplitViewController with sidebar + terminal area |
| `SidebarViewController` | NSOutlineView with tracks and terminals |
| `TerminalAreaViewController` | Hosts focused terminal, activity panel, shell panel |
| `TerminalContainerView` | NSView wrapping WorkshopTerminalView + PTYOutputMonitor |
| `WorkshopTerminalView` | LocalProcessTerminalView subclass for output interception |
| `ShellTerminalPanelView` | Tabbed shell terminals at bottom of terminal area |
| `ActivityPanelView` | Right-side panel showing activity log entries |
| `StatusDotView` | Custom NSView drawing colored status indicators |
| `NewTrackSheet` | Modal sheet for creating a new work track |
| `SessionManager` | Spawns/restarts/removes terminal sessions |
| `SQLiteStore` | GRDB DatabasePool, migrations, CRUD operations |
| `PTYOutputMonitor` | Ring buffer, timer, ANSI stripping, state machine |
| `IPCListener` | POSIX Unix domain socket server |
| `IPCMessageHandler` | Routes IPC messages to appropriate handlers |
| `ClaudeCommandBuilder` | Builds claude CLI command + environment variables |
| `MCPConfigGenerator` | Writes per-terminal MCP config JSON files |
| `GitStatusChecker` | Polls git status for terminals with known working dirs |
| `NotificationManager` | UNUserNotificationCenter + dock badge management |
| `RingBuffer` | Fixed-capacity circular byte buffer |
| `ANSIStripper` | Regex-based ANSI escape sequence removal |
| `FuzzyMatcher` | Levenshtein distance + substring matching |
| `StringExtensions` | `toKebabCase()` on String |

---

## 2. Terminal Rendering Layer

### 2.1 SwiftTerm Integration

SwiftTerm is added via SPM: `https://github.com/migueldeicaza/SwiftTerm` (from: "1.11.0").

Two key classes:
- `TerminalView` -- bare NSView requiring manual PTY wiring
- `LocalProcessTerminalView` -- subclass that manages PTY creation, process spawning, and I/O bridging automatically

**We use `LocalProcessTerminalView` exclusively.**

### 2.2 Delegate Architecture

**CRITICAL**: `LocalProcessTerminalView` already conforms to `TerminalViewDelegate` internally. Do NOT also conform your container to `TerminalViewDelegate`. Doing so creates duplicate conformance and undefined behavior.

Instead, use two mechanisms:

1. **`LocalProcessTerminalViewDelegate`** -- set via `.processDelegate` property. Provides process lifecycle callbacks:

```swift
// CRITICAL: Note the exact parameter types -- they are NOT uniform
func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int)
func setTerminalTitle(source: LocalProcessTerminalView, title: String)
func processTerminated(source: TerminalView, exitCode: Int32?)  // NOTE: TerminalView, not LocalProcessTerminalView
func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?)  // NOTE: TerminalView, not LocalProcessTerminalView
```

2. **Subclass `LocalProcessTerminalView`** to override `dataReceived(slice:)` for output monitoring:

```swift
final class MymuxTerminalView: LocalProcessTerminalView {
    var outputMonitor: PTYOutputMonitor?

    override func dataReceived(slice: ArraySlice<UInt8>) {
        super.dataReceived(slice: slice)  // MUST call super first
        outputMonitor?.dataReceived(slice)
    }
}
```

### 2.3 Starting a Process

```swift
terminalView.startProcess(
    executable: "/bin/zsh",
    args: ["-l", "-c", command],
    environment: env,  // [String] of "KEY=VALUE" pairs
    execName: nil
)
```

The `environment` parameter is an array of `"KEY=VALUE"` strings, NOT a dictionary.

### 2.4 Font Configuration

```swift
terminalView.font = NSFont(name: "SF Mono", size: 13)
    ?? NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
```

### 2.5 Color Configuration

**CRITICAL**: `installColors()` takes a `[Color]` array, not named foreground/background parameters.

### 2.6 OSC 7 Working Directory

`hostCurrentDirectoryUpdate` receives a `file://` URL string from OSC 7. You must extract the path:

```swift
func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
    guard let dir = directory else { return }
    let path: String
    if dir.hasPrefix("file://") {
        path = URL(string: dir)?.path ?? dir
    } else {
        path = dir
    }
    // Use path
}
```

---

## 3. SPM Executable Considerations

**CRITICAL: These are the most common build failures. Get these wrong and the app will silently fail to launch or crash at startup.**

### 3.1 Entry Point: Use Explicit main.swift

Do NOT use `@main` on AppDelegate. The `@main` attribute does not reliably start `NSApplication` for SPM executable targets.

```swift
// main.swift
import AppKit

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
```

**CRITICAL**: `app.setActivationPolicy(.regular)` MUST be called before `app.run()`. Without it:
- No Dock icon appears
- Windows cannot receive focus
- The app appears to run but is invisible

### 3.2 Bundle Identifier Guard

**CRITICAL**: `UNUserNotificationCenter.current()` CRASHES at runtime if there is no bundle identifier. SPM executables run via `swift run` do NOT have a bundle identifier.

Guard ALL notification center access:

```swift
if Bundle.main.bundleIdentifier != nil {
    let center = UNUserNotificationCenter.current()
    center.delegate = self
    center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
        // ...
    }
} else {
    print("No bundle identifier -- skipping UNUserNotificationCenter setup")
}
```

This guard must appear on EVERY call to `UNUserNotificationCenter.current()`, not just initialization.

### 3.3 Database Path

Use `~/.mymux/` as the database directory:

```swift
let dbDir = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".mymux")
try FileManager.default.createDirectory(at: dbDir, withIntermediateDirectories: true)
let dbPath = dbDir.appendingPathComponent("mymux.db").path
```

### 3.4 Build and Run

```bash
cd Mymux && swift run
```

The Package.swift must use `.executableTarget` (not `.target`):

```swift
.executableTarget(
    name: "Mymux",
    dependencies: [
        "SwiftTerm",
        .product(name: "GRDB", package: "GRDB.swift"),
    ],
    path: "Sources"
),
```

---

## 4. Data Layer

### 4.1 SQLite Schema

5 tables across 3 migrations:

#### Migration 001: Base Schema

```sql
CREATE TABLE work_tracks (
    id          TEXT PRIMARY KEY,
    name        TEXT NOT NULL,
    repoPath    TEXT NOT NULL,
    branch      TEXT NOT NULL,
    linearTicketUrl TEXT,
    contextNotes TEXT DEFAULT '',
    status      TEXT NOT NULL DEFAULT 'active',
    createdAt   TEXT NOT NULL,
    updatedAt   TEXT NOT NULL
);

CREATE TABLE terminals (
    id              TEXT PRIMARY KEY,
    trackId         TEXT NOT NULL REFERENCES work_tracks(id) ON DELETE CASCADE,
    name            TEXT NOT NULL,
    runtimeStatus   TEXT NOT NULL DEFAULT 'live',
    createdAt       TEXT NOT NULL,
    lastAccessedAt  TEXT
);
CREATE INDEX idx_terminals_track ON terminals(trackId);
CREATE INDEX idx_terminals_status ON terminals(runtimeStatus);

CREATE TABLE reference_files (
    id          TEXT PRIMARY KEY,
    trackId     TEXT NOT NULL REFERENCES work_tracks(id) ON DELETE CASCADE,
    filePath    TEXT NOT NULL,
    description TEXT DEFAULT '',
    sortOrder   INTEGER NOT NULL DEFAULT 0
);

CREATE TABLE activity_log (
    id          TEXT PRIMARY KEY,
    terminalId  TEXT NOT NULL REFERENCES terminals(id) ON DELETE CASCADE,
    message     TEXT NOT NULL,
    createdAt   TEXT NOT NULL
);
CREATE INDEX idx_activity_log_terminal ON activity_log(terminalId);
```

#### Migration 002: Track Keywords

```sql
CREATE TABLE track_keywords (
    id       TEXT PRIMARY KEY,
    trackId  TEXT NOT NULL REFERENCES work_tracks(id) ON DELETE CASCADE,
    keyword  TEXT NOT NULL
);
```

#### Migration 003: Worktree Name

```sql
ALTER TABLE terminals ADD COLUMN worktreeName TEXT NOT NULL DEFAULT '';
```

### 4.2 GRDB Configuration

```swift
let dbPool = try DatabasePool(path: dbPath)

var migrator = DatabaseMigrator()

#if DEBUG
migrator.eraseDatabaseOnSchemaChange = true  // Wipe DB on schema mismatch in debug
#endif

migrator.registerMigration("001_baseSchema") { db in /* ... */ }
migrator.registerMigration("002_trackKeywords") { db in /* ... */ }
migrator.registerMigration("003_worktreeName") { db in /* ... */ }

try migrator.migrate(dbPool)
```

### 4.3 Models (GRDB Records)

All models conform to `Codable, FetchableRecord, PersistableRecord, Identifiable`.

All IDs are `UUID().uuidString`.

All timestamps are ISO8601 strings: `ISO8601DateFormatter().string(from: Date())`.

#### WorkTrack

```swift
struct WorkTrack: Codable, FetchableRecord, PersistableRecord, Identifiable {
    var id: String
    var name: String
    var repoPath: String
    var branch: String
    var linearTicketUrl: String?
    var contextNotes: String
    var status: String              // "active" | "archived"
    var createdAt: String
    var updatedAt: String

    static let databaseTableName = "work_tracks"
    static let terminals = hasMany(Terminal.self, using: Terminal.trackForeignKey)
    static let referenceFiles = hasMany(ReferenceFile.self)
    static let trackKeywords = hasMany(TrackKeyword.self)
}
```

#### Terminal

```swift
struct Terminal: Codable, FetchableRecord, PersistableRecord, Identifiable {
    var id: String
    var trackId: String
    var name: String
    var worktreeName: String        // Derived from name via toKebabCase()
    var runtimeStatus: String       // "live" | "suspended" | "completed"
    var createdAt: String
    var lastAccessedAt: String?

    static let databaseTableName = "terminals"
    static let trackForeignKey = ForeignKey(["trackId"])
    static let track = belongsTo(WorkTrack.self, using: trackForeignKey)

    init(/* ... */) {
        // ...
        self.worktreeName = worktreeName ?? name.toKebabCase()
    }
}
```

#### ActivityLogEntry

```swift
struct ActivityLogEntry: Codable, FetchableRecord, PersistableRecord, Identifiable {
    var id: String
    var terminalId: String
    var message: String
    var createdAt: String

    static let databaseTableName = "activity_log"
}
```

#### ReferenceFile

```swift
struct ReferenceFile: Codable, FetchableRecord, PersistableRecord, Identifiable {
    var id: String
    var trackId: String
    var filePath: String
    var description: String
    var sortOrder: Int

    static let databaseTableName = "reference_files"
}
```

#### TrackKeyword

```swift
struct TrackKeyword: Codable, FetchableRecord, PersistableRecord, Identifiable {
    var id: String
    var trackId: String
    var keyword: String

    static let databaseTableName = "track_keywords"
}
```

### 4.4 Enums

```swift
enum DisplayStatus: String, Codable {
    case active, thinking, waiting, suspended, completed
}

enum RuntimeStatus: String, Codable {
    case live, suspended, completed
}

enum TrackStatus: String, Codable {
    case active, archived
}
```

### 4.5 Reactive Sidebar Updates

Use GRDB `ValueObservation` for live sidebar data:

```swift
let observation = ValueObservation.tracking { db -> ([WorkTrack], [Terminal]) in
    let tracks = try WorkTrack.order(Column("updatedAt").desc).fetchAll(db)
    let terminals = try Terminal.order(Column("createdAt").asc).fetchAll(db)
    return (tracks, terminals)
}
self.observation = observation.start(in: sqliteStore.dbPool, onError: { error in
    print("Sidebar observation error: \(error)")
}, onChange: { [weak self] (tracks, terminals) in
    self?.tracks = tracks
    self?.terminalsByTrack = Dictionary(grouping: terminals, by: \.trackId)
    self?.outlineView.reloadData()
    for track in tracks {
        self?.outlineView.expandItem(track.id)
    }
})
```

Similarly for the Activity panel:

```swift
let observation = ValueObservation.tracking { db in
    try ActivityLogEntry
        .filter(Column("terminalId") == terminalId)
        .order(Column("createdAt").asc)
        .limit(100)
        .fetchAll(db)
}
```

### 4.6 Startup Reconciliation

On app launch, mark all previously-live terminals as suspended (processes cannot survive app restart):

```swift
func markAllLiveTerminalsAsSuspended() throws {
    try dbPool.write { db in
        try db.execute(
            sql: "UPDATE terminals SET runtimeStatus = ? WHERE runtimeStatus = ?",
            arguments: [RuntimeStatus.suspended.rawValue, RuntimeStatus.live.rawValue]
        )
    }
}
```

---

## 5. IPC System

### 5.1 Socket Implementation

**CRITICAL**: Use POSIX sockets (`socket`/`bind`/`listen`/`accept`), NOT `Network.framework`'s `NWListener`. `NWListener` silently fails to create Unix domain socket files on macOS. This is a known issue. You will waste hours debugging a listener that appears to start but never receives connections.

**CRITICAL**: Use `DispatchSource.makeReadSource` for both the server FD (to accept connections) and each client FD (to read data). Do NOT use busy-wait loops or `select()`/`poll()`.

### 5.2 Socket Path and Permissions

```
/tmp/mymux-ipc.sock
```

Permissions: `chmod(socketPath, 0o600)` -- owner read/write only.

Always `unlink(socketPath)` before `bind()` to remove stale socket files from previous runs.

### 5.3 Server Setup (Complete Code)

```swift
final class IPCListener {
    private let socketPath = "/tmp/mymux-ipc.sock"
    private let queue = DispatchQueue(label: "com.mymux.ipc")
    private var serverFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private var clientSources: [Int32: DispatchSourceRead] = [:]
    private var connections: [String: Int32] = [:]        // terminalId -> client fd
    private var connectionBuffers: [Int32: String] = [:]  // per-client read buffer

    var onMessage: ((String, [String: Any]) -> [String: Any]?)?

    func start() throws {
        unlink(socketPath)

        serverFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard serverFD >= 0 else {
            throw IPCError("Failed to create socket: \(String(cString: strerror(errno)))")
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            socketPath.withCString { cstr in
                _ = strcpy(UnsafeMutableRawPointer(ptr).assumingMemoryBound(to: CChar.self), cstr)
            }
        }

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                bind(serverFD, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            close(serverFD)
            throw IPCError("Failed to bind: \(String(cString: strerror(errno)))")
        }

        chmod(socketPath, 0o600)

        guard listen(serverFD, 10) == 0 else {
            close(serverFD)
            throw IPCError("Failed to listen: \(String(cString: strerror(errno)))")
        }

        let source = DispatchSource.makeReadSource(fileDescriptor: serverFD, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptClient() }
        source.setCancelHandler { [weak self] in
            if let fd = self?.serverFD, fd >= 0 { close(fd) }
        }
        source.resume()
        acceptSource = source
    }

    func stop() {
        acceptSource?.cancel()
        for (_, source) in clientSources { source.cancel() }
        clientSources.removeAll()
        connections.removeAll()
        connectionBuffers.removeAll()
        serverFD = -1
        unlink(socketPath)
    }
    // ... (accept, read, write methods below)
}
```

### 5.4 NDJSON Protocol

All messages are newline-delimited JSON (one JSON object per line, terminated by `\n`).

#### Handshake

Client sends:
```json
{"type":"hello","terminal_id":"<uuid>","version":1}
```

Server responds:
```json
{"type":"hello_ack","status":"ok"}
```

**CRITICAL**: The `hello` message associates a client FD with a terminal ID. Do NOT overwrite an existing MCP server connection with a hook's ephemeral connection:

```swift
if connections[terminalId] == nil {
    connections[terminalId] = fd
}
```

#### Request/Response Pattern

All post-handshake messages include a `req_id` for correlation:

Client sends:
```json
{"type":"log_activity","message":"Completed auth refactor","req_id":"r1","terminal_id":"abc-123"}
```

Server responds:
```json
{"type":"ack","req_id":"r1","status":"ok"}
```

#### Message Types

| type | Direction | Fields | Response |
|------|-----------|--------|----------|
| `hello` | client->server | `terminal_id`, `version` | `hello_ack` |
| `log_activity` | client->server | `message`, `req_id` | `ack` |
| `set_terminal_title` | client->server | `title`, `req_id` | `ack` |
| `set_working_directory` | client->server | `path`, `req_id` | `ack` |
| `notify_user` | client->server | `message`, `urgency`, `req_id` | `ack` |
| `request_user_input` | client->server | `question`, `options?`, `req_id` | `user_input_response` (async) |

#### Async Response for request_user_input

The `request_user_input` handler does NOT return a synchronous response. Instead, it posts an `NSNotification` with name `"IPCResponse"` containing `["terminalId": String, "response": [String: Any]]`. The AppDelegate observes this notification and calls `ipcListener.sendResponse(terminalId:message:)`.

Response format:
```json
{"type":"user_input_response","req_id":"r5","answer":"Yes, proceed"}
```

Or on timeout:
```json
{"type":"user_input_response","req_id":"r5","error":"timeout","message":"User did not respond within 5 minutes"}
```

### 5.5 Client Read Buffering

TCP/UDS reads may deliver partial lines. Buffer per-client and split on `\n`:

```swift
private func readFromClient(fd: Int32) {
    var buf = [UInt8](repeating: 0, count: 4096)
    let n = read(fd, &buf, buf.count)
    if n <= 0 { clientSources[fd]?.cancel(); return }

    let chunk = String(bytes: buf[0..<n], encoding: .utf8) ?? ""
    var buffer = (connectionBuffers[fd] ?? "") + chunk

    while let newlineIndex = buffer.firstIndex(of: "\n") {
        let line = String(buffer[buffer.startIndex..<newlineIndex])
        buffer = String(buffer[buffer.index(after: newlineIndex)...])
        if !line.isEmpty { processLine(line, fromFD: fd) }
    }
    connectionBuffers[fd] = buffer
}
```

### 5.6 Writing JSON

```swift
private func writeJSON(_ obj: [String: Any], toFD fd: Int32) {
    guard let data = try? JSONSerialization.data(withJSONObject: obj),
          var str = String(data: data, encoding: .utf8) else { return }
    str += "\n"
    str.withCString { cstr in
        _ = write(fd, cstr, strlen(cstr))
    }
}
```

---

## 6. MCP Server

### 6.1 Technology

TypeScript, compiled with esbuild into a single `.mjs` file.

**CRITICAL**: Must use `--format=esm` because the MCP SDK uses top-level `await`. CommonJS (`--format=cjs`) will fail with a syntax error at the `await server.connect(transport)` line.

### 6.2 Build Command

```bash
cd mcp-server && npx esbuild src/index.ts --bundle --platform=node --target=node20 --format=esm --outfile=../Resources/mymux-mcp-server.mjs
```

Output file: `Resources/mymux-mcp-server.mjs`

### 6.3 package.json

```json
{
  "name": "mymux-mcp-server",
  "version": "1.0.0",
  "type": "module",
  "scripts": {
    "build": "esbuild src/index.ts --bundle --platform=node --target=node20 --format=esm --outfile=../Resources/mymux-mcp-server.mjs"
  },
  "dependencies": {
    "@modelcontextprotocol/sdk": "^1.0.0",
    "zod": "^3.22.0"
  },
  "devDependencies": {
    "esbuild": "^0.19.0",
    "typescript": "^5.0.0"
  }
}
```

### 6.4 Environment Variables

The MCP server reads two env vars:
- `MYMUX_TERMINAL_ID` -- UUID of the terminal session
- `MYMUX_SOCKET_PATH` -- path to UDS socket (`/tmp/mymux-ipc.sock`)

### 6.5 IPC Connection with Reconnection

```typescript
let reconnectAttempts = 0;

function connectIPC() {
  ipcSocket = net.createConnection(SOCKET_PATH!, () => {
    reconnectAttempts = 0;
    sendIPC({ type: "hello", terminal_id: TERMINAL_ID, version: 1 });
  });

  // NDJSON buffered read
  let buffer = "";
  ipcSocket.on("data", (data) => {
    buffer += data.toString();
    const lines = buffer.split("\n");
    buffer = lines.pop()!;
    for (const line of lines) {
      if (!line.trim()) continue;
      const msg = JSON.parse(line);
      if (msg.req_id && pendingRequests.has(msg.req_id)) {
        const pending = pendingRequests.get(msg.req_id)!;
        clearTimeout(pending.timeout);
        pendingRequests.delete(msg.req_id);
        pending.resolve(msg);
      }
    }
  });

  ipcSocket.on("error", () => scheduleReconnect());
  ipcSocket.on("close", () => scheduleReconnect());
}

function scheduleReconnect() {
  const delay = Math.min(1000 * Math.pow(2, reconnectAttempts++), 10000);
  setTimeout(connectIPC, delay);
}
```

### 6.6 MCP Tools (5 total)

#### `set_working_directory`
- Parameter: `path` (string, required) -- absolute path to current working directory
- Purpose: Reports Claude's cwd to the app for git status checking
- This should be called FIRST by Claude on every session start

#### `log_activity`
- Parameter: `message` (string, required) -- activity description
- Purpose: Creates timestamped entry in activity_log table, visible in activity panel

#### `set_terminal_title`
- Parameter: `title` (string, required) -- new terminal name
- Purpose: Updates terminal.name in database, reflected in sidebar

#### `notify_user`
- Parameters: `message` (string, required), `urgency` (enum: "low"|"normal"|"critical", optional, default "normal")
- Purpose: Sends macOS notification
- `low` = sidebar only (no OS notification), `normal` = OS notification, `critical` = OS notification + dock bounce

#### `request_user_input`
- Parameters: `question` (string, required), `options` (string array, optional)
- Purpose: Shows native NSAlert, blocks up to 5 minutes for user response
- If `options` provided: buttons for each option. If omitted: text input field.
- 5-minute timeout returns error to Claude

### 6.7 Request/Response with Timeout

```typescript
function sendIPCAndWait(msg: Record<string, unknown>, timeoutMs = 30000): Promise<any> {
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
```

### 6.8 MCP Config Generation

Per-terminal config files at `/tmp/mymux-mcp/mcp-{terminalId}.json`:

```json
{
  "mcpServers": {
    "mymux": {
      "command": "node",
      "args": ["/path/to/Resources/mymux-mcp-server.mjs"],
      "env": {
        "MYMUX_TERMINAL_ID": "<terminal-uuid>",
        "MYMUX_SOCKET_PATH": "/tmp/mymux-ipc.sock"
      }
    }
  }
}
```

File permissions: `0o600`.

The MCP server path is resolved by searching (in order):
1. Bundle.main.resourcePath + "/mymux-mcp-server.mjs"
2. Relative to executable: `../.build/ -> Resources/mymux-mcp-server.mjs`
3. `cwd/Resources/mymux-mcp-server.mjs`
4. `cwd/Mymux/Resources/mymux-mcp-server.mjs`

---

## 7. Claude Code Launch Command

### 7.1 Command Construction

```swift
func buildCommand() -> String {
    var parts = ["cd", shellEscape(track.repoPath), "&&", "claude"]

    if isRestart {
        parts.append("--continue")
    }

    // Named worktree for session resumption
    if !terminal.worktreeName.isEmpty {
        parts.append(contentsOf: ["--worktree", shellEscape(terminal.worktreeName)])
    } else {
        parts.append("--worktree")
    }

    if let configPath = mcpConfigPath {
        parts.append(contentsOf: ["--mcp-config", shellEscape(configPath)])
        parts.append(contentsOf: ["--allowedTools", "\"mcp__mymux__*\""])
    }

    let systemPrompt = buildSystemPrompt()
    if !systemPrompt.isEmpty {
        parts.append(contentsOf: ["--system-prompt", shellEscape(systemPrompt)])
    }

    return parts.joined(separator: " ")
}
```

### 7.2 New Session vs Restart

- **New session**: `cd "<repo>" && claude --worktree "<kebab-name>" --mcp-config "<config-path>" --allowedTools "mcp__mymux__*" --system-prompt "<prompt>"`
- **Restart**: `cd "<repo>" && claude --continue --worktree "<kebab-name>" --mcp-config "<config-path>" --allowedTools "mcp__mymux__*" --system-prompt "<prompt>"`

The only difference is `--continue` for restart.

### 7.3 Environment Variables

```swift
func buildEnvironment(terminalId: String, socketPath: String = "/tmp/mymux-ipc.sock") -> [String] {
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
    env.append("MYMUX_SOCKET_PATH=\(socketPath)")

    return env
}
```

**CRITICAL**: `MYMUX_TERMINAL_ID` and `MYMUX_SOCKET_PATH` are inherited by the Claude process, which means the MCP server subprocess AND the SessionStart hook both have access to them automatically.

### 7.4 System Prompt Template

```
You are working on: <track.name>
Terminal purpose: <terminal.name>

Linear ticket: <track.linearTicketUrl>  (if present)

Context:
<track.contextNotes>  (if non-empty)

IMPORTANT -- Mymux Tools:
You have access to Mymux MCP tools. Use them proactively:
- set_working_directory: CALL THIS FIRST -- report your current working directory (pwd) immediately on startup
- log_activity: Log milestones frequently (features done, tests passing, blockers hit)
- set_terminal_title: Update your terminal name to reflect current task
- notify_user: Alert the user when you finish major work or hit a blocker
- request_user_input: Ask the user when you need a decision you cannot make from context

Begin by calling set_working_directory with your current working directory, then start working on this task.
```

### 7.5 Shell Escaping

```swift
private func shellEscape(_ str: String) -> String {
    "\"" + str.replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
        .replacingOccurrences(of: "$", with: "\\$")
        .replacingOccurrences(of: "`", with: "\\`") + "\""
}
```

### 7.6 Worktree Name Derivation

Terminal names are converted to kebab-case for `--worktree`:

```swift
extension String {
    func toKebabCase() -> String {
        let lowered = lowercased()
        let pattern = try! NSRegularExpression(pattern: "[^a-z0-9]+")
        let range = NSRange(lowered.startIndex..., in: lowered)
        let replaced = pattern.stringByReplacingMatches(in: lowered, range: range, withTemplate: "-")
        return replaced.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }
}
```

Examples: "Auth Refactor" -> "auth-refactor", "Test Runner 2" -> "test-runner-2"

---

## 8. PTY Output Monitoring

### 8.1 Architecture

Each terminal has one `PTYOutputMonitor` instance that:
1. Receives raw bytes from the PTY via the `WorkshopTerminalView.dataReceived(slice:)` override
2. Writes bytes to a 4096-byte ring buffer
3. Updates `lastOutputTimestamp` on every byte received
4. Runs a timer (every 500ms) that evaluates state transitions
5. Fires `onStatusChanged` callback on the main thread when state changes

### 8.2 State Machine

```
                  dataReceived
                      |
                      v
ANY STATE --------> ACTIVE
                      |
                 1s silence
                      |
                      v
                   THINKING
                      |
                 3s silence
                      |
           +----------+----------+
           |                     |
     prompt detected      no prompt detected
           |                     |
           v                     v
        WAITING              THINKING (stays)

Process exited --> SUSPENDED
```

Transitions:
- Any `dataReceived` call -> `.active`
- 1-3 seconds of silence -> `.thinking`
- >3 seconds silence + prompt pattern detected -> `.waiting`
- >3 seconds silence + no prompt pattern -> `.thinking`
- Process terminated -> `.suspended`

### 8.3 Prompt Detection

After 3+ seconds of silence, the monitor reads the last 512 bytes from the ring buffer, strips ANSI codes, and checks the last non-empty line against these patterns:

```swift
private static let promptPatterns: [NSRegularExpression] = [
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

### 8.4 ANSI Stripping

Three regex patterns handle the major escape sequence types:

```swift
enum ANSIStripper {
    private static let csiPattern = try! NSRegularExpression(pattern: #"\x1b\[[0-9;]*[a-zA-Z]"#)
    private static let oscPattern = try! NSRegularExpression(pattern: #"\x1b\][^\x07]*\x07"#)
    private static let oscStPattern = try! NSRegularExpression(pattern: #"\x1b\][^\x1b]*\x1b\\"#)

    static func strip(_ input: String) -> String {
        var result = input
        // Apply each pattern sequentially (ranges change after each replacement)
        result = csiPattern.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result), withTemplate: "")
        result = oscPattern.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result), withTemplate: "")
        result = oscStPattern.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result), withTemplate: "")
        return result
    }

    static func strip(bytes: [UInt8]) -> String {
        guard let str = String(bytes: bytes, encoding: .utf8) else {
            return String(bytes: bytes, encoding: .ascii) ?? ""
        }
        return strip(str)
    }
}
```

### 8.5 Ring Buffer

```swift
final class RingBuffer {
    private var buffer: [UInt8]
    private var writeIndex: Int = 0
    private var count: Int = 0
    let capacity: Int

    init(capacity: Int = 4096) {
        self.capacity = capacity
        self.buffer = [UInt8](repeating: 0, count: capacity)
    }

    func write(_ data: ArraySlice<UInt8>) {
        for byte in data {
            buffer[writeIndex] = byte
            writeIndex = (writeIndex + 1) % capacity
            if count < capacity { count += 1 }
        }
    }

    func lastBytes(_ n: Int) -> [UInt8] {
        let bytesToRead = min(n, count)
        guard bytesToRead > 0 else { return [] }
        var result = [UInt8](repeating: 0, count: bytesToRead)
        let startIndex = (writeIndex - bytesToRead + capacity) % capacity
        for i in 0..<bytesToRead {
            result[i] = buffer[(startIndex + i) % capacity]
        }
        return result
    }
}
```

### 8.6 OSC Notification Parsing

The monitor also watches for inline OSC notification sequences in the raw output:

- **OSC 9** (iTerm2): `ESC ] 9 ; message BEL`
- **OSC 777** (rxvt): `ESC ] 777 ; notify ; title ; body BEL`
- **OSC 99** (Kitty): `ESC ] 99 ; params ; message BEL`

These fire `onOSCNotification?(title, body)` immediately.

### 8.7 Timer Configuration

All monitoring runs on a dedicated `DispatchQueue`:

```swift
private let timerQueue = DispatchQueue(label: "com.mymux.ptymonitor")

func start() {
    let timer = DispatchSource.makeTimerSource(queue: timerQueue)
    timer.schedule(deadline: .now() + 0.5, repeating: 0.5)
    timer.setEventHandler { [weak self] in self?.evaluateState() }
    timer.resume()
    self.timer = timer
}
```

---

## 9. SessionStart Hook

### 9.1 Purpose

Detects Claude's working directory on startup/resume and reports it to the app via IPC. This is a backup mechanism -- the MCP `set_working_directory` tool is the primary path, but the hook fires earlier (before Claude processes the system prompt).

### 9.2 Hook Script (Resources/hooks/session-start.sh)

```bash
#!/bin/bash
# mymux -- SessionStart hook
# Reads the cwd from Claude Code's stdin JSON and sends it to the app
# via the IPC Unix domain socket. Runs on both startup and resume.

INPUT=$(cat)

CWD=$(echo "$INPUT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('cwd',''))" 2>/dev/null)

if [ -z "$CWD" ] || [ -z "$MYMUX_TERMINAL_ID" ] || [ -z "$MYMUX_SOCKET_PATH" ]; then
    exit 0
fi

python3 -c "
import socket, json
sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
try:
    sock.connect('$MYMUX_SOCKET_PATH')
    hello = json.dumps({'type':'hello','terminal_id':'$MYMUX_TERMINAL_ID','version':1}) + '\n'
    sock.sendall(hello.encode())
    sock.recv(4096)
    msg = json.dumps({'type':'set_working_directory','terminal_id':'$MYMUX_TERMINAL_ID','path':'$CWD','req_id':'hook-1'}) + '\n'
    sock.sendall(msg.encode())
    sock.recv(4096)
    sock.close()
except Exception as e:
    pass
" 2>/dev/null
exit 0
```

### 9.3 Hook Installation

**CRITICAL**: MERGE with existing hooks in `~/.claude/settings.json`. Do NOT overwrite the entire file.

```swift
private func installSessionStartHook() {
    // 1. Find hook script path (search bundle, cwd, relative to executable)
    // 2. Read existing ~/.claude/settings.json
    var settings: [String: Any] = [:]
    if let data = try? Data(contentsOf: settingsPath),
       let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
        settings = existing
    }

    // 3. Build hook config
    let hookEntry: [String: Any] = [
        "type": "command",
        "command": hookScriptPath,
        "timeout": 10,
    ]
    let startupMatcher: [String: Any] = ["matcher": "startup", "hooks": [hookEntry]]
    let resumeMatcher: [String: Any] = ["matcher": "resume", "hooks": [hookEntry]]

    // 4. Merge -- preserve other hook types
    var hooks = settings["hooks"] as? [String: Any] ?? [:]
    hooks["SessionStart"] = [startupMatcher, resumeMatcher]
    settings["hooks"] = hooks

    // 5. Write back
    if let data = try? JSONSerialization.data(withJSONObject: settings, options: .prettyPrinted) {
        try? data.write(to: settingsPath)
    }
}
```

### 9.4 How the Hook Gets Environment Variables

The hook inherits `MYMUX_TERMINAL_ID` and `MYMUX_SOCKET_PATH` from the Claude process environment, which were set by `ClaudeCommandBuilder.buildEnvironment()`. Claude Code passes these through to hook subprocesses.

### 9.5 Matchers

Both `"startup"` and `"resume"` matchers are required. The hook must fire on initial Claude startup AND when resuming a `--continue` session.

---

## 10. Git Status Checker

### 10.1 Architecture

Runs on a `DispatchQueue` with `.utility` QoS priority. Polls every 10 seconds.

```swift
final class GitStatusChecker {
    private let queue = DispatchQueue(label: "com.mymux.gitstatus", qos: .utility)
    private var timer: DispatchSourceTimer?
    var terminals: [(id: String, repoPath: String)] = []
    var onStatusesUpdated: (([String: GitStatus]) -> Void)?

    func start(interval: TimeInterval = 10) {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: interval)
        timer.setEventHandler { [weak self] in self?.checkAll() }
        timer.resume()
        self.timer = timer
    }
}
```

### 10.2 Only Check Terminals with Known Working Directory

The checker only polls terminals that have a known worktree directory (set by the hook or MCP tool). Terminals without a known cwd are skipped.

```swift
private func updateGitCheckerTerminals() {
    var terminals: [(id: String, repoPath: String)] = []
    for track in allTracks {
        for terminal in trackTerminals {
            if let cwd = sessionManager.workingDirectories[terminal.id], !cwd.isEmpty {
                terminals.append((id: terminal.id, repoPath: cwd))
            }
        }
    }
    gitStatusChecker.terminals = terminals
}
```

### 10.3 Git Commands

For each terminal:

1. **Is it a git repo?** `git rev-parse --git-dir`
2. **Dirty working tree?** `git status --porcelain`
3. **Lines changed vs HEAD?** `git diff --numstat HEAD`
4. **Untracked file line counts**: `git ls-files --others --exclude-standard`, then read each file and count lines (counted as additions)
5. **Commits ahead of remote**: `git rev-parse --abbrev-ref --symbolic-full-name @{u}` then `git rev-list --count @{u}..HEAD`

### 10.4 GitStatus Model

```swift
struct GitStatus {
    let isDirty: Bool
    let linesAdded: Int
    let linesRemoved: Int
    let commitsAhead: Int

    static let clean = GitStatus(isDirty: false, linesAdded: 0, linesRemoved: 0, commitsAhead: 0)
}
```

`isDirty` is true if there are uncommitted changes OR commits ahead of origin.

### 10.5 Display in Sidebar

Dirty terminals show:
- Terminal name in amber/orange color
- Git info label: `+42 -7  2^` (lines added, lines removed, commits ahead)

---

## 11. Shell Terminal Panel

### 11.1 Purpose

Provides plain shell terminals (not Claude sessions) at the bottom of the terminal area for running commands like `git log`, `npm test`, etc.

### 11.2 Architecture

`ShellTerminalPanelView` is an NSView containing:
- A tab bar at top (28px height)
- A content area below showing the active `LocalProcessTerminalView`

### 11.3 Spawning Shell Terminals

```swift
let shellPath = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
var env: [String] = []
let inherited = ["HOME", "PATH", "LANG", "USER", "SHELL", "TERM_PROGRAM", "COLORTERM", "EDITOR"]
for key in inherited {
    if let value = ProcessInfo.processInfo.environment[key] {
        env.append("\(key)=\(value)")
    }
}
env.append("TERM=xterm-256color")
env.append("COLORTERM=truecolor")

terminalView.startProcess(
    executable: shellPath,
    args: ["-l"],    // Login shell
    environment: env,
    execName: nil
)

// cd to worktree directory and clear
if !repoPath.isEmpty {
    terminalView.send(txt: "cd \"\(repoPath)\" && clear\n")
}
```

### 11.4 Tab Naming

First tab: shell basename (e.g., "zsh")
Subsequent tabs: "zsh (2)", "zsh (3)", etc.

### 11.5 Tab Close Behavior

When all tabs are closed, the `onAllTabsClosed` callback fires, causing the terminal area to collapse the shell panel.

### 11.6 Shell Panel Only Opens When Working Directory is Known

The shell panel button does nothing (`guard !currentRepoPath.isEmpty else { return }`) until a terminal has reported its working directory.

---

## 12. UI Layout

### 12.1 Main Split: NSSplitViewController

**CRITICAL**: Use `NSSplitViewItem(viewController:)`, NOT `NSSplitViewItem(sidebarWithViewController:)`. The sidebar variant creates a collapsible sidebar (with hide/show animation) instead of a standard resizable pane. This causes unexpected collapse behavior.

```swift
let sidebarItem = NSSplitViewItem(viewController: sidebarVC)
sidebarItem.minimumThickness = 220
sidebarItem.maximumThickness = 500
sidebarItem.holdingPriority = .init(251)

let terminalItem = NSSplitViewItem(viewController: terminalAreaVC)
terminalItem.minimumThickness = 400

splitView.dividerStyle = .thin
splitView.setPosition(280, ofDividerAt: 0)
```

### 12.2 Terminal Area: Constraint-Based Layout, NOT NSSplitView

**CRITICAL**: The terminal area (right pane) uses manual constraint-based layout for its three sub-areas. Do NOT use NSSplitView or NSSplitViewController for the terminal area interior. Using NSSplitView inside an NSSplitViewController causes an Auto Layout constraint loop crash.

Layout structure:
```
+--toolbar buttons (top-right)--+
|                               |
| +--terminal container--+--activity panel--+
| |                      |     (250px)      |
| |  (fills remaining)   |                  |
| |                      |                  |
| +----------------------+                  |
| +--shell panel---------+                  |
| |     (250px height)   |                  |
| +----------------------+------------------+
```

The activity panel is controlled by a width constraint that animates between 250px and 0px:

```swift
panelWidthConstraint = activityPanel.widthAnchor.constraint(equalToConstant: 250)

@objc private func toggleActivityPanel() {
    activityPanelVisible.toggle()
    NSAnimationContext.runAnimationGroup { ctx in
        ctx.duration = 0.2
        panelWidthConstraint.animator().constant = activityPanelVisible ? 250 : 0
        activityPanel.animator().isHidden = !activityPanelVisible
    }
}
```

The shell panel uses a height constraint and switches the terminal container's bottom anchor:

```swift
// Two mutually exclusive bottom constraints for terminal container:
terminalBottomToRoot = terminalContainer.bottomAnchor.constraint(equalTo: root.bottomAnchor)
terminalBottomToShell = terminalContainer.bottomAnchor.constraint(equalTo: shellPlaceholder.topAnchor, constant: -1)

// Show shell: switch constraints
terminalBottomToRoot.isActive = false
terminalBottomToShell.isActive = true
shellPanelHeightConstraint.animator().constant = 250

// Hide shell: switch back
terminalBottomToShell.isActive = false
terminalBottomToRoot.isActive = true
shellPanelHeightConstraint.animator().constant = 0
```

### 12.3 Window Configuration

```swift
let window = NSWindow(
    contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800),
    styleMask: [.titled, .closable, .miniaturizable, .resizable],
    backing: .buffered,
    defer: false
)
window.title = "mymux"
window.contentViewController = splitVC
window.center()
window.makeKeyAndOrderFront(nil)
```

### 12.4 Sidebar: NSOutlineView

- Style: `.sourceList`
- No header view (`outlineView.headerView = nil`)
- Data source uses String item IDs (track IDs at root level, terminal IDs as children)
- `isItemExpandable` returns true for track IDs
- Drag and drop between tracks: `registerForDraggedTypes([.string])`
- Right-click context menu via `NSMenuDelegate`

### 12.5 Status Dot Rendering

```swift
final class StatusDotView: NSView {
    var status: DisplayStatus = .suspended { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 1, dy: 1)
        switch status {
        case .active:    NSColor.systemGreen.setFill(); NSBezierPath(ovalIn: rect).fill()
        case .thinking:  NSColor.systemBlue.withAlphaComponent(pulseAlpha()).setFill(); NSBezierPath(ovalIn: rect).fill()
        case .waiting:   /* amber filled + stroked ring */
        case .suspended: /* gray stroked ring */
        case .completed: /* gray checkmark */
        }
    }

    // Pulse: sin wave at 3Hz, alpha range 0.4-1.0
    private func pulseAlpha() -> CGFloat {
        let t = Date().timeIntervalSinceReferenceDate
        return 0.4 + 0.6 * CGFloat(sin(t * 3.0) * 0.5 + 0.5)
    }

    // Timer at 30fps for pulse animation
    func startPulsingIfNeeded() {
        guard pulseTimer == nil else { return }
        pulseTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            guard let self = self, self.status == .thinking else { return }
            self.needsDisplay = true
        }
    }
}
```

Dimensions: 12x12 points. Inset by 1pt for drawing.

---

## 13. Notification System

### 13.1 Bundle Identifier Guard

**CRITICAL**: Guard ALL `UNUserNotificationCenter` access behind the bundle identifier check:

```swift
private var canSendNotifications: Bool {
    Bundle.main.bundleIdentifier != nil
}
```

This affects:
- `requestAuthorization` in AppDelegate
- `terminalBecameWaiting` -- fire notification
- `terminalStoppedWaiting` -- remove delivered notification
- `sendCustomNotification` -- notify_user MCP tool

### 13.2 Dock Badge

```swift
private func updateDockBadge() {
    DispatchQueue.main.async {
        if self.waitingTerminals.isEmpty {
            NSApp.dockTile.badgeLabel = nil
        } else {
            NSApp.dockTile.badgeLabel = String(self.waitingTerminals.count)
        }
    }
}
```

### 13.3 Debounce

One notification per waiting cycle. Track with two sets:
- `waitingTerminals: Set<String>` -- currently waiting terminal IDs
- `notifiedTerminals: Set<String>` -- terminals that have already fired a notification this cycle

When a terminal becomes waiting:
1. Insert into `waitingTerminals`
2. If NOT in `notifiedTerminals`: fire notification, insert into `notifiedTerminals`

When a terminal stops waiting:
1. Remove from both `waitingTerminals` and `notifiedTerminals`

### 13.4 Notification Content

```swift
let content = UNMutableNotificationContent()
content.title = "mymux"
content.body = "\(terminalName) is waiting for input"
content.sound = .default
content.userInfo = ["terminalId": terminalId]

let request = UNNotificationRequest(
    identifier: "waiting-\(terminalId)",
    content: content,
    trigger: UNTimeIntervalNotificationTrigger(timeInterval: 0.1, repeats: false)
)
```

### 13.5 Notification Click Handling

Clicking a notification focuses the terminal:

```swift
func userNotificationCenter(_ center: UNUserNotificationCenter,
    didReceive response: UNNotificationResponse,
    withCompletionHandler completionHandler: @escaping () -> Void) {
    let userInfo = response.notification.request.content.userInfo
    if let terminalId = userInfo["terminalId"] as? String {
        windowManager.focusTerminal(id: terminalId)
    }
    completionHandler()
}
```

### 13.6 Critical Urgency

For `notify_user` with urgency "critical": request dock bounce:

```swift
NSApp.requestUserAttention(.criticalRequest)
```

---

## 14. File Structure

```
Mymux/
  Package.swift
  Sources/
    main.swift
    App/
      AppDelegate.swift
      WindowManager.swift
    Views/
      MainSplitViewController.swift       (contains TerminalAreaViewController)
      SidebarViewController.swift
      TerminalContainerView.swift          (contains MymuxTerminalView subclass)
      ShellTerminalPanelView.swift
      ActivityPanelView.swift
      StatusDotView.swift
      NewTrackSheet.swift
    Services/
      SessionManager.swift
      SQLiteStore.swift
      PTYOutputMonitor.swift
      IPCListener.swift
      IPCMessageHandler.swift
      ClaudeCommandBuilder.swift
      MCPConfigGenerator.swift
      GitStatusChecker.swift
      NotificationManager.swift
    Models/
      DisplayStatus.swift                  (DisplayStatus, RuntimeStatus, TrackStatus enums)
      WorkTrack.swift
      Terminal.swift
      ActivityLogEntry.swift
      ReferenceFile.swift
      TrackKeyword.swift
    Utilities/
      RingBuffer.swift
      ANSIStripper.swift
      FuzzyMatcher.swift
      StringExtensions.swift
  Resources/
    hooks/
      session-start.sh
    mymux-mcp-server.mjs                   (built from mcp-server/)
  mcp-server/
    package.json
    tsconfig.json
    src/
      index.ts
```

### 14.1 Package.swift

```swift
// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "Mymux",
    platforms: [
        .macOS(.v14)
    ],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", from: "1.11.0"),
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.0.0"),
    ],
    targets: [
        .executableTarget(
            name: "Mymux",
            dependencies: [
                "SwiftTerm",
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            path: "Sources"
        ),
    ]
)
```

### 14.2 MCP Server tsconfig.json

```json
{
  "compilerOptions": {
    "target": "ES2020",
    "module": "ESNext",
    "moduleResolution": "node",
    "strict": true,
    "esModuleInterop": true,
    "skipLibCheck": true,
    "outDir": "./dist"
  },
  "include": ["src/**/*"]
}
```

---

## 15. Security

### 15.1 IPC Socket

- Path: `/tmp/mymux-ipc.sock`
- Permissions: `0o600` (owner read/write only)
- `unlink()` before `bind()` to prevent binding to stale sockets
- `unlink()` on shutdown in `applicationWillTerminate`

### 15.2 MCP Config Files

- Path: `/tmp/mymux-mcp/mcp-{terminalId}.json`
- Created with `posixPermissions: 0o600`
- Removed per-terminal on terminal delete: `MCPConfigGenerator.removeConfig(terminalId:)`
- All removed on shutdown: `MCPConfigGenerator.removeAllConfigs()`

### 15.3 Cleanup on Shutdown

```swift
func applicationWillTerminate(_ notification: Notification) {
    ipcListener?.stop()                    // Closes socket, unlinks file
    MCPConfigGenerator.removeAllConfigs()  // Removes /tmp/mymux-mcp/ directory
    NSApp.dockTile.badgeLabel = nil        // Clear dock badge
}
```

---

## 16. Wiring Summary (AppDelegate)

The AppDelegate is the central wiring point. Here is the complete initialization order:

1. Initialize `SQLiteStore` (may fail -- show alert and terminate)
2. Guard `UNUserNotificationCenter` behind bundle identifier check
3. Call `markAllLiveTerminalsAsSuspended()` to reconcile state
4. Create `IPCListener`
5. Create `WindowManager` (which creates `SessionManager` internally)
6. Create `IPCMessageHandler` with references to `sqliteStore` and `notificationManager`
7. Wire `ipcListener.onMessage` to `ipcMessageHandler.handleMessage`
8. Wire `ipcMessageHandler.onWorkingDirectorySet` to update `sessionManager.workingDirectories`
9. Observe `NSNotification.Name("IPCResponse")` for async IPC responses
10. Call `ipcListener.start()`
11. Call `installSessionStartHook()`
12. Call `windowManager.showMainWindow()`

---

## 17. Naming Conventions

All references throughout the codebase use the "mymux" branding:

| Old (Workshop) | New (mymux) |
|----------------|-------------|
| `Workshop.app` | `mymux.app` |
| `WORKSHOP_TERMINAL_ID` | `MYMUX_TERMINAL_ID` |
| `WORKSHOP_SOCKET_PATH` | `MYMUX_SOCKET_PATH` |
| `/tmp/workshop-ipc.sock` | `/tmp/mymux-ipc.sock` |
| `/tmp/workshop-mcp/` | `/tmp/mymux-mcp/` |
| `~/.workshop-native/` | `~/.mymux/` |
| `workshop.db` | `mymux.db` |
| `workshop-mcp-server.mjs` | `mymux-mcp-server.mjs` |
| `workshop-tools` (MCP server name) | `mymux-tools` |
| `mcp__workshop__*` (allowedTools) | `mcp__mymux__*` |
| `com.workshop.*` (dispatch labels) | `com.mymux.*` |
| Window title "Workshop" | Window title "mymux" |
| Notification title "Workshop" | Notification title "mymux" |
