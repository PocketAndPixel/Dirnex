import Foundation

/// XML, HTML, SVG and `.plist` (PLAN.md §M17 ▸ Slice 2).
///
/// The one Slice 2 scanner that is load-bearing rather than a nicety: M16 made **source** the
/// default rendering for a file that has two, so an `.html` a user steps onto now shows its markup
/// by default — this is what stops that being a wall of one colour.
///
/// It fits no `LanguageGrammar` because markup has no keywords, no numbers and no line comments;
/// what it has is a *shape*. So it is its own ~150 lines, which is the trade the milestone named.
/// It is still one pass with one lookahead: a tag is scanned whole where it is found, so nothing is
/// remembered between tags and there is no state to stack.
///
/// The kinds it borrows, and why each is the right bucket rather than the only one left:
/// - **`.typeOrTag`** for a tag's name and its brackets. `SyntaxToken.Kind` names it "type *or*
///   tag" for exactly this: to a reader, `<section>` and `String` are the same thing — the name of
///   the shape a thing has.
/// - **`.keyword`** for an attribute name, which is the element's own vocabulary.
/// - **`.string`** for an attribute value and for `CDATA`, both of which are literal text.
/// - **`.number`** for an entity (`&amp;`, `&#x1F600;`). Markup has no numeric literals at all, so
///   the kind is otherwise unused here — and an entity *is* a numeric or named escape.
enum SyntaxMarkupScanner {
    static func tokens(in text: String) -> [SyntaxToken] {
        guard !text.isEmpty else { return [] }
        var scanner = Scanner(units: Array(text.utf16))
        return scanner.run()
    }

    private static let commentOpen = Unit.pattern("<!--")
    private static let commentClose = Unit.pattern("-->")
    private static let cdataOpen = Unit.pattern("<![CDATA[")
    private static let cdataClose = Unit.pattern("]]>")
    private static let declarationOpen = Unit.pattern("<!")
    private static let instructionOpen = Unit.pattern("<?")
    private static let instructionClose = Unit.pattern("?>")
    private static let selfClosing = Unit.pattern("/>")

    private struct Scanner {
        let units: [UInt16]
        private var index = 0
        private var tokens: [SyntaxToken] = []

        init(units: [UInt16]) { self.units = units }

        mutating func run() -> [SyntaxToken] {
            while index < units.count {
                if scanBracketed() { continue }
                if scanEntity() { continue }
                index += 1
            }
            return tokens
        }

        /// Everything that opens with `<`, longest form first — `<!--` has to be tested before
        /// `<!`, and `<![CDATA[` before both.
        private mutating func scanBracketed() -> Bool {
            guard index < units.count, units[index] == Unit.less else { return false }
            if matches(SyntaxMarkupScanner.commentOpen) {
                return scanDelimited(
                    open: SyntaxMarkupScanner.commentOpen,
                    close: SyntaxMarkupScanner.commentClose,
                    kind: .comment
                )
            }
            if matches(SyntaxMarkupScanner.cdataOpen) {
                return scanDelimited(
                    open: SyntaxMarkupScanner.cdataOpen,
                    close: SyntaxMarkupScanner.cdataClose,
                    kind: .string
                )
            }
            if matches(SyntaxMarkupScanner.instructionOpen) {
                return scanDelimited(
                    open: SyntaxMarkupScanner.instructionOpen,
                    close: SyntaxMarkupScanner.instructionClose,
                    kind: .keyword
                )
            }
            // A doctype: `<!DOCTYPE html>`. Its internal subset (`[ … ]`) can contain a `>`, which
            // this ends early on — a wrong colour on a construct almost nothing carries, and the
            // alternative is bracket counting.
            if matches(SyntaxMarkupScanner.declarationOpen) {
                return scanDelimited(
                    open: SyntaxMarkupScanner.declarationOpen,
                    close: [Unit.greater],
                    kind: .keyword
                )
            }
            return scanTag()
        }

        /// `<!-- … -->` and friends: one token from opener to closer, or to the end of the buffer
        /// when the closer never comes (a file cut at `TextPreview.byteLimit` is exactly that).
        private mutating func scanDelimited(
            open: [UInt16],
            close: [UInt16],
            kind: SyntaxToken.Kind
        ) -> Bool {
            let start = index
            index += open.count
            while index < units.count, !matches(close) { index += 1 }
            if index < units.count { index += close.count }
            emit(from: start, kind: kind)
            return true
        }

