import AppKit

final class IPCMessageHandler {
    private let sqliteStore: SQLiteStore
    private weak var notificationManager: NotificationManager?
    private weak var sessionManager: SessionManager?

    var onWorkingDirectorySet: ((String, String) -> Void)?

    init(sqliteStore: SQLiteStore, notificationManager: NotificationManager? = nil, sessionManager: SessionManager? = nil) {
        self.sqliteStore = sqliteStore
        self.notificationManager = notificationManager
        self.sessionManager = sessionManager
    }

    func setNotificationManager(_ nm: NotificationManager) {
        notificationManager = nm
    }

    func setSessionManager(_ sm: SessionManager) {
        sessionManager = sm
    }

    // MARK: - Message Dispatch

    func handleMessage(_ terminalId: String, payload: [String: Any]) -> [String: Any]? {
        guard let type = payload["type"] as? String else {
            return nil
        }

        let reqId = payload["req_id"] as? String ?? ""

        switch type {
        case "log_activity":
            return handleLogActivity(terminalId: terminalId, payload: payload, reqId: reqId)

        case "set_terminal_title":
            return handleSetTerminalTitle(terminalId: terminalId, payload: payload, reqId: reqId)

        case "set_working_directory":
            return handleSetWorkingDirectory(terminalId: terminalId, payload: payload, reqId: reqId)

        case "notify_user":
            return handleNotifyUser(terminalId: terminalId, payload: payload, reqId: reqId)

        case "request_user_input":
            handleRequestUserInput(terminalId: terminalId, payload: payload, reqId: reqId)
            return nil  // Response is async via NSNotification

        default:
            return ["type": "error", "req_id": reqId, "message": "Unknown message type: \(type)"]
        }
    }

    // MARK: - Handlers

    private func handleLogActivity(terminalId: String, payload: [String: Any], reqId: String) -> [String: Any]? {
        guard let message = payload["message"] as? String else {
            return ["type": "ack", "req_id": reqId, "status": "error", "message": "Missing 'message' field"]
        }

        let entry = ActivityLogEntry(
            id: UUID().uuidString,
            terminalId: terminalId,
            message: message,
            createdAt: ISO8601DateFormatter().string(from: Date())
        )

        do {
            try sqliteStore.insertActivityLogEntry(entry)
            return ["type": "ack", "req_id": reqId, "status": "ok"]
        } catch {
            print("Failed to insert activity log: \(error)")
            return ["type": "ack", "req_id": reqId, "status": "error", "message": error.localizedDescription]
        }
    }

    private func handleSetTerminalTitle(terminalId: String, payload: [String: Any], reqId: String) -> [String: Any]? {
        guard let title = payload["title"] as? String else {
            return ["type": "ack", "req_id": reqId, "status": "error", "message": "Missing 'title' field"]
        }

        do {
            try sqliteStore.updateTerminalName(id: terminalId, name: title)
            return ["type": "ack", "req_id": reqId, "status": "ok"]
        } catch {
            print("Failed to update terminal title: \(error)")
            return ["type": "ack", "req_id": reqId, "status": "error", "message": error.localizedDescription]
        }
    }

    private func handleSetWorkingDirectory(terminalId: String, payload: [String: Any], reqId: String) -> [String: Any]? {
        guard let path = payload["path"] as? String else {
            return ["type": "ack", "req_id": reqId, "status": "error", "message": "Missing 'path' field"]
        }

        sessionManager?.updateWorkingDirectory(terminalId: terminalId, path: path)
        onWorkingDirectorySet?(terminalId, path)

        return ["type": "ack", "req_id": reqId, "status": "ok"]
    }

    private func handleNotifyUser(terminalId: String, payload: [String: Any], reqId: String) -> [String: Any]? {
        guard let message = payload["message"] as? String else {
            return ["type": "ack", "req_id": reqId, "status": "error", "message": "Missing 'message' field"]
        }

        let urgency = payload["urgency"] as? String ?? "normal"
        notificationManager?.sendCustomNotification(message: message, urgency: urgency, terminalId: terminalId)

        return ["type": "ack", "req_id": reqId, "status": "ok"]
    }

    private func handleRequestUserInput(terminalId: String, payload: [String: Any], reqId: String) {
        let question = payload["question"] as? String ?? "Input required"
        let options = payload["options"] as? [String]

        // Present NSAlert on main thread
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }

            let alert = NSAlert()
            alert.messageText = "mymux — Input Required"
            alert.informativeText = question

            var textField: NSTextField?

            if let opts = options, !opts.isEmpty {
                // Add buttons for each option (max 3)
                for option in opts.prefix(3) {
                    alert.addButton(withTitle: option)
                }
            } else {
                // Add text input field
                let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
                field.placeholderString = "Type your answer..."
                alert.accessoryView = field
                textField = field
                alert.addButton(withTitle: "OK")
                alert.addButton(withTitle: "Cancel")
            }

            // 5-minute timeout
            var didRespond = false
            let timeoutItem = DispatchWorkItem { [weak self] in
                guard !didRespond else { return }
                didRespond = true
                let response: [String: Any] = [
                    "type": "user_input_response",
                    "req_id": reqId,
                    "error": "timeout",
                    "message": "User did not respond within 5 minutes"
                ]
                NotificationCenter.default.post(
                    name: NSNotification.Name("IPCResponse"),
                    object: nil,
                    userInfo: ["terminalId": terminalId, "response": response]
                )
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 300, execute: timeoutItem)

            let completionHandler: (NSApplication.ModalResponse) -> Void = { modalResponse in
                guard !didRespond else { return }
                didRespond = true
                timeoutItem.cancel()

                let answer: String
                if let opts = options, !opts.isEmpty {
                    let idx = modalResponse.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
                    if idx >= 0 && idx < opts.count {
                        answer = opts[idx]
                    } else {
                        answer = ""
                    }
                } else if let field = textField {
                    if modalResponse == .alertFirstButtonReturn {
                        answer = field.stringValue
                    } else {
                        answer = ""
                    }
                } else {
                    answer = ""
                }

                let response: [String: Any] = [
                    "type": "user_input_response",
                    "req_id": reqId,
                    "answer": answer
                ]
                NotificationCenter.default.post(
                    name: NSNotification.Name("IPCResponse"),
                    object: nil,
                    userInfo: ["terminalId": terminalId, "response": response]
                )
            }

            if let keyWindow = NSApp.keyWindow {
                alert.beginSheetModal(for: keyWindow, completionHandler: completionHandler)
            } else {
                let response = alert.runModal()
                completionHandler(response)
            }
        }
    }
}
