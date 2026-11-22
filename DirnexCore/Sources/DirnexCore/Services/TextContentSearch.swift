import Foundation

/// Finds text inside a local file by reading its bytes: what "Content contains" means where Spotlight
/// has no index to ask (PLAN.md §M40 Slice 3).
///
/// **Plain text only.** A file is read as UTF-8, or as UTF-16 when its first bytes say so, and
/// anything else is skipped as binary, unread past its first 8 KiB. So nothing inside a PDF, a Word
/// document or a compressed file is found, which Spotlight finds through importers this has no
/// counterpart for. The Find Files dialog says so where this is what runs.
///
/// **Matched as Spotlight's content clause is**, case- and diacritic-insensitively (the `cd` on
/// `kMDItemTextContent`), so "cafe" finds "Café", "strasse" finds "Straße" and "іжак" finds "Їжак".
/// Through `NSString.range(of:options:)`, which was measured 2026-11-18 at 240 MB/s over ASCII and
/// 110 MB/s over Cyrillic in a Release build, against 13 and 9 MB/s for Swift's own
/// `String.range(of:options:)` on the same chunks.
///
/// Read in chunks of ``chunkSize``, so a file of any size costs one chunk of memory, and Stop is
/// polled before each read.
public enum TextContentSearch {
    /// How much is read at a time.
    public static let chunkSize = 1 << 20
    /// How much of the start decides whether a file is text: git's own rule, a NUL in the first
    /// 8 000 or so bytes, rounded to a page.
    static let sniffLength = 8192

    /// Whether the file at `path` holds `needle` as text.
    ///
    /// `false` for a file that cannot be opened or read, for a binary one, and for an empty needle.
    /// A symlink is not followed (`O_NOFOLLOW`): its target is somewhere else, and a walk never goes
    /// there either.
    public static func file(
        at path: String,
        contains needle: String,
        isCancelled: () -> Bool = { false }
    ) -> Bool {
        guard !needle.isEmpty else { return false }
        let descriptor = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }

        var buffer = [UInt8](repeating: 0, count: chunkSize)
        return chunks(contain: needle, isCancelled: isCancelled) {
            while true {
                let count = buffer.withUnsafeMutableBytes { read(
                    descriptor,
                    $0.baseAddress,
                    chunkSize
                ) }
                if count < 0, errno == EINTR { continue }
                // An error ends the file as an end of file does: what was read has been searched.
                return count > 0 ? Data(buffer[0..<count]) : nil
            }
        }
    }

    /// Whether the chunks `next` hands over, read as one text, hold `needle`. `next` answers `nil` at
    /// the end. The file reader's body, and what the tests drive with chunks cut where they choose.
    static func chunks(
        contain needle: String,
        isCancelled: () -> Bool = { false },
        next: () -> Data?
    ) -> Bool {
        guard !needle.isEmpty, !isCancelled() else { return false }
        // The whole sniffing length or the whole file, whichever is shorter, however the reads came
        // back: a byte order mark split by a short first read would otherwise read as UTF-8. The
        // chunks read ahead for it are then searched as they came.
        var readAhead: [Data] = []
        var head = Data()
        while head.count < sniffLength, let more = next() {
            readAhead.append(more)
            head.append(more.prefix(sniffLength - head.count))
        }
        guard !head.isEmpty, let sniffed = TextEncodingSniff.classify(head) else { return false }

        var decoder = TextChunkDecoder(encoding: sniffed.encoding)
        var matcher = TextMatcher(needle: needle)
        var markLeft = sniffed.byteOrderMarkLength
        var readAheadIndex = 0
        while true {
            var bytes: Data
            if readAheadIndex < readAhead.count {
                bytes = readAhead[readAheadIndex]
                readAheadIndex += 1
            } else if let more = next() {
                bytes = more
            } else {
                break
            }
            if markLeft > 0 {
                let dropped = min(markLeft, bytes.count)
                bytes = bytes.dropFirst(dropped)
                markLeft -= dropped
            }
            if matcher.feed(decoder.decode(bytes)) { return true }
            if isCancelled() { return false }
        }
        return matcher.feed(decoder.finish())
    }
}

