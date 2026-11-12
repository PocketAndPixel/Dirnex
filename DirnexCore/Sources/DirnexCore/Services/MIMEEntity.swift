import Foundation

/// One MIME entity: its headers and its decoded body, or its parts when it is a multipart
/// (RFC 2045, RFC 2046). The subset an `.mhtml` needs, and no more (PLAN.md §M39).
///
/// Read as bytes rather than as a string, because a part's body is in whatever encoding its own header
/// names — a windows-1252 page beside a UTF-8 frame, in one file — and only the headers are ASCII.
/// Line endings are CRLF in what Chrome writes and LF in a file somebody edited, so both are accepted
/// everywhere a line ends.
///
/// Left out on purpose: RFC 2047 encoded words in header values, RFC 2231 parameter continuations, and
/// `message/rfc822` parts, none of which an archive's resources use.
public struct MIMEEntity: Sendable, Equatable {
    /// The headers in file order, names as written. ``header(_:)`` looks one up.
    public var headers: [(name: String, value: String)]
    /// The body with its transfer encoding undone. Empty for a multipart, whose content is ``parts``.
    public var body: Data
    /// The parts of a multipart, each an entity of its own. Empty for anything else.
    public var parts: [MIMEEntity]

    public static func == (lhs: MIMEEntity, rhs: MIMEEntity) -> Bool {
        lhs.headers.elementsEqual(rhs.headers) { $0.name == $1.name && $0.value == $1.value }
            && lhs.body == rhs.body && lhs.parts == rhs.parts
    }

    /// How deep multiparts nest before the rest are read as opaque bodies. An archive nests one level;
    /// the bound is for a file somebody built to make the reader recurse.
    public static let maximumDepth = 8

    /// The first header named `name`, compared without regard to case as RFC 5322 says.
    public func header(_ name: String) -> String? {
        headers.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    /// The parsed `Content-Type`, or RFC 2045's default, `text/plain`, when there is none.
    public var contentType: MIMEContentType {
        header("Content-Type").map(MIMEContentType.init(parsing:)) ?? MIMEContentType(
            type: "text/plain"
        )
    }

    /// The entity in `data`, or `nil` when the header block never ends: a file that is not MIME at all
    /// has no blank line after a run of `Name: value` lines.
    public init?(parsing data: Data) {
        self.init(bytes: [UInt8](data), depth: 0)
    }

    private init?(bytes: [UInt8], depth: Int) {
        guard let split = Self.headerEnd(in: bytes) else { return nil }
        let headers = Self.headers(in: bytes[..<split.headerEnd])
        func value(_ name: String) -> String? {
            headers.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
        }
        self.headers = headers
        let content = Array(bytes[split.bodyStart...])
        let type = value("Content-Type").map(MIMEContentType.init(parsing:))
        if let type, type.isMultipart, let boundary = type.parameter("boundary"), !boundary.isEmpty,
           depth + 1 < Self.maximumDepth {
            body = Data()
            parts = Self.split(content, boundary: Array(boundary.utf8)).compactMap {
                MIMEEntity(bytes: $0, depth: depth + 1)
            }
        } else {
            body = Self.decode(content, transferEncoding: value("Content-Transfer-Encoding"))
            parts = []
        }
    }

    /// Every entity that is not a multipart, in file order, nested multiparts flattened.
    public var leaves: [MIMEEntity] {
        parts.isEmpty ? [self] : parts.flatMap(\.leaves)
    }
}

// MARK: - Headers

extension MIMEEntity {
    /// Where the header block ends and the body begins: the first empty line. A part with no headers at
    /// all starts with one, and an entity whose headers run to the end of the data has an empty body.
    private static func headerEnd(in bytes: [UInt8]) -> (headerEnd: Int, bodyStart: Int)? {
        var lineStart = 0
        var index = 0
        while index < bytes.count {
            guard bytes[index] == lf else {
                index += 1
                continue
            }
            let lineEnd = index > lineStart && bytes[index - 1] == cr ? index - 1 : index
            if lineEnd == lineStart { return (lineStart, index + 1) }
            index += 1
            lineStart = index
        }
        // No blank line. Headers that end the data are still headers, but only if they read as such.
        guard lineStart == bytes.count, !bytes.isEmpty else { return nil }
        return (bytes.count, bytes.count)
    }

