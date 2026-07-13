import Foundation
import GRDB

struct ActivityLogEntry: Codable, FetchableRecord, PersistableRecord, Identifiable {
    var id: String
    var terminalId: String
    var message: String
    var createdAt: String

    static let databaseTableName = "activity_log"

    init(
        id: String = UUID().uuidString,
        terminalId: String,
        message: String,
        createdAt: String = ISO8601DateFormatter().string(from: Date())
    ) {
        self.id = id
        self.terminalId = terminalId
        self.message = message
        self.createdAt = createdAt
    }
}
