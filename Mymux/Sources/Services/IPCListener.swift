import Foundation
import Darwin

// MARK: - Error

struct IPCError: Error {
    let message: String
    init(_ message: String) { self.message = message }
}

// MARK: - IPCListener

// CRITICAL: Use POSIX sockets (socket/bind/listen/accept), NOT Network.framework NWListener
// NWListener silently fails to create UDS files on macOS
// Use DispatchSource.makeReadSource for server FD and each client FD
// NO busy-wait loops or select()/poll()
// Per-client read buffers for NDJSON partial-line accumulation
// unlink() BEFORE bind() and again in stop()
// socket path /tmp/mymux-ipc.sock, permissions chmod 0o600
// hello message: first-wins for terminal ID registration

final class IPCListener {
    let socketPath = "/tmp/mymux-ipc.sock"
    private let queue = DispatchQueue(label: "com.mymux.ipc")
    private var serverFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private var clientSources: [Int32: DispatchSourceRead] = [:]
    private var connections: [String: Int32] = [:]          // terminalId -> client fd (first-wins)
    private var connectionBuffers: [Int32: String] = [:]    // per-client NDJSON buffer

    var onMessage: ((String, [String: Any]) -> [String: Any]?)?

    // MARK: - Start / Stop

    func start() throws {
        socketPath.withCString { path in _ = unlink(path) }

        serverFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard serverFD >= 0 else {
            throw IPCError("Failed to create socket: \(String(cString: strerror(errno)))")
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            socketPath.withCString { cstr in
                _ = strcpy(UnsafeMutableRawPointer(ptr).assumingMemoryBound(to: CChar.self), cstr)
            }
        }

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                bind(serverFD, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            close(serverFD)
            serverFD = -1
            throw IPCError("Failed to bind: \(String(cString: strerror(errno)))")
        }

        socketPath.withCString { path in _ = chmod(path, 0o600) }

        guard listen(serverFD, 10) == 0 else {
            close(serverFD)
            serverFD = -1
            throw IPCError("Failed to listen: \(String(cString: strerror(errno)))")
        }

        let source = DispatchSource.makeReadSource(fileDescriptor: serverFD, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptClient() }
        source.setCancelHandler { [weak self] in
            if let fd = self?.serverFD, fd >= 0 { close(fd) }
        }
        source.resume()
        acceptSource = source

        print("IPCListener: Listening on \(socketPath)")
    }

    func stop() {
        acceptSource?.cancel()
        acceptSource = nil

        queue.sync {
            for (_, source) in clientSources { source.cancel() }
            clientSources.removeAll()
            connections.removeAll()
            connectionBuffers.removeAll()
            if serverFD >= 0 {
                close(serverFD)
                serverFD = -1
            }
        }

        socketPath.withCString { path in _ = unlink(path) }
    }

    // MARK: - Accept Client

    private func acceptClient() {
        let clientFD = accept(serverFD, nil, nil)
        guard clientFD >= 0 else { return }

        connectionBuffers[clientFD] = ""

        let source = DispatchSource.makeReadSource(fileDescriptor: clientFD, queue: queue)
        source.setEventHandler { [weak self] in self?.readFromClient(fd: clientFD) }
        source.setCancelHandler {
            close(clientFD)
        }
        source.resume()
        clientSources[clientFD] = source
    }

    // MARK: - Read

    private func readFromClient(fd: Int32) {
        var buf = [UInt8](repeating: 0, count: 4096)
        let n = read(fd, &buf, buf.count)
        if n <= 0 {
            disconnectClient(fd: fd)
            return
        }

        let chunk = String(bytes: buf[0..<n], encoding: .utf8) ?? ""
        var buffer = (connectionBuffers[fd] ?? "") + chunk

        while let newlineIndex = buffer.firstIndex(of: "\n") {
            let line = String(buffer[buffer.startIndex..<newlineIndex])
            buffer = String(buffer[buffer.index(after: newlineIndex)...])
            if !line.isEmpty {
                processLine(line, fromFD: fd)
            }
        }
        connectionBuffers[fd] = buffer
    }

    private func disconnectClient(fd: Int32) {
        clientSources[fd]?.cancel()
        clientSources.removeValue(forKey: fd)
        connectionBuffers.removeValue(forKey: fd)
        // Remove from connections map
        connections = connections.filter { $0.value != fd }
    }

    // MARK: - Process Line

    private func processLine(_ line: String, fromFD fd: Int32) {
        guard let data = line.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else {
            return
        }

        if type == "hello" {
            guard let terminalId = json["terminal_id"] as? String else { return }
            // First-wins: only register if not already connected
            if connections[terminalId] == nil {
                connections[terminalId] = fd
            }
            writeJSON(["type": "hello_ack", "status": "ok"], toFD: fd)
            return
        }

        // For other messages, look up terminal_id
        guard let terminalId = json["terminal_id"] as? String else { return }

        if let response = onMessage?(terminalId, json) {
            writeJSON(response, toFD: fd)
        }
    }

    // MARK: - Send Response

    func sendResponse(terminalId: String, message: [String: Any]) {
        queue.async { [weak self] in
            guard let self = self,
                  let fd = self.connections[terminalId] else { return }
            self.writeJSON(message, toFD: fd)
        }
    }

    // MARK: - Write JSON

    private func writeJSON(_ obj: [String: Any], toFD fd: Int32) {
        guard let data = try? JSONSerialization.data(withJSONObject: obj),
              var str = String(data: data, encoding: .utf8) else { return }
        str += "\n"
        str.withCString { cstr in
            _ = write(fd, cstr, strlen(cstr))
        }
    }
}
