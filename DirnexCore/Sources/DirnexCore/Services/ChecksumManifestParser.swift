import Foundation

public extension ChecksumManifest {
    /// Parse a checksum file's text.
    ///
    /// - Parameters:
    ///   - text: The whole file. Line endings may be LF, CRLF or bare CR; a missing trailing
    ///     newline is fine; blank lines and `;` / `#` comments are skipped.
    ///   - implicitName: The name a bare-digest line refers to — see
    ///     ``ChecksumManifest/impliedName(forManifestFileName:)``. `crc32`'s own output is nothing
    ///     but the hex, so without this the entry has no name to verify against.
    ///
    /// - Throws: ``ChecksumError/manifestUnreadable`` when no line parsed, and
    ///   ``ChecksumError/manifestMixesAlgorithms(first:second:)`` on the first line whose digest
    ///   width disagrees with the ones before it.
    static func parse(_ text: String, implicitName: String? = nil) throws -> ChecksumManifest {
        try ChecksumManifestParser.parse(text, implicitName: implicitName)
    }

    /// Parse a checksum file's bytes, choosing an encoding from its BOM.
    ///
    /// A checksum file is normally plain ASCII, but the names in it are not: a `.sfv` written on
    /// Windows can be UTF-16, and a Notepad-saved one carries a UTF-8 BOM that would otherwise
    /// become part of the first line's digest. Falls back to Latin-1, which cannot fail, rather
    /// than refusing a file over one undecodable byte in a name.
    static func parse(_ data: Data, implicitName: String? = nil) throws -> ChecksumManifest {
        try parse(ChecksumManifestParser.decode(data), implicitName: implicitName)
    }
}

/// The tolerant reader behind ``ChecksumManifest/parse(_:implicitName:)``.
///
/// It accepts every shape the M14 probe captured from the real tools on macOS 26 — which is the
/// actual user-facing advantage over the stock ones, since `shasum -c` refuses the `openssl` and
/// BSD forms outright:
///
/// | Producer | Line |
/// |---|---|
/// | `shasum`, `md5sum`, `sha256sum` | `<hex>␣␣<name>` |
/// | `shasum -b` | `<hex>␣*<name>` |
/// | BSD `md5` | `MD5 (<name>) = <hex>` |
/// | `openssl dgst` | `SHA256(<name>)= <hex>` |
/// | `md5 -r` | `<hex>␣<name>` |
/// | `crc32`, `.sfv` | bare `<hex>`, and `<name>␣<hex>` with `;` comments |
///
/// **Escaping differs between two tools that ship on the same Mac**, which the probe found and
/// which no amount of format documentation would have: for a name containing a backslash,
/// `shasum` writes `\<hex>␣␣back\\slash.txt` — a leading `\` marks the line and the name is escaped
/// — while Apple's `/sbin/sha256sum` (Darwin 1.0) writes `<hex>␣␣back\slash.txt` raw. Both must
/// come back as `back\slash.txt`, so the leading marker is what decides whether to unescape.
enum ChecksumManifestParser {
    /// One successfully read line: the entry, and the algorithm its digest width implies.
    private struct Parsed {
        let entry: ChecksumManifestEntry
        let algorithm: ChecksumAlgorithm
    }

    static func parse(_ text: String, implicitName: String?) throws -> ChecksumManifest {
        var entries: [ChecksumManifestEntry] = []
        var unrecognized: [Int] = []
        var algorithm: ChecksumAlgorithm?

        // `isNewline`, not `$0 == "\n" || $0 == "\r"`: Swift groups CRLF into a *single*
        // `Character`, which equals neither — so the explicit comparison silently fails to split a
        // Windows-written file at all and reads the whole thing as one unparseable line. It also
        // keeps the line numbers below honest, since CRLF stays one separator rather than two.
        let lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        for (index, rawLine) in lines.enumerated() {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix(";") || line.hasPrefix("#") { continue }
            guard let parsed = parseLine(line, implicitName: implicitName) else {
                unrecognized.append(index + 1)
                continue
            }
            if let algorithm, algorithm != parsed.algorithm {
                throw ChecksumError.manifestMixesAlgorithms(
                    first: algorithm,
                    second: parsed.algorithm
                )
            }
            algorithm = parsed.algorithm
            entries.append(parsed.entry)
        }

        guard let algorithm, !entries.isEmpty else { throw ChecksumError.manifestUnreadable }
        return ChecksumManifest(
            algorithm: algorithm,
            entries: entries,
            unrecognizedLines: unrecognized
        )
    }

