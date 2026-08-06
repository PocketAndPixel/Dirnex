import Foundation

/// Escaping, and the one rule the whole rendered preview rests on (PLAN.md §M18 ▸ Slice 1).
///
/// **Every** string that reaches the output goes through here. Not "every string that might contain
/// markup" — every one, without exception, because an exception is a hole and a hole in this
/// particular wall is a page that runs somebody else's code the moment a cursor passes over their
/// file. CommonMark says to pass raw HTML through; this renderer does not, and that decision is
/// what leaves nothing for a sanitizer to get wrong: there is no path from a `.md` to an element.
///
/// The five named characters are the HTML5 set. `'` is escaped as `&#39;` rather than `&apos;`,
/// which is the safe spelling everywhere including inside an attribute.
enum MarkdownHTML {
    static func escaped(_ text: some StringProtocol) -> String {
        var result = ""
        result.reserveCapacity(text.count)
        for character in text {
            switch character {
            case "&": result += "&amp;"
            case "<": result += "&lt;"
            case ">": result += "&gt;"
            case "\"": result += "&quot;"
            case "'": result += "&#39;"
            default: result.append(character)
            }
        }
        return result
    }

    /// `name="value"`, or nothing at all when there is no value — so an absent title leaves no
    /// empty attribute behind.
    static func attribute(_ name: String, _ value: String?) -> String {
        guard let value, !value.isEmpty else { return "" }
        return " \(name)=\"\(escaped(value))\""
    }

    /// An element with children already rendered.
    static func element(_ tag: String, _ inner: String, attributes: String = "") -> String {
        "<\(tag)\(attributes)>\(inner)</\(tag)>"
    }
}

/// Which URLs a rendered document is allowed to point at (PLAN.md §M18 ▸ Slice 1).
///
/// A second wall behind the escaping, for the one thing escaping cannot reach: `[click](javascript:…)`
/// is *valid Markdown*, and it produces a real `href` with no raw HTML anywhere in the file. The
/// preview already refuses to navigate anywhere but the document it loaded, and scripts are off —
/// but a link whose destination is a script is not something to leave to two other layers agreeing
/// with each other.
///
/// Allow-list, never a block-list: the schemes named below are the ones a document has a reason to
/// use, and anything else renders as **plain text**, keeping the words and losing the link.
enum MarkdownURL {
    private static let allowed: Set<String> = [
        "http", "https", "mailto", "ftp", "ftps", "file", "tel", "sftp"
    ]

    static func sanitized(_ destination: String, isImage: Bool) -> String? {
        let trimmed = destination.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let scheme = scheme(of: trimmed) else { return trimmed }
        if allowed.contains(scheme) { return trimmed }
        // A `data:` image is what a self-contained document inlines, and the content rules already
        // let one load (docs/NOTES.md ▸ M16's measurements). Only images: `data:text/html` in a
        // link is a page of somebody else's making.
        if isImage, scheme == "data", trimmed.lowercased().hasPrefix("data:image/") { return trimmed }
        return nil
    }

    /// The lowercased scheme of an absolute URL, or `nil` for a relative one.
    ///
    /// Whitespace and control characters are dropped before the test rather than after, because
    /// `java\tscript:` and `java%0Ascript:` are the same URL to a browser and two different strings
    /// to a naive `hasPrefix`.
    private static func scheme(of destination: String) -> String? {
        var scheme = ""
        for character in destination {
            if character == ":" { return scheme.lowercased() }
            if character.isWhitespace || character.unicodeScalars.contains(where: {
                $0.properties.generalCategory == .control
            }) {
                continue
            }
            guard character.isLetter || character.isNumber || "+-.".contains(character) else {
                // `/`, `#`, `?` and the rest: this is a relative URL, and there is no scheme.
                return nil
            }
            scheme.append(character)
        }
        return nil
    }
}