        /// An element: `<name`, then its attributes, then `>` or `/>`.
        ///
        /// A `<` with no name after it is **not** a tag — which is what leaves `a < b` in a script
        /// or in prose alone rather than colouring the rest of the document as an element.
        private mutating func scanTag() -> Bool {
            var nameStart = index + 1
            if nameStart < units.count, units[nameStart] == Unit.slash { nameStart += 1 }
            guard nameStart < units.count, isNameStart(units[nameStart]) else { return false }
            let start = index
            index = nameStart
            while index < units.count, isNameBody(units[index]) { index += 1 }
            emit(from: start, kind: .typeOrTag)
            scanAttributes()
            return true
        }

        /// The inside of a tag, up to its closing bracket.
        ///
        /// `expectingValue` is one `Bool` living inside one call — an unquoted HTML value
        /// (`width=100`) is a value because of the `=` before it, and there is nothing else to
        /// distinguish it from an attribute name. That is a lookbehind of one token, not the state
        /// stack PLAN.md §6 draws the line at.
        private mutating func scanAttributes() {
            var expectingValue = false
            while index < units.count {
                let unit = units[index]
                if Unit.isSpaceOrTab(unit) || Unit.isLineBreak(unit) {
                    index += 1
                } else if matches(SyntaxMarkupScanner.selfClosing) {
                    index += 2
                    emit(from: index - 2, kind: .typeOrTag)
                    return
                } else if unit == Unit.greater {
                    index += 1
                    emit(from: index - 1, kind: .typeOrTag)
                    return
                } else if unit == Unit.equals {
                    expectingValue = true
                    index += 1
                } else if unit == Unit.doubleQuote || unit == Unit.singleQuote {
                    scanQuotedValue(quote: unit)
                    expectingValue = false
                } else {
                    scanBareRun(asValue: expectingValue)
                    expectingValue = false
                }
            }
        }

        /// A quoted attribute value. Unlike a source-code string it *may* span lines — a `title`
        /// wrapped across two lines is ordinary in hand-written HTML — but it may never cross the
        /// tag's own closing bracket, which is what bounds the damage from a missing quote.
        private mutating func scanQuotedValue(quote: UInt16) {
            let start = index
            index += 1
            while index < units.count, units[index] != quote, units[index] != Unit.greater {
                index += 1
            }
            if index < units.count, units[index] == quote { index += 1 }
            emit(from: start, kind: .string)
        }

        /// An attribute name, or an unquoted value.
        private mutating func scanBareRun(asValue: Bool) {
            let start = index
            while index < units.count {
                let unit = units[index]
                if Unit.isSpaceOrTab(unit) || Unit.isLineBreak(unit) { break }
                if unit == Unit.greater || unit == Unit.equals { break }
                if unit == Unit.doubleQuote || unit == Unit.singleQuote { break }
                if matches(SyntaxMarkupScanner.selfClosing) { break }
                index += 1
            }
            // Nothing consumed: a character none of the branches claims. Step over it, or the
            // attribute loop spins on it forever.
            guard index > start else {
                index += 1
                return
            }
            emit(from: start, kind: asValue ? .string : .keyword)
        }

        /// `&amp;`, `&#160;`, `&#x1F600;` — bounded by a `;` within a plausible length, so a bare
        /// ampersand in prose (which is invalid markup and extremely common) colours nothing.
        private mutating func scanEntity() -> Bool {
            guard units[index] == Unit.ampersand else { return false }
            var probe = index + 1
            if probe < units.count, units[probe] == Unit.hash { probe += 1 }
            let bodyStart = probe
            while probe < units.count, probe - bodyStart < 10, isEntityBody(units[probe]) {
                probe += 1
            }
            guard probe > bodyStart, probe < units.count, units[probe] == Unit.semicolon else {
                return false
            }
            let start = index
            index = probe + 1
            emit(from: start, kind: .number)
            return true
        }

        // MARK: Primitives

        private func isNameStart(_ unit: UInt16) -> Bool {
            Unit.isASCIILetter(unit) || unit == Unit.underscore || unit >= Unit.asciiCeiling
        }

        /// A qualified name may carry `:`, `-` and `.` — `xsi:type`, `data-id`, `xml.lang`.
        private func isNameBody(_ unit: UInt16) -> Bool {
            isNameStart(unit) || Unit.isDigit(unit) || unit == Unit.colon || unit == Unit.minus
                || unit == Unit.dot
        }

        private func isEntityBody(_ unit: UInt16) -> Bool {
            Unit.isASCIILetter(unit) || Unit.isDigit(unit)
        }

        private mutating func emit(from start: Int, kind: SyntaxToken.Kind) {
            index = min(index, units.count)
            guard index > start else { return }
            tokens.append(SyntaxToken(offset: start, length: index - start, kind: kind))
        }

        private func matches(_ pattern: [UInt16]) -> Bool {
            Unit.matches(pattern, in: units, at: index)
        }
    }
}
