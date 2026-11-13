import Foundation

/// Math in a Markdown document: GitHub's four spellings, read in the inline pass (PLAN.md §M39 ▸
/// Slice 8). `TeXMath` draws what they hold.
///
/// - `$x$`, inline;
/// - `$$x$$`, display, whether it stands alone between lines or in the middle of one;
/// - `` $`x`$ ``, inline, the spelling GitHub added in 2023 for TeX that collides with Markdown;
/// - a ```` ```math ```` fence, display, read as a code block is (`MarkdownHTMLRenderer`).
///
/// ## When a dollar opens and closes
///
/// GitHub writes none of this down. Read off its renderer on 2026-11-14 with synthetic samples
/// (`gh api markdown`, `mode=gfm`: math is off in `mode=markdown`) and a real file served as
/// HTML (docs/NOTES.md ▸ Working rhythm):
///
/// - **A `$` opens** at the start of a run of text or after ASCII whitespace or `(`, and only when
///   no whitespace follows it. Every other punctuation before it, a letter, `“` and a no-break space
///   keep it text: `word$x$`, `"$x$"` and `[$x$` are not math. After a code span or a `**` it
///   opens, since GitHub's run of text starts there; after a single `*` or `_` it does not.
/// - **It closes** at the next `$` that has no whitespace before it and no ASCII letter, digit or
///   `_` after it. So `$5 and $10` is text (the second `$` follows a space), as are `$x$5`,
///   `$x$y` and `$x$_`, while `$x$é`, `$x$.` and `$x$’s` are math.
/// - **Nor where it reads a template.** `${a}, which is (${b})` and `${d}-${e}` are text, while
///   `${d}-$` and `$x-${e}` are math: a closer followed by `{` closes nothing when the content
///   opened with `{`. JavaScript and shell documents quote `${name}` often (a Wix guide, jsdom's
///   README and a Cloudflare one on this Mac), and this is the rule that leaves them alone.
/// - **A dollar inside a code span closes nothing**, since GitHub reads code spans first: in
///   ``use ${a} as in `"${a}/x"` `` and ``never a `$` `` the formula has no end, and stays text.
/// - **`$$` follows the same rules**, except that a line break may follow the opener and precede
///   the closer, which is how a display block is written. `$$ x $$` on one line is text.
/// - **`` $`…`$ ``** has no boundary rules (`word$`x`$word` is math) and trims as a code span does.
///   A `$` before a backtick that does not close this way is text, and the code span is read next.
///
/// ## Where this departs from GitHub, deliberately
///
/// - **What is between the dollars is TeX, kept as written.** GitHub reads Markdown's escapes first,
///   so `$\{a\}$` reaches MathJax as `${a}$` and draws no braces, and `$a \\ b$` loses its line
///   break: seen on 2026-11-14 in the arxiv template on this Mac, whose `$X = \{x_1, …\}$` draws
///   without its set braces on GitHub. Pandoc, VS Code and GitHub's own `` $`…`$ `` keep the TeX, and
///   so does this, so the braces are drawn. The same reading means emphasis never reaches inside:
///   `$a*b$ and $c*d$` is two formulas, where GitHub makes emphasis of `*b$ and $c*`.
/// - **The content holds no unescaped `$`.** The first one either closes the formula or, failing the
///   rules above, leaves the opener as text, so a paragraph of prices costs one look ahead per
///   dollar. GitHub agrees on every sample tried (`$x $y$` is text and then `y`).
/// - **No math inside a link's text**, as on GitHub (`MarkdownInlineParser`).
enum MarkdownMath {
    /// The math at `start`, which holds a `$`, and the index after it; or `nil` and the index after
    /// the dollars that are text. `mayOpen` says whether the text before allows a `$` to open
    /// there; the dollar-backtick spelling does not ask.
    static func take(
        in characters: [Character],
        at start: Int,
        mayOpen: Bool
    ) -> (node: MarkdownInline?, end: Int) {
        let run = runLength(of: "$", in: characters, from: start)
        if run == 1, start + 1 < characters.count, characters[start + 1] == "`" {
            let spelled = codeSpelled(in: characters, at: start)
            return (spelled?.node, spelled?.end ?? start + 1)
        }
        guard run <= 2, mayOpen,
              let close = closingIndex(in: characters, after: start + run, run: run)
        else { return (nil, start + run) }
        let tex = String(characters[(start + run)..<close])
        let end = close + run
        return (.math(tex: tex, display: run == 2, written: String(characters[start..<end])), end)
    }

