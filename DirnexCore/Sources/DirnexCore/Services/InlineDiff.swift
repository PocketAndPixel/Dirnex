import Foundation

/// The parts of two alike lines that differ, for marking inside a changed row of the compare
/// window (PLAN.md §M31 Slice 2).
///
/// Ranges are UTF-16 offsets from the start of each line, which is what a text view's attributes
/// take. They are in order and never overlap, and either side may have none: a word removed on the
/// left leaves nothing to mark on the right.
public struct InlineDifference: Sendable, Equatable {
    public let left: [Range<Int>]
    public let right: [Range<Int>]

    public init(left: [Range<Int>], right: [Range<Int>]) {
        self.left = left
        self.right = right
    }
}

/// Comparing two lines word by word.
///
/// A line is split into words (letters, digits and `_`), runs of whitespace, and single other
/// characters, and the words are compared with the same search as the lines, so `count + 1` against
/// `total + 1` marks `count` and `total` and nothing else. Characters alone would mark the letters
/// two unrelated words happen to share, which reads as noise. Two marked words with only whitespace
/// between them are marked as one stretch.
///
/// The comparison follows the options: whitespace that the options overlook is never marked, and
/// neither is a difference in case when case is ignored. Words compare as bytes, like lines.
enum InlineDiff {
    /// Lines longer than this, in UTF-16 units, are not compared inside: the whole line is the
    /// difference. A minified file is one enormous line, and marking inside it helps nobody.
    static let maximumLineLength = 10000

    static func difference(
        _ left: Substring,
        _ right: Substring,
        options: LineDiffOptions
    ) -> InlineDifference? {
        guard left.utf16.count <= maximumLineLength, right.utf16.count <= maximumLineLength else {
            return nil
        }
        let leftTokens = tokens(of: left, options: options)
        let rightTokens = tokens(of: right, options: options)
        var table: [[UInt8]: Int32] = [:]
        func identities(_ tokens: [Token]) -> [Int32] {
            tokens.map { token in
                if let known = table[token.key] {
                    return known
                }
                let identity = Int32(table.count)
                table[token.key] = identity
                return identity
            }
        }
        let leftIDs = identities(leftTokens)
        let rightIDs = identities(rightTokens)
        let changed = MyersDiff.changes(
            leftIDs,
            rightIDs,
            costLimit: MyersDiff.defaultCostLimit(
                leftCount: leftIDs.count,
                rightCount: rightIDs.count
            )
        )
        return InlineDifference(
            left: marked(leftTokens, changed.left, in: left),
            right: marked(rightTokens, changed.right, in: right)
        )
    }

    /// A word, a run of whitespace or a single other character, and where it sits.
    private struct Token {
        /// What the token is compared by: its bytes, folded as the options say.
        let key: [UInt8]
        /// UTF-16 offsets within the line.
        let range: Range<Int>
    }

    private enum Kind {
        case word
        case space
        case other
    }

    /// A token before the options have had their say.
    private struct RawToken {
        let text: Substring
        let kind: Kind
        let range: Range<Int>
    }

    private static func kind(of character: Character) -> Kind {
        if character == " " || character == "\t" {
            return .space
        }
        if character.isLetter || character.isNumber || character == "_" {
            return .word
        }
        return .other
    }

    /// The tokens of `line` that take part in the comparison. Whitespace the options overlook is
    /// left out, so it can be neither matched nor marked.
    private static func tokens(of line: Substring, options: LineDiffOptions) -> [Token] {
        var tokens: [RawToken] = []
        var index = line.startIndex
        var offset = 0
        while index < line.endIndex {
            let kind = Self.kind(of: line[index])
            var end = line.index(after: index)
            var width = line[index].utf16.count
            while kind != .other, end < line.endIndex, Self.kind(of: line[end]) == kind {
                width += line[end].utf16.count
                end = line.index(after: end)
            }
            tokens.append(
                RawToken(text: line[index..<end], kind: kind, range: offset..<(offset + width))
            )
            offset += width
            index = end
        }
        if options.whitespace != .compare, tokens.last?.kind == .space {
            tokens.removeLast()
        }
        return tokens.compactMap { token in
            switch (token.kind, options.whitespace) {
            case (.space, .ignoreAll):
                return nil
            case (.space, .ignoreChanges):
                return Token(key: [UInt8(ascii: " ")], range: token.range)
            default:
                let text = options.ignoresCase ? token.text.lowercased() : String(token.text)
                return Token(key: Array(text.utf8), range: token.range)
            }
        }
    }

    /// The changed tokens as ranges, joining two that only whitespace separates.
    private static func marked(_ tokens: [Token], _ changed: [Bool], in line: Substring) -> [
        Range<Int>
    ] {
        let utf16 = Array(line.utf16)
        var ranges: [Range<Int>] = []
        for (token, isChanged) in zip(tokens, changed) where isChanged {
            if let last = ranges.last,
               utf16[last.upperBound..<token.range.lowerBound].allSatisfy(isWhitespace) {
                ranges[ranges.count - 1] = last.lowerBound..<token.range.upperBound
            } else {
                ranges.append(token.range)
            }
        }
        return ranges
    }

    private static func isWhitespace(_ unit: UInt16) -> Bool {
        unit == UInt16(UInt8(ascii: " ")) || unit == UInt16(UInt8(ascii: "\t"))
    }
}
