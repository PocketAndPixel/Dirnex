import Foundation

/// Why a pattern could not be compiled — the two answers a bar has to tell apart (2026-09-18).
public enum PatternSearchError: Error, Equatable, Sendable {
    /// It carries a back reference (`\1`–`\9`), the one construct that takes the engine out of its
    /// linear simulation and into backtracking: measured, `(a*)*\1b` over a run of `a`s costs 0.17 s
    /// at 20 characters, 2.5 s at 24 and **40 s** at 28, while every pattern without one stays
    /// linear at every length tried. The bar searches on every keystroke, so this is refused rather
    /// than run, and the refusal says so — a pattern that simply never returned would read as the
    /// app having hung.
    case backReference
    /// The engine would not compile it: an unbalanced `(`, `[` or `{`, a trailing backslash, a
    /// repetition with nothing to repeat. Half-typed, this is the ordinary state of a pattern, so it
    /// is something to *say* rather than a failure to report.
    case invalid
}

/// A pattern compiled once per query and matched against UTF-8 bytes where they lie (2026-09-18).
///
/// **The engine is macOS's own `regex(3)`, and that is the whole reason pattern search exists here.**
/// The find bar shipped without it for a measured reason: `NSRegularExpression` is ICU, which
/// backtracks, and `(a+)+b` over **28 characters** took 9.4 s with `enumerateMatches`' `stop` pointer
/// read only *between* matches — so a query typed a letter at a time could wedge a thread with
/// nothing able to interrupt it. Swift's `Regex` is worse (past 10 s at 20 characters). What nobody
/// had asked is what libc does: macOS's `regex.h` is **TRE** (Laurikari), a tagged-NFA *parallel*
/// simulation, and it answers that pattern in 0.00002 s and a million characters of it in 0.05 s —
/// measured 2026-09-18 with capture on, against every shape that kills a backtracker (`^(a|aa)+$`,
/// `^((a*)*)*$`, `^(a?){100}a{100}$`). Back references are the single exception, and are refused.
///
/// The cost that remains is linear in input **×** pattern, since a bounded repetition expands the
/// machine: `a{255}b` over 4 MB of nothing but `a` is 4.25 s, the worst case measured. Over ordinary
/// text the same pattern is **41 ms** and `(a{100}){100}b` is 32 ms, because the live state set dies
/// at the first byte that does not fit — so this is a fact about a degenerate *file*, not about a
/// pattern anyone can type, and it needs no complexity budget in front of it.
///
/// Three flags decide what the syntax is:
///
/// - **`REG_ENHANCED`** is what makes the pattern the one people type: `\d \w \s \b \B \< \>`, the
///   `\n \t \xNN` literals, `\Q…\E`, and lazy `*?`. Without it `\b` is a literal `b` and finds
///   nothing, which reads as a broken bar. It is also what makes back references *available*, hence
///   the scan below.
/// - **`REG_NEWLINE`** makes `^` and `$` line anchors and stops `.` crossing a line, which is what
///   every find field means by them and what a one-line text field can express: a newline is still
///   reachable as `\n`.
/// - **`REG_ICASE`** unless the search is case-sensitive, so the bar's own option means here what it
///   means everywhere else.
///
/// **The locale is captured at compile time, not read at exec time** — measured both ways: compiled
/// under UTF-8 and executed under `C`, `^.$` matches `б` and `REG_ICASE` folds `ПАНОРАМА`; compiled
/// under `C` and executed under UTF-8, neither does. That matters because a GUI-launched app has no
/// locale at all (docs/NOTES.md ▸ Design lessons), so the process's is `C` and a pattern compiled
/// under it would read `.` as a byte. `uselocale` is thread-local, costs 0.4 µs with `newlocale`, and
/// is set around `regcomp` alone — once per query rather than once per cell.
///
/// One compiled pattern is safe to match from several threads at once: measured, 8 threads × 201
/// rounds against one `regex_t` agreed with the serial answers every time, which is what the
/// `@unchecked Sendable` below rests on.
public final class PatternSearch: @unchecked Sendable {
    /// `REG_ENHANCED`, which the C header puts behind `__DARWIN_C_LEVEL >= __DARWIN_C_FULL` and
    /// Swift's Darwin module does not import. The value is Apple's (`0400` in `<_regex.h>`).
    private static let enhanced: Int32 = 0o400

    /// A UTF-8 `LC_CTYPE`, made once and never freed, since it lasts as long as the process does.
    /// `nil` only if the C library will not make one, where a pattern compiles under whatever locale
    /// the thread has and `.` reads a byte rather than a character.
    private nonisolated(unsafe) static let utf8Locale: locale_t? =
        newlocale(Int32(LC_CTYPE_MASK), "UTF-8", nil)

    private var program = regex_t()
    /// Whether `program` holds anything to free: `regcomp` leaves it undefined when it fails, and a
    /// class whose initializer throws after its properties are set still runs its `deinit`.
    private var isCompiled = false

    /// Compile `pattern`, or say why it cannot be.
    public init(_ pattern: String, caseSensitive: Bool) throws(PatternSearchError) {
        guard !Self.containsBackReference(pattern) else { throw .backReference }
        var flags = REG_EXTENDED | Self.enhanced | REG_NEWLINE
        if !caseSensitive { flags |= REG_ICASE }
        let previous = Self.utf8Locale.map { uselocale($0) }
        defer { if let previous { _ = uselocale(previous) } }
        // Ranges are rewritten first: the engine's own range comparison keeps only the low 8 bits
        // of a character, so `[A-Z]` would take `я` (``PatternSearch/expandingRanges(_:)``).
        guard regcomp(&program, Self.expandingRanges(pattern), flags) == 0 else { throw .invalid }
        isCompiled = true
    }

