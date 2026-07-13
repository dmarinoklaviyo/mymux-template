import Foundation

enum FuzzyMatcher {
    static func matches(_ query: String, in target: String) -> Bool {
        target.lowercased().contains(query.lowercased())
    }
}
