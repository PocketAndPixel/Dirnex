import Foundation

/// What an XML node reads as: an attribute's value and an element's text with their references read,
/// a node's path, and an element's source — dedented for the strip and ⌘C, on one line for a table's
/// cell (2026-09-16).
extension XMLTree {
    // MARK: - Values

    /// An attribute's value, with its references read and its whitespace normalized.
    public func attributeValue(of node: Int, byteLimit: Int = .max) -> String {
        var output: [UInt8] = []
        appendText(of: node, to: &output, byteLimit: byteLimit)
        return JSONDocument.decodeUTF8(output)
    }

    /// The text `node` holds: an element's content with its comments and processing instructions left
    /// out, its CDATA unwrapped and its references read — or a text node's, or an attribute's value.
    /// Whitespace around it is kept; `trimmedText` takes it off.
    public func text(of node: Int, byteLimit: Int = .max) -> String {
        var output: [UInt8] = []
        appendText(of: node, to: &output, byteLimit: byteLimit)
        return JSONDocument.decodeUTF8(output)
    }

    /// `text(of:)` without the whitespace around it — what a cell, the strip and ⌘C show. XML's own
    /// whitespace only (space, tab, line feed, carriage return), so a no-break or zero-width space a file
    /// opens a value with is kept.
    public func trimmedText(of node: Int, byteLimit: Int = .max) -> String {
        // Past the limit only by the whitespace a leading run may take, so a cell never decodes a
        // megabyte to show a line.
        var output: [UInt8] = []
        appendText(of: node, to: &output, byteLimit: JSONDocument.saturatingSum(byteLimit, 4096))
        let first = output.firstIndex { !XMLByte.isWhitespace($0) } ?? output.endIndex
        let last = output.lastIndex { !XMLByte.isWhitespace($0) }.map { $0 + 1 } ?? first
        var trimmed = Array(output[first..<max(first, last)])
        JSONDocument.cut(&trimmed, toBytes: byteLimit)
        return JSONDocument.decodeUTF8(trimmed)
    }

    func appendText(of node: Int, to output: inout [UInt8], byteLimit: Int) {
        let entry = nodes[node]
        switch entry.kind {
        case .attribute, .text:
            appendText(
                from: Int(entry.start),
                to: Int(entry.end),
                reading: entry.flags & Node.needsDecoding == 0 ? .asWritten
                    : entry.kind == .attribute ? .attributeValue
                    : entry.flags & Node.isCDATA != 0 ? .characterData : .text,
                to: &output,
                byteLimit: byteLimit
            )
        case .element:
            guard entry.flags & Node.contentHasMarkup != 0 else {
                appendText(
                    from: Int(entry.contentStart),
                    to: Int(entry.contentEnd),
                    reading: .asWritten,
                    to: &output,
                    byteLimit: byteLimit
                )
                return
            }
            appendContent(of: entry, to: &output, byteLimit: byteLimit)
        }
    }

    /// How a run of bytes becomes text.
    private enum Reading {
        /// The bytes are the text.
        case asWritten
        /// References read, and a carriage return read as a line break.
        case text
        /// A carriage return read as a line break, and nothing else: CDATA.
        case characterData
        /// References read, and a carriage return, line feed or tab read as a space — one space for a
        /// carriage return and line feed together.
        case attributeValue
    }

    /// An element's content read as text: comments and processing instructions skipped, CDATA
    /// unwrapped, references read, and stopping at a tag — which in a leaf only a cut can leave.
    private func appendContent(of entry: Node, to output: inout [UInt8], byteLimit: Int) {
        let end = Int(entry.contentEnd)
        let limit = JSONDocument.saturatingSum(output.count, byteLimit)
        var index = Int(entry.contentStart)
        while index < end, output.count < limit {
            guard bytes[index] == XMLByte.lessThan else {
                var runEnd = index
                while runEnd < end, bytes[runEnd] != XMLByte.lessThan {
                    runEnd += 1
                }
                appendText(
                    from: index,
                    to: runEnd,
                    reading: .text,
                    to: &output,
                    byteLimit: limit - output.count
                )
                index = runEnd
                continue
            }
            if matches(XMLByte.commentOpen, at: index) {
                index = find(XMLByte.commentClose, from: index + 4, before: end)
                    .map { $0 + XMLByte.commentClose.count } ?? end
            } else if matches(XMLByte.cdataOpen, at: index) {
                let start = index + XMLByte.cdataOpen.count
                let close = find(XMLByte.cdataClose, from: start, before: end)
                appendText(
                    from: start,
                    to: close ?? end,
                    reading: .characterData,
                    to: &output,
                    byteLimit: limit - output.count
                )
                index = close.map { $0 + XMLByte.cdataClose.count } ?? end
            } else if index + 1 < end, bytes[index + 1] == XMLByte.question {
                index = find(XMLByte.instructionClose, from: index + 2, before: end)
                    .map { $0 + XMLByte.instructionClose.count } ?? end
            } else {
                return
            }
        }
        JSONDocument.cut(&output, toBytes: limit)
    }

