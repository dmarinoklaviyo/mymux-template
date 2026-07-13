<!--
## Sync Impact Report

**Version Change**: 1.0.0 → 1.1.0

### Modified Principles
- **III. Native macOS Stack Only → III. macOS Compatibility Required**
  Old: mandated exclusive use of SwiftTerm + GRDB + AppKit; prohibited all unlisted frameworks.
  New: requires the app work on macOS 14+ without App Sandbox; the prescribed stack is the
  recommended default path, but alternative libraries are permitted with justification.

### Added Sections
None

### Removed Sections
None

### Templates Updated
- ✅ `.specify/templates/plan-template.md` — Constitution Check comment updated to reflect
  Principle III now requires justification for non-default stack choices, not prohibition

### Deferred Items
None
-->

# mymux Constitution

## Core Principles

### I. Observability-First (NON-NEGOTIABLE)

Every feature MUST be demonstrably observable in the running app before it is considered
complete. Runtime state MUST be visible through the app's own mechanisms: status indicator
dots (active/thinking/waiting/suspended/completed), the activity log panel, git dirty
indicators, and macOS notifications. Features that affect session state MUST surface that
state change in the sidebar. An agent MUST NOT declare work done based on compilation
success alone — observable behavior in `swift run` is the minimum bar.

**Rationale**: mymux's core value proposition is centralized, real-time observability of
multiple Claude sessions. A feature that cannot be observed in the running app has not
delivered its value.

### II. Test Before Done (NON-NEGOTIABLE)

No feature, task, or implementation is complete until it has been tested and confirmed
working end-to-end. Specifically:

- `swift build` MUST succeed with no errors before any task is marked complete
- `swift run` MUST launch the app with the main window visible
- The feature's acceptance scenarios MUST be demonstrably satisfied in the running app
- Status transitions MUST be triggerable and visually confirmed in the sidebar
- MCP tool calls MUST round-trip through the IPC socket and produce visible effects
- An agent MUST NOT report a task complete without having verified it in a live run
- Compilation success alone does not constitute completion

**Rationale**: The user has explicitly required that nothing be declared done until it is
tested and observable. Verification is part of implementation, not a follow-up step.

### III. macOS Compatibility Required

mymux MUST run on macOS 14 (Sonoma) or later without requiring App Sandbox (PTY access
demands this). Stack and library choices are flexible within that constraint:

- The app MUST build and run on macOS 14+ without App Sandbox
- The prescribed stack (SwiftTerm, GRDB.swift, AppKit, POSIX sockets) is the **default
  recommended path** — `founding-docs/mymux-technical-specification.md` documents
  CRITICAL failure modes for common alternatives and is authoritative for this stack
- Alternative libraries or frameworks MAY be used when they demonstrably work on macOS
  and offer a clear advantage over the prescribed approach
- Any deviation from the prescribed stack MUST be documented in the plan's Complexity
  Tracking table with a brief rationale

**Rationale**: The app must work reliably on macOS; the specific stack is not sacred.
The technical spec's CRITICAL notes remain valid for the default path and SHOULD be
consulted before selecting alternatives to avoid known dead ends.

### IV. POSIX IPC Protocol Strictly

All IPC between the MCP server and mymux.app MUST follow the specified NDJSON protocol:

- Socket path: `/tmp/mymux-ipc.sock`, permissions `0o600`
- `unlink()` before `bind()` on startup; `unlink()` again on shutdown
- Handshake: `hello` → `hello_ack` before any tool messages
- All post-handshake messages MUST include `req_id` for correlation
- Async responses (e.g., `request_user_input`) MUST route via `NSNotification`
- Per-client read buffering is required — UDS reads may deliver partial lines
- `DispatchSource.makeReadSource` for server and client FDs — no busy-wait loops

**Rationale**: `Network.framework` Unix domain sockets are known to silently fail on
macOS. The POSIX approach is fully specified and verified in the technical spec.

### V. Scope Discipline (YAGNI)

Features MUST NOT be added beyond those defined in the PRD. The following are explicitly
out of scope and MUST NOT be implemented:

- Split pane or multi-terminal grid layouts
- Cross-platform support
- Linear integration or ticket metadata
- AI-generated activity summaries
- Auto-branching or PR creation from within mymux

Shell sessions are ephemeral (not persisted to the database). Activity log entries display
only what Claude explicitly logs via `log_activity`. Worktree names MUST derive from
terminal display names via `toKebabCase()` — no manual overrides.

**Rationale**: mymux is a focused personal developer tool for a workshop demonstration.
Scope creep delays delivery of the core value proposition.

## Quality Gates

Before any implementation task is declared complete, the applicable gates below MUST pass.
Gates G1–G2 apply to every task. Gates G3–G6 apply when the relevant feature is touched.

- **G1 — Build**: `cd Mymux && swift build` completes with no errors
- **G2 — Launch**: `swift run` starts the app; main window appears with sidebar + terminal area
- **G3 — IPC Handshake**: Spawning a terminal causes the MCP server to connect and send
  `hello`; app responds with `hello_ack` (verify via `set_working_directory` effect)
- **G4 — Status Visible**: At least one status transition is observable in the sidebar
  status dot (e.g., typing in the terminal → active state shows green dot)
- **G5 — Activity Logged**: A `log_activity` call from MCP produces a visible entry in
  the Activity Log Panel in real-time
- **G6 — Persistence**: Quit and relaunch; tracks and terminals reappear in sidebar with
  `suspended` indicator

## Development Workflow

1. **Read founding docs before starting any feature.** `founding-docs/mymux-prd.md` and
   `founding-docs/mymux-technical-specification.md` contain CRITICAL implementation notes
   that prevent wasted effort. The tech spec is authoritative on all Swift/AppKit patterns
   for the default stack.

2. **Follow the speckit workflow.** Spec → Plan → Tasks → Implement. Do not skip to
   implementation. The plan MUST identify which Quality Gates apply to each phase.

3. **Build and run continuously.** Run `swift build` after every non-trivial change.
   Run `swift run` after completing each task. Do not accumulate unverified changes.

4. **Report only verified work.** When marking a task complete, an agent MUST confirm
   it was verified in a live `swift run` session. The phrase "compiles successfully" is
   not sufficient — observable runtime behavior is required.

5. **Check `.specify/memory/` for prior decisions** before re-deriving research, data
   models, or contracts.

## Governance

This constitution supersedes all other practices, preferences, and defaults. All
implementation decisions MUST be consistent with the principles above.

**Amendment procedure**: Any amendment requires:
1. A version bump per semantic versioning (MAJOR: breaking principle changes; MINOR: new
   principles or sections or material redefinitions; PATCH: clarifications and wording fixes)
2. Updating `LAST_AMENDED_DATE` to the amendment date
3. Re-running consistency propagation across dependent templates via `/speckit.constitution`
4. A commit of the form `docs: amend constitution to vX.Y.Z (<summary>)`

**Compliance**: Every PR and review MUST verify adherence to Principles I and II.
Stack choices that deviate from the prescribed path MUST be documented in the plan's
Complexity Tracking table with a brief rationale.

**Guidance file**: `founding-docs/mymux-technical-specification.md` is the authoritative
reference for all implementation-level CRITICAL notes and code patterns for the default stack.

**Version**: 1.1.0 | **Ratified**: 2026-06-26 | **Last Amended**: 2026-06-26
