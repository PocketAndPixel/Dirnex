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
    }

    /// The query, lowercased unless the search is case-sensitive.
    public let needle: String
    /// How the text is read.
    public let options: Options
    /// The needle's UTF-8.
    let bytes: [UInt8]
    /// Whether the needle is all ASCII, and so compared a byte at a time.
    let isASCII: Bool

    public init(_ query: String, options: Options = []) {
        self.options = options
        needle = options.contains(.caseSensitive) ? query : query.lowercased()
        bytes = Array(needle.utf8)
        isASCII = bytes.allSatisfy { $0 < 0x80 }
    }

    /// Whether nothing is typed, which every text matches.
    public var isEmpty: Bool {
        needle.isEmpty
    }

    /// Whether `text` contains the query. `true` for an empty query.
    public func matches(_ text: String) -> Bool {
        guard !isEmpty else { return true }
        guard isASCII else { return matchesAsCharacters(text) }
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
        return isASCII ? byteOccurrences(in: text) : characterOccurrences(in: text)
    }

    // MARK: - Word boundaries

    /// Whether `scalar` is part of a word, and so stops a match beside it from being a whole one:
    /// a letter, a digit, or `_`.
    ///
    /// Unicode's own properties rather than an ASCII table, and the difference is visible in ordinary
    /// prose: a curly quote, an em dash, an ellipsis and a no-break space are *not* word characters, so
    /// a whole-word search finds `beta` in `“beta”` — which a rule reading "any non-ASCII byte is part
    /// of a word" would miss, and miss silently, in every typeset document anybody previews.
    ///
    /// **A combining mark has to be named, because `isAlphabetic` does not cover it** — probed
    /// 2026-09-18 rather than assumed, and the assumption was wrong: U+0301 COMBINING ACUTE ACCENT is
    /// `nonspacingMark` with `isAlphabetic` **false**, while U+05B4 HEBREW POINT HIRIQ, the same
    /// category, is **true**. So the property alone is not a rule about marks at all, and without the
    /// categories a decomposed `café` would end a word after `cafe` and whole-word-match it — the
    /// opposite of the answer the accent-counting rule beside it gives for the same pair.
    ///
    /// `numericType` rather than an ASCII digit range, so `٣` counts as a digit like `3`. And `_` is
    /// named because it is `connectorPunctuation` and alphabetic to nobody, while being exactly what
    /// every language means by one identifier — which matters here, since this app previews source
    /// code more than anything else.
    static func isWordScalar(_ scalar: Unicode.Scalar) -> Bool {
        if scalar == "_" { return true }
        let properties = scalar.properties
        if properties.isAlphabetic || properties.numericType != nil { return true }
        switch properties.generalCategory {
        case .nonspacingMark, .spacingMark, .enclosingMark: return true
        default: return false
        }
    }

    /// Whether the match at `position` stands alone: the scalar ending before it and the one beginning
    /// after it are not part of a word. The bounds count as boundaries, so a value that *is* the query
    /// is a whole word.
    static func isWholeWord(
        _ haystack: UnsafeBufferPointer<UInt8>,
        at position: Int,
        length: Int,
        from: Int,
        to: Int
    ) -> Bool {
        if position > from, let before = scalar(
            endingBefore: position,
            in: haystack,
            notBefore: from
        ),
            isWordScalar(before) {
            return false
        }
        let end = position + length
        if end < to, let after = scalar(startingAt: end, in: haystack, before: to),
           isWordScalar(after) {
            return false
        }
        return true
    }

    /// The scalar whose UTF-8 ends at `position`. UTF-8 self-synchronizes, so this walks back over at
    /// most three continuation bytes to find the lead byte.
    private static func scalar(
        endingBefore position: Int,
        in haystack: UnsafeBufferPointer<UInt8>,
        notBefore lower: Int
    ) -> Unicode.Scalar? {
        var start = position - 1
        while start > lower, haystack[start] >= 0x80, haystack[start] < 0xC0 {
            start -= 1
        }
        return scalar(startingAt: start, in: haystack, before: position)
    }

    /// The scalar whose UTF-8 begins at `position`, or `nil` for bytes that are not a whole one —
    /// which counts as a boundary, since nothing that is not a character can be part of a word.
    private static func scalar(
        startingAt position: Int,
        in haystack: UnsafeBufferPointer<UInt8>,
        before upper: Int
    ) -> Unicode.Scalar? {
        guard position >= 0, position < upper else { return nil }
        let lead = haystack[position]
        if lead < 0x80 { return Unicode.Scalar(lead) }
        let length: Int
        var value: UInt32
        switch lead {
        case 0xC0...0xDF: length = 2; value = UInt32(lead & 0x1F)
        case 0xE0...0xEF: length = 3; value = UInt32(lead & 0x0F)
        case 0xF0...0xF7: length = 4; value = UInt32(lead & 0x07)
        default: return nil
        }
        guard position + length <= upper else { return nil }
        for offset in 1..<length {
            let byte = haystack[position + offset]
            guard byte >= 0x80, byte < 0xC0 else { return nil }
            value = (value << 6) | UInt32(byte & 0x3F)
        }
        return Unicode.Scalar(value)
    }

    /// The same question about a text being read as characters: what sits either side of `range`.
    /// The first scalar of the neighbouring character decides, so the two branches read one rule.
    static func isWholeWord(_ range: Range<String.Index>, in text: String) -> Bool {
        if range.lowerBound > text.startIndex {
            let before = text[text.index(before: range.lowerBound)]
            if let scalar = before.unicodeScalars.first, isWordScalar(scalar) { return false }
        }
        if range.upperBound < text.endIndex {
            let after = text[range.upperBound]
            if let scalar = after.unicodeScalars.first, isWordScalar(scalar) { return false }
        }
        return true
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
