import Foundation

/// Rewriting `[a-z]` into `[abcdefghijklmnopqrstuvwxyz]` before the pattern is compiled — because
/// the range macOS's own engine compiles is not the range anybody means (2026-09-18).
///
/// **The comparison behind a bracket range keeps only the low 8 bits of each character**, measured by
/// asking what each range accepts, one character at a time, and finding a rule that fits every
/// answer exactly: `[A-Z]` (0x41–0x5A) takes `я` (U+044**F**) and `ё` (U+04**51**); `[А-Я]`
/// (0x0410–0x042F, truncated to 0x10–0x2F) takes a **space**, `!`, `-` and `中` (U+4E**2D**) while
/// taking none of `а`, `A` or `0`; `[א-ת]` takes `é`. It is libc's, not this app's — the same answers
/// come out of a twenty-line C program — and it is the one thing measured here that is simply wrong
/// rather than merely surprising.
///
/// Every other bracket construct is exact, which is what makes the repair small: a single character
/// (`[Д]`), a negation, a POSIX class (`[[:upper:]]` is Unicode-aware and right) and case folding over
/// an expanded class all behave. So the ranges are expanded into their own characters and nothing
/// else is touched. Expanding is what the engine would have done had it compared code points, and it
/// answers identically where the truncation happens not to bite: over 3.6 MB of ordinary text
/// `[a-zA-Z0-9_]+` found the same 720 000 matches raw and expanded, at 0.27 s against 0.38 s.
///
/// **The cap is the engine's own**: a bracket expression holding more than **1024** items fails to
/// compile with `REG_ESPACE` (measured — 1024 compiles, 1025 does not), so a range wider than that is
/// left exactly as it was typed. What that costs is the truncation above, on a range spanning a
/// thousand code points or more — where it changes an answer that was already "very nearly anything".
///
/// The syntax it parses is the one the engine takes, which is **not** the syntax outside a bracket:
/// probed, a backslash inside a bracket expression is a literal backslash (`[\x41]` matches `\`, not
/// `A`, and `[\d]` matches `d`), `]` is literal when it comes first, `-` is literal first or last,
/// and `[:class:]`, `[.collating.]` and `[=equivalence=]` are their own items.
extension PatternSearch {
    /// The most characters a range is expanded into, per bracket expression. One under the engine's
    /// own ceiling of 1024 items, leaving the class's other items room.
    static let bracketItemLimit = 1000

    /// `pattern` with every bracket range it can afford to expand written out character by character.
    /// A pattern with no bracket expression, and one whose classes hold no range, come back unchanged.
    static func expandingRanges(_ pattern: String) -> String {
        let scalars = Array(pattern.unicodeScalars)
        var out = String.UnicodeScalarView()
        var index = 0
        while index < scalars.count {
            let scalar = scalars[index]
            // Outside a bracket expression a backslash escapes, so `\[` opens nothing.
            if scalar == "\\", index + 1 < scalars.count {
                out.append(scalar)
                out.append(scalars[index + 1])
                index += 2
                continue
            }
            guard scalar == "[", let klass = bracketExpression(in: scalars, from: index) else {
                out.append(scalar)
                index += 1
                continue
            }
            out.append(contentsOf: klass.text)
            index = klass.end
        }
        return String(out)
    }

    // MARK: - Private

