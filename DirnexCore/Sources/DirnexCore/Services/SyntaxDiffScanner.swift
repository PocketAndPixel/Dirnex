import Foundation

/// A unified diff or patch (PLAN.md §M17 ▸ Slice 2).
///
/// Entirely line-oriented — every decision is made from a line's first characters and nothing is
/// remembered between lines, which makes it the shortest scanner in the milestone and the one whose
/// output is most obviously right.
///
/// **Order is the whole correctness argument.** `--- a/file` and `+++ b/file` begin with the same
/// characters as a removed and an added line, so the file headers have to be tested first; written
/// the other way round, every diff's own header reads as a deletion followed by an insertion. That
/// is a wrong colour in the one place a reader looks to orient themselves.
///
/// `.inserted` and `.deleted` are this scanner's reason for existing as kinds — see
/// `SyntaxToken.Kind`, which argues why they are not borrowed from `.comment` and `.string`.
enum SyntaxDiffScanner {
    static func tokens(in text: String) -> [SyntaxToken] {
        guard !text.isEmpty else { return [] }
        let units = Array(text.utf16)
        var tokens: [SyntaxToken] = []
        var lineStart = 0
        while lineStart < units.count {
            let end = Unit.lineEnd(from: lineStart, in: units)
            if end > lineStart, let kind = kind(ofLineAt: lineStart, to: end, in: units) {
                tokens.append(
                    SyntaxToken(offset: lineStart, length: end - lineStart, kind: kind)
                )
            }
            lineStart = Unit.nextLineStart(after: end, in: units)
        }
        return tokens
    }

    /// Headers that name a file or a mode. `git`'s extended headers are included because a
    /// `git diff` capture is the common case and they otherwise sit uncoloured between two hunks.
    private static let headers = [
        "diff ", "index ", "--- ", "+++ ", "Index: ", "==========",
        "old mode ", "new mode ", "new file mode ", "deleted file mode ",
        "similarity index ", "rename from ", "rename to ", "copy from ", "copy to ",
        "Binary files ", "GIT binary patch"
    ].map(Unit.pattern)

    private static let hunk = Unit.pattern("@@")

    private static func kind(
        ofLineAt start: Int,
        to end: Int,
        in units: [UInt16]
    ) -> SyntaxToken.Kind? {
        for header in headers where Unit.matches(header, in: units, at: start) {
            return .typeOrTag
        }
        if Unit.matches(hunk, in: units, at: start) { return .keyword }
        switch units[start] {
        case Unit.plus: return .inserted
        case Unit.minus: return .deleted
        // `\ No newline at end of file` — the one line in a diff that is about the diff.
        case Unit.backslash: return .comment
        default: return nil
        }
    }
}
