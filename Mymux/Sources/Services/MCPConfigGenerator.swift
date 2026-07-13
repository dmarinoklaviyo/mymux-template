import Foundation

enum MCPConfigGenerator {
    static let socketPath = "/tmp/mymux-ipc.sock"
    static let configDir = "/tmp/mymux-mcp"

    static func configPath(terminalId: String) -> String {
        return "\(configDir)/mcp-\(terminalId).json"
    }

    static func resolveMCPServerPath() -> String? {
        // 1. Bundle resource path
        if let resourcePath = Bundle.main.resourcePath {
            let bundlePath = (resourcePath as NSString).appendingPathComponent("mymux-mcp-server.mjs")
            if FileManager.default.fileExists(atPath: bundlePath) {
                return bundlePath
            }
        }

        // 2. Relative to executable (for SPM builds)
        let executableURL = Bundle.main.executableURL
        if let execURL = executableURL {
            // .build/debug/Mymux -> up two levels -> project root -> Resources/
            let candidates = [
                execURL.deletingLastPathComponent()
                    .appendingPathComponent("Resources/mymux-mcp-server.mjs"),
                execURL.deletingLastPathComponent()
                    .deletingLastPathComponent()
                    .deletingLastPathComponent()
                    .appendingPathComponent("Resources/mymux-mcp-server.mjs"),
                execURL.deletingLastPathComponent()
                    .deletingLastPathComponent()
                    .deletingLastPathComponent()
                    .appendingPathComponent("Mymux/Resources/mymux-mcp-server.mjs"),
            ]
            for candidate in candidates {
                if FileManager.default.fileExists(atPath: candidate.path) {
                    return candidate.path
                }
            }
        }

        // 3. cwd-relative paths
        let cwd = FileManager.default.currentDirectoryPath
        let cwdCandidates = [
            (cwd as NSString).appendingPathComponent("Resources/mymux-mcp-server.mjs"),
            (cwd as NSString).appendingPathComponent("Mymux/Resources/mymux-mcp-server.mjs"),
        ]
        for path in cwdCandidates {
            if FileManager.default.fileExists(atPath: path) {
                return path
            }
        }

        return nil
    }

    @discardableResult
    static func writeConfig(terminalId: String) throws -> String {
        // Ensure config directory exists
        try FileManager.default.createDirectory(
            atPath: configDir,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        let serverPath = resolveMCPServerPath() ?? "/usr/local/bin/mymux-mcp-server.mjs"

        let config: [String: Any] = [
            "mcpServers": [
                "mymux": [
                    "command": "node",
                    "args": [serverPath],
                    "env": [
                        "MYMUX_TERMINAL_ID": terminalId,
                        "MYMUX_SOCKET_PATH": socketPath
                    ]
                ]
            ]
        ]

        let data = try JSONSerialization.data(withJSONObject: config, options: .prettyPrinted)
        let path = configPath(terminalId: terminalId)
        try data.write(to: URL(fileURLWithPath: path))

        // Set permissions to owner read/write only
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)

        return path
    }

    static func removeConfig(terminalId: String) {
        try? FileManager.default.removeItem(atPath: configPath(terminalId: terminalId))
    }

    static func removeAllConfigs() {
        try? FileManager.default.removeItem(atPath: configDir)
    }
}