// MARK: - Which text, if any

/// What a file's first bytes say about how to read it.
enum TextEncodingSniff {
    enum Encoding: Equatable {
        case utf8
        case utf16LittleEndian
        case utf16BigEndian
    }

    /// The encoding of a file that starts with `head`, and how many of those bytes are a byte order
    /// mark to skip; `nil` for a binary file.
    ///
    /// A byte order mark decides it. Without one, a file with no NUL in `head` is UTF-8, which is
    /// also what ASCII and a damaged UTF-8 file are read as. A NUL is the mark of a binary file, with
    /// one exception: UTF-16 written without a mark, where the NULs are the high bytes of Latin
    /// characters and so all fall on one side of each pair. That is taken as UTF-16 when every NUL is
    /// on one side and at least half the pairs hold one; anything else with a NUL is binary.
    static func classify(_ head: Data) -> (encoding: Encoding, byteOrderMarkLength: Int)? {
        let bytes = [UInt8](head)
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { return (.utf8, 3) }
        // UTF-32's little-endian mark starts with UTF-16's; it is not read.
        if bytes.starts(with: [0xFF, 0xFE, 0x00, 0x00]) { return nil }
        if bytes.starts(with: [0xFF, 0xFE]) { return (.utf16LittleEndian, 2) }
        if bytes.starts(with: [0xFE, 0xFF]) { return (.utf16BigEndian, 2) }
        guard bytes.contains(0) else { return (.utf8, 0) }

        let pairs = bytes.count / 2
        var evenNULs = 0
        var oddNULs = 0
        for index in 0..<(pairs * 2) where bytes[index] == 0 {
            if index.isMultiple(of: 2) { evenNULs += 1 } else { oddNULs += 1 }
        }
        if evenNULs == 0, oddNULs * 2 >= pairs { return (.utf16LittleEndian, 0) }
        if oddNULs == 0, evenNULs * 2 >= pairs { return (.utf16BigEndian, 0) }
        return nil
    }
}

// MARK: - Bytes to text

/// Turns a file's chunks into text one at a time, holding back the bytes of a character a chunk
/// boundary cut in two until the next chunk completes it.
///
/// `NSString(data:encoding:)` answers `nil` for UTF-8 that ends partway through a character, so
/// without the carry every chunk boundary inside a Cyrillic or CJK text would lose its whole chunk.
/// UTF-16 has two such cuts: an odd byte, and the first half of a surrogate pair. What is still not
/// valid UTF-8 once the cut is mended (a Latin-1 or Windows-1252 file) is read with each bad byte as
/// U+FFFD, so an ASCII needle is still found in it.
struct TextChunkDecoder {
    let encoding: TextEncodingSniff.Encoding
    private var carry = Data()

    init(encoding: TextEncodingSniff.Encoding) {
        self.encoding = encoding
    }

    /// The text of `bytes`, less any character it ends partway through.
    mutating func decode(_ bytes: Data) -> NSString {
        var data = Data()
        data.append(carry)
        data.append(bytes)
        let kept = data.count - heldBack(in: data)
        carry = data.subdata(in: kept..<data.count)
        return text(of: data.subdata(in: 0..<kept))
    }

    /// Whatever was held back at the end of the file, read as it is.
    mutating func finish() -> NSString {
        defer { carry = Data() }
        return text(of: carry)
    }

