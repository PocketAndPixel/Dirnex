import Foundation

/// The five kinds of GitHub alert (PLAN.md §M39 ▸ Slice 6).
///
/// The raw value is the kind's name as GitHub spells it in a class, `markdown-alert-note`, which is
/// the vocabulary the page's stylesheet is written against. What the kind is *called* on the page is
/// the app's, through `MarkdownRenderOptions.alertTitle`, since a title is a word somebody reads.
public enum MarkdownAlertKind: String, CaseIterable, Equatable, Sendable {
    case note
    case tip
    case important
    case warning
    case caution
}

/// `> [!NOTE]`: a blockquote that GitHub draws as a colored, titled box.
///
/// 5.7 % of the Markdown files on this Mac carry one (PLAN.md §M39's corpus), every one of them as a
/// marker alone on the quote's first line, and GitHub's own renderer draws one inside a list item and
/// in mixed case (`[!Note]`) alike (checked 2026-11-13 against `eslint-plugin-import`'s `order.md`
/// and `tough-cookie`'s README as GitHub serves them). So the rule is the marker, any case, alone on
/// the first line but for trailing spaces, and at least one line after it. Anything else stays the
/// blockquote it is: a marker with text beside it, one below the first line, `[!UNKNOWN]`, or a
/// marker with nothing under it, which keeps the literal text rather than drawing an empty box.
enum MarkdownAlert {
    /// The alert a blockquote's lines open, and the lines of its body, or `nil` for a plain quote.
    static func take(_ lines: [String]) -> (MarkdownAlertKind, [String])? {
        guard let first = lines.first, MarkdownLine.indentation(of: first) < 4,
              let kind = kind(in: first)
        else { return nil }
        let body = Array(lines.dropFirst())
        guard body.contains(where: { !MarkdownLine.isBlank($0) }) else { return nil }
        return (kind, body)
    }

    /// `[!NOTE]` and its four siblings, in any case.
    private static func kind(in line: String) -> MarkdownAlertKind? {
        let marker = MarkdownLine.trimmingTrailingWhitespace(MarkdownLine.content(of: line))
        guard marker.hasPrefix("[!"), marker.hasSuffix("]"), marker.count > 3 else { return nil }
        let name = marker.dropFirst(2).dropLast()
        return MarkdownAlertKind(rawValue: name.lowercased())
    }
}
