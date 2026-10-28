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
