import Foundation

/// One side's lines with the whitespace another side gave the same base lines: the extra take of a
/// conflict whitespace explains (PLAN.md §M37 Slice 5).
///
/// `spacing` is the base's lines with only their whitespace changed, line for line. Each line of
/// `edit` is paired with the base line it came from: unchanged lines exactly, and each changed block
/// as the compare window lays it out on rows (`RowAlignment.blockRows`), alike lines together and the
/// rest side by side from the top. Pairing only alike lines would leave a short edited line, `x` made
/// `x!`, unpaired, and the spacing of the line it replaced would be lost without a word. A line is
/// four parts, carried one at a time: its indentation, its text, the whitespace after the text, and
/// its ending. For each part of a paired line:
/// - a part `spacing` left as the base had it stays as `edit` has it;
/// - a part `edit` left as the base had it takes `spacing`'s;
/// - a part both changed the same way stays;
/// - indentation both changed, where `edit`'s still starts with the base's, is `spacing`'s followed
///   by the rest of `edit`'s, so a line `edit` nested deeper keeps its extra depth;
/// - anything else both changed cannot be carried, and nothing is returned.
///
/// A line `edit` added has no base line, so `spacing` changed nothing on it. It keeps its text and
/// trailing whitespace. Its indentation is re-based on the paired line whose base indentation is the
/// longest start of its own, the nearest on a tie, so a block `spacing` indented by four takes the
/// added line along. A blank one keeps its indentation. Its ending follows the nearest paired line's.
///
/// Bytes throughout, never `Character`s: whitespace is git's space and tab, which are ASCII, so
/// every split falls between whole UTF-8 sequences and the parts join back to the same bytes.
enum WhitespaceCarry {
    /// `edit` with `spacing`'s whitespace, one line for each of `edit`'s, or `nil` when some of it
    /// cannot be carried. `spacing` and `base` have the same number of lines.
    static func carry(spacing: [TextLine], base: [TextLine], onto edit: [TextLine]) -> [TextLine]? {
        precondition(
            spacing.count == base.count,
            "spacing must be the base with its whitespace changed"
        )
        let pairs = basePairs(of: edit, in: base)
        let baseParts = base.map(LineParts.init)
        let spacingParts = spacing.map(LineParts.init)
        let references = References(pairs: pairs, base: baseParts)
        var carried: [TextLine] = []
        carried.reserveCapacity(edit.count)
        for (index, line) in edit.enumerated() {
            let parts = LineParts(line)
            if let baseIndex = pairs[index] {
                guard let line = carry(
                    parts,
                    base: baseParts[baseIndex],
                    spacing: spacingParts[baseIndex]
                )
                else { return nil }
                carried.append(line.line)
            } else {
                carried.append(references.added(
                    parts,
                    at: index,
                    base: baseParts,
                    spacing: spacingParts
                ).line)
            }
        }
        return carried
    }

    // MARK: - Pairing

    /// The base line each of `edit`'s lines came from, `nil` for a line `edit` added.
    private static func basePairs(of edit: [TextLine], in base: [TextLine]) -> [Int?] {
        var pairs = [Int?](repeating: nil, count: edit.count)
        var baseIndex = 0
        var editIndex = 0
        func pairUnchanged(until end: Int) {
            while baseIndex < end {
                pairs[editIndex] = baseIndex
                baseIndex += 1
                editIndex += 1
            }
        }
        for change in LineDiff.compare(base, edit).changes {
            pairUnchanged(until: change.left.lowerBound)
            let rows = RowAlignment.blockRows(
                left: change.left.map { ($0, base[$0]) },
                right: change.right.map { ($0, edit[$0]) },
                options: LineDiffOptions()
            )
            for row in rows {
                guard let left = row.left, let right = row.right else { continue }
                pairs[right] = left
            }
            baseIndex = change.left.upperBound
            editIndex = change.right.upperBound
        }
        pairUnchanged(until: base.count)
        return pairs
    }

    // MARK: - Carrying

    /// A paired line with `spacing`'s whitespace, or `nil` when both changed one part differently.
    private static func carry(_ edit: LineParts, base: LineParts, spacing: LineParts) -> LineParts? {
        let indent = part(edit.indent, base.indent, spacing.indent)
            ?? (edit.indent.starts(with: base.indent)
                ? spacing.indent + edit.indent.dropFirst(base.indent.count) : nil)
        guard let indent,
              let text = part(edit.text, base.text, spacing.text),
              let trailing = part(edit.trailing, base.trailing, spacing.trailing),
              let terminator = part(edit.terminator, base.terminator, spacing.terminator)
        else { return nil }
        return LineParts(indent: indent, text: text, trailing: trailing, terminator: terminator)
    }

