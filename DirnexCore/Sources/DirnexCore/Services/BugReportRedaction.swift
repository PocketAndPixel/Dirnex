import Foundation

/// Shortens the home folder to `~` in everything a bug report carries (PLAN.md §M30). A path names
/// the person (`/Users/jane`), and the report needs only where a file sits relative to home.
///
/// Two spellings are replaced: the plain one, and the one a crash report writes, whose JSON escapes
/// every slash (`\/Users\/jane`, measured in a real `.ips` on 2026-10-01). The home is replaced only
/// where its name ends: `/Users/janet` and `/Users/jane.doe` are other people's folders, and are
/// left alone, while the full stop in "… in /Users/jane." ends a sentence. Case is ignored, as the
/// Mac's own disk ignores it.
public struct BugReportRedaction: Sendable, Hashable {
    /// Such as `/Users/jane`, without a trailing slash.
    public let homePath: String

    public init(homePath: String) {
        var path = homePath
        while path.count > 1, path.hasSuffix("/") {
            path.removeLast()
        }
        self.homePath = path
    }

    /// This Mac's home folder.
    public static var current: BugReportRedaction {
        BugReportRedaction(homePath: NSHomeDirectory())
    }

    public func redacted(_ text: String) -> String {
        // `/` alone, or nothing, would turn every path into `~`.
        guard homePath.count > 1 else { return text }
        let escaped = homePath.replacingOccurrences(of: "/", with: "\\/")
        return replacingHome(escaped, in: replacingHome(homePath, in: text))
    }

    private func replacingHome(_ home: String, in text: String) -> String {
        var result = ""
        var rest = text[...]
        while let found = rest.range(of: home, options: [.literal, .caseInsensitive]) {
            result += rest[..<found.lowerBound]
            result += Self.continuesName(rest[found.upperBound...]) ? rest[found] : "~"
            rest = rest[found.upperBound...]
        }
        return result + rest
    }

    /// Whether `tail`, the text right after a home path, makes it a longer name: a letter or digit
    /// (`/Users/janet`), or a `.`, `-` or `_` with more of a name after it (`/Users/jane.doe`).
    private static func continuesName(_ tail: Substring) -> Bool {
        let scalars = tail.unicodeScalars.prefix(2)
        let isName = { (scalar: Unicode.Scalar) in CharacterSet.alphanumerics.contains(scalar) }
        guard let next = scalars.first else { return false }
        if isName(next) { return true }
        guard "._-".unicodeScalars.contains(next), let after = scalars.dropFirst().first else { return false }
        return isName(after) || "._-".unicodeScalars.contains(after)
    }
}

/// Makes a crash report fit to send (PLAN.md §M30): the home folder shortened, the values that
/// identify the Mac rather than the crash removed, and the size capped.
///
/// A crash report is an `.ips` file: one line of JSON, then a JSON body. It is trimmed as text, not
/// parsed and written back, so what reaches Oleg is Apple's own report with a few values blanked, and
/// a 64-bit register value cannot lose precision in a round trip through `JSONSerialization`.
public enum CrashReportTrimmer {
    /// Keys whose values stay the same across reports from one Mac, or one boot, and say nothing
    /// about the crash. Their values become `""`. Seen in a real report on 2026-10-01.
    public static let identifyingKeys = [
        "crashReporterKey", "deviceIdentifierForVendor", "bootSessionUUID", "sleepWakeUUID"
    ]

    /// Ends a report that was cut to fit.
    public static let cutMarker = "\n[Trimmed by Dirnex to fit the report.]\n"

    /// `text` ready to send: redacted, identifiers removed, and at most `maxBytes` of UTF-8.
    public static func trimmed(
        _ text: String,
        redaction: BugReportRedaction,
        maxBytes: Int = BugReport.Limits.crashReportBytes
    ) -> String {
        cut(removingIdentifiers(from: redaction.redacted(text)), toBytes: maxBytes)
    }

    /// `text` as it was if it fits in `maxBytes` of UTF-8, or its start with ``cutMarker`` after it.
    /// The start of a report is the part worth keeping: the exception, the reason and the crashed
    /// thread come before the long lists.
    public static func cut(_ text: String, toBytes maxBytes: Int) -> String {
        guard text.utf8.count > maxBytes else { return text }
        let room = maxBytes - cutMarker.utf8.count
        guard room > 0 else { return "" }
        return BugReportText.prefix(text, maxBytes: room) + cutMarker
    }

    /// Blanks the value of each of ``identifyingKeys``, written `"key" : "value"` (the body's
    /// spacing) or `"key":"value"` (the first line's). A test checks the pattern names every key.
    static func removingIdentifiers(from text: String) -> String {
        // A `Regex` isn't `Sendable`, so it can't be a `static let`.
        let pattern =
            #/(?<key>"(?:crashReporterKey|deviceIdentifierForVendor|bootSessionUUID|sleepWakeUUID)"\s*:\s*)"[^"]*"/#
        return text.replacing(pattern) { match in "\(match.output.key)\"\"" }
    }
}
