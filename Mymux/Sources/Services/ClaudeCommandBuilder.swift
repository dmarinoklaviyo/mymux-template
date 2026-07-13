import Foundation

enum ClaudeCommandBuilder {
    static func buildCommand(terminal: Terminal, track: WorkTrack, isRestart: Bool, mcpConfigPath: String) -> String {
        var parts: [String] = []

        // cd to repo path
        let repoPath = track.repoPath.isEmpty ? FileManager.default.homeDirectoryForCurrentUser.path : track.repoPath
        parts.append("cd")
        parts.append(shellEscape(repoPath))
        parts.append("&&")
        parts.append("claude")

        // Restart flag
        if isRestart {
            parts.append("--continue")
        }

        // MCP config
        if !mcpConfigPath.isEmpty {
            parts.append("--mcp-config")
            parts.append(shellEscape(mcpConfigPath))
            parts.append("--allowedTools")
            parts.append("\"mcp__mymux__*\"")
        }

        // System prompt
        let systemPrompt = buildSystemPrompt(track: track, terminal: terminal)
        if !systemPrompt.isEmpty {
            parts.append("--system-prompt")
            parts.append(shellEscape(systemPrompt))
        }

        return parts.joined(separator: " ")
    }

    static func buildEnvironment(terminalId: String) -> [String] {
        var env: [String] = []

        let inherited = ["HOME", "PATH", "LANG", "USER", "SHELL"]
        for key in inherited {
            if let value = ProcessInfo.processInfo.environment[key] {
                env.append("\(key)=\(value)")
            }
        }

        env.append("TERM=xterm-256color")
        env.append("COLORTERM=truecolor")
        env.append("MYMUX_TERMINAL_ID=\(terminalId)")
        env.append("MYMUX_SOCKET_PATH=/tmp/mymux-ipc.sock")

        return env
    }

    static func buildSystemPrompt(track: WorkTrack, terminal: Terminal) -> String {
        var lines: [String] = []

        lines.append("You are working on: \(track.name)")
        lines.append("Terminal purpose: \(terminal.name)")
        lines.append("")

        if let ticketUrl = track.linearTicketUrl, !ticketUrl.isEmpty {
            lines.append("Linear ticket: \(ticketUrl)")
            lines.append("")
        }

        if !track.contextNotes.isEmpty {
            lines.append("Context:")
            lines.append(track.contextNotes)
            lines.append("")
        }

        lines.append("IMPORTANT -- Mymux Tools:")
        lines.append("You have access to Mymux MCP tools. Use them proactively:")
        lines.append("- set_working_directory: CALL THIS FIRST -- report your current working directory (pwd) immediately on startup")
        lines.append("- log_activity: Log milestones frequently (features done, tests passing, blockers hit)")
        lines.append("- set_terminal_title: Update your terminal name to reflect current task")
        lines.append("- notify_user: Alert the user when you finish major work or hit a blocker")
        lines.append("- request_user_input: Ask the user when you need a decision you cannot make from context")
        lines.append("")
        lines.append("Begin by calling set_working_directory with your current working directory, then start working on this task.")

        return lines.joined(separator: "\n")
    }

    private static func shellEscape(_ str: String) -> String {
        "\"" + str
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "$", with: "\\$")
            .replacingOccurrences(of: "`", with: "\\`") + "\""
    }
}