    /// The `$` at the end of the formula that opens at `contentStart`, or `nil` when the next `$`
    /// does not close it.
    private static func closingIndex(in characters: [Character], after contentStart: Int, run: Int) -> Int? {
        guard contentStart < characters.count else { return nil }
        let first = characters[contentStart]
        if isSpace(first) {
            // Only `$$` may be followed by a line break, and only by spaces before one.
            let nextText = characters[contentStart...].firstIndex { !isSpace($0) }
            guard run == 2, let nextText, characters[nextText].isNewline else { return nil }
        } else if first.isNewline, run == 1 {
            return nil
        }
        var cursor = contentStart
        while cursor < characters.count, characters[cursor] != "$" {
            // A code span is read before math on GitHub, so a dollar inside one closes nothing.
            if characters[cursor] == "`" { return nil }
            cursor += characters[cursor] == "\\" ? 2 : 1
        }
        guard cursor < characters.count, cursor > contentStart,
              runLength(of: "$", in: characters, from: cursor) >= run,
              closes(characters, at: cursor, run: run)
        else { return nil }
        // `${a}, which is (${b})`: a template's variables, which GitHub leaves as text when the
        // content opens with `{` and a `{` follows the closer, and only then.
        if first == "{", cursor + run < characters.count, characters[cursor + run] == "{" { return nil }
        return cursor
    }

    /// Whether the `$` (or `$$`) at `index` may close: no whitespace before it, unless for `$$` the
    /// whitespace runs back to a line break, and no ASCII letter, digit or `_` after it.
    private static func closes(_ characters: [Character], at index: Int, run: Int) -> Bool {
        let before = characters[index - 1]
        if before.isNewline, run == 1 { return false }
        if isSpace(before) {
            guard run == 2,
                  let lastText = characters[..<index].lastIndex(where: { !isSpace($0) }),
                  characters[lastText].isNewline
            else { return false }
        }
        guard index + run < characters.count else { return true }
        let after = characters[index + run]
        return !(after.isASCII && (after.isLetter || after.isNumber || after == "_"))
    }

    /// `` $`…`$ ``: a backtick run, the TeX, a backtick run of the same length and a `$`. `nil` when
    /// no such close follows.
    private static func codeSpelled(
        in characters: [Character],
        at start: Int
    ) -> (node: MarkdownInline, end: Int)? {
        let ticks = runLength(of: "`", in: characters, from: start + 1)
        let contentStart = start + 1 + ticks
        var cursor = contentStart
        while cursor < characters.count {
            guard characters[cursor] == "`" else {
                cursor += 1
                continue
            }
            let length = runLength(of: "`", in: characters, from: cursor)
            let dollar = cursor + length
            if length == ticks, dollar < characters.count, characters[dollar] == "$" {
                let tex = MarkdownInline.codeSpanContent(String(characters[contentStart..<cursor]))
                let written = String(characters[start...dollar])
                return (.math(tex: tex, display: false, written: written), dollar + 1)
            }
            cursor = dollar
        }
        return nil
    }

    /// Whether a `$` may open after what the scanner has read: after whitespace or `(`, or where
    /// GitHub's run of text starts, which is the start of the text, after an element, or after a
    /// `**` or `~~`; not after a single `*` or `_`, nor straight after another formula.
    static func mayOpen(after character: Character?, item: MarkdownInlineEmphasis.Item?) -> Bool {
        if let character { return character == "(" || (character.isASCII && character.isWhitespace) }
        switch item {
        case nil: return true
        case let .delimiter(delimiter)?: return delimiter.length >= 2
        case .node(.math)?: return false
        case .node?: return true
        }
    }

    private static func isSpace(_ character: Character) -> Bool {
        character == " " || character == "\t"
    }

    private static func runLength(
        of character: Character,
        in characters: [Character],
        from start: Int
    ) -> Int {
        MarkdownInline.runLength(of: character, in: characters, from: start)
    }
}
