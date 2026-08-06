import Foundation

/// What one language looks like to the scanner (PLAN.md §M17).
///
/// A value type, deliberately: ~25 languages are *data*, not 25 pieces of code. Two shapes cover
/// almost all of it — the C family (`//`, `/* */`, `"…"`, keywords) and the hash-comment family
/// (`#`, no block comment, a different keyword set) — and a language that fits neither gets its own
/// scanner rather than a flag here (`SyntaxHighlighter` ▸ the markup and line-oriented grammars).
///
/// The boundary this type defends is written into the milestone (PLAN.md §6, the accretion risk):
/// a grammar earns a field when several languages need it, and the tell that the boundary is being
/// crossed is a field that would make the scanner remember *where it has been*. One pass, one
/// lookahead; anything more is a parser, which is a compiler's job and not a preview's.
public struct LanguageGrammar: Equatable, Sendable {
    /// A comment that runs from a token to the end of the line. A list because the language decides
    /// how many spellings it has — C has `//`, SQL has `--`, PHP has both plus `#`.
    public var lineComments: [String]
    public var blockComment: BlockComment?
    /// Quote-delimited literals, longest opener first — see `SyntaxHighlighter`, which matches them
    /// in the order given so `"""` claims its opening before `"` does.
    public var strings: [StringLiteral]
    /// Words that colour as `.keyword`. Stored lowercased when `keywordsAreCaseInsensitive`.
    public var keywords: Set<String>
    /// Built-in type names, which colour as `.typeOrTag`. Only names the language itself defines:
    /// a type the *user* declared is a type because of a declaration somewhere else, which is a
    /// compiler's knowledge and explicitly out of scope (PLAN.md §M17 ▸ not in scope).
    public var typeNames: Set<String>
    /// A character that, immediately followed by an identifier, colours the pair as one keyword —
    /// Swift's `@MainActor`, Java's `@Override`, ObjC's `@interface`. `nil` where the language has
    /// no such form.
    ///
    /// Guarded on an identifier following, which is what keeps ObjC's `@"literal"` a string.
    public var annotationSigil: String?
    /// A character that opens a preprocessor directive when it is the first thing on a line —
    /// C's `#include`. Only set where the same character is not already a line comment, so a
    /// grammar never has to decide between the two.
    public var preprocessorSigil: String?
    /// SQL, and nothing else in the shipped table: `SELECT` and `select` are the same word.
    public var keywordsAreCaseInsensitive: Bool
    /// Swift nests block comments and C does not, which is the difference between `/* /* */ */`
    /// ending where the file says it does and colouring the rest of the file as a comment.
    public var blockCommentsNest: Bool

    public init(
        lineComments: [String] = [],
        blockComment: BlockComment? = nil,
        strings: [StringLiteral] = [],
        keywords: Set<String> = [],
        typeNames: Set<String> = [],
        annotationSigil: String? = nil,
        preprocessorSigil: String? = nil,
        keywordsAreCaseInsensitive: Bool = false,
        blockCommentsNest: Bool = false
    ) {
        self.lineComments = lineComments
        self.blockComment = blockComment
        self.strings = strings
        self.keywords = keywords
        self.typeNames = typeNames
        self.annotationSigil = annotationSigil
        self.preprocessorSigil = preprocessorSigil
        self.keywordsAreCaseInsensitive = keywordsAreCaseInsensitive
        self.blockCommentsNest = blockCommentsNest
    }

    /// `/* … */`, and whether the language lets one sit inside another.
    public struct BlockComment: Equatable, Sendable {
        public var open: String
        public var close: String

        public init(open: String, close: String) {
            self.open = open
            self.close = close
        }
    }

    /// One quote-delimited literal form.
    public struct StringLiteral: Equatable, Sendable {
        public var open: String
        public var close: String
        /// The character that makes the next one literal, usually `\`. `nil` for the forms that
        /// have none — a shell's single quotes, a Makefile's.
        public var escape: Character?
        /// Whether the literal may cross a line break.
        ///
        /// `false` for ordinary quotes on purpose, and it is a robustness decision rather than a
        /// grammatical one: an apostrophe in a comment the scanner already skipped is impossible,
        /// but an unterminated quote is not, and a literal allowed to run to EOF paints the rest of
        /// the file. Stopping at the line break makes the damage one line instead of the document.
        public var spansLines: Bool

        public init(open: String, close: String, escape: Character? = "\\", spansLines: Bool = false) {
            self.open = open
            self.close = close
            self.escape = escape
            self.spansLines = spansLines
        }

        /// `"…"` and `'…'`: the pair every C-family and hash-family language shares.
        public static let doubleQuoted = StringLiteral(open: "\"", close: "\"")
        public static let singleQuoted = StringLiteral(open: "'", close: "'")
        /// Swift's and Python's `"""…"""`, which is why it must be listed before `doubleQuoted`.
        public static let tripleDoubleQuoted =
            StringLiteral(open: "\"\"\"", close: "\"\"\"", spansLines: true)
        public static let tripleSingleQuoted =
            StringLiteral(open: "'''", close: "'''", spansLines: true)
        /// JavaScript's template literal. `${…}` inside it is not re-entered — see
        /// `SyntaxHighlighter.scanString`, and PLAN.md §M17 for why interpolation is left alone.
        public static let backtickQuoted = StringLiteral(open: "`", close: "`", spansLines: true)
        /// A shell's single quotes: no escape character exists inside them at all.
        public static let unescapedSingleQuoted = StringLiteral(open: "'", close: "'", escape: nil)
    }

    /// A whitespace-separated word list, which is how the grammar table spells its keyword sets.
    ///
    /// A set literal of 60 quoted strings is unreadable and unreviewable; this is the same data in
    /// the shape it is actually read in. Split on `\.isWhitespace` rather than on a literal space so
    /// the list can wrap across lines — and note that a `Character` is a grapheme, so a CRLF in this
    /// source file is one whitespace character rather than two (docs/NOTES.md).
    static func words(_ list: String) -> Set<String> {
        Set(list.split(whereSeparator: \.isWhitespace).map(String.init))
    }
}
