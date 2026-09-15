import Foundation

/// The text a Quick View filter looks for, read the one way both filters read it, and where it lies in
/// a value on screen (2026-09-15).
///
/// Case does not count and accents do (`DelimitedTable.rowsMatching`, `JSONDocument.filter`). A query
/// that is all ASCII is compared a byte at a time with `A`–`Z` folded, which is what lets a filter read
/// a file's bytes in place. Any other query is compared a character at a time against the text
/// lowercased: the standard library's `contains`, which a probe showed the filters call rather than
/// Foundation's, so a flag or a joined emoji stays whole. The two branches part company at the edges
/// (`e` is a byte of a decomposed `é` and not one of its characters), which is why the marks a cell
/// draws follow the same branch as the match rather than a rule of their own.
public struct FilterQuery: Sendable, Equatable {
    /// The query, lowercased.
    public let needle: String
    /// The needle's UTF-8.
    let bytes: [UInt8]
    /// Whether the needle is all ASCII, and so compared a byte at a time.
    let isASCII: Bool

    public init(_ query: String) {
        needle = query.lowercased()
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
        guard isASCII else { return text.lowercased().contains(needle) }
        let utf8 = Array(text.utf8)
        return DelimitedTable.foldedContains(utf8, from: 0, to: utf8.count, needle: bytes)
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

    // MARK: - Private

    private func byteOccurrences(in text: String) -> [Range<String.Index>] {
        let haystack = Array(text.utf8)
        var offsets: [Int] = []
        var position = 0
        while position + bytes.count <= haystack.count {
            if matchesFolded(haystack, at: position) {
                offsets.append(position)
                position += bytes.count
            } else {
                position += 1
            }
        }
        // An ASCII byte is never part of a longer UTF-8 sequence, so every offset here is a scalar's.
        let utf8 = text.utf8
        return offsets.map { offset in
            let start = utf8.index(utf8.startIndex, offsetBy: offset)
            return start..<utf8.index(start, offsetBy: bytes.count)
        }
    }

    private func matchesFolded(_ haystack: [UInt8], at position: Int) -> Bool {
        for (offset, byte) in bytes.enumerated() where DelimitedTable.folded(
            haystack[position + offset]
        ) != byte {
            return false
        }
        return true
    }

    private func characterOccurrences(in text: String) -> [Range<String.Index>] {
        let lowered = text.lowercased()
        let found = lowered.ranges(of: needle)
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
