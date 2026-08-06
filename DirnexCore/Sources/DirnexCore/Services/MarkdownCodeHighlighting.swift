import Foundation

/// A fenced code block's body, coloured by M17's scanner (PLAN.md §M18 ▸ Slice 2).
///
/// The point of routing through `SyntaxHighlighter` rather than writing a second scanner is that the
/// fence in the *rendered* page and the same file in *source* mode are then coloured by one grammar
/// table and one scanner. Two would drift, and the drift would show up as the same `.swift` snippet
/// looking different on `1` and on `2` — which reads as one of the two being broken.
///
/// A fence with no info string, or one naming a language nothing here claims, is plain escaped text.
/// That is the same "an unknown type is not a special case" rule the text backend keeps: an
/// unclaimed fence renders exactly as it did before this existed.
enum MarkdownCodeHighlighting {
    static func body(_ code: String, info: String?) -> String {
        guard let info, let language = SyntaxLanguage.forFenceInfo(info) else {
            return MarkdownHTML.escaped(code)
        }
        return spans(in: code, tokens: SyntaxHighlighter.tokens(in: code, language: language))
    }

    /// The body as escaped text with one `<span>` per token.
    ///
    /// Works in **UTF-16 code units** and slices with `String(decoding:as:)`, because that is the
    /// unit `SyntaxToken` measures in and converting the offsets to `String.Index` would be a claim
    /// that no token boundary ever lands inside a grapheme cluster. Decoding cannot trap: a slice
    /// that did split a surrogate pair yields a replacement character, where an index conversion
    /// would crash the preview over somebody's file.
    static func spans(in code: String, tokens: [SyntaxToken]) -> String {
        guard !tokens.isEmpty else { return MarkdownHTML.escaped(code) }
        let units = Array(code.utf16)
        var html = ""
        var cursor = 0
        for token in tokens {
            // Tokens arrive in order and non-overlapping; the guard is what keeps that a property of
            // this loop rather than an assumption about a scanner in another file.
            guard token.offset >= cursor, token.end <= units.count else { continue }
            if token.offset > cursor { html += escaped(units[cursor..<token.offset]) }
            let text = escaped(units[token.offset..<token.end])
            html += className(for: token.kind)
                .map { MarkdownHTML.element("span", text, attributes: " class=\"\($0)\"") } ?? text
            cursor = token.end
        }
        if cursor < units.count { html += escaped(units[cursor...]) }
        return html
    }

    /// The class one token kind carries.
    ///
    /// An explicit switch rather than `"tok-" + kind.rawValue`, for the reason `SyntaxLanguage
    /// .scanning` is one switch: a kind added later is named by the compiler here, and has to be
    /// given a class deliberately — and Slice 3's stylesheet has to grow a rule for it. Deriving the
    /// name from the raw value would emit `tok-typeOrTag`, a class no stylesheet author would guess.
    private static func className(for kind: SyntaxToken.Kind) -> String? {
        switch kind {
        case .keyword: "tok-keyword"
        case .string: "tok-string"
        case .comment: "tok-comment"
        case .number: "tok-number"
        case .typeOrTag: "tok-type"
        case .inserted: "tok-inserted"
        case .deleted: "tok-deleted"
        // Never emitted by the scanner — an unclaimed run is already the page's own text colour, so
        // a span for it would change nothing and cost a tag.
        case .plain: nil
        }
    }

    private static func escaped(_ units: ArraySlice<UInt16>) -> String {
        MarkdownHTML.escaped(String(decoding: units, as: UTF16.self))
    }
}
