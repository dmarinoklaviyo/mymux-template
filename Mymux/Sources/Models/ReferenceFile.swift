import Foundation
import GRDB

struct ReferenceFile: Codable, FetchableRecord, PersistableRecord, Identifiable {
    var id: String
    var trackId: String
    var filePath: String
    var description: String
    var sortOrder: Int

    static let databaseTableName = "reference_files"

    init(
        id: String = UUID().uuidString,
        trackId: String,
        filePath: String,
        description: String = "",
        sortOrder: Int = 0
    ) {
        self.id = id
        self.trackId = trackId
        self.filePath = filePath
        self.description = description
        self.sortOrder = sortOrder
    }
}