    /// Append `bytes[start..<end]` read as `reading` says, stopping once `byteLimit` bytes are
    /// appended — cut back to a whole character.
    private func appendText(
        from start: Int,
        to end: Int,
        reading: Reading,
        to output: inout [UInt8],
        byteLimit: Int
    ) {
        let limit = JSONDocument.saturatingSum(output.count, byteLimit)
        guard reading != .asWritten else {
            output.append(
                contentsOf: bytes[start..<min(end, JSONDocument.saturatingSum(start, byteLimit))]
            )
            JSONDocument.cut(&output, toBytes: limit)
            return
        }
        let breakByte = reading == .attributeValue ? XMLByte.space : XMLByte.lineFeed
        var index = start
        while index < end, output.count < limit {
            let byte = bytes[index]
            index += 1
            switch byte {
            case XMLByte.carriageReturn:
                output.append(breakByte)
                if index < end, bytes[index] == XMLByte.lineFeed { index += 1 }
            case XMLByte.lineFeed where reading == .attributeValue,
                 XMLByte.tab where reading == .attributeValue:
                output.append(XMLByte.space)
            case XMLByte.ampersand where reading != .characterData:
                guard let (character, next) = reference(at: index - 1, before: end) else {
                    output.append(byte)
                    continue
                }
                output.append(contentsOf: String(character).utf8)
                index = next
            default:
                output.append(byte)
            }
        }
        JSONDocument.cut(&output, toBytes: limit)
    }

    /// The character the reference at `start` stands for, and the offset past its `;` — or `nil` for
    /// an entity this does not read, which is then shown as written. A character reference to a
    /// scalar no string can hold reads as U+FFFD.
    private func reference(at start: Int, before end: Int) -> (Character, Int)? {
        var semicolon = start + 1
        while semicolon < end, semicolon - start <= 12, bytes[semicolon] != XMLByte.semicolon {
            semicolon += 1
        }
        guard semicolon < end, bytes[semicolon] == XMLByte.semicolon, semicolon > start + 1 else {
            return nil
        }
        let name = bytes[(start + 1)..<semicolon]
        if name.first == XMLByte.hash {
            let digits = name.dropFirst()
            let isHex = digits.first == 0x78 // x
            let body = isHex ? digits.dropFirst() : digits
            guard !body.isEmpty else { return nil }
            var value: UInt32 = 0
            for digit in body {
                let figure = isHex ? JSONByte.hexValue(digit)
                    : JSONByte.isDigit(digit) ? UInt32(digit - 0x30) : nil
                guard let figure else { return nil }
                value = value > 0x10FFFF ? value : value * (isHex ? 16 : 10) + figure
            }
            return (Character(Unicode.Scalar(value) ?? "\u{FFFD}"), semicolon + 1)
        }
        let character: Character? = switch Array(name) {
        case Array("lt".utf8): "<"
        case Array("gt".utf8): ">"
        case Array("amp".utf8): "&"
        case Array("quot".utf8): "\""
        case Array("apos".utf8): "'"
        default: nil
        }
        return character.map { ($0, semicolon + 1) }
    }

    private func matches(_ marker: [UInt8], at index: Int) -> Bool {
        index + marker.count <= bytes.count
            && marker.indices.allSatisfy { bytes[index + $0] == marker[$0] }
    }

    /// Where the next `marker` at or after `start` begins, or `nil` when none ends before `end`.
    private func find(_ marker: [UInt8], from start: Int, before end: Int) -> Int? {
        var index = start
        while index + marker.count <= end {
            if matches(marker, at: index) { return index }
            index += 1
        }
        return nil
    }

    // MARK: - Summaries

    /// An element's attributes as written, `name="value"` one after another — what a row shows for an
    /// element whose attributes are what there is to say before it is opened.
    public func attributeSummary(of node: Int, byteLimit: Int = TreeLabel.cellTextLimit) -> String {
        var output: [UInt8] = []
        for attribute in attributes(of: node) {
            let entry = nodes[attribute]
            if !output.isEmpty { output.append(XMLByte.space) }
            output.append(contentsOf: bytes[Int(entry.nameStart)..<Int(entry.nameEnd)])
            output.append(XMLByte.equals)
            output.append(XMLByte.quote)
            output.append(contentsOf: bytes[Int(entry.start)..<Int(entry.end)])
            output.append(XMLByte.quote)
            guard output.count <= byteLimit else {
                JSONDocument.cut(&output, toBytes: byteLimit)
                return JSONDocument.decodeUTF8(output) + "…"
            }
        }
        return JSONDocument.decodeUTF8(output)
    }