    /// The `Name: value` lines of a header block, a line that starts with a space or tab continuing
    /// the one before (RFC 5322's folding). A line with no colon is not a header and is skipped.
    private static func headers(in block: ArraySlice<UInt8>) -> [(name: String, value: String)] {
        var unfolded: [[UInt8]] = []
        for line in lines(block) {
            if let first = line.first, first == space || first == tab, !unfolded.isEmpty {
                unfolded[unfolded.count - 1] += [space] + line.drop { $0 == space || $0 == tab }
            } else {
                unfolded.append(Array(line))
            }
        }
        return unfolded.compactMap { line in
            guard let colon = line.firstIndex(of: UInt8(ascii: ":")) else { return nil }
            let name = headerText(line[..<colon]).trimmingCharacters(in: .whitespaces)
            let value = headerText(line[(colon + 1)...]).trimmingCharacters(in: .whitespaces)
            return name.isEmpty ? nil : (name, value)
        }
    }

    /// A header's bytes as text. Headers are ASCII (RFC 5322), so the non-failing decode is exact for
    /// every header that follows the rule, and one that breaks it keeps its other characters rather than
    /// vanishing whole, which a failable decode would make it do.
    private static func headerText(_ bytes: ArraySlice<UInt8>) -> String {
        // swiftlint:disable:next optional_data_string_conversion
        String(decoding: bytes, as: UTF8.self)
    }

    /// The lines of `bytes` without their endings, CRLF or LF.
    private static func lines(_ bytes: ArraySlice<UInt8>) -> [ArraySlice<UInt8>] {
        var lines: [ArraySlice<UInt8>] = []
        var start = bytes.startIndex
        var index = bytes.startIndex
        while index < bytes.endIndex {
            if bytes[index] == lf {
                let end = index > start && bytes[index - 1] == cr ? index - 1 : index
                lines.append(bytes[start..<end])
                start = index + 1
            }
            index += 1
        }
        if start < bytes.endIndex { lines.append(bytes[start...]) }
        return lines
    }
}

// MARK: - Multipart

extension MIMEEntity {
    /// The parts between the delimiter lines of a multipart body (RFC 2046 §5.1.1).
    ///
    /// A delimiter is a line that starts with `--` and the boundary, followed by nothing but optional
    /// whitespace, or by `--` for the last. The line ending *before* a delimiter belongs to the
    /// delimiter, so a part's bytes stop short of it. The preamble before the first delimiter and the
    /// epilogue after the last are not parts.
    private static func split(_ body: [UInt8], boundary: [UInt8]) -> [[UInt8]] {
        let dashes = [UInt8(ascii: "-"), UInt8(ascii: "-")]
        let delimiter = dashes + boundary
        var parts: [[UInt8]] = []
        var partStart: Int?
        var lineStart = 0
        while lineStart <= body.count {
            let newline = body[lineStart...].firstIndex(of: lf) ?? body.count
            let lineEnd = newline > lineStart && body[newline - 1] == cr ? newline - 1 : newline
            let line = body[lineStart..<lineEnd]
            if line.starts(with: delimiter) {
                let rest = line.dropFirst(delimiter.count)
                let isClose = rest.starts(with: dashes)
                let trailer = isClose ? rest.dropFirst(2) : rest
                if trailer.allSatisfy({ $0 == space || $0 == tab }) {
                    if let start = partStart {
                        // Drop the line ending that precedes this delimiter.
                        var end = lineStart
                        if end > start, body[end - 1] == lf { end -= 1 }
                        if end > start, body[end - 1] == cr { end -= 1 }
                        parts.append(Array(body[start..<max(start, end)]))
                    }
                    if isClose { return parts }
                    partStart = newline + 1
                }
            }
            lineStart = newline + 1
        }
        // No closing delimiter: whatever followed the last one is still a part.
        if let start = partStart, start < body.count { parts.append(Array(body[start...])) }
        return parts
    }
}

// MARK: - Transfer encodings

extension MIMEEntity {
    /// `bytes` with `encoding` undone. `7bit`, `8bit`, `binary`, none and anything unknown are the
    /// bytes as they stand: an unknown encoding cannot be undone, and showing its text beats showing
    /// nothing.
    static func decode(_ bytes: [UInt8], transferEncoding encoding: String?) -> Data {
        switch encoding?.trimmingCharacters(in: .whitespaces).lowercased() {
        case "base64": decodeBase64(bytes)
        case "quoted-printable": decodeQuotedPrintable(bytes)
        default: Data(bytes)
        }
    }

