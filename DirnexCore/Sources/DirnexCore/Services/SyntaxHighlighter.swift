import Foundation

/// The single-pass scanner that turns a previewed file into coloured spans (PLAN.md §M17).
///
/// One pass, one lookahead, no regex and no `NSRegularExpression`. That is the whole design, and
/// the milestone's stated boundary (PLAN.md §6): the tell that a scanner is turning into a parser
/// is a grammar that needs to remember *where it has been*, and nothing here does — the block
/// comment's nesting depth is a counter, not a stack of contexts.
///
/// What makes the boundary affordable is that highlighting only ever *adds* foreground colour to a
/// document that already renders correctly. A construct the scanner gets wrong is a wrong colour,
/// never a wrong character, so the honest fix for a hard one is to stop colouring it. The list of
/// constructs deliberately left alone — string interpolation, JS regex literals, heredocs, JSX —
/// is in PLAN.md §M17, and each carries a comment where the scanner would otherwise have handled it.
///
/// Measured before it was written (PLAN.md §M17): 1.1 ms for 128 KB, 5.2 ms for 1 MB, 17.2 ms at
/// `TextPreview.byteLimit`. That is what buys the simplest possible arrangement — the whole buffer
/// scanned in one go on the detached task that already reads the file, with no viewport-incremental
/// pass and no per-paragraph state.
public enum SyntaxHighlighter {
    /// Tokenize `text` as `language`, whether that means the grammar table or one of the three
    /// scanners that fit no table at all (PLAN.md §M17 ▸ Slice 2).
    public static func tokens(in text: String, language: SyntaxLanguage) -> [SyntaxToken] {
        switch language.scanning {
        case let .grammar(grammar): tokens(in: text, grammar: grammar)
        case .markup: SyntaxMarkupScanner.tokens(in: text)
        case .markdown: SyntaxMarkdownScanner.tokens(in: text)
        case .diff: SyntaxDiffScanner.tokens(in: text)
        }
    }

    /// Tokenize `text` against `grammar`, in order, non-overlapping, and never zero-length.
    ///
    /// Only coloured spans come back: a run the grammar makes no claim about is absent rather than
    /// present as `.plain`, because the text view already draws it in its own `.textColor`.
    public static func tokens(in text: String, grammar: LanguageGrammar) -> [SyntaxToken] {
        guard !text.isEmpty else { return [] }
        var scanner = Scanner(units: Array(text.utf16), grammar: CompiledGrammar(grammar))
        return scanner.run()
    }
}

// MARK: - The compiled grammar

/// `LanguageGrammar` with every delimiter turned into the UTF-16 units the scanner compares
/// against, once per file rather than once per character.
private struct CompiledGrammar {
    let lineComments: [[UInt16]]
    let blockOpen: [UInt16]
    let blockClose: [UInt16]
    let hasBlockComment: Bool
    let blockCommentsNest: Bool
    let strings: [CompiledString]
    let annotationSigil: [UInt16]
    let preprocessorSigil: [UInt16]
    let keywords: Set<String>
    let typeNames: Set<String>
    let keywordsAreCaseInsensitive: Bool
    /// Longest word worth building a `String` for. Every identifier in the file is measured against
    /// it before anything is allocated, and the ones that pass are short enough to live in Swift's
    /// small-string representation — so the hot path of the scanner allocates nothing at all.
    let maxWordLength: Int

    struct CompiledString {
        let open: [UInt16]
        let close: [UInt16]
        let escape: UInt16?
        let spansLines: Bool
    }

    init(_ grammar: LanguageGrammar) {
        lineComments = grammar.lineComments.map { Array($0.utf16) }
        blockOpen = grammar.blockComment.map { Array($0.open.utf16) } ?? []
        blockClose = grammar.blockComment.map { Array($0.close.utf16) } ?? []
        hasBlockComment = !blockOpen.isEmpty && !blockClose.isEmpty
        blockCommentsNest = grammar.blockCommentsNest
        // Longest opener first, so `"""` claims its own opening before `"` can. Sorted here rather
        // than left to the table: a grammar written in the wrong order would fail quietly, by
        // colouring a multi-line string's body as code.
        strings = grammar.strings
            .sorted { $0.open.utf16.count > $1.open.utf16.count }
            .map {
                CompiledString(
                    open: Array($0.open.utf16),
                    close: Array($0.close.utf16),
                    escape: $0.escape.flatMap { Array(String($0).utf16).first },
                    spansLines: $0.spansLines
                )
            }
        annotationSigil = grammar.annotationSigil.map { Array($0.utf16) } ?? []
        preprocessorSigil = grammar.preprocessorSigil.map { Array($0.utf16) } ?? []
        keywords = grammar.keywords
        typeNames = grammar.typeNames
        keywordsAreCaseInsensitive = grammar.keywordsAreCaseInsensitive
        maxWordLength = (grammar.keywords.map(\.utf16.count) + grammar.typeNames.map(\.utf16.count))
            .max() ?? 0
    }
}

