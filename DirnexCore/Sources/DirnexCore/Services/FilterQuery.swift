import Foundation

/// The text a Quick View filter looks for, read the one way both filters read it, and where it lies in
/// a value on screen (2026-09-15), under the options the bar offers (2026-09-18).
///
/// By default case does not count and accents do (`DelimitedTable.rowsMatching`, `JSONDocument.filter`).
/// A query that is all ASCII is compared a byte at a time with `A`–`Z` folded, which is what lets a
/// filter read a file's bytes in place. Any other query is compared a character at a time against the
/// text lowercased: the standard library's `contains`, which a probe showed the filters call rather
/// than Foundation's, so a flag or a joined emoji stays whole. The two branches part company at the
/// edges (`e` is a byte of a decomposed `é` and not one of its characters), which is why the marks a
/// cell draws follow the same branch as the match rather than a rule of their own.
///
/// **One type owns what "contains" means**, which is what keeps the options from applying to some
/// surfaces and not others: every caller that used to reach for `DelimitedTable.foldedContains`
/// directly now asks `matchesBytes(_:from:to:)`, so the table, the three trees, the text preview, the
/// rendered page and the PDF cannot drift into six readings of one box. That matters more here than
/// tidiness — a bar that counted differently depending on which preview was up would be one bar
/// telling two stories, which is the same reason `PDFDocument.findString` was turned down.
public struct FilterQuery: Sendable, Equatable {
    /// How the text is read. The default — neither — is what shipped before the bar offered a choice,
    /// and every call site that does not pass options keeps exactly that behaviour.
    public struct Options: OptionSet, Sendable, Hashable {
        public let rawValue: Int

        public init(rawValue: Int) {
            self.rawValue = rawValue
        }

        /// `Beta` no longer matches `beta`. The ASCII branch stops folding and the other branch stops
        /// lowercasing, so neither pays for a case it was told not to ignore.
        public static let caseSensitive = Options(rawValue: 1 << 0)
        /// A match must be a whole word: no letter, digit or `_` immediately before or after it, so
        /// `beta` is found in `'beta'` and not in `betaOnly`.
        public static let wholeWord = Options(rawValue: 1 << 1)
        /// The text is a pattern rather than something to find literally (``PatternSearch``), read by
        /// macOS's own `regex(3)` — which is TRE, and linear, which is what made this offerable at
        /// all (2026-09-18). Case Sensitive and Whole Word keep meaning exactly what they mean
        /// without it: the first is the engine's `REG_ICASE`, the second is this file's own
        /// word-boundary rule applied to each match, so one box never means two things.
        public static let pattern = Options(rawValue: 1 << 2)
    }

    /// The query, lowercased unless the search is case-sensitive.
    public let needle: String
    /// How the text is read.
    public let options: Options
    /// The needle's UTF-8.
    let bytes: [UInt8]
    /// Whether the needle is all ASCII, and so compared a byte at a time.
    let isASCII: Bool
    /// The compiled pattern, when the text is one and it compiled.
    let pattern: PatternSearch?
    /// Why the pattern would not compile, when it would not — what the bar says instead of a count.
    /// `nil` whenever the text is not a pattern, or is one that compiled.
    public let patternProblem: PatternSearchError?

    public init(_ query: String, options: Options = []) {
        self.options = options
        // A pattern is never lowercased: its case is the engine's business (`REG_ICASE`), and folding
        // it here would quietly rewrite `\W` into `\w` — an option turning a pattern into its own
        // negation is the kind of wrong nothing downstream could notice.
        let isPattern = options.contains(.pattern)
        needle = isPattern || options.contains(.caseSensitive) ? query : query.lowercased()
        bytes = Array(needle.utf8)
        isASCII = bytes.allSatisfy { $0 < 0x80 }
        guard isPattern, !query.isEmpty else {
            pattern = nil
            patternProblem = nil
            return
        }
        do {
            pattern = try PatternSearch(query, caseSensitive: options.contains(.caseSensitive))
            patternProblem = nil
        } catch {
            pattern = nil
            patternProblem = error
        }
    }

    /// Two queries are the same question when they read the same text the same way. Spelled out
    /// rather than synthesized because a compiled pattern is an object, and two compiled from one
    /// string are the same question whether or not they are the same object.
    public static func == (lhs: FilterQuery, rhs: FilterQuery) -> Bool {
        lhs.needle == rhs.needle && lhs.options == rhs.options
    }

    /// Whether nothing is typed, which every text matches.
    public var isEmpty: Bool {
        needle.isEmpty
    }

    /// Whether the query is read straight off a value's bytes, which is what lets a filter search a
    /// file in place. True of an ASCII query, and of every pattern — the engine reads UTF-8 itself.
    ///
    /// Read by the three filters that hold their file as bytes, so a pattern reaches them by the same
    /// door an ordinary query does rather than through a branch of its own.
    var readsBytes: Bool {
        pattern != nil || (!options.contains(.pattern) && isASCII)
    }

    /// Whether `text` contains the query. `true` for an empty query.
    public func matches(_ text: String) -> Bool {
        guard !isEmpty else { return true }
        guard options.contains(.pattern) || isASCII else { return matchesAsCharacters(text) }
        let utf8 = Array(text.utf8)
        return matchesBytes(utf8, from: 0, to: utf8.count)
    }