    deinit {
        if isCompiled { regfree(&program) }
    }

    /// The leftmost match beginning at or after `searchStart`, within `bounds` — or `nil` when there
    /// is none. Byte offsets into `haystack`, and never empty: a pattern that can match nothing at
    /// all (`a*`) is stepped past rather than reported, since a zero-width match highlights nothing
    /// and would never advance.
    ///
    /// **The slice is given one character of context**, which is not tidiness: iterating means handing
    /// the engine the rest of the buffer, and the rest of a buffer has nothing before it — so `\bbeta`
    /// over `betabeta` reported **two** matches when sliced naively and **one** with the preceding
    /// character included (measured). `REG_NOTBOL` keeps `^` from matching at the seam, and the
    /// context is what every other assertion needs, all of which look back exactly one character.
    /// A leftmost match that starts *inside* the context overlaps the previous one, and the search is
    /// then repeated from `searchStart` with no context — one extra call, in the one case that needs
    /// it.
    func firstMatch(
        in haystack: UnsafeBufferPointer<UInt8>,
        at searchStart: Int,
        within bounds: Range<Int>
    ) -> Range<Int>? {
        var start = searchStart
        while start <= bounds.upperBound {
            let context = start > bounds.lowerBound
                ? Self.scalarStart(before: start, in: haystack, notBefore: bounds.lowerBound)
                : start
            guard var found = exec(
                haystack,
                from: context,
                to: bounds.upperBound,
                isStart: context == bounds.lowerBound
            ) else { return nil }
            if found.lowerBound < start {
                // Overlaps what the caller has already had: ask again from the seam itself, where
                // the only thing lost is what an assertion at that one position could have seen.
                guard let retry = exec(
                    haystack,
                    from: start,
                    to: bounds.upperBound,
                    isStart: start == bounds.lowerBound
                ) else { return nil }
                found = retry
            }
            guard !found.isEmpty else {
                start = Self.scalarStart(
                    after: found.lowerBound,
                    in: haystack,
                    before: bounds.upperBound
                )
                continue
            }
            return found
        }
        return nil
    }

    /// One run of the engine over `haystack[from..<to]`, answering in the haystack's own offsets.
    ///
    /// `isStart` is what `^` is told: the slice begins where the *search* does, rather than part-way
    /// through it. It is the value's own start and not the file's — a cell searched in place begins a
    /// line as surely as a document does, which is what makes `^beta$` mean a cell holding exactly
    /// that.
    private func exec(
        _ haystack: UnsafeBufferPointer<UInt8>,
        from: Int,
        to: Int,
        isStart: Bool
    ) -> Range<Int>? {
        guard let base = haystack.baseAddress, from <= to else { return nil }
        var match = regmatch_t()
        let notBOL: Int32 = isStart ? 0 : REG_NOTBOL
        let found = withUnsafeMutablePointer(to: &match) { slot in
            UnsafeRawPointer(base + from).withMemoryRebound(
                to: CChar.self,
                capacity: to - from
            ) { chars in
                regnexec(&program, chars, to - from, 1, slot, notBOL)
            }
        }
        guard found == 0, match.rm_so >= 0 else { return nil }
        return (from + Int(match.rm_so))..<(from + Int(match.rm_eo))
    }

    // MARK: - Reading the pattern

    /// Whether `pattern` carries a back reference — `\1` through `\9` outside a bracket expression,
    /// which is where the enhanced escapes stop meaning anything at all ("within a bracket
    /// expression, most characters lose their magic", `re_format(7)`). `\\1` is a backslash and a
    /// digit, not a reference, which is why the escape is consumed rather than matched on.
    static func containsBackReference(_ pattern: String) -> Bool {
        var inBracket = false
        var bracketIndex = 0
        var escaped = false
        for (index, character) in pattern.enumerated() {
            if escaped {
                escaped = false
                if !inBracket, character.isNumber, character != "0" { return true }
                continue
            }
            if character == "\\" {
                escaped = true
                continue
            }
            if inBracket {
                // A `]` that opens the expression, or follows its negation, is the literal bracket.
                if character == "]", index > bracketIndex + 1 { inBracket = false }
                continue
            }
            if character == "[" {
                inBracket = true
                // Where the expression's literal-`]` window starts: after `[` and any `^`.
                bracketIndex = index
                continue
            }
        }
        return false
    }

    // MARK: - Scalar boundaries

    /// Where the scalar ending at `position` begins. UTF-8 self-synchronizes, so this walks back over
    /// at most three continuation bytes.
    static func scalarStart(
        before position: Int,
        in haystack: UnsafeBufferPointer<UInt8>,
        notBefore lower: Int
    ) -> Int {
        var start = position - 1
        while start > lower, haystack[start] >= 0x80, haystack[start] < 0xC0 {
            start -= 1
        }
        return max(start, lower)
    }

    /// Where the scalar beginning at `position` ends — one character on, which is how an empty match
    /// is stepped past without ever splitting one.
    static func scalarStart(
        after position: Int,
        in haystack: UnsafeBufferPointer<UInt8>,
        before upper: Int
    ) -> Int {
        var next = position + 1
        while next < upper, haystack[next] >= 0x80, haystack[next] < 0xC0 {
            next += 1
        }
        return next
    }
}