    /// One bracket expression, rewritten, and where it ends — or `nil` when it is not one, including
    /// the unterminated `[` a half-typed pattern is full of, which is left for the engine to refuse.
    private static func bracketExpression(
        in scalars: [Unicode.Scalar],
        from start: Int
    ) -> (text: String.UnicodeScalarView, end: Int)? {
        var parsed = BracketExpression()
        var index = start + 1
        if index < scalars.count, scalars[index] == "^" {
            parsed.isNegated = true
            index += 1
        }
        var isFirst = true
        while index < scalars.count {
            let scalar = scalars[index]
            if scalar == "]", !isFirst {
                return parsed.expandedRanges > 0
                    ? (parsed.rebuilt(fallingBackTo: scalars[start...index]), index + 1)
                    : (String.UnicodeScalarView(scalars[start...index]), index + 1)
            }
            isFirst = false
            if let item = collatingItem(in: scalars, from: index) {
                parsed.verbatim.append(item.text)
                index = item.end
                continue
            }
            // `a-b` is a range; a `-` before the closing bracket is a character of its own.
            if index + 2 < scalars.count, scalars[index + 1] == "-", scalars[index + 2] != "]" {
                parsed.add(range: scalar...scalars[index + 2])
                index += 3
                continue
            }
            parsed.characters.insert(scalar)
            index += 1
        }
        return nil
    }

    /// `[:class:]`, `[.collating.]` or `[=equivalence=]` at `index`, which are items rather than the
    /// start of another bracket expression.
    private static func collatingItem(
        in scalars: [Unicode.Scalar],
        from index: Int
    ) -> (text: String.UnicodeScalarView, end: Int)? {
        guard scalars[index] == "[", index + 1 < scalars.count else { return nil }
        let marker = scalars[index + 1]
        guard marker == ":" || marker == "." || marker == "=" else { return nil }
        var end = index + 2
        while end + 1 < scalars.count {
            if scalars[end] == marker, scalars[end + 1] == "]" {
                return (String.UnicodeScalarView(scalars[index...(end + 1)]), end + 2)
            }
            end += 1
        }
        return nil
    }
}

/// A bracket expression taken apart: what it holds, and how to write it back down so that the engine
/// reads the same set. Which is a question of *order* — inside a bracket there is nothing to escape
/// with, so `]` has to come first, `-` last, and `^` anywhere but first.
private struct BracketExpression {
    var isNegated = false
    var characters: Set<Unicode.Scalar> = []
    /// `[:alpha:]` and friends, kept exactly as they were written.
    var verbatim: [String.UnicodeScalarView] = []
    /// Ranges too wide for the engine's own item ceiling, left as they were typed.
    var wideRanges: [ClosedRange<Unicode.Scalar>] = []
    /// How many characters the expansions have spent, and whether any happened at all.
    var expandedRanges = 0
    private var spent = 0

    /// Expand `range` into its characters, or keep it if there is no room left for it.
    mutating func add(range: ClosedRange<Unicode.Scalar>) {
        let width = Int(range.upperBound.value) - Int(range.lowerBound.value) + 1
        guard range.lowerBound <= range.upperBound,
              width <= PatternSearch.bracketItemLimit - spent
        else {
            wideRanges.append(range)
            return
        }
        for value in range.lowerBound.value...range.upperBound.value {
            // A surrogate is not a character, and a range spanning the gap simply steps over it.
            guard let scalar = Unicode.Scalar(value) else { continue }
            characters.insert(scalar)
        }
        spent += width
        expandedRanges += 1
    }

    /// The expression written back down, or `original` where it cannot be: the one set that has no
    /// spelling is a `^` with nothing that may stand before it.
    func rebuilt(fallingBackTo original: ArraySlice<Unicode.Scalar>) -> String.UnicodeScalarView {
        var body = String.UnicodeScalarView()
        if characters.contains("]") { body.append("]") }
        for item in verbatim { body.append(contentsOf: item) }
        for range in wideRanges {
            body.append(range.lowerBound)
            body.append("-")
            body.append(range.upperBound)
        }
        body.append(contentsOf: characters.filter { $0 != "]" && $0 != "^" && $0 != "-" }
            .sorted { $0.value < $1.value })
        if characters.contains("^") { body.append("^") }
        if characters.contains("-") { body.append("-") }
        guard !body.isEmpty, !(body.first == "^" && !isNegated) else {
            return String.UnicodeScalarView(original)
        }
        var out = String.UnicodeScalarView()
        out.append("[")
        if isNegated { out.append("^") }
        out.append(contentsOf: body)
        out.append("]")
        return out
    }
}