    /// Whether `haystack[from..<to]` (clamped to the haystack) contains the query, comparing bytes —
    /// the in-place path a filter reads a file with, so a cell or a value is never decoded to be
    /// searched. Only meaningful for an ASCII query, which is the only kind the callers take it for.
    ///
    /// `from` and `to` bound the *value*, not the file, which is what makes the whole-word rule right
    /// at a cell's edges: a value's first character has nothing before it, so it begins a word even
    /// though the byte before it in the file is a comma.
    public func matchesBytes(_ haystack: [UInt8], from: Int, to: Int) -> Bool {
        guard !bytes.isEmpty else { return true }
        if options.contains(.pattern) {
            // A pattern that would not compile matches nothing, which is what the bar's own sentence
            // about it explains: every row gone with no reason given would read as a broken filter.
            guard let pattern else { return false }
            return haystack.withUnsafeBufferPointer { raw in
                let lower = max(from, 0)
                let upper = min(to, raw.count)
                // A caller may hand over a value whose bounds cross — an empty quoted cell is
                // `start + 1 ..< end - 1` — and a range whose bounds cross is a trap, not an answer.
                guard lower <= upper else { return false }
                return firstPatternMatch(pattern, in: raw, within: lower..<upper) != nil
            }
        }
        return haystack.withUnsafeBufferPointer { raw in
            let upper = min(to, raw.count)
            let lower = max(from, 0)
            guard upper - lower >= bytes.count else { return false }
            var position = lower
            while position <= upper - bytes.count {
                if matchesNeedle(raw, at: position),
                   !options.contains(.wholeWord)
                   || Self.isWholeWord(
                       raw,
                       at: position,
                       length: bytes.count,
                       from: lower,
                       to: upper
                   ) {
                    return true
                }
                position += 1
            }
            return false
        }
    }

    /// Where the query lies in `text`, left to right and not overlapping — what a cell marks. Empty for
    /// an empty query, which matches everything and marks nothing.
    ///
    /// Also empty in the one case the marks cannot be placed: a text whose lowercasing changes how many
    /// characters it holds, since the match is found in the lowercased text and mapped back character
    /// for character. None a probe tried did: `İ` lowercases to two scalars that are still one
    /// character.
    public func occurrences(in text: String) -> [Range<String.Index>] {
        guard !isEmpty else { return [] }
        if options.contains(.pattern) { return patternOccurrences(in: text) }
        return isASCII ? byteOccurrences(in: text) : characterOccurrences(in: text)
    }

    // MARK: - Private

    /// Whether the needle sits at `position`, folding the haystack unless the search is case-sensitive.
    func matchesNeedle(_ haystack: UnsafeBufferPointer<UInt8>, at position: Int) -> Bool {
        let folding = !options.contains(.caseSensitive)
        for (offset, byte) in bytes.enumerated() {
            let candidate = haystack[position + offset]
            if (folding ? DelimitedTable.folded(candidate) : candidate) != byte { return false }
        }
        return true
    }

    /// The character branch of `matches`, which needs the ranges only when a whole word is asked for.
    private func matchesAsCharacters(_ text: String) -> Bool {
        let haystack = options.contains(.caseSensitive) ? text : text.lowercased()
        guard options.contains(.wholeWord) else { return haystack.contains(needle) }
        return haystack.ranges(of: needle).contains { Self.isWholeWord($0, in: haystack) }
    }

    private func byteOccurrences(in text: String) -> [Range<String.Index>] {
        let haystack = Array(text.utf8)
        var offsets: [Int] = []
        haystack.withUnsafeBufferPointer { raw in
            var position = 0
            while position + bytes.count <= raw.count {
                if matchesNeedle(raw, at: position),
                   !options.contains(.wholeWord)
                   || Self.isWholeWord(
                       raw,
                       at: position,
                       length: bytes.count,
                       from: 0,
                       to: raw.count
                   ) {
                    offsets.append(position)
                    position += bytes.count
                } else {
                    position += 1
                }
            }
        }
        // An ASCII byte is never part of a longer UTF-8 sequence, so every offset here is a scalar's.
        let utf8 = text.utf8
        return offsets.map { offset in
            let start = utf8.index(utf8.startIndex, offsetBy: offset)
            return start..<utf8.index(start, offsetBy: bytes.count)
        }
    }

    private func characterOccurrences(in text: String) -> [Range<String.Index>] {
        let lowered = options.contains(.caseSensitive) ? text : text.lowercased()
        let found = lowered.ranges(of: needle).filter {
            !options.contains(.wholeWord) || Self.isWholeWord($0, in: lowered)
        }
        guard !found.isEmpty, lowered.count == text.count else { return [] }
        var loweredIndex = lowered.startIndex
        var textIndex = text.startIndex
        var marks: [Range<String.Index>] = []
        for range in found {
            while loweredIndex < range.lowerBound {
                lowered.formIndex(after: &loweredIndex)
                text.formIndex(after: &textIndex)
            }
            let start = textIndex
            while loweredIndex < range.upperBound {
                lowered.formIndex(after: &loweredIndex)
                text.formIndex(after: &textIndex)
            }
            marks.append(start..<textIndex)
        }
        return marks
    }
}
