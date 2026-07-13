import Foundation
import GRDB

struct TrackKeyword: Codable, FetchableRecord, PersistableRecord, Identifiable {
    var id: String
    var trackId: String
    var keyword: String

    static let databaseTableName = "track_keywords"

    init(
        id: String = UUID().uuidString,
        trackId: String,
        keyword: String
    ) {
        self.id = id
        self.trackId = trackId
        self.keyword = keyword
    }
}
