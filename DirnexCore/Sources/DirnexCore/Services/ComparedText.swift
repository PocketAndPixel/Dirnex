import Foundation

/// One side of a text comparison: the whole file decoded, and how it was encoded (PLAN.md §M31
/// Slice 2).
///
/// The decoding is Quick View's (`TextPreview.decodedText`), so the window shows what the preview
/// shows. Two things differ. The file is read whole or not at all, since a comparison that stopped
/// partway would report the rest as missing; and the encoding and byte-order mark are kept, since
/// two files can say the same thing in different bytes, and the window then has to say which bytes.
public struct ComparedText: Sendable {
    public let text: String
    public let encoding: String.Encoding
    public let hasByteOrderMark: Bool

    public init(text: String, encoding: String.Encoding = .utf8, hasByteOrderMark: Bool = false) {
        self.text = text
        self.encoding = encoding
        self.hasByteOrderMark = hasByteOrderMark
    }

    /// Why a file cannot be compared as text.
    public enum Failure: Error, Equatable {
        /// Bigger than the limit: `ByteComparator`'s pre-scan limit, past which ⌥F3 already asks
        /// before reading anything.
        case tooLarge(byteSize: Int64, limit: Int64)
        /// A NUL byte with no byte-order mark: not text.
        case binary
        /// No encoding decodes it without loss.
        case undecodable
        /// The file could not be opened or read.
        case unreadable
        /// The caller asked the read to stop.
        case stopped
    }

    /// The largest side the compare window reads as text on a Mac with this much memory (PLAN.md
    /// §M37): 1/32 of it, and never under `ByteComparator.prescanByteLimit`.
    ///
    /// A pair costs about 13 times one side's bytes once it is on screen (measured 2026-11-08), so
    /// this keeps a pair to about 40 % of memory. A pair past it goes to the byte view.
    public static func windowByteLimit(
        physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory
    ) -> Int64 {
        max(ByteComparator.prescanByteLimit, Int64(clamping: physicalMemory / 32))
    }

    /// What can be told about a file without reading it whole: its size, or the failure a whole read
    /// would give for being past `byteLimit` or for showing a NUL in its first
    /// `TextPreview.sniffLength` bytes (PLAN.md §M37 Slice 3).
    ///
    /// The limit now lets through files of gigabytes, and a binary among them should not be read
    /// whole to find the NUL that nearly always sits in its first bytes. Blocking.
    public static func precheck(
        contentsOf url: URL,
        byteLimit: Int64
    ) throws(Failure) -> Int64 {
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize else {
            throw .unreadable
        }
        guard Int64(size) <= byteLimit else {
            throw .tooLarge(byteSize: Int64(size), limit: byteLimit)
        }
        guard let handle = try? FileHandle(forReadingFrom: url) else { throw .unreadable }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: TextPreview.sniffLength) else {
            // `nil` from `read` is the end of the file, which for an empty file is the first read;
            // the `try?` folds it in with a failed read, and an empty file has no NUL either way.
            return Int64(size)
        }
        guard !TextPreview.isBinary(head) else { throw .binary }
        return Int64(size)
    }

    /// Read and decode a whole local file. Blocking; call it off the main thread.
    public static func read(
        contentsOf url: URL,
        byteLimit: Int64 = ByteComparator.prescanByteLimit
    ) throws(Failure) -> ComparedText {
        try decode(contents(of: url, byteLimit: byteLimit))
    }

    /// A whole local file's bytes, refused past `byteLimit`. Blocking.
    static func contents(of url: URL, byteLimit: Int64) throws(Failure) -> Data {
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize else {
            throw .unreadable
        }
        guard Int64(size) <= byteLimit else {
            throw .tooLarge(byteSize: Int64(size), limit: byteLimit)
        }
        guard let data = try? Data(contentsOf: url) else { throw .unreadable }
        // The file may have grown between the size check and the read.
        guard Int64(data.count) <= byteLimit else {
            throw .tooLarge(byteSize: Int64(data.count), limit: byteLimit)
        }
        return data
    }

    /// Decode a whole file's bytes.
    public static func decode(_ data: Data) throws(Failure) -> ComparedText {
        guard !TextPreview.isBinary(data) else { throw .binary }
        guard let decoded = TextPreview.decodedText(data, isTruncated: false) else {
            throw .undecodable
        }
        return ComparedText(
            text: decoded.text,
            encoding: decoded.encoding,
            hasByteOrderMark: decoded.hasByteOrderMark
        )
    }
}
