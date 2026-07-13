<!-- SPECKIT START -->
For additional context about technologies to be used, project structure,
shell commands, and other important information, read the current plan
<!-- SPECKIT END -->

## Active Technologies
- Swift 5.9+ (SPM executable target targeting macOS 14+); TypeScript 5.0 for MCP server, compiled by esbuild to ESM + SwiftTerm ~>1.11 (terminal emulation), GRDB.swift ~>7.0 (SQLite ORM), AppKit (UI); Node.js 20+ + `@modelcontextprotocol/sdk` (MCP server) (001-mymux-app)
- SQLite at `~/.mymux/mymux.db` managed via GRDB DatabasePool; no persistence for shell sessions or in-flight display status (001-mymux-app)

## Recent Changes
- 001-mymux-app: Added Swift 5.9+ (SPM executable target targeting macOS 14+); TypeScript 5.0 for MCP server, compiled by esbuild to ESM + SwiftTerm ~>1.11 (terminal emulation), GRDB.swift ~>7.0 (SQLite ORM), AppKit (UI); Node.js 20+ + `@modelcontextprotocol/sdk` (MCP server)
- Linear ticket linking: `WorkTrack.linearTicketUrl` (String?, already in DB schema) is now surfaced in the UI. `NewTrackSheet` has a "Linear Ticket" URL field. The sidebar shows a blue link-icon child row under each track that has a ticket set — clicking opens the URL in the browser. Right-click on a track (or the ticket row itself) to set/change/remove. Key files: `SidebarViewController.swift` (`LinearTicketCellView`, `isLinearItem`/`trackIdFromLinearItem` helpers, updated data source), `NewTrackSheet.swift`, `AppDelegate.swift` (`sidebarDidRequestSetLinearTicket`).
- Paste in terminals: `AppDelegate.setupMainMenu()` now builds an Edit menu (Cut/Copy/Paste/Select All wired to `NSText` actions). SPM executables have no default menu, so without it Cmd+V never reached the terminal views.
- Mouse-motion guard: `TerminalContainerView` installs a local `NSEvent` monitor that swallows `.mouseMoved` events while the terminal is in `anyEvent` mouse mode (`\x1b[?1003h`, which Claude Code enables for interactive prompts) and the pointer is over the view — prevents hovering from auto-selecting a prompt choice. Clicks/scroll/selection unaffected.
- Track archive & rehydrate: `ArchiveService.swift` serializes a track (all DB rows + `~/.claude/projects/<encoded-repoPath>` transcripts + `git diff HEAD` patch + meta) to `~/.mymux/archives/<trackId>.tar.gz` with a `<trackId>.json` sidecar for fast listing, then deletes the track from the live DB (so it leaves the sidebar; no schema migration needed). Rehydrate re-inserts rows, restores transcripts (so `claude --continue` resumes the conversation), best-effort reapplies the patch, and deletes the archive. UI: right-click track ▸ "Archive Track…" (`SidebarViewController.menuArchiveTrack` → `sidebarDidRequestArchiveTrack`), and File ▸ "Archived Tracks…" opens `ArchivedTracksSheet` (rehydrate/delete). ~1,500–3,000 tracks fit in 1 GB (gzipped, transcripts dominate). Note: `git diff HEAD` captures modified tracked files only — untracked files are not archived.
