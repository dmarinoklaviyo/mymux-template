# Contract: Claude Code Launch Command

**Feature**: 001-mymux-app  
**Date**: 2026-06-29

Defines the exact shell command mymux constructs when spawning or restarting a Claude Code session.

---

## New Session

```bash
cd "<repo-path>" && claude \
  --worktree "<kebab-case-terminal-name>" \
  --mcp-config "/tmp/mymux-mcp/mcp-<terminal-uuid>.json" \
  --allowedTools "mcp__mymux__*" \
  --system-prompt "<system-prompt>"
```

## Restarted Session (suspended → live)

```bash
cd "<repo-path>" && claude \
  --continue \
  --worktree "<kebab-case-terminal-name>" \
  --mcp-config "/tmp/mymux-mcp/mcp-<terminal-uuid>.json" \
  --allowedTools "mcp__mymux__*" \
  --system-prompt "<system-prompt>"
```

The only difference between new and restart is the `--continue` flag.

---

## Environment Variables (inherited by Claude and its subprocesses)

| Variable | Value | Purpose |
|----------|-------|---------|
| HOME | from parent process | Shell initialization |
| PATH | from parent process | Binary resolution |
| LANG | from parent process | Locale |
| USER | from parent process | User identity |
| SHELL | from parent process | Default shell for subprocesses |
| TERM | `xterm-256color` | Terminal type declaration |
| COLORTERM | `truecolor` | 24-bit color support |
| MYMUX_TERMINAL_ID | `<terminal-uuid>` | Identifies the terminal in IPC and hooks |
| MYMUX_SOCKET_PATH | `/tmp/mymux-ipc.sock` | IPC socket location for MCP server and hook |

`MYMUX_TERMINAL_ID` and `MYMUX_SOCKET_PATH` are automatically inherited by both the MCP server subprocess and the SessionStart hook.

---

## Shell Escaping Rules

All arguments are double-quoted and escape the following characters:

| Character | Escaped As |
|-----------|-----------|
| `\` | `\\` |
| `"` | `\"` |
| `$` | `\$` |
| `` ` `` | `` \` `` |

---

## Worktree Name Derivation

Terminal display name → kebab-case via `toKebabCase()`:
1. Lowercase the entire string
2. Replace all sequences of non-alphanumeric characters with `-`
3. Trim leading and trailing `-`

Examples:

| Display Name | Worktree Name |
|-------------|---------------|
| Auth Refactor | `auth-refactor` |
| Test Runner 2 | `test-runner-2` |
| Fix: Payment Bug | `fix-payment-bug` |
| "Hello World!" | `hello-world` |

---

## SessionStart Hook

Installed in `~/.claude/settings.json` under `hooks.SessionStart` with matchers for both `"startup"` and `"resume"`. The hook script is at `Resources/hooks/session-start.sh`.

The hook reads Claude's stdin JSON, extracts `cwd`, and sends a `set_working_directory` IPC message to the app using the environment variables already set on the Claude process.

**CRITICAL**: When writing to `~/.claude/settings.json`, READ the existing file first and merge the hook entry under `hooks.SessionStart`. Do NOT overwrite the file.

---

## MCP Config File Location and Cleanup

- Created: `/tmp/mymux-mcp/mcp-<terminal-uuid>.json` at session start
- Permissions: `0o600`
- Removed: on terminal delete (`MCPConfigGenerator.removeConfig(terminalId:)`)
- All removed: on app shutdown (`MCPConfigGenerator.removeAllConfigs()`)