// MARK: - The scan

/// The scan state: a position in the file's UTF-16 code units and the tokens found so far.
///
/// UTF-16 rather than `Character` for two independent reasons. The offsets have to index an
/// `NSRange` on the far side (`SyntaxToken`), and — docs/NOTES.md — a Swift `Character` makes CRLF
/// **one** grapheme that equals neither `"\n"` nor `"\r"`, so a `Character`-based scan of a
/// Windows-written file finds no line breaks at all. A code unit has no such subtlety.
private struct Scanner {
    let units: [UInt16]
    let grammar: CompiledGrammar
    private var index = 0
    private var tokens: [SyntaxToken] = []

    init(units: [UInt16], grammar: CompiledGrammar) {
        self.units = units
        self.grammar = grammar
    }

    mutating func run() -> [SyntaxToken] {
        while index < units.count {
            if scanComment() { continue }
            if scanString() { continue }
            if scanDirective() { continue }
            if scanNumber() { continue }
            if scanWord() { continue }
            index += 1
        }
        return tokens
    }

    // MARK: Comments

    /// A block comment first, then each line-comment spelling. Both run to the end of the buffer
    /// when they are never closed — which is what a file truncated at `TextPreview.byteLimit` hands
    /// over, and what an unterminated `/*` genuinely means.
    private mutating func scanComment() -> Bool {
        if grammar.hasBlockComment, matches(grammar.blockOpen) {
            let start = index
            index += grammar.blockOpen.count
            var depth = 1
            while index < units.count {
                if grammar.blockCommentsNest, matches(grammar.blockOpen) {
                    depth += 1
                    index += grammar.blockOpen.count
                } else if matches(grammar.blockClose) {
                    index += grammar.blockClose.count
                    depth -= 1
                    if depth == 0 { break }
                } else {
                    index += 1
                }
            }
            emit(from: start, kind: .comment)
            return true
        }
        for token in grammar.lineComments where matches(token) {
            let start = index
            index += token.count
            while index < units.count, !Unit.isLineBreak(units[index]) { index += 1 }
            emit(from: start, kind: .comment)
            return true
        }
        return false
    }

    // MARK: Strings

    /// A quote-delimited literal, delimiters included in the token.
    ///
    /// This is where **string interpolation** would be handled — Swift's `\(…)`, JavaScript's and
    /// the shell's `${…}` — and deliberately is not (PLAN.md §M17). A keyword inside an
    /// interpolation stays the string's colour, which is the quiet direction: the alternative is
    /// re-entering the scanner from inside a literal, which is the state stack the milestone's
    /// boundary is drawn against.
    private mutating func scanString() -> Bool {
        for literal in grammar.strings where matches(literal.open) {
            let start = index
            index += literal.open.count
            while index < units.count {
                let unit = units[index]
                if let escape = literal.escape, unit == escape {
                    // Past the end when the escape is the file's last unit; the loop stops there.
                    index = min(index + 2, units.count)
                } else if !literal.spansLines, Unit.isLineBreak(unit) {
                    break
                } else if matches(literal.close) {
                    index += literal.close.count
                    break
                } else {
                    index += 1
                }
            }
            emit(from: start, kind: .string)
            return true
        }
        return false
    }

    // MARK: Directives, numbers, words

    /// `#include`, and only where a directive can legally be: first on its line. The line-start test
    /// is what keeps C's stringify operator inside a macro body from colouring as one.
    private mutating func scanDirective() -> Bool {
        guard !grammar.preprocessorSigil.isEmpty, matches(grammar.preprocessorSigil) else {
            return false
        }
        guard isAtLineStart(index) else { return false }
        var lookahead = index + grammar.preprocessorSigil.count
        while lookahead < units.count, Unit.isSpaceOrTab(units[lookahead]) { lookahead += 1 }
        guard lookahead < units.count, Unit.isIdentifierStart(units[lookahead]) else { return false }
        let start = index
        index = lookahead
        while index < units.count, Unit.isIdentifierContinue(units[index]) { index += 1 }
        emit(from: start, kind: .keyword)
        return true
    }

