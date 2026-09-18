import Foundation

/// The pattern half of ``FilterQuery``: the loop every pattern caller runs, and the marks it draws
/// (2026-09-18). Lifted out when that type reached SwiftLint's `type_body_length`, by concept rather
/// than by shaving lines — what is here is everything only a pattern does, and what stays there is
/// what every query does whether it is one or not.
///
/// The engine is ``PatternSearch``; the rules around it are these.
extension FilterQuery {
    /// The matches of a pattern that pass the whole-word rule, from `searchStart` on — the one loop
    /// every pattern caller runs, so the rule is applied once rather than at each of them.
    ///
    /// A match the rule turns down is stepped past by a *character*, not skipped to its end, since a
    /// later match may begin inside it. That stays linear overall: each call costs the distance it
    /// advances, and the distances telescope.
    func firstPatternMatch(
        _ pattern: PatternSearch,
        in haystack: UnsafeBufferPointer<UInt8>,
        within bounds: Range<Int>,
        from searchStart: Int? = nil
    ) -> Range<Int>? {
        var start = searchStart ?? bounds.lowerBound
        while let found = pattern.firstMatch(in: haystack, at: start, within: bounds) {
            if !options.contains(.wholeWord) || Self.isWholeWord(
                haystack,
                at: found.lowerBound,
                length: found.count,
                from: bounds.lowerBound,
                to: bounds.upperBound
            ) {
                return found
            }
            start = PatternSearch.scalarStart(
                after: found.lowerBound,
                in: haystack,
                before: bounds.upperBound
            )
        }
        return nil
    }

    /// The pattern branch of `occurrences`: byte ranges from the engine, turned into the text's own
    /// indices. Every offset is a scalar boundary — the engine reads whole characters under a UTF-8
    /// locale — so the utf8 view addresses them exactly.
    func patternOccurrences(in text: String) -> [Range<String.Index>] {
        guard let pattern else { return [] }
        let haystack = Array(text.utf8)
        var found: [Range<Int>] = []
        haystack.withUnsafeBufferPointer { raw in
            let bounds = 0..<raw.count
            var start = 0
            while let match = firstPatternMatch(pattern, in: raw, within: bounds, from: start) {
                found.append(match)
                start = match.upperBound
            }
        }
        let utf8 = text.utf8
        return found.compactMap { range in
            guard let lower = utf8.index(
                utf8.startIndex,
                offsetBy: range.lowerBound,
                limitedBy: utf8.endIndex
            ),
                let upper = utf8.index(
                    utf8.startIndex,
                    offsetBy: range.upperBound,
                    limitedBy: utf8.endIndex
                ),
                let lowerIndex = lower.samePosition(in: text),
                let upperIndex = upper.samePosition(in: text)
            else { return nil }
            return lowerIndex..<upperIndex
        }
    }
}
