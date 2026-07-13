import Foundation

// Polls git status every 10s for each terminal with a known working directory.
// Runs git commands on a .utility QoS queue to avoid blocking the main thread.
final class GitStatusChecker {
    var onStatusUpdate: ((String, GitStatus) -> Void)?

    private var paths: [String: String] = [:]
    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "com.mymux.gitstatus", qos: .utility)

    func start() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 2, repeating: 10)
        t.setEventHandler { [weak self] in
            self?.checkAll()
        }
        t.resume()
        timer = t
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    func setPath(terminalId: String, path: String) {
        queue.async { [weak self] in
            guard let self = self else { return }
            self.paths[terminalId] = path
            self.checkOne(terminalId: terminalId, path: path)
        }
    }

    func removePath(terminalId: String) {
        queue.async { [weak self] in
            self?.paths.removeValue(forKey: terminalId)
        }
    }

    // MARK: - Private

    private func checkAll() {
        for (terminalId, path) in paths {
            checkOne(terminalId: terminalId, path: path)
        }
    }

    private func checkOne(terminalId: String, path: String) {
        let status = computeGitStatus(in: path)
        DispatchQueue.main.async { [weak self] in
            self?.onStatusUpdate?(terminalId, status)
        }
    }

    private func computeGitStatus(in path: String) -> GitStatus {
        guard isGitRepo(path: path) else { return .clean }

        let porcelain = git(["status", "--porcelain"], in: path)
        let isDirty = !porcelain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        var linesAdded = 0
        var linesRemoved = 0

        if isDirty {
            let numstat = git(["diff", "--numstat", "HEAD"], in: path)
            for line in numstat.components(separatedBy: "\n") where !line.isEmpty {
                let parts = line.components(separatedBy: "\t")
                if parts.count >= 2 {
                    linesAdded += Int(parts[0]) ?? 0
                    linesRemoved += Int(parts[1]) ?? 0
                }
            }
        }

        let aheadRaw = git(["rev-list", "--count", "@{u}..HEAD"], in: path)
        let commitsAhead = Int(aheadRaw.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0

        return GitStatus(
            isDirty: isDirty,
            linesAdded: linesAdded,
            linesRemoved: linesRemoved,
            commitsAhead: commitsAhead
        )
    }

    private func isGitRepo(path: String) -> Bool {
        let output = git(["rev-parse", "--is-inside-work-tree"], in: path)
        return output.trimmingCharacters(in: .whitespacesAndNewlines) == "true"
    }

    @discardableResult
    private func git(_ args: [String], in path: String) -> String {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        proc.arguments = args
        proc.currentDirectoryURL = URL(fileURLWithPath: path)
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        do {
            try proc.run()
            proc.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8) ?? ""
        } catch {
            return ""
        }
    }
}
