import Foundation

/// Where a query lies in a text preview, for finding it in place (2026-09-17): every occurrence as
/// the UTF-16 offsets a text view addresses, left to right and not overlapping, and the arithmetic of
/// stepping through them.
///
/// The query is read the one way the table and tree filters read it (`FilterQuery`), options included:
/// by default case does not count and accents do, an ASCII query compares a byte at a time with
/// `A`–`Z` folded, and any other query compares whole characters in the text lowercased. So a word the
/// filters find in a CSV cell is found in the same file's source, and the two never disagree about
/// what matches — under Case Sensitive and Whole Word as much as without them.
///
/// UTF-16 rather than `String.Index` because the text view is where the offsets are spent: a match is
/// highlighted and scrolled to by `NSRange`, and mapping 145 000 `String.Index` ranges to `NSRange`
/// took 17 ms of a main-actor turn on a 4 MB file (measured), where counting UTF-16 units during the
/// scan costs nothing.
public struct TextFindMatches: Sendable, Equatable {
    /// Each match's UTF-16 offsets, ascending and not overlapping.
    public let ranges: [Range<Int>]
    /// Whether every match was found, or the search stopped at its limit with more to come.
    public let isComplete: Bool

    /// The most matches a search keeps. A one-letter query over a 4 MB file has hundreds of thousands,
    /// which nobody steps through and which would cost memory for nothing; the count says there are
    /// more.
    public static let limit = 100_000

    public init(ranges: [Range<Int>], isComplete: Bool) {
        self.ranges = ranges
        self.isComplete = isComplete
    }

    /// Every occurrence of `query` in `text`, up to `limit`, or `nil` once `isCancelled` answers
    /// `true`. An empty query finds nothing. Blocking over a large text; call it off the main thread.
    public static func find(
        _ query: FilterQuery,
        in text: String,
        limit: Int = TextFindMatches.limit,
        isCancelled: () -> Bool = { false }
    ) -> TextFindMatches? {
        guard !query.isEmpty else { return TextFindMatches(ranges: [], isComplete: true) }
        return query.isASCII
            ? query.utf16ByteOccurrences(in: text, limit: limit, isCancelled: isCancelled)
            : query.utf16CharacterOccurrences(in: text, limit: limit, isCancelled: isCancelled)
    }

    public var count: Int {
        ranges.count
    }

    public var isEmpty: Bool {
        ranges.isEmpty
    }

    /// The first match starting at or after `offset`, or the first match of all when there is none
    /// past it — where a search begins, so typing finds what is below the reader rather than jumping
    /// back to the top of the file. `nil` with nothing found.
    public func index(atOrAfter offset: Int) -> Int? {
        guard !ranges.isEmpty else { return nil }
        let found = firstIndex { $0.lowerBound >= offset }
        return found < ranges.count ? found : 0
    }

    /// The match `step` matches from `index`, wrapping past either end.
    public func index(_ index: Int, steppedBy step: Int) -> Int {
        guard !ranges.isEmpty else { return 0 }
        let wrapped = (index + step) % ranges.count
        return wrapped < 0 ? wrapped + ranges.count : wrapped
    }

    /// The matches overlapping `window`, as a range of indices — which ones a view highlights for the
    /// part of the text it has on screen. An empty window overlaps nothing.
    public func indices(overlapping window: Range<Int>) -> Range<Int> {
        guard !window.isEmpty else { return 0..<0 }
        let start = firstIndex { $0.upperBound > window.lowerBound }
        let end = firstIndex { $0.lowerBound >= window.upperBound }
        return start..<max(start, end)
    }

    /// The indices in `range` that are not in `other`: at most two runs, one below `other` and one
    /// above it. What a view un-highlights as a window moves, and what it newly highlights.
    public static func indices(_ range: Range<Int>, notIn other: Range<Int>) -> [Range<Int>] {
        guard !other.isEmpty else { return range.isEmpty ? [] : [range] }
        let belowEnd = min(range.upperBound, other.lowerBound)
        let aboveStart = max(range.lowerBound, other.upperBound)
        // Clamped, since a run that does not exist would otherwise be a range whose bounds cross.
        let below = range.lowerBound..<max(range.lowerBound, belowEnd)
        let above = min(aboveStart, range.upperBound)..<range.upperBound
        return [below, above].filter { !$0.isEmpty }
    }

    // MARK: - Private

    /// The first index whose match satisfies `predicate`, which must be false for a prefix of the
    /// matches and true for the rest; `count` when none does.
    private func firstIndex(where predicate: (Range<Int>) -> Bool) -> Int {
        var low = 0
        var high = ranges.count
        while low < high {
            let middle = (low + high) / 2
            if predicate(ranges[middle]) {
                high = middle
            } else {
                low = middle + 1
            }
        }
        return low
    }
}

