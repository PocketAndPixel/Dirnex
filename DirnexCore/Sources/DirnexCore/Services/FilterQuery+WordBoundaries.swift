import Foundation

/// What counts as a word, and so what makes a match a whole one (2026-09-18). One rule, read by both
/// of ``FilterQuery``'s branches and by a pattern's matches alike, which is what stops Whole Word
/// meaning three things in one bar.
///
/// Lifted out of `FilterQuery` when that type reached SwiftLint's `type_body_length`. It is a concept
/// of its own: two of the three answers here were measured rather than assumed, and the measurements
/// are what the doc comments carry.
extension FilterQuery {
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
}
