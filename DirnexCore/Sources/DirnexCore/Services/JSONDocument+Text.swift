import Foundation

/// What a JSON value reads as: a string's text, a value's path, and a container written out again —
/// indented for the strip under the tree and for ⌘C, compact for a table's cell (2026-09-15).
///
/// Written out from the values rather than reformatted from the source: the keys and scalars are
/// copied exactly as the file writes them, so `1.10` stays `1.10` and an escape stays an escape, and
/// the whitespace and comments between them are replaced.
extension JSONDocument {
    // MARK: - Scalars

    /// What a scalar says: a string's text with its escapes read, and a number, `true`, `false` or
    /// `null` as written. Empty for a container.
    ///
    /// - Parameter byteLimit: the most UTF-8 bytes of text wanted — what a cell draws — cut back to a
    ///   whole character.
    public func scalarText(of value: Int, byteLimit: Int = .max) -> String {
        var output: [UInt8] = []
        appendScalarText(of: value, to: &output, byteLimit: byteLimit)
        return Self.decodeUTF8(output)
    }

    /// Append what `scalarText` returns, as UTF-8 — or for a container, its compact JSON.
    func appendText(of value: Int, to output: inout [UInt8]) {
        if kind(of: value).isContainer {
            _ = writeJSON(value, indented: false, into: &output, byteLimit: .max)
        } else {
            appendScalarText(of: value, to: &output, byteLimit: .max)
        }
    }

    private func appendScalarText(of value: Int, to output: inout [UInt8], byteLimit: Int) {
        let node = nodes[value]
        let start = output.count
        switch node.kind {
        case .object, .array:
            return
        case .string:
            appendDecodedString(
                openingQuote: Int(node.valueStart),
                closingQuote: Int(node.valueEnd) - 1,
                hasEscapes: node.flags & Node.valueHasEscapes != 0,
                to: &output,
                byteLimit: byteLimit
            )
        case .number, .boolean, .null:
            let end = min(Int(node.valueEnd), Self.saturatingSum(Int(node.valueStart), byteLimit))
            output.append(contentsOf: bytes[Int(node.valueStart)..<end])
        }
        Self.cut(&output, toBytes: Self.saturatingSum(start, byteLimit))
    }

    /// `base + extra`, or `Int.max` where that would overflow — so `.max` can stand for no limit.
    static func saturatingSum(_ base: Int, _ extra: Int) -> Int {
        let (sum, overflows) = base.addingReportingOverflow(max(extra, 0))
        return overflows ? .max : sum
    }

    // MARK: - Strings

    /// The text between two quotes, its escapes read.
    func decodeString(openingQuote: Int, closingQuote: Int, hasEscapes: Bool) -> String {
        guard hasEscapes else {
            return Self.decodeUTF8(bytes[(openingQuote + 1)..<closingQuote])
        }
        var output: [UInt8] = []
        appendDecodedString(
            openingQuote: openingQuote,
            closingQuote: closingQuote,
            hasEscapes: true,
            to: &output,
            byteLimit: .max
        )
        return Self.decodeUTF8(output)
    }

    /// Append the text between two quotes, its escapes read, stopping once `byteLimit` bytes are
    /// appended. A `\u` escape of a lone surrogate — which no string can hold — reads as U+FFFD.
    private func appendDecodedString(
        openingQuote: Int,
        closingQuote: Int,
        hasEscapes: Bool,
        to output: inout [UInt8],
        byteLimit: Int
    ) {
        let first = openingQuote + 1
        let limit = Self.saturatingSum(output.count, byteLimit)
        guard hasEscapes else {
            let end = min(closingQuote, Self.saturatingSum(first, byteLimit))
            output.append(contentsOf: bytes[first..<end])
            return
        }
        var index = first
        while index < closingQuote, output.count < limit {
            let byte = bytes[index]
            guard byte == JSONByte.backslash else {
                output.append(byte)
                index += 1
                continue
            }
            let escape = bytes[index + 1]
            index += 2
            switch escape {
            case 0x62: output.append(0x08) // b
            case 0x66: output.append(0x0C) // f
            case 0x6E: output.append(JSONByte.lineFeed) // n
            case 0x72: output.append(JSONByte.carriageReturn) // r
            case 0x74: output.append(JSONByte.tab) // t
            case 0x75: // u
                var scalar = hex4(at: index)
                index += 4
                if scalar >= 0xD800, scalar <= 0xDBFF, index + 5 < closingQuote,
                   bytes[index] == JSONByte.backslash, bytes[index + 1] == 0x75 {
                    let low = hex4(at: index + 2)
                    if low >= 0xDC00, low <= 0xDFFF {
                        scalar = 0x10000 + ((scalar - 0xD800) << 10) + (low - 0xDC00)
                        index += 6
                    }
                }
                let resolved = Unicode.Scalar(scalar) ?? "\u{FFFD}"
                output.append(contentsOf: String(resolved).utf8)
            default:
                output.append(escape) // " \ /
            }
        }
    }

    private func hex4(at index: Int) -> UInt32 {
        (0..<4).reduce(0) { value, offset in
            value << 4 | (JSONByte.hexValue(bytes[index + offset]) ?? 0)
        }
    }

    /// The offset of the closing quote of the string whose opening quote is at `openingQuote`.
    func closingQuote(after openingQuote: Int) -> Int {
        var index = openingQuote + 1
        while index < bytes.count {
            switch bytes[index] {
            case JSONByte.backslash: index += 2
            case JSONByte.quote: return index
            default: index += 1
            }
        }
        return bytes.count
    }