    // MARK: - Paths

    /// Where `node` sits, as an XPath: `/root/child` from the top, with `[n]` after a name that more
    /// than one sibling element has, counting from 1; `/@name` for an attribute; and `/text()` for a
    /// text, with `[n]` when its element holds more than one.
    public func path(of node: Int) -> String {
        var segments: [String] = []
        var current = node
        while true {
            let up = parent(of: current)
            let siblings = up.map(content(of:)) ?? roots
            switch kind(of: current) {
            case .attribute:
                segments.append("@" + name(of: current))
            case .text:
                let texts = siblings.filter { kind(of: $0) == .text }
                let index = texts.firstIndex(of: current).map { $0 + 1 } ?? 1
                segments.append(texts.count > 1 ? "text()[\(index)]" : "text()")
            case .element:
                let entry = nodes[current]
                let own = Array(bytes[Int(entry.nameStart)..<Int(entry.nameEnd)])
                let named = siblings.filter { kind(of: $0) == .element && hasName($0, own) }
                let index = named.firstIndex(of: current).map { $0 + 1 } ?? 1
                segments.append(
                    named.count > 1 ? "\(name(of: current))[\(index)]" : name(of: current)
                )
            }
            guard let up else { break }
            current = up
        }
        return "/" + segments.reversed().joined(separator: "/")
    }

    // MARK: - Source

    /// An element as the file writes it, each line after its first taken back by the indentation of
    /// the line it starts on, so it reads as though it were a file of its own.
    public func dedentedSource(of node: Int, byteLimit: Int = .max) -> String {
        let entry = nodes[node]
        let start = Int(entry.start)
        var lineStart = start
        while lineStart > 0, bytes[lineStart - 1] == XMLByte.space || bytes[lineStart - 1] == XMLByte.tab {
            lineStart -= 1
        }
        let atLineStart = lineStart == 0 || bytes[lineStart - 1] == XMLByte.lineFeed
            || bytes[lineStart - 1] == XMLByte.carriageReturn
        let indent = atLineStart ? start - lineStart : 0
        var output: [UInt8] = []
        var index = start
        let end = Int(entry.end)
        while index < end, output.count <= byteLimit {
            let byte = bytes[index]
            output.append(byte)
            index += 1
            guard byte == XMLByte.lineFeed else { continue }
            var skipped = 0
            while skipped < indent, index < end,
                  bytes[index] == XMLByte.space || bytes[index] == XMLByte.tab {
                index += 1
                skipped += 1
            }
        }
        guard index < end || output.count > byteLimit else { return JSONDocument.decodeUTF8(output) }
        JSONDocument.cut(&output, toBytes: byteLimit)
        return JSONDocument.decodeUTF8(output) + "…"
    }

    /// An element as the file writes it on one line: the whitespace between two tags that holds a line
    /// break — the file's indentation — left out. What a table's cell shows for an element holding
    /// elements.
    func appendCompactSource(of node: Int, to output: inout [UInt8]) {
        let entry = nodes[node]
        appendCompact(from: Int(entry.start), to: Int(entry.end), to: &output)
    }

    /// What an element holds, between its tags, on one line and without the whitespace around it —
    /// what a table's cell shows for a record whose text sits beside elements.
    func appendCompactContent(of node: Int, to output: inout [UInt8]) {
        let entry = nodes[node]
        var start = Int(entry.contentStart)
        var end = Int(entry.contentEnd)
        while start < end, XMLByte.isWhitespace(bytes[start]) {
            start += 1
        }
        while end > start, XMLByte.isWhitespace(bytes[end - 1]) {
            end -= 1
        }
        appendCompact(from: start, to: end, to: &output)
    }

    private func appendCompact(from start: Int, to end: Int, to output: inout [UInt8]) {
        let first = output.count
        var index = start
        while index < end {
            let byte = bytes[index]
            guard XMLByte.isWhitespace(byte), output.count > first, output.last == XMLByte.greaterThan else {
                output.append(byte)
                index += 1
                continue
            }
            var runEnd = index
            var hasBreak = false
            while runEnd < end, XMLByte.isWhitespace(bytes[runEnd]) {
                if bytes[runEnd] == XMLByte.lineFeed || bytes[runEnd] == XMLByte.carriageReturn {
                    hasBreak = true
                }
                runEnd += 1
            }
            if !(hasBreak && runEnd < end && bytes[runEnd] == XMLByte.lessThan) {
                output.append(contentsOf: bytes[index..<runEnd])
            }
            index = runEnd
        }
    }
}
