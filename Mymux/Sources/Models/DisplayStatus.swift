import Foundation

enum DisplayStatus: String, Codable, Equatable {
    case active, thinking, waiting, suspended, completed
}

enum RuntimeStatus: String, Codable, Equatable {
    case live, suspended, completed
}

enum TrackStatus: String, Codable, Equatable {
    case active, archived
}