    // MARK: - Paths

    /// Where `value` sits, as a JSONPath: `$` for the root, `.name` for a key that reads as an
    /// identifier, `["a key"]` for any other key, and `[3]` for an element. With several roots — a
    /// JSON Lines file — each is `$[n]`, as though the file were one array of them.
    public func path(of value: Int) -> String {
        var segments: [String] = []
        var current = value
        while let parent = parent(of: current) {
            if let key = key(of: current) {
                segments.append(Self.pathSegment(forKey: key))
            } else {
                segments.append("[\(position(of: current))]")
            }
            current = parent
        }
        if roots.count > 1 {
            segments.append("[\(position(of: current))]")
        }
        return "$" + segments.reversed().joined()
    }

    /// `.key`, or `["key"]` with the key escaped as a JSON string when it is not an identifier —
    /// letters in any script, digits after the first, `_` and `$`.
    static func pathSegment(forKey key: String) -> String {
        let isIdentifier = key.first.map { $0.isLetter || $0 == "_" || $0 == "$" } == true
            && key.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "$" }
        if isIdentifier { return "." + key }
        var escaped = ""
        for scalar in key.unicodeScalars {
            switch scalar {
            case "\"": escaped += "\\\""
            case "\\": escaped += "\\\\"
            case "\n": escaped += "\\n"
            case "\r": escaped += "\\r"
            case "\t": escaped += "\\t"
            default:
                if scalar.value < 0x20 {
                    escaped += String(format: "\\u%04x", scalar.value)
                } else {
                    escaped.unicodeScalars.append(scalar)
                }
            }
        }
        return "[\"" + escaped + "\"]"
    }

    // MARK: - Writing out

    /// `value` as indented JSON: two spaces a level, every key and scalar as the file writes it.
    /// Cut after `byteLimit` UTF-8 bytes, at a whole character, with `…` after the cut.
    public func formattedText(of value: Int, byteLimit: Int = .max) -> String {
        written(value, indented: true, byteLimit: byteLimit)
    }

    /// `value` as JSON with no whitespace — what a table cell shows for a nested value.
    public func compactText(of value: Int, byteLimit: Int = .max) -> String {
        written(value, indented: false, byteLimit: byteLimit)
    }

    private func written(_ value: Int, indented: Bool, byteLimit: Int) -> String {
        var output: [UInt8] = []
        let isWhole = writeJSON(value, indented: indented, into: &output, byteLimit: byteLimit)
        guard !isWhole || output.count > byteLimit else { return Self.decodeUTF8(output) }
        Self.cut(&output, toBytes: byteLimit)
        return Self.decodeUTF8(output) + "…"
    }

    /// Append `value` as JSON, and say whether all of it was written before `output` passed
    /// `byteLimit` bytes. With its own stack rather than recursion, for the reason the scanner has one.
    func writeJSON(_ value: Int, indented: Bool, into output: inout [UInt8], byteLimit: Int) -> Bool {
        var open: [(container: Int, next: Int)] = []
        var pendingValue: Int? = value
        while output.count <= byteLimit {
            if let current = pendingValue {
                pendingValue = nil
                let node = nodes[current]
                guard node.kind.isContainer else {
                    output.append(contentsOf: bytes[Int(node.valueStart)..<Int(node.valueEnd)])
                    continue
                }
                let isObject = node.kind == .object
                output.append(isObject ? JSONByte.openBrace : JSONByte.openBracket)
                if node.childCount == 0 {
                    output.append(isObject ? JSONByte.closeBrace : JSONByte.closeBracket)
                } else {
                    open.append((current, 0))
                }
                continue
            }
            guard let top = open.last else { return true }
            let container = nodes[top.container]
            let isObject = container.kind == .object
            guard top.next < Int(container.childCount) else {
                open.removeLast()
                if indented { Self.appendLineBreak(depth: open.count, to: &output) }
                output.append(isObject ? JSONByte.closeBrace : JSONByte.closeBracket)
                continue
            }
            if top.next > 0 { output.append(JSONByte.comma) }
            if indented { Self.appendLineBreak(depth: open.count, to: &output) }
            let element = child(top.next, of: top.container)
            if isObject {
                let keyStart = Int(nodes[element].keyStart)
                output.append(contentsOf: bytes[keyStart...closingQuote(after: keyStart)])
                output.append(JSONByte.colon)
                if indented { output.append(JSONByte.space) }
            }
            open[open.count - 1].next += 1
            pendingValue = element
        }
        return false
    }

    private static func appendLineBreak(depth: Int, to output: inout [UInt8]) {
        output.append(JSONByte.lineFeed)
        output.append(contentsOf: repeatElement(JSONByte.space, count: depth * 2))
    }

    /// Cut `output` to at most `limit` bytes, and back to the start of a character a cut split — which
    /// can be a cut made before this one, by a copy that stopped at the limit.
    static func cut(_ output: inout [UInt8], toBytes limit: Int) {
        if output.count > limit {
            output.removeSubrange(max(limit, 0)...)
        }
        guard let lead = output.lastIndex(where: { $0 & 0xC0 != 0x80 }) else { return }
        let byte = output[lead]
        let length = byte < 0x80 ? 1 : byte >= 0xF0 ? 4 : byte >= 0xE0 ? 3 : 2
        if output.count - lead < length {
            output.removeSubrange(lead...)
        }
    }
}