    /// How many bytes at the end of `data` belong to a character the next chunk completes.
    private func heldBack(in data: Data) -> Int {
        switch encoding {
        case .utf8:
            return Self.incompleteUTF8Tail(data)
        case .utf16LittleEndian, .utf16BigEndian:
            let odd = data.count % 2
            let whole = data.count - odd
            guard whole >= 2 else { return odd }
            let first = UInt16(data[data.startIndex + whole - 2])
            let second = UInt16(data[data.startIndex + whole - 1])
            let unit = encoding == .utf16LittleEndian ? first | second << 8 : first << 8 | second
            let isHighSurrogate = (0xD800...0xDBFF).contains(unit)
            return odd + (isHighSurrogate ? 2 : 0)
        }
    }

    /// The length of a UTF-8 sequence `data` ends partway through, or 0 when it ends on a whole
    /// character. Only the last three bytes can be such a start; a longer run of continuation bytes
    /// is not valid UTF-8 and is left to the lossy reading.
    static func incompleteUTF8Tail(_ data: Data) -> Int {
        let count = data.count
        guard count > 0 else { return 0 }
        for back in 1...min(4, count) {
            let byte = data[data.startIndex + count - back]
            if byte & 0b1100_0000 == 0b1000_0000 { continue } // a continuation byte
            let length: Int
            switch byte {
            case 0b1100_0000...0b1101_1111: length = 2
            case 0b1110_0000...0b1110_1111: length = 3
            case 0b1111_0000...0b1111_0111: length = 4
            default: return 0 // ASCII, or a byte no sequence starts with
            }
            return back < length ? back : 0
        }
        return 0
    }

    private func text(of data: Data) -> NSString {
        guard !data.isEmpty else { return "" }
        let encoding: String.Encoding = switch self.encoding {
        case .utf8: .utf8
        case .utf16LittleEndian: .utf16LittleEndian
        case .utf16BigEndian: .utf16BigEndian
        }
        if let text = NSString(data: data, encoding: encoding.rawValue) { return text }
        // Only UTF-8 gets here: the UTF-16 readings keep a lone surrogate rather than failing. Lossy
        // on purpose, which is the whole point of this line.
        // swiftlint:disable:next optional_data_string_conversion
        return NSString(string: String(decoding: data, as: UTF8.self))
    }
}

// MARK: - Finding the needle

/// Searches text that arrives a chunk at a time, including across the joins between chunks.
///
/// Each chunk is searched on its own, and then the join: the end of the previous chunk with the
/// start of this one. The overlap is generous because a match need not be as long as the needle:
/// "Straße" is six characters and matches "STRASSE", "é" written decomposed is two, and a ligature
/// "ﬃ" is one that matches "ffi".
struct TextMatcher {
    static let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]

    let needle: String
    /// How much of a chunk's end is kept for the join, in UTF-16 units.
    let overlap: Int
    private var tail: NSString = ""

    init(needle: String) {
        self.needle = needle
        overlap = needle.utf16.count * 4 + 32
    }

    /// Whether `text`, or the join between it and the text before it, holds the needle.
    mutating func feed(_ text: NSString) -> Bool {
        if text.range(of: needle, options: Self.options).location != NSNotFound { return true }
        if tail.length > 0 {
            let joined = NSMutableString(string: tail)
            joined.append(Self.slice(of: text, from: 0, length: overlap) as String)
            if joined.range(of: needle, options: Self.options).location != NSNotFound { return true }
        }
        // The next join's left half: this chunk's end, or all of the text so far when the chunk is
        // shorter than the overlap.
        let source: NSString = text.length >= overlap ? text : {
            let all = NSMutableString(string: tail)
            all.append(text as String)
            return all
        }()
        let start = max(0, source.length - overlap)
        tail = Self.slice(of: source, from: start, length: source.length - start)
        return false
    }

    /// The characters of `text` within the range, widened to whole composed characters so a join
    /// never starts on a combining mark or half a surrogate pair.
    private static func slice(of text: NSString, from start: Int, length: Int) -> NSString {
        let clamped = NSRange(location: start, length: min(length, text.length - start))
        guard clamped.length > 0 else { return "" }
        return text.substring(with: text.rangeOfComposedCharacterSequences(for: clamped)) as NSString
    }
}