extension FilterQuery {
    /// How many units of the scan pass between two looks at the cancellation flag.
    private static let cancellationStride = 1 << 16

    /// The ASCII branch: a byte at a time with `A`–`Z` folded, counting UTF-16 units as it goes. A match
    /// can only start on an ASCII byte, which is always a whole scalar, and an ASCII needle is as many
    /// UTF-16 units as it is bytes.
    fileprivate func utf16ByteOccurrences(
        in text: String,
        limit: Int,
        isCancelled: () -> Bool
    ) -> TextFindMatches? {
        var text = text
        let needle = bytes
        return text.withUTF8 { haystack -> TextFindMatches? in
            let length = needle.count
            var ranges: [Range<Int>] = []
            var position = 0
            var utf16 = 0
            var sinceCheck = 0
            while position + length <= haystack.count {
                sinceCheck += 1
                if sinceCheck == Self.cancellationStride {
                    sinceCheck = 0
                    if isCancelled() { return nil }
                }
                let byte = haystack[position]
                if byte < 0x80, matchesNeedle(haystack, at: position), wholeWordHolds(
                    haystack,
                    at: position,
                    length: length
                ) {
                    guard ranges.count < limit else {
                        return TextFindMatches(ranges: ranges, isComplete: false)
                    }
                    ranges.append(utf16..<utf16 + length)
                    position += length
                    utf16 += length
                    continue
                }
                // A lead byte starts a scalar: four-byte scalars are two UTF-16 units, the rest one.
                // Continuation bytes (10xxxxxx) add nothing.
                if byte < 0x80 || (byte >= 0xC0 && byte < 0xF0) {
                    utf16 += 1
                } else if byte >= 0xF0 {
                    utf16 += 2
                }
                position += 1
            }
            return TextFindMatches(ranges: ranges, isComplete: true)
        }
    }

    /// Whether a whole-word search is satisfied here — free, and `true`, when none was asked for.
    /// The bounds are the whole text's, since a preview searches a document rather than a field.
    private func wholeWordHolds(
        _ haystack: UnsafeBufferPointer<UInt8>,
        at position: Int,
        length: Int
    ) -> Bool {
        guard options.contains(.wholeWord) else { return true }
        return FilterQuery.isWholeWord(
            haystack,
            at: position,
            length: length,
            from: 0,
            to: haystack.count
        )
    }

    /// The other branch: whole characters in the text lowercased, mapped back character for character
    /// as `occurrences(in:)` maps them, and nothing found in a text whose lowercasing changes how many
    /// characters it holds, for the same reason.
    fileprivate func utf16CharacterOccurrences(
        in text: String,
        limit: Int,
        isCancelled: () -> Bool
    ) -> TextFindMatches? {
        let lowered = options.contains(.caseSensitive) ? text : text.lowercased()
        var ranges: [Range<Int>] = []
        var searchStart = lowered.startIndex
        var cursor = CharacterCursor(lowered: lowered.startIndex, text: text.startIndex)
        var checkedCount = false
        while let found = lowered[searchStart...].firstRange(of: needle) {
            if isCancelled() { return nil }
            if !checkedCount {
                guard lowered.count == text.count else {
                    return TextFindMatches(ranges: [], isComplete: true)
                }
                checkedCount = true
            }
            guard !options.contains(.wholeWord) || FilterQuery.isWholeWord(found, in: lowered) else {
                searchStart = found.upperBound
                continue
            }
            guard ranges.count < limit else {
                return TextFindMatches(ranges: ranges, isComplete: false)
            }
            cursor.advance(to: found.lowerBound, in: lowered, text)
            let start = cursor.utf16
            cursor.advance(to: found.upperBound, in: lowered, text)
            ranges.append(start..<cursor.utf16)
            searchStart = found.upperBound
        }
        return TextFindMatches(ranges: ranges, isComplete: true)
    }
}

/// The same place in a text and in its lowercased copy, kept in step a character at a time, with the
/// UTF-16 offset of that place in the original.
private struct CharacterCursor {
    var lowered: String.Index
    var text: String.Index
    var utf16 = 0

    /// Step both a character at a time until the lowercased copy reaches `target`.
    mutating func advance(to target: String.Index, in loweredText: String, _ original: String) {
        while lowered < target {
            loweredText.formIndex(after: &lowered)
            let next = original.index(after: text)
            utf16 += original.utf16.distance(from: text, to: next)
            text = next
        }
    }
}