    /// One part: `edit`'s where `spacing` left the base's alone or both agree, `spacing`'s where
    /// `edit` left it alone, and `nil` where both changed it differently.
    private static func part<Part: Equatable>(_ edit: Part, _ base: Part, _ spacing: Part) -> Part? {
        if spacing == base || edit == spacing { return edit }
        if edit == base { return spacing }
        return nil
    }

    /// The paired lines an added line follows, found once for all of them: one rewritten file is
    /// one conflict of hundreds of thousands of lines.
    private struct References {
        let pairs: [Int?]
        /// For each of `edit`'s lines, the nearest paired line at or above it and at or below it.
        let above: [Int?]
        let below: [Int?]
        /// The positions in `edit` of the paired lines with text, in order, by their base line's
        /// indentation. A file has few distinct indentations.
        let byIndent: [[UInt8]: [Int]]

        init(pairs: [Int?], base: [LineParts]) {
            self.pairs = pairs
            var above = [Int?](repeating: nil, count: pairs.count)
            var below = [Int?](repeating: nil, count: pairs.count)
            var last: Int?
            for index in pairs.indices {
                if pairs[index] != nil { last = index }
                above[index] = last
            }
            last = nil
            for index in pairs.indices.reversed() {
                if pairs[index] != nil { last = index }
                below[index] = last
            }
            self.above = above
            self.below = below
            var byIndent: [[UInt8]: [Int]] = [:]
            for (index, pair) in pairs.enumerated() {
                guard let pair, !base[pair].text.isEmpty else { continue }
                byIndent[base[pair].indent, default: []].append(index)
            }
            self.byIndent = byIndent
        }

        /// A line `edit` added, its indentation and ending following the paired lines around it.
        func added(
            _ parts: LineParts,
            at index: Int,
            base: [LineParts],
            spacing: [LineParts]
        ) -> LineParts {
            var line = parts
            if !parts.text.isEmpty,
               let indent = byIndent.keys.filter({ parts.indent.starts(with: $0) }).max(
                   by: { $0.count < $1.count }
               ),
               let positions = byIndent[indent],
               let reference = Self.nearest(to: index, in: positions).flatMap({ pairs[$0] }),
               spacing[reference].indent != base[reference].indent {
                line.indent = spacing[reference].indent + parts.indent.dropFirst(indent.count)
            }
            let around = [above[index], below[index]].compactMap(\.self)
            if let reference = Self.nearest(to: index, in: around).flatMap({ pairs[$0] }),
               parts.terminator == base[reference].terminator {
                line.terminator = spacing[reference].terminator
            }
            return line
        }

        /// The position in `positions`, which are in order, nearest to `index`: the one above on a tie.
        static func nearest(to index: Int, in positions: [Int]) -> Int? {
            var low = 0
            var high = positions.count
            while low < high {
                let middle = (low + high) / 2
                if positions[middle] < index {
                    low = middle + 1
                } else {
                    high = middle
                }
            }
            let candidates = [
                low > 0 ? positions[low - 1] : nil,
                low < positions.count ? positions[low] : nil
            ]
            return candidates.compactMap(\.self).min { abs($0 - index) < abs($1 - index) }
        }
    }
}

/// A line as its four parts: the whitespace before its text, the text, the whitespace after it,
/// and its ending. A blank line is all indentation. Whitespace is git's: a space or a tab.
struct LineParts: Equatable {
    var indent: [UInt8]
    var text: [UInt8]
    var trailing: [UInt8]
    var terminator: LineTerminator

    init(indent: [UInt8], text: [UInt8], trailing: [UInt8], terminator: LineTerminator) {
        self.indent = indent
        self.text = text
        self.trailing = trailing
        self.terminator = terminator
    }

    init(_ line: TextLine) {
        let bytes = Array(line.content.utf8)
        let start = bytes.firstIndex { !Self.isBlank($0) } ?? bytes.count
        let end = bytes.lastIndex { !Self.isBlank($0) }.map { $0 + 1 } ?? bytes.count
        indent = Array(bytes[..<start])
        text = Array(bytes[start..<end])
        trailing = Array(bytes[end...])
        terminator = line.terminator
    }

    var line: TextLine {
        TextLine(
            content: Substring(Self.decodeUTF8(indent + text + trailing)),
            terminator: terminator
        )
    }

    /// The non-failing decode, and exact here rather than lossy: the parts are a `String`'s own UTF-8
    /// cut at ASCII bytes, never inside a multi-byte sequence, so a failable decode would be a `nil`
    /// no line can produce.
    private static func decodeUTF8(_ bytes: [UInt8]) -> String {
        // swiftlint:disable:next optional_data_string_conversion
        String(decoding: bytes, as: UTF8.self)
    }

    private static func isBlank(_ byte: UInt8) -> Bool {
        byte == UInt8(ascii: " ") || byte == UInt8(ascii: "\t")
    }
}
