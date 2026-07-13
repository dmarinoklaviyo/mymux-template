# Data Model: mymux

**Feature**: 001-mymux-app  
**Date**: 2026-06-29

---

## Persisted Entities (SQLite via GRDB)

### WorkTrack

Represents a named group of Claude Code sessions tied to a project or feature context.

| Field | Type | Constraints | Description |
|-------|------|-------------|-------------|
| id | TEXT (UUID) | PK | UUID string |
| name | TEXT | NOT NULL | Display name shown in sidebar |
| repoPath | TEXT | NOT NULL | Absolute path to the repository |
| branch | TEXT | NOT NULL | Git branch name (may be empty string) |
| linearTicketUrl | TEXT | nullable | Optional Linear ticket URL |
| contextNotes | TEXT | DEFAULT '' | Free-form context injected into system prompt |
| status | TEXT | NOT NULL DEFAULT 'active' | TrackStatus: `active` or `archived` |
| createdAt | TEXT | NOT NULL | ISO 8601 timestamp |
| updatedAt | TEXT | NOT NULL | ISO 8601 timestamp |

**Relationships**: has-many Terminal (cascade delete), has-many ReferenceFile (cascade delete), has-many TrackKeyword (cascade delete)

---

### Terminal

Represents an individual Claude Code session within a work track.

| Field | Type | Constraints | Description |
|-------|------|-------------|-------------|
| id | TEXT (UUID) | PK | UUID string |
| trackId | TEXT | FK → work_tracks(id) CASCADE DELETE | Parent track |
| name | TEXT | NOT NULL | Display name in sidebar |
| worktreeName | TEXT | NOT NULL DEFAULT '' | Kebab-case name for `--worktree` flag |
| runtimeStatus | TEXT | NOT NULL DEFAULT 'live' | RuntimeStatus: `live`, `suspended`, or `completed` |
| createdAt | TEXT | NOT NULL | ISO 8601 timestamp |
| lastAccessedAt | TEXT | nullable | ISO 8601 timestamp, updated on focus |

**Relationships**: belongs-to WorkTrack, has-many ActivityLogEntry (cascade delete)

**Derived field**: `worktreeName` = `name.toKebabCase()` (e.g., "Auth Refactor" → `auth-refactor`)

---

### ActivityLogEntry

A timestamped message explicitly logged by a Claude Code session.

| Field | Type | Constraints | Description |
|-------|------|-------------|-------------|
| id | TEXT (UUID) | PK | UUID string |
| terminalId | TEXT | FK → terminals(id) CASCADE DELETE | Owning terminal |
| message | TEXT | NOT NULL | Activity message from Claude |
| createdAt | TEXT | NOT NULL | ISO 8601 timestamp |

**Read pattern**: ValueObservation on `terminalId` equality, ordered by `createdAt ASC`, limit 100.

---

### ReferenceFile

An optional file reference associated with a work track for context.

| Field | Type | Constraints | Description |
|-------|------|-------------|-------------|
| id | TEXT (UUID) | PK | UUID string |
| trackId | TEXT | FK → work_tracks(id) CASCADE DELETE | Parent track |
| filePath | TEXT | NOT NULL | Absolute file path |
| description | TEXT | DEFAULT '' | Optional description |
| sortOrder | INTEGER | NOT NULL DEFAULT 0 | Display ordering |

---

### TrackKeyword

A keyword tag associated with a work track.

| Field | Type | Constraints | Description |
|-------|------|-------------|-------------|
| id | TEXT (UUID) | PK | UUID string |
| trackId | TEXT | FK → work_tracks(id) CASCADE DELETE | Parent track |
| keyword | TEXT | NOT NULL | Keyword string |

---

## Schema Migrations

| Migration | Tables Modified |
|-----------|----------------|
| 001_baseSchema | CREATE: work_tracks, terminals, reference_files, activity_log; indexes |
| 002_trackKeywords | CREATE: track_keywords |
| 003_worktreeName | ALTER terminals ADD COLUMN worktreeName TEXT NOT NULL DEFAULT '' |

---

## Transient (In-Memory Only)

### DisplayStatus

Runtime classification of a terminal session derived from PTY output monitoring. Not persisted.

| Value | Visual | Condition |
|-------|--------|-----------|
| `active` | Green filled circle (●) | Output received within ~1 second |
| `thinking` | Blue pulsing circle | Silence 1–3s, no prompt detected |
| `waiting` | Amber circle + `[!]` badge | Silence >3s + prompt pattern matched |
| `suspended` | Gray open circle (◌) | Process exited or app quit |
| `completed` | Dim checkmark (✓) | Session task completed |

### GitStatus

Per-terminal git state snapshot, refreshed every 10 seconds. Only computed when `workingDirectory` is known.

| Field | Type | Description |
|-------|------|-------------|
| isDirty | Bool | true if uncommitted changes or commits ahead |
| linesAdded | Int | Lines added vs HEAD (including untracked file lines) |
| linesRemoved | Int | Lines removed vs HEAD |
| commitsAhead | Int | Commits ahead of upstream |

**Static constant**: `GitStatus.clean` = `{false, 0, 0, 0}`

### WorkingDirectories (SessionManager)

`[terminalId: String]` — maps terminal UUID to its reported working directory path. Populated by `set_working_directory` MCP tool or SessionStart hook. Not persisted.

---

## State Machines

### Terminal RuntimeStatus (Persisted)

```
[new]
  │
  ▼
 live ──── (app quit) ────► suspended ──── (Restart) ────► live
  │
  └─── (task done) ─────► completed
```

- On app launch: all `live` terminals are marked `suspended` (startup reconciliation)
- `Restart` button: creates new live session from suspended terminal record

### Terminal DisplayStatus (In-Memory)

```
          ┌──── dataReceived ────────────────────────────────┐
          │                                                   │
          ▼                                                   │
       ACTIVE ──── 1s silence ──► THINKING ──── 3s silence ──┤
                                        ▲              │      │
                                        │         prompt?     │
                                        │       /         \   │
                                  no prompt    YES        NO  │
                                        │      │              │
                                        └──────┘              │
                                      WAITING ◄───────────────┘
                                        │
                               process exits
                                        │
                                        ▼
                                   SUSPENDED
```

---

## Reactive Observation (GRDB ValueObservation)

| Observer | Tracked Table(s) | Consumer |
|----------|-----------------|----------|
| Sidebar data | work_tracks + terminals (joined) | SidebarViewController |
| Activity log | activity_log (filtered by terminalId) | ActivityPanelView |
