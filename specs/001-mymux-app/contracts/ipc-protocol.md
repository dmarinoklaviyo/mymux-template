# Contract: IPC Protocol (mymux ↔ MCP Server)

**Feature**: 001-mymux-app  
**Date**: 2026-06-29

---

## Transport

- **Type**: Unix Domain Socket (SOCK_STREAM)
- **Path**: `/tmp/mymux-ipc.sock`
- **Permissions**: `0o600` (owner read/write only)
- **Lifecycle**: `unlink()` before `bind()` on startup; `unlink()` on shutdown
- **Server implementation**: POSIX `socket`/`bind`/`listen`/`accept` + `DispatchSource.makeReadSource` (NOT Network.framework NWListener)

## Wire Format

NDJSON — each message is a single line of JSON terminated by `\n`. Partial-line reads must be buffered per client FD.

## Handshake (required before any tool messages)

**Step 1** — MCP server sends immediately on connection:

```json
{"type":"hello","terminal_id":"<uuid>","version":1}
```

**Step 2** — App responds:

```json
{"type":"hello_ack","status":"ok"}
```

**Rule**: The `hello` message associates a client file descriptor with a terminal UUID. If a `hello` arrives for an already-registered terminal ID, it is ignored (first-wins). This prevents the SessionStart hook's ephemeral connection from overwriting the persistent MCP server connection.

## Post-Handshake Messages

All client→server messages after the handshake include `req_id` (unique string per request) and `terminal_id`. The server responds with an ack on the same connection.

### Message Types

| `type` | Direction | Required Fields | Response |
|--------|-----------|-----------------|----------|
| `log_activity` | client→server | `message: string`, `req_id`, `terminal_id` | `ack` |
| `set_terminal_title` | client→server | `title: string`, `req_id`, `terminal_id` | `ack` |
| `set_working_directory` | client→server | `path: string`, `req_id`, `terminal_id` | `ack` |
| `notify_user` | client→server | `message: string`, `urgency?: "low"\|"normal"\|"critical"`, `req_id`, `terminal_id` | `ack` |
| `request_user_input` | client→server | `question: string`, `options?: string[]`, `req_id`, `terminal_id` | `user_input_response` (async) |

### Standard Ack Response

```json
{"type":"ack","req_id":"<matching-req-id>","status":"ok"}
```

### Async Response: request_user_input

The app does NOT immediately respond. Instead it posts an `NSNotification("IPCResponse")` which routes the response back asynchronously. Response on answer:

```json
{"type":"user_input_response","req_id":"<matching-req-id>","answer":"<user-provided-text-or-option>"}
```

Response on timeout (5 minutes):

```json
{"type":"user_input_response","req_id":"<matching-req-id>","error":"timeout","message":"User did not respond within 5 minutes"}
```

## Writing JSON to Socket

Each response is serialized with `JSONSerialization` and written with a trailing `\n`:

```
<JSON-object>\n
```

## Error Handling

- If `read()` returns ≤ 0 on a client FD: cancel the client's DispatchSource and close the FD.
- Malformed JSON lines are silently dropped.
- Missing `terminal_id` in post-handshake messages: message is silently dropped.