    /// Decode a checksum file's bytes. UTF-32's little-endian BOM *starts with* UTF-16 LE's, so it
    /// is tested first (docs/NOTES.md); Latin-1 is the fallback because it decodes any byte.
    static func decode(_ data: Data) -> String {
        let boms: [(marker: [UInt8], encoding: String.Encoding)] = [
            ([0xEF, 0xBB, 0xBF], .utf8),
            ([0xFF, 0xFE, 0x00, 0x00], .utf32LittleEndian),
            ([0x00, 0x00, 0xFE, 0xFF], .utf32BigEndian),
            ([0xFF, 0xFE], .utf16LittleEndian),
            ([0xFE, 0xFF], .utf16BigEndian)
        ]
        for bom in boms where data.starts(with: bom.marker) {
            if let text = String(data: data.dropFirst(bom.marker.count), encoding: bom.encoding) {
                return text
            }
        }
        return String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1)
            ?? ""
    }

    // MARK: - One line

    /// The order is the disambiguation. A line whose *name* happens to be all hex — `deadbeef
    /// 4dbf2cc1` — could be read either way; the leading-digest reading wins, because that is what
    /// every GNU-family tool produces and `.sfv` files carry `;` headers and real names in
    /// practice.
    private static func parseLine(_ line: String, implicitName: String?) -> Parsed? {
        parseLeadingDigest(line, implicitName: implicitName)
            ?? parseLabelled(line)
            ?? parseTrailingDigest(line)
    }

    /// `<hex>␣␣<name>` · `<hex>␣*<name>` · `<hex>␣<name>` · bare `<hex>`, with the optional leading
    /// `\` escape marker.
    private static func parseLeadingDigest(_ line: String, implicitName: String?) -> Parsed? {
        var body = Substring(line)
        let isEscaped = body.hasPrefix("\\")
        if isEscaped { body = body.dropFirst() }

        let hex = body.prefix(while: isHexDigit)
        guard let algorithm = ChecksumAlgorithm(hexDigitCount: hex.count) else { return nil }
        var rest = body.dropFirst(hex.count)

        // Bare hex: `crc32` prints nothing else, and a `.crc` companion's whole content is this.
        if rest.isEmpty {
            guard !isEscaped else { return nil }
            return Parsed(
                entry: ChecksumManifestEntry(name: implicitName ?? "", digest: hex.lowercased()),
                algorithm: algorithm
            )
        }

        guard let separator = rest.first, separator == " " || separator == "\t" else { return nil }
        rest = rest.dropFirst()
        // GNU's second column is the mode marker: two spaces for text, ` *` for binary. `md5 -r`
        // has no such column, so anything else is already the name. `U` and `^` (GNU's universal
        // and BSD-reversed modes) are deliberately not treated as markers — nothing on macOS emits
        // them, and doing so would eat the first letter of any `md5 -r` name starting with one.
        var isBinary = false
        if let marker = rest.first, marker == "*" || marker == " " {
            isBinary = marker == "*"
            rest = rest.dropFirst()
        }
        guard !rest.isEmpty else { return nil }

        let name = isEscaped ? unescaped(String(rest)) : String(rest)
        return Parsed(
            entry: ChecksumManifestEntry(
                name: normalized(name),
                digest: hex.lowercased(),
                isBinary: isBinary
            ),
            algorithm: algorithm
        )
    }

    /// `MD5 (<name>) = <hex>` (BSD `md5`) and `SHA256(<name>)= <hex>` (`openssl dgst`).
    ///
    /// The *last* `)` closes the name, not the first: a name may contain parentheses, and a hex
    /// digest never can.
    private static func parseLabelled(_ line: String) -> Parsed? {
        guard let open = line.firstIndex(of: "("),
              let close = line.lastIndex(of: ")"),
              open < close,
              let algorithm = ChecksumAlgorithm(
                  label: String(line[line.startIndex..<open]).trimmingCharacters(in: .whitespaces)
              )
        else { return nil }

        var tail = line[line.index(after: close)...].drop(while: isBlank)
        guard tail.first == "=" else { return nil }
        tail = tail.dropFirst().drop(while: isBlank)
        guard tail.count == algorithm.hexDigitCount, tail.allSatisfy(isHexDigit) else { return nil }

        let name = String(line[line.index(after: open)..<close])
        guard !name.isEmpty else { return nil }
        return Parsed(
            entry: ChecksumManifestEntry(name: normalized(name), digest: tail.lowercased()),
            algorithm: algorithm
        )
    }

    /// `<name>␣<hex>` — the `.sfv` layout. The name may contain spaces, so the digest is the last
    /// whitespace-separated token and everything before it is the name.
    private static func parseTrailingDigest(_ line: String) -> Parsed? {
        guard let lastBlank = line.lastIndex(where: isBlank) else { return nil }
        let hex = line[line.index(after: lastBlank)...]
        guard hex.allSatisfy(isHexDigit),
              let algorithm = ChecksumAlgorithm(hexDigitCount: hex.count)
        else { return nil }

        let name = String(line[line.startIndex..<lastBlank])
            .trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return nil }
        return Parsed(
            entry: ChecksumManifestEntry(name: normalized(name), digest: hex.lowercased()),
            algorithm: algorithm
        )
    }

    // MARK: - Characters and names

    /// ASCII hex only. `Character.isHexDigit` also answers `true` for fullwidth and other Unicode
    /// digit forms, which would let a name be read as a digest.
    private static func isHexDigit(_ character: Character) -> Bool {
        character.isASCII && character.isHexDigit
    }

    private static func isBlank(_ character: Character) -> Bool {
        character == " " || character == "\t"
    }

    /// `./file` and `file` name the same thing; nothing else about a name is touched, because it
    /// has to match a real directory entry byte for byte.
    private static func normalized(_ name: String) -> String {
        name.hasPrefix("./") ? String(name.dropFirst(2)) : name
    }

    /// Undo `shasum`'s escaping, left to right so an escaped backslash can't be re-read as the
    /// start of the next escape. An unknown escape is left alone rather than swallowed — the name
    /// on disk is the authority, and inventing a character is worse than keeping a literal one.
    private static func unescaped(_ name: String) -> String {
        var result = ""
        var iterator = name.makeIterator()
        while let character = iterator.next() {
            guard character == "\\" else {
                result.append(character)
                continue
            }
            switch iterator.next() {
            case "\\": result.append("\\")
            case "n": result.append("\n")
            case "r": result.append("\r")
            case let other?: result.append("\\"); result.append(other)
            case nil: result.append("\\")
            }
        }
        return result
    }
}
