import Foundation

/// `<https://example.com>` and `<someone@example.com>` (PLAN.md §M18 ▸ Slice 1).
///
/// Narrow on purpose. Everything else inside angle brackets is **text** — this renderer does not
/// pass raw HTML through, so `<div>` renders as the five characters somebody typed, and that is the
/// decision that keeps the generated page inert with no sanitizer to keep correct.
enum MarkdownAutolink {
    struct Link: Equatable {
        /// Where it points. An email address gains the `mailto:` a reader's mail client needs.
        let destination: String
        /// What it shows, which is what the author wrote between the brackets.
        let label: String
    }

    static func parse(_ text: String) -> Link? {
        guard !text.isEmpty, !text.contains(where: { $0.isWhitespace || $0 == "<" }) else {
            return nil
        }
        if let scheme = schemeLength(of: text), text.count > scheme {
            return Link(destination: text, label: text)
        }
        guard isEmail(text) else { return nil }
        return Link(destination: "mailto:\(text)", label: text)
    }

    /// The length of a leading `scheme:`, or `nil`. A scheme is a letter followed by up to 31 of
    /// letter, digit, `+`, `.` or `-` — RFC 3986's shape, which is also what keeps a bare `a:b` in
    /// prose from becoming a link.
    private static func schemeLength(of text: String) -> Int? {
        guard let first = text.first, first.isLetter else { return nil }
        var length = 0
        for character in text {
            if character == ":" { break }
            guard character.isLetter || character.isNumber || "+-.".contains(character),
                  length < 32
            else { return nil }
            length += 1
        }
        guard length >= 2, text.count > length, Array(text)[length] == ":" else { return nil }
        return length + 1
    }

    /// One `@`, something on each side, and a dot in the domain. Deliberately not RFC 5322: the
    /// question here is "did the author mean an address", and the cost of a wrong yes is a link
    /// that goes nowhere useful rather than anything unsafe.
    private static func isEmail(_ text: String) -> Bool {
        let parts = text.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, parts[1].contains(".") else { return false }
        guard let last = parts[1].split(separator: ".").last, last.count >= 2 else { return false }
        return !parts[1].hasPrefix(".") && !parts[1].hasSuffix(".")
    }
}
