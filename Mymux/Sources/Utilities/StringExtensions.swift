import Foundation

extension String {
    func toKebabCase() -> String {
        let lowered = lowercased()
        let pattern = try! NSRegularExpression(pattern: "[^a-z0-9]+")
        let range = NSRange(lowered.startIndex..., in: lowered)
        let replaced = pattern.stringByReplacingMatches(in: lowered, range: range, withTemplate: "-")
        return replaced.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }
}
