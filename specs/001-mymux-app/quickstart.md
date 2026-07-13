# Quickstart: Building and Running mymux

**Feature**: 001-mymux-app  
**Date**: 2026-06-29

---

## Prerequisites

- macOS 14 (Sonoma) or later
- Xcode Command Line Tools: `xcode-select --install`
- Node.js 20+: `node --version` (must be ≥ 20)
- `claude` CLI installed and authenticated: `claude --version`

---

## Step 1: Build the MCP Server

The MCP server TypeScript source must be compiled into an ESM bundle before the Swift app can use it.

```bash
cd mcp-server
npm install
npm run build
cd ..
```

This produces `Mymux/Resources/mymux-mcp-server.mjs`.

**Verify**: `ls Mymux/Resources/mymux-mcp-server.mjs` should exist.

---

## Step 2: Build and Run the Swift App

```bash
cd Mymux
swift run
```

Expected output: The main window appears with a three-column layout (sidebar | terminal area | activity panel).

**First run note**: Swift Package Manager will resolve and compile SwiftTerm and GRDB.swift dependencies. This takes 1–2 minutes on first run.

---

## Step 3: Verify Core Functionality

### G2 — App Launches

The main window appears with:
- Left sidebar showing "+" button at the top
- Center area showing an empty state message
- Right panel toggle button in the toolbar

### G1 — Build Passes

```bash
cd Mymux && swift build
```

Should complete with no errors.

---

## Common Build Issues

### "No such module 'SwiftTerm'"
Run `swift package resolve` inside the `Mymux/` directory, then retry `swift build`.

### App launches but no Dock icon / window won't focus
This means `setActivationPolicy(.regular)` was not called before `app.run()` in `main.swift`. This is a CRITICAL failure — see `research.md`.

### UNUserNotificationCenter crash during `swift run`
The notification center requires a bundle identifier. All access to `UNUserNotificationCenter.current()` must be guarded with `Bundle.main.bundleIdentifier != nil`. See `research.md`.

### MCP server fails to start for a terminal
Verify `mymux-mcp-server.mjs` exists in `Mymux/Resources/`. If missing, re-run Step 1.

### IPC socket not receiving messages
Verify the socket is at `/tmp/mymux-ipc.sock` and has permissions `0o600`. Check that `unlink()` was called before `bind()`.

---

## Development Workflow

1. After any Swift source change: `swift build` to check for errors
2. After completing a task: `swift run` to verify observable behavior
3. After changing the MCP server TypeScript: re-run `npm run build` in `mcp-server/`, then `swift run`
4. Database resets: delete `~/.mymux/mymux.db` to start fresh (DEBUG builds also reset on schema change)

---

## Cleaning Up

Remove the IPC socket and MCP config files (normally done by app shutdown):

```bash
rm -f /tmp/mymux-ipc.sock
rm -rf /tmp/mymux-mcp/
```

Reset the database:

```bash
rm -f ~/.mymux/mymux.db
```
