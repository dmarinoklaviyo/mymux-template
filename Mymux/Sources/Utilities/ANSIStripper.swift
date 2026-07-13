import Foundation

enum ANSIStripper {
    private static let csiPattern = try! NSRegularExpression(pattern: #"\x1b\[[0-9;]*[a-zA-Z]"#)
    private static let oscPattern = try! NSRegularExpression(pattern: #"\x1b\][^\x07]*\x07"#)
    private static let oscStPattern = try! NSRegularExpression(pattern: #"\x1b\][^\x1b]*\x1b\\"#)

    static func strip(_ input: String) -> String {
        var result = input
        result = csiPattern.stringByReplacingMatches(
            in: result,
            range: NSRange(result.startIndex..., in: result),
            withTemplate: ""
        )
        result = oscPattern.stringByReplacingMatches(
            in: result,
            range: NSRange(result.startIndex..., in: result),
            withTemplate: ""
        )
        result = oscStPattern.stringByReplacingMatches(
            in: result,
            range: NSRange(result.startIndex..., in: result),
            withTemplate: ""
        )
        return result
    }

    static func strip(bytes: [UInt8]) -> String {
        guard let str = String(bytes: bytes, encoding: .utf8) else {
            return String(bytes: bytes, encoding: .ascii) ?? ""
        }
        return strip(str)
    }
}
