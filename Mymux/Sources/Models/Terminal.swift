import Foundation
import GRDB

struct Terminal: Codable, FetchableRecord, PersistableRecord, Identifiable {
    var id: String
    var trackId: String
    var name: String
    var worktreeName: String
    var runtimeStatus: String
    var createdAt: String
    var lastAccessedAt: String?

    static let databaseTableName = "terminals"
    static let trackForeignKey = ForeignKey(["trackId"])
    static let track = belongsTo(WorkTrack.self, using: trackForeignKey)
    static let activityEntries = hasMany(ActivityLogEntry.self)

    init(
        id: String = UUID().uuidString,
        trackId: String,
        name: String,
        worktreeName: String? = nil,
        runtimeStatus: String = RuntimeStatus.live.rawValue,
        createdAt: String = ISO8601DateFormatter().string(from: Date()),
        lastAccessedAt: String? = nil
    ) {
        self.id = id
        self.trackId = trackId
        self.name = name
        self.worktreeName = worktreeName ?? name.toKebabCase()
        self.runtimeStatus = runtimeStatus
        self.createdAt = createdAt
        self.lastAccessedAt = lastAccessedAt
    }
}
