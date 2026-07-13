import Foundation
import GRDB

struct WorkTrack: Codable, FetchableRecord, PersistableRecord, Identifiable {
    var id: String
    var name: String
    var repoPath: String
    var branch: String
    var linearTicketUrl: String?
    var contextNotes: String
    var status: String
    var createdAt: String
    var updatedAt: String

    static let databaseTableName = "work_tracks"
    static let terminals = hasMany(Terminal.self, using: Terminal.trackForeignKey)
    static let referenceFiles = hasMany(ReferenceFile.self)
    static let trackKeywords = hasMany(TrackKeyword.self)

    init(
        id: String = UUID().uuidString,
        name: String,
        repoPath: String = "",
        branch: String = "",
        linearTicketUrl: String? = nil,
        contextNotes: String = "",
        status: String = TrackStatus.active.rawValue,
        createdAt: String = ISO8601DateFormatter().string(from: Date()),
        updatedAt: String = ISO8601DateFormatter().string(from: Date())
    ) {
        self.id = id
        self.name = name
        self.repoPath = repoPath
        self.branch = branch
        self.linearTicketUrl = linearTicketUrl
        self.contextNotes = contextNotes
        self.status = status
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
