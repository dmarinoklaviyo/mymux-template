import Foundation

/// Archives a full work track (metadata + Claude conversation transcripts +
/// uncommitted git changes) to a compressed tarball, and rehydrates it later.
///
/// Archive layout (`~/.mymux/archives/<trackId>.tar.gz`):
///   manifest.json      — the track + all child rows (terminals, activity log,
///                         reference files, keywords)
///   meta.json          — branch, repoPath, archivedAt, format version,
///                         transcript dir name
///   transcripts/       — copy of ~/.claude/projects/<encoded-repoPath>/*.jsonl
///                         (the Claude conversation, restored so `claude
///                         --continue` resumes it after rehydration)
///   uncommitted.patch  — `git diff HEAD` of the worktree (in-flight work)
///
/// A sidecar `<trackId>.json` is written next to each tarball so the archive
/// list can be shown without extracting every tarball.
final class ArchiveService {
    static let formatVersion = 1

    private let store: SQLiteStore
    private let fileManager = FileManager.default

    init(store: SQLiteStore) {
        self.store = store
    }

    // MARK: - Manifest types

    struct Manifest: Codable {
        var version: Int
        var track: WorkTrack
        var terminals: [Terminal]
        var activityLog: [ActivityLogEntry]
        var referenceFiles: [ReferenceFile]
        var keywords: [TrackKeyword]
    }

    struct Meta: Codable {
        var version: Int
        var trackId: String
        var trackName: String
        var repoPath: String
        var branch: String
        var archivedAt: String
        var transcriptDirName: String?
        var hasUncommittedPatch: Bool
    }

    /// Lightweight sidecar used to render the archive list quickly.
    struct ArchiveSummary: Codable {
        var trackId: String
        var trackName: String
        var repoPath: String
        var branch: String
        var archivedAt: String
        var archivePath: String
        var sizeBytes: Int64
    }

    // MARK: - Paths

    var archivesDirectory: URL {
        fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(".mymux")
            .appendingPathComponent("archives")
    }

    private var claudeProjectsDirectory: URL {
        fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude")
            .appendingPathComponent("projects")
    }