    /// A numeric literal, starting at a digit and swallowing whatever the language spells its
    /// radices, separators and suffixes with — `0xFF`, `0b1010`, `1_000_000`, `3.14f`, `1e-9`, `10L`.
    ///
    /// One rule for every language in the table, because there is nothing here they disagree about
    /// that a preview can see. It starts at a *digit*, so a leading-dot literal (`.5`) colours from
    /// the `5` — the alternative is deciding whether the `.` is a decimal point or a member access,
    /// which needs to know what came before it.
    private mutating func scanNumber() -> Bool {
        guard Unit.isDigit(units[index]) else { return false }
        let start = index
        index += 1
        while index < units.count {
            let unit = units[index]
            if Unit.isDigit(unit) || Unit.isASCIILetter(unit) || unit == Unit.underscore {
                index += 1
            } else if unit == Unit.dot, index + 1 < units.count, Unit.isDigit(units[index + 1]) {
                index += 2
            } else if unit == Unit.plus || unit == Unit.minus, Unit.isExponentMarker(
                units[index - 1]
            ) {
                index += 1
            } else {
                break
            }
        }
        emit(from: start, kind: .number)
        return true
    }

    /// An identifier, or a sigil-plus-identifier annotation.
    ///
    /// Always consumes the *whole* run even when it colours nothing, which is what keeps
    /// `class_name` from matching the keyword `class` at its front.
    private mutating func scanWord() -> Bool {
        let start = index
        if !grammar.annotationSigil.isEmpty, matches(grammar.annotationSigil) {
            let after = index + grammar.annotationSigil.count
            // An identifier has to follow, which is what leaves Objective-C's `@"…"` to the string
            // branch on the next pass rather than claiming the `@` for a keyword.
            guard after < units.count, Unit.isIdentifierStart(units[after]) else { return false }
            index = after
            while index < units.count, Unit.isIdentifierContinue(units[index]) { index += 1 }
            emit(from: start, kind: .keyword)
            return true
        }
        guard Unit.isIdentifierStart(units[index]) else { return false }
        while index < units.count, Unit.isIdentifierContinue(units[index]) { index += 1 }
        if let kind = classify(from: start, to: index) {
            emit(from: start, kind: kind)
        }
        return true
    }

    /// Look the run up in the grammar's two word sets, building a `String` only when it could
    /// plausibly be in one: short enough, and ASCII, since no keyword in the table is anything else
    /// (`SyntaxLanguageTests` asserts that, because a non-ASCII keyword would be dead data here).
    ///
    /// Both filters run before a single character is copied, and what survives them is short enough
    /// to live in Swift's inline small-string representation — so the scanner's hot path allocates
    /// nothing per identifier.
    private func classify(from start: Int, to end: Int) -> SyntaxToken.Kind? {
        guard end - start <= grammar.maxWordLength else { return nil }
        var raw = ""
        for position in start..<end {
            let unit = units[position]
            guard unit < Unit.asciiCeiling else { return nil }
            raw.unicodeScalars.append(UnicodeScalar(UInt8(unit)))
        }
        let word = grammar.keywordsAreCaseInsensitive ? raw.lowercased() : raw
        if grammar.keywords.contains(word) { return .keyword }
        if grammar.typeNames.contains(word) { return .typeOrTag }
        return nil
    }

    // MARK: Primitives

    private mutating func emit(from start: Int, kind: SyntaxToken.Kind) {
        index = min(index, units.count)
        guard index > start else { return }
        tokens.append(SyntaxToken(offset: start, length: index - start, kind: kind))
    }

    private func matches(_ pattern: [UInt16]) -> Bool {
        Unit.matches(pattern, in: units, at: index)
    }

    /// Whether only indentation stands between `position` and the start of its line.
    private func isAtLineStart(_ position: Int) -> Bool {
        var back = position - 1
        while back >= 0 {
            if Unit.isLineBreak(units[back]) { return true }
            guard Unit.isSpaceOrTab(units[back]) else { return false }
            back -= 1
        }
        return true
    }
}
