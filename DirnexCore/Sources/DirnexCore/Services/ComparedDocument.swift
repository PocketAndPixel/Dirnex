import Foundation

/// One side of a comparison as lines that can change, and the way back to the file's bytes (PLAN.md
/// §M33 Slice 1).
///
/// The compare window edits lines, never characters. Copying a change across replaces some lines
/// with others (`LineEdit`), and a save encodes the lines with the encoding and byte-order mark the
/// file was read with. Each line keeps its own ending, so a line nobody touched is written back as
/// it was read, byte for byte.
///
/// That holds only where reading and writing are exact inverses, so a document is written back once
/// as soon as it is read, and `isSavable` says whether that gave the same bytes. Two kinds of
/// file fail it: Foundation drops a second UTF-8 byte-order mark after the first, and an odd byte at
/// the end of a UTF-16 file. Probed 2026-10-25, nothing else did, over every version of every text
/// file in this repository's history (7 449) and every text file on the development Mac (555 676, in
/// 25 encodings).
public struct ComparedDocument: Sendable {
    /// The lines as they stand, edits included. Only the last can lack a line break.
    public private(set) var lines: [TextLine]
    public let encoding: String.Encoding
    public let hasByteOrderMark: Bool
    /// Whether writing the unedited lines back gave the file's own bytes. When it did not, a save
    /// would change bytes nobody edited, so the side opens read-only and the window says why.
    public let isSavable: Bool
    /// The line ending lines copied in take: the one most of the file's lines ended in as it was
    /// read, the first met on a tie. `nil` for a file with no line break at all.
    public let commonLineEnding: LineTerminator?
    /// The lines the file holds, as read or as last saved, which `isEdited` compares with.
    private var readLines: [TextLine]

    /// Why the lines cannot be written in the document's encoding.
    public enum EncodingFailure: Error, Equatable {
        /// `character`, on line `line` (counted from 0), has no bytes in the encoding. A save
        /// refuses it by name rather than write something else in its place.
        case unencodable(line: Int, character: Character)
    }

    init(
        lines: [TextLine],
        encoding: String.Encoding,
        hasByteOrderMark: Bool,
        isSavable: Bool
    ) {
        self.lines = lines
        self.encoding = encoding
        self.hasByteOrderMark = hasByteOrderMark
        self.isSavable = isSavable
        commonLineEnding = Self.commonLineEnding(of: lines)
        readLines = lines
    }

    /// Read a whole local file, refusing what `ComparedText.read` refuses. Blocking; call it off
    /// the main thread.
    public static func read(
        contentsOf url: URL,
        byteLimit: Int64 = ByteComparator.prescanByteLimit
    ) throws(ComparedText.Failure) -> ComparedDocument {
        try decode(ComparedText.contents(of: url, byteLimit: byteLimit))
    }

    /// Decode a whole file's bytes as `ComparedText` does, and check they come back unchanged.
    public static func decode(_ data: Data) throws(ComparedText.Failure) -> ComparedDocument {
        let text = try ComparedText.decode(data)
        let lines = TextLines.split(text.text)
        let written = try? encode(
            lines,
            encoding: text.encoding,
            hasByteOrderMark: text.hasByteOrderMark
        )
        return ComparedDocument(
            lines: lines,
            encoding: text.encoding,
            hasByteOrderMark: text.hasByteOrderMark,
            isSavable: written == data
        )
    }

    /// The first `count` lines as text, each with its ending.
    public func text(ofFirstLines count: Int) -> String {
        lines.prefix(count).reduce(into: "") { text, line in
            text += line.content
            text += line.terminator.text
        }
    }

    // MARK: - Editing

    /// Whether any line differs from the file as read or last saved, by its bytes or its ending. An
    /// edit undone, or copied back by hand, leaves the document unedited.
    public var isEdited: Bool {
        guard lines.count == readLines.count else { return true }
        return zip(lines, readLines).contains { !Self.sameBytes($0, $1) }
    }