    /// Claude encodes a project path by replacing `/` and `.` with `-`.
    /// e.g. /Users/foo/bar.baz -> -Users-foo-bar-baz
    private func claudeProjectDirName(for repoPath: String) -> String {
        return repoPath
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ".", with: "-")
    }

    private func archiveURL(for trackId: String) -> URL {
        archivesDirectory.appendingPathComponent("\(trackId).tar.gz")
    }

    private func sidecarURL(for trackId: String) -> URL {
        archivesDirectory.appendingPathComponent("\(trackId).json")
    }

    // MARK: - Archive

    /// Serializes the track to a tarball and removes it from the live database.
    @discardableResult
    func archive(trackId: String) throws -> ArchiveSummary {
        guard let track = try store.fetchTrack(id: trackId) else {
            throw ArchiveError.trackNotFound(trackId)
        }

        try fileManager.createDirectory(at: archivesDirectory, withIntermediateDirectories: true)

        // Gather all child rows.
        let terminals = try store.fetchTerminals(forTrackId: trackId)
        var activity: [ActivityLogEntry] = []
        for terminal in terminals {
            activity += try store.fetchActivityLogEntries(forTerminalId: terminal.id, limit: Int.max)
        }
        let refs = try store.fetchReferenceFiles(forTrackId: trackId)
        let keywords = try store.fetchTrackKeywords(forTrackId: trackId)

        // Staging directory.
        let staging = fileManager.temporaryDirectory
            .appendingPathComponent("mymux-archive-\(trackId)-\(UUID().uuidString)")
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: staging) }

        // 1. manifest.json
        let manifest = Manifest(
            version: Self.formatVersion,
            track: track,
            terminals: terminals,
            activityLog: activity,
            referenceFiles: refs,
            keywords: keywords
        )
        try writeJSON(manifest, to: staging.appendingPathComponent("manifest.json"))

        // 2. transcripts/
        var transcriptDirName: String?
        if !track.repoPath.isEmpty {
            let dirName = claudeProjectDirName(for: track.repoPath)
            let source = claudeProjectsDirectory.appendingPathComponent(dirName)
            if fileManager.fileExists(atPath: source.path) {
                let dest = staging.appendingPathComponent("transcripts")
                try fileManager.copyItem(at: source, to: dest)
                transcriptDirName = dirName
            }
        }

        // 3. uncommitted.patch
        var hasPatch = false
        if !track.repoPath.isEmpty, isGitRepo(track.repoPath) {
            let patch = runGit(["-C", track.repoPath, "diff", "HEAD"])
            if let patch = patch, !patch.isEmpty {
                try patch.write(
                    to: staging.appendingPathComponent("uncommitted.patch"),
                    atomically: true,
                    encoding: .utf8
                )
                hasPatch = true
            }
        }

        // 4. meta.json
        let archivedAt = ISO8601DateFormatter().string(from: Date())
        let meta = Meta(
            version: Self.formatVersion,
            trackId: track.id,
            trackName: track.name,
            repoPath: track.repoPath,
            branch: track.branch,
            archivedAt: archivedAt,
            transcriptDirName: transcriptDirName,
            hasUncommittedPatch: hasPatch
        )
        try writeJSON(meta, to: staging.appendingPathComponent("meta.json"))

        // 5. tar -czf
        let tarball = archiveURL(for: trackId)
        if fileManager.fileExists(atPath: tarball.path) {
            try fileManager.removeItem(at: tarball)
        }
        try runTar(["-czf", tarball.path, "-C", staging.path, "."])

        guard fileManager.fileExists(atPath: tarball.path) else {
            throw ArchiveError.tarFailed
        }

        // 6. sidecar summary
        let size = (try? tarball.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { Int64($0) } ?? 0
        let summary = ArchiveSummary(
            trackId: track.id,
            trackName: track.name,
            repoPath: track.repoPath,
            branch: track.branch,
            archivedAt: archivedAt,
            archivePath: tarball.path,
            sizeBytes: size
        )
        try writeJSON(summary, to: sidecarURL(for: trackId))

        // 7. Remove from live DB (cascade removes terminals, activity, refs, keywords).
        try store.deleteTrack(id: trackId)

        return summary
    }

    // MARK: - Rehydrate

    /// Restores an archived track back into the live database and Claude's
    /// project directory, then deletes the archive.
    @discardableResult
    func rehydrate(trackId: String) throws -> WorkTrack {
        let tarball = archiveURL(for: trackId)
        guard fileManager.fileExists(atPath: tarball.path) else {
            throw ArchiveError.archiveNotFound(trackId)
        }

        // Extract into a staging dir.
        let staging = fileManager.temporaryDirectory
            .appendingPathComponent("mymux-rehydrate-\(trackId)-\(UUID().uuidString)")
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: staging) }

        try runTar(["-xzf", tarball.path, "-C", staging.path])

        // Read manifest.
        let manifest: Manifest = try readJSON(from: staging.appendingPathComponent("manifest.json"))
        guard manifest.version <= Self.formatVersion else {
            throw ArchiveError.unsupportedVersion(manifest.version)
        }

        // Guard against a track that already exists live.
        if try store.fetchTrack(id: manifest.track.id) != nil {
            throw ArchiveError.trackAlreadyLive(manifest.track.id)
        }

        // Re-insert rows. Order matters for foreign keys:
        // track -> terminals -> activity; refs/keywords depend on track.
        var restored = manifest.track
        restored.status = TrackStatus.active.rawValue
        try store.insertTrack(restored)
        for terminal in manifest.terminals { try store.insertTerminal(terminal) }
        for entry in manifest.activityLog { try store.insertActivityLogEntry(entry) }
        for ref in manifest.referenceFiles { try store.insertReferenceFile(ref) }
        for keyword in manifest.keywords { try store.insertTrackKeyword(keyword) }

        // Restore transcripts.
        let transcripts = staging.appendingPathComponent("transcripts")
        if fileManager.fileExists(atPath: transcripts.path), !restored.repoPath.isEmpty {
            let dirName = claudeProjectDirName(for: restored.repoPath)
            let dest = claudeProjectsDirectory.appendingPathComponent(dirName)
            try fileManager.createDirectory(at: claudeProjectsDirectory, withIntermediateDirectories: true)
            if !fileManager.fileExists(atPath: dest.path) {
                try fileManager.copyItem(at: transcripts, to: dest)
            } else {
                // Merge individual files without clobbering newer sessions.
                let files = try fileManager.contentsOfDirectory(at: transcripts, includingPropertiesForKeys: nil)
                for file in files {
                    let target = dest.appendingPathComponent(file.lastPathComponent)
                    if !fileManager.fileExists(atPath: target.path) {
                        try fileManager.copyItem(at: file, to: target)
                    }
                }
            }
        }

        // Reapply uncommitted patch (best-effort — never blocks rehydration).
        let patchURL = staging.appendingPathComponent("uncommitted.patch")
        if fileManager.fileExists(atPath: patchURL.path), !restored.repoPath.isEmpty, isGitRepo(restored.repoPath) {
            _ = runGit(["-C", restored.repoPath, "apply", patchURL.path])
        }

        // Delete the archive + sidecar now that it is live again.
        try? fileManager.removeItem(at: tarball)
        try? fileManager.removeItem(at: sidecarURL(for: trackId))

        return restored
    }

    // MARK: - Listing

    /// Lists all archives, newest first. Reads sidecars; falls back to reading
    /// meta.json out of the tarball if a sidecar is missing.
    func listArchives() -> [ArchiveSummary] {
        guard let entries = try? fileManager.contentsOfDirectory(
            at: archivesDirectory,
            includingPropertiesForKeys: [.fileSizeKey]
        ) else { return [] }

        var summaries: [ArchiveSummary] = []
        for url in entries where url.pathExtension == "gz" {
            let trackId = url.deletingPathExtension().deletingPathExtension().lastPathComponent
            if let summary = try? readJSON(from: sidecarURL(for: trackId)) as ArchiveSummary {
                summaries.append(summary)
            } else if let meta = readMetaFromTarball(url) {
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { Int64($0) } ?? 0
                summaries.append(ArchiveSummary(
                    trackId: meta.trackId,
                    trackName: meta.trackName,
                    repoPath: meta.repoPath,
                    branch: meta.branch,
                    archivedAt: meta.archivedAt,
                    archivePath: url.path,
                    sizeBytes: size
                ))
            }
        }
        return summaries.sorted { $0.archivedAt > $1.archivedAt }
    }

    func deleteArchive(trackId: String) throws {
        try? fileManager.removeItem(at: archiveURL(for: trackId))
        try? fileManager.removeItem(at: sidecarURL(for: trackId))
    }

    // MARK: - Helpers

    private func readMetaFromTarball(_ tarball: URL) -> Meta? {
        // Stream meta.json to stdout: tar -xzf <file> -O ./meta.json
        guard let data = runTarData(["-xzf", tarball.path, "-O", "./meta.json"]) else { return nil }
        return try? JSONDecoder().decode(Meta.self, from: data)
    }

    private func writeJSON<T: Encodable>(_ value: T, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(value)
        try data.write(to: url, options: .atomic)
    }

    private func readJSON<T: Decodable>(from url: URL) throws -> T {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func isGitRepo(_ path: String) -> Bool {
        let output = runGit(["-C", path, "rev-parse", "--is-inside-work-tree"])
        return output?.trimmingCharacters(in: .whitespacesAndNewlines) == "true"
    }

    @discardableResult
    private func runGit(_ args: [String]) -> String? {
        guard let data = runProcess("/usr/bin/git", args) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func runTar(_ args: [String]) throws {
        guard runProcess("/usr/bin/tar", args) != nil else {
            throw ArchiveError.tarFailed
        }
    }

    private func runTarData(_ args: [String]) -> Data? {
        return runProcess("/usr/bin/tar", args)
    }

    /// Runs a process, returns stdout Data on exit 0, nil otherwise.
    private func runProcess(_ launchPath: String, _ args: [String]) -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = args
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        // git diff / apply and tar all return 0 on success.
        return process.terminationStatus == 0 ? data : nil
    }

    // MARK: - Errors

    enum ArchiveError: LocalizedError {
        case trackNotFound(String)
        case archiveNotFound(String)
        case trackAlreadyLive(String)
        case unsupportedVersion(Int)
        case tarFailed

        var errorDescription: String? {
            switch self {
            case .trackNotFound(let id): return "Track \(id) not found."
            case .archiveNotFound(let id): return "No archive found for track \(id)."
            case .trackAlreadyLive(let id): return "Track \(id) is already active."
            case .unsupportedVersion(let v): return "Archive format version \(v) is newer than this app supports."
            case .tarFailed: return "Failed to read or write the archive tarball."
            }
        }
    }
}