    /// Base64 with every byte outside the alphabet ignored — the line breaks, and any whitespace a
    /// mail system added — and the padding restored when it was cut.
    static func decodeBase64(_ bytes: [UInt8]) -> Data {
        var clean = bytes.filter { byte in
            (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(byte)
                || (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(byte)
                || (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
                || byte == UInt8(ascii: "+") || byte == UInt8(ascii: "/")
        }
        // A remainder of one cannot be a whole byte; drop it rather than refuse the part.
        if clean.count % 4 == 1 { clean.removeLast() }
        while clean.count % 4 != 0 { clean.append(UInt8(ascii: "=")) }
        return Data(base64Encoded: Data(clean)) ?? Data()
    }

    /// Quoted-printable (RFC 2045 §6.7): `=XX` is the byte `XX`, `=` at the end of a line joins it to
    /// the next, and an `=` followed by anything else stands for itself, as the RFC suggests a robust
    /// decoder do.
    static func decodeQuotedPrintable(_ bytes: [UInt8]) -> Data {
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count)
        var index = 0
        while index < bytes.count {
            let byte = bytes[index]
            guard byte == UInt8(ascii: "=") else {
                out.append(byte)
                index += 1
                continue
            }
            if index + 1 < bytes.count, bytes[index + 1] == lf {
                index += 2
            } else if index + 2 < bytes.count, bytes[index + 1] == cr, bytes[index + 2] == lf {
                index += 3
            } else if index + 2 < bytes.count, let high = hexValue(bytes[index + 1]),
                      let low = hexValue(bytes[index + 2]) {
                out.append(high << 4 | low)
                index += 3
            } else {
                out.append(byte)
                index += 1
            }
        }
        return Data(out)
    }

    private static func hexValue(_ byte: UInt8) -> UInt8? {
        switch byte {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): byte - UInt8(ascii: "0")
        case UInt8(ascii: "A")...UInt8(ascii: "F"): byte - UInt8(ascii: "A") + 10
        case UInt8(ascii: "a")...UInt8(ascii: "f"): byte - UInt8(ascii: "a") + 10
        default: nil
        }
    }
}

private let cr = UInt8(ascii: "\r")
private let lf = UInt8(ascii: "\n")
private let space = UInt8(ascii: " ")
private let tab = UInt8(ascii: "\t")

// MARK: - Content-Type

/// A `Content-Type` value: the media type and its parameters (RFC 2045 §5.1).
public struct MIMEContentType: Sendable, Equatable {
    /// `type/subtype`, lowercased: media types compare without regard to case.
    public var type: String
    /// Parameter names lowercased, values as written, a quoted value unquoted.
    public var parameters: [String: String]

    public init(type: String, parameters: [String: String] = [:]) {
        self.type = type.lowercased()
        self.parameters = parameters
    }

    /// Parse a header value such as `multipart/related; type="text/html"; boundary="--x--"`.
    public init(parsing value: String) {
        let fields = Self.fields(value)
        type = (fields.first ?? "").trimmingCharacters(in: .whitespaces).lowercased()
        var parameters: [String: String] = [:]
        for field in fields.dropFirst() {
            guard let equals = field.firstIndex(of: "=") else { continue }
            let name = field[..<equals].trimmingCharacters(in: .whitespaces).lowercased()
            var value = field[field.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") {
                value = String(value.dropFirst().dropLast())
                    .replacingOccurrences(of: "\\\"", with: "\"")
            }
            if !name.isEmpty, parameters[name] == nil { parameters[name] = value }
        }
        self.parameters = parameters
    }

    public var isMultipart: Bool { type.hasPrefix("multipart/") }

    public func parameter(_ name: String) -> String? { parameters[name.lowercased()] }

    /// The value split at the semicolons that are not inside a quoted string.
    private static func fields(_ value: String) -> [String] {
        var fields: [String] = []
        var current = ""
        var quoted = false
        var escaped = false
        for character in value {
            if escaped {
                current.append(character)
                escaped = false
            } else if character == "\\", quoted {
                current.append(character)
                escaped = true
            } else if character == "\"" {
                quoted.toggle()
                current.append(character)
            } else if character == ";", !quoted {
                fields.append(current)
                current = ""
            } else {
                current.append(character)
            }
        }
        fields.append(current)
        return fields
    }
}
