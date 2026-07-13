# Research: mymux — Technical Decisions

**Feature**: 001-mymux-app  
**Date**: 2026-06-29  
**Source**: founding-docs/mymux-technical-specification.md (authoritative)

All technical decisions are pre-resolved by the founding technical specification. This document records those decisions with rationale so future agents do not re-derive them.

---

## Terminal Emulation

**Decision**: Use `LocalProcessTerminalView` from SwiftTerm ~>1.11 exclusively.  
**Rationale**: Manages PTY creation, process spawning, and I/O bridging internally. No tmux, WebSocket bridge, or browser-based emulator needed.  
**Alternatives considered**: `TerminalView` (requires manual PTY wiring — more complex, no advantage); WebView-based terminals (browser dependency, sandboxing conflicts).  
**CRITICAL note**: `LocalProcessTerminalView` already conforms to `TerminalViewDelegate` internally. Do NOT also conform your container to `TerminalViewDelegate` — duplicate conformance causes undefined behavior. Use `LocalProcessTerminalView.processDelegate` instead.

---

## Delegate Architecture

**Decision**: Subclass `LocalProcessTerminalView` as `MymuxTerminalView` to override `dataReceived(slice:)` for output monitoring. Use the `.processDelegate` property for lifecycle callbacks.  
**Rationale**: This is the only supported interception point for raw PTY byte output without re-implementing PTY internals.  
**CRITICAL note**: `processTerminated` and `hostCurrentDirectoryUpdate` callbacks use `TerminalView` (not `LocalProcessTerminalView`) as the `source` type.

---

## IPC Transport

**Decision**: POSIX sockets (`socket`/`bind`/`listen`/`accept`) with `DispatchSource.makeReadSource`. Socket at `/tmp/mymux-ipc.sock`, permissions `0o600`.  
**Rationale**: `Network.framework`'s `NWListener` silently fails to create Unix domain socket files on macOS — a known issue. POSIX approach is verified to work.  
**Alternatives considered**: `Network.framework` NWListener (known broken for UDS on macOS), TCP sockets (unnecessary for local IPC, no access control), named pipes (no bidirectional framing).

---

## IPC Wire Format

**Decision**: NDJSON (newline-delimited JSON). Handshake: `hello` → `hello_ack`. Post-handshake messages include `req_id` for correlation.  
**Rationale**: Human-readable, easily debuggable, trivial to parse in both Swift and Node.js without binary framing overhead.  
**Per-client buffering required**: UDS reads may deliver partial lines. Each client FD has an associated string buffer; lines are extracted on `\n`.

---

## MCP Server Technology

**Decision**: TypeScript compiled by esbuild into a single `mymux-mcp-server.mjs` ESM bundle in `Resources/`.  
**Rationale**: The `@modelcontextprotocol/sdk` uses top-level `await`. ESM format (`--format=esm`) is required — CommonJS (`--format=cjs`) fails with a syntax error at `await server.connect(transport)`.  
**Build command**: `cd mcp-server && npx esbuild src/index.ts --bundle --platform=node --target=node20 --format=esm --outfile=../Resources/mymux-mcp-server.mjs`

---

## Entry Point

**Decision**: Explicit `main.swift` with `NSApplication.shared` + manual delegate wiring. `app.setActivationPolicy(.regular)` MUST be called before `app.run()`.  
**Rationale**: `@main` on AppDelegate does not reliably start `NSApplication` for SPM executable targets. Without `.setActivationPolicy(.regular)`: no Dock icon, windows cannot receive focus.

---

## UNUserNotificationCenter Guard

**Decision**: ALL access to `UNUserNotificationCenter.current()` MUST be guarded by `Bundle.main.bundleIdentifier != nil`.  
**Rationale**: `UNUserNotificationCenter.current()` CRASHES at runtime when there is no bundle identifier. SPM executables run via `swift run` have no bundle identifier.

---

## UI Layout Strategy

**Decision**: Main window uses `NSSplitViewController` for the three columns (sidebar, terminal area, activity panel). The terminal area interior uses manual constraint-based layout — NOT a nested `NSSplitView`.  
**Rationale**: Using `NSSplitView` inside `NSSplitViewController` causes an Auto Layout constraint loop crash. Activity panel visibility is animated via a width constraint (250px ↔ 0px). Shell panel visibility uses mutually exclusive bottom constraints on the terminal container.  
**CRITICAL note**: Use `NSSplitViewItem(viewController:)`, NOT `NSSplitViewItem(sidebarWithViewController:)`. The sidebar variant creates unexpected collapsible behavior.

---

## Database Path and GRDB Setup

**Decision**: SQLite at `~/.mymux/mymux.db` via GRDB `DatabasePool`. Three migrations (001_baseSchema, 002_trackKeywords, 003_worktreeName). `eraseDatabaseOnSchemaChange = true` in DEBUG builds only.  
**Rationale**: Provides transactional reads, `ValueObservation` for reactive UI, and safe schema evolution.

---

## Session Resumption

**Decision**: Named worktrees via `--worktree <kebab-name>` flag. `toKebabCase()` derives the worktree name from the terminal's display name. Restart adds `--continue` to resume conversation history.  
**Rationale**: Claude Code uses the worktree name to locate and resume the correct conversation. Kebab-case ensures shell-safe names.

---

## SessionStart Hook

**Decision**: Install a hook in `~/.claude/settings.json` matching both `"startup"` and `"resume"` matchers. Hook runs a Python3 one-liner to extract `cwd` from Claude's stdin JSON and send it to the app via UDS.  
**CRITICAL note**: MERGE with existing `~/.claude/settings.json` — do NOT overwrite the entire file.

---

## OSC 7 Working Directory

**Decision**: `hostCurrentDirectoryUpdate` receives a `file://` URL string. Extract path via `URL(string: dir)?.path`.  
**Rationale**: The MCP `set_working_directory` tool is the primary path; OSC 7 is a supplementary signal. The hook is the fallback for session startup before MCP connects.

---

## Prompt Detection Timing

**Decision**: PTYOutputMonitor uses a 500ms DispatchSourceTimer. Active → Thinking after ~1s silence; Thinking → Waiting after ~3s silence + prompt pattern match.  
**Prompt patterns**: `> $`, `❯ $`, `$ $`, `(y/n)`, `[Y/n]`, `Do you want to`, `Allow .+?`, `Press Enter`.  
**ANSI stripping**: Three regex patterns (CSI, OSC with BEL, OSC with ST) applied sequentially before prompt matching.

---

## Resolved: No NEEDS CLARIFICATION Items

The founding technical specification resolves all implementation choices. No unknowns remain.