    /// Note that the file now holds `saved`: the lines of a copy of this document that was saved.
    /// Edits made while the save ran stay edits, and an undo past the save makes the document
    /// edited again.
    public mutating func markSaved(_ saved: [TextLine]) {
        readLines = saved
    }

    /// Apply `edit`, and return the edit that undoes it.
    @discardableResult
    public mutating func apply(_ edit: LineEdit) -> LineEdit {
        precondition(edit.range.upperBound <= lines.count, "an edit past the document's end")
        let removed = Array(lines[edit.range])
        lines.replaceSubrange(edit.range, with: edit.replacement)
        let end = edit.range.lowerBound + edit.replacement.count
        // A line that lacks a line break anywhere but last would join the next one in the file.
        let first = max(0, edit.range.lowerBound - 1)
        let last = min(end, lines.count - 1)
        precondition(
            first >= last || !lines[first..<last].contains { $0.terminator == .none },
            "a line with no line break ahead of another"
        )
        return LineEdit(range: edit.range.lowerBound..<end, replacement: removed)
    }

    // MARK: - Writing

    /// The lines as bytes: the byte-order mark the file had, then each line in the document's
    /// encoding with its own ending.
    ///
    /// Unicode holds every character, so only a legacy encoding can refuse one, and it is then
    /// named with its line. Foundation composes a decomposed character on the way, so `e` with a
    /// combining acute is written as Latin-1's `é`: the same text, in the only bytes the encoding
    /// has for it.
    public func encoded() throws(EncodingFailure) -> Data {
        try Self.encode(lines, encoding: encoding, hasByteOrderMark: hasByteOrderMark)
    }

    /// Lines encoded one at a time, so a line that fails is the one named. `decode` checks the
    /// result against the file, which would catch an encoding whose state ran across lines.
    static func encode(
        _ lines: [TextLine],
        encoding: String.Encoding,
        hasByteOrderMark: Bool
    ) throws(EncodingFailure) -> Data {
        var data = Data(hasByteOrderMark ? TextPreview.byteOrderMark(for: encoding) ?? [] : [])
        if encoding == .utf8 {
            for line in lines {
                data.append(contentsOf: line.content.utf8)
                data.append(contentsOf: line.terminator.text.utf8)
            }
            return data
        }
        for (index, line) in lines.enumerated() {
            let text = String(line.content) + line.terminator.text
            guard let bytes = text.data(using: encoding, allowLossyConversion: false) else {
                throw unencodable(text, line: index, encoding: encoding)
            }
            data.append(bytes)
        }
        return data
    }

    /// The character of `text` the encoding cannot hold: the last one of the shortest prefix it
    /// cannot encode.
    private static func unencodable(
        _ text: String,
        line: Int,
        encoding: String.Encoding
    ) -> EncodingFailure {
        let characters = Array(text)
        var encodes = 0
        var fails = characters.count
        while fails - encodes > 1 {
            let middle = (encodes + fails) / 2
            if String(characters[..<middle]).data(using: encoding, allowLossyConversion: false)
                != nil {
                encodes = middle
            } else {
                fails = middle
            }
        }
        return .unencodable(line: line, character: characters[fails - 1])
    }

    // MARK: - Lines

    private static func sameBytes(_ first: TextLine, _ second: TextLine) -> Bool {
        first.terminator == second.terminator
            && first.content.utf8.elementsEqual(second.content.utf8)
    }

    private static func commonLineEnding(of lines: [TextLine]) -> LineTerminator? {
        var counts: [LineTerminator: Int] = [:]
        var firstMet: [LineTerminator] = []
        for line in lines where line.terminator != .none {
            if counts[line.terminator] == nil {
                firstMet.append(line.terminator)
            }
            counts[line.terminator, default: 0] += 1
        }
        var common: LineTerminator?
        var commonCount = 0
        for ending in firstMet where counts[ending, default: 0] > commonCount {
            common = ending
            commonCount = counts[ending, default: 0]
        }
        return common
    }
}
