# Specification Quality Checklist: mymux — Multi-Session Claude Code Orchestrator

**Purpose**: Validate specification completeness and quality before proceeding to planning
**Created**: 2026-06-29
**Feature**: [spec.md](../spec.md)

## Content Quality

- [x] No implementation details (languages, frameworks, APIs)
- [x] Focused on user value and business needs
- [x] Written for non-technical stakeholders
- [x] All mandatory sections completed

## Requirement Completeness

- [x] No [NEEDS CLARIFICATION] markers remain
- [x] Requirements are testable and unambiguous
- [x] Success criteria are measurable
- [x] Success criteria are technology-agnostic (no implementation details)
- [x] All acceptance scenarios are defined
- [x] Edge cases are identified
- [x] Scope is clearly bounded
- [x] Dependencies and assumptions identified

## Feature Readiness

- [x] All functional requirements have clear acceptance criteria
- [x] User scenarios cover primary flows
- [x] Feature meets measurable outcomes defined in Success Criteria
- [x] No implementation details leak into specification

## Notes

- All items pass. Specification is ready for `/speckit.clarify` or `/speckit.plan`.

---

## Runtime Verification: G1 + G2 — Build & Launch (US1)

Steps to verify after `cd Mymux && swift build && swift run`:

- [ ] G1: `swift build` exits 0 with no errors (warnings OK)
- [ ] G2: `swift run` opens a 1200×800 window within 3 seconds
- [ ] G2: Sidebar is visible on the left with a source-list style
- [ ] G2: Toolbar shows "Shell" and "Activity" buttons in top-right of terminal area
- [ ] G2: Terminal area shows the empty state label
- [ ] US1: Clicking "+" (new track button if present) opens `NewTrackSheet`
- [ ] US1: After track + console creation, the console row appears with a status dot
- [ ] US1: Typing in the terminal → green (active) dot within 1s
- [ ] US1: Stopping output for 1–3s → blue pulsing (thinking) dot
- [ ] US1: Silence >3s at a prompt → amber (waiting) dot

---

## Runtime Verification: G4 — Notifications (US2)

Steps to verify macOS notifications and dock badge:

- [ ] G4: Waiting terminal state fires a macOS banner notification
- [ ] G4: Dock badge shows count of waiting sessions
- [ ] G4: Clicking notification brings mymux window to front with correct session visible
- [ ] G4: Terminal transitions out of waiting → dock badge count decreases
- [ ] G4: No notification crash when running via `swift run` (no bundle ID)

---

## Runtime Verification: US3 — Track & Console CRUD

- [ ] "+" top button → `NewTrackSheet` appears with Name/Path/Branch/Notes fields
- [ ] Fill form + Create → track appears in sidebar
- [ ] Per-track "⊕" button → new console row added, terminal session spawns
- [ ] Right-click console → "Delete Console" → row removed, process killed
- [ ] Right-click track → "Delete Track" → confirmation alert → track + all consoles removed
- [ ] Drag console row onto another track → console moves to new track in sidebar

---

## Runtime Verification: G3 + G5 — MCP Tools (US4)

Steps to verify IPC and MCP tool integration:

- [ ] G3: Spawning a console → MCP config written to `/tmp/mymux-mcp/mcp-<uuid>.json`
- [ ] G3: MCP server connects and sends `hello` over IPC socket
- [ ] G3: `hello_ack` is sent back (visible in app logs)
- [ ] G5: Claude calls `set_working_directory` → `sessionManager.workingDirectories` updated
- [ ] G5: Claude calls `log_activity("msg")` → entry written to `activity_log` table in DB
- [ ] G5: `request_user_input` from Claude → NSAlert sheet appears on main window within 500ms
- [ ] G5: Answering the alert → response sent back over IPC within 30s

---

## Runtime Verification: G5 — Activity Log Panel (US5)

- [ ] Toggle "Activity" button → panel slides in at 250px width on the right
- [ ] Select a console with logged entries → entries appear with `HH:mm:ss` timestamps
- [ ] Switch to another console → panel shows that console's entries
- [ ] No console selected → "Select a console to see activity" label shown
- [ ] Console selected but no entries → "No activity logged yet" label shown
- [ ] Claude calls `log_activity` while panel is open → entry appears without manual refresh
- [ ] Toggle "Activity" button again → panel slides back to 0 width

---

## Runtime Verification: US6 — Git Dirty Indicators

- [ ] Console with known working directory + dirty worktree → name turns amber within 10s
- [ ] `+N -M` diff stat shown inline next to console name
- [ ] `N↑` shown when commits ahead of upstream
- [ ] Clean worktree → no amber or diff indicators
- [ ] No working directory set → no git indicators shown at all

---

## Runtime Verification: US7 — Shell Panel

- [ ] Select a console with known working directory, click "Shell" → panel opens at 250px height
- [ ] Shell panel shows a tab bar with "shell 1" tab and a running shell
- [ ] `pwd` in shell → returns the working directory path
- [ ] Click "+" button → new tab opens with another shell in same directory
- [ ] Click "×" button → current tab closes; last tab closure → panel auto-collapses
- [ ] Hide panel → shell continues running → show panel → same shell state
- [ ] Click "Shell" with no working directory known → alert dialog shown, no panel opens

---

## Runtime Verification: G6 — Session Persistence (US8)

- [ ] Create a track + 2 consoles, let them reach active state
- [ ] Quit the app (Cmd+Q)
- [ ] Relaunch → both consoles appear as suspended (gray circles) in sidebar
- [ ] Select suspended terminal → "Session Suspended" placeholder + "Restart" button shown
- [ ] Click "Restart" → new Claude Code process starts with `--continue`
- [ ] Restarted session calls `set_working_directory` automatically via SessionStart hook
- [ ] App quit → `/tmp/mymux-ipc.sock` removed, `/tmp/mymux-mcp/` configs removed, dock badge cleared
