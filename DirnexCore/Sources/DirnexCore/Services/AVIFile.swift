import Foundation

/// Why an AVI file could not be read.
public enum AVIError: Error, Equatable, Sendable {
    /// No `RIFF` header naming an AVI.
    case notAVI
    /// The bytes at `offset` break the format: a chunk running past its parent, a header too short.
    case malformed(offset: UInt64)
    /// The file ends before its stream headers.
    case truncated
    /// No index the file's chunks can be found by, and no chunks to walk.
    case noIndex
}

/// The main AVI header (`avih`).
public struct AVIMainHeader: Equatable, Sendable {
    public var microsecondsPerFrame: UInt32 = 0
    public var flags: UInt32 = 0
    public var totalFrames: UInt32 = 0
    public var streamCount: UInt32 = 0
    public var width: UInt32 = 0
    public var height: UInt32 = 0

    public init() {}
}

/// An AVI file, read as far as its stream headers (PLAN.md §M42 ▸ Slice 5), with its index read when
/// asked for.
///
/// An AVI is a RIFF file: a `hdrl` list of headers, one `strl` list per stream, then a `movi` list of
/// chunks named by stream number and kind (`00dc` a picture of stream 0, `01wb` sound of stream 1),
/// then an `idx1` index of them. Files past a gigabyte follow OpenDML: more RIFF chunks of type `AVIX`
/// after the first, each with its own `movi`, and per-stream indexes (`indx`, then `ix00` chunks)
/// instead of the one `idx1`.
///
/// **Opening reads the headers and the top-level chunk headers alone**, a few hundred bytes for the
/// card, and notes where the `movi` lists and the `idx1` are. `index()` reads the index.
public struct AVIFile: Sendable {
    public let header: AVIMainHeader
    public let streams: [AVIStream]
    /// The OpenDML header's frame count (`dmlh`), which covers every RIFF where `avih`'s may cover the
    /// first alone.
    public let totalFrames: UInt32?
    /// Each `movi` list's data: the first RIFF's, then each `AVIX`'s.
    public let movieLists: [Range<UInt64>]
    /// Where the `movi` list's own chunk starts, which `idx1` offsets usually count from.
    let firstMovieListOffset: UInt64?
    /// The `idx1` chunk's data, when the file has one.
    let legacyIndex: Range<UInt64>?
    let source: any RandomAccessByteSource

    /// The most this reader holds in memory of the header list or of one index chunk.
    static let headerLimit = 16 * 1024 * 1024

    public init(source: any RandomAccessByteSource) throws {
        self.source = source
        let start = try source.read(at: 0, count: 12)
        guard start.count == 12, start.prefix(4) == Data("RIFF".utf8),
              start.suffix(4) == Data("AVI ".utf8)
        else { throw AVIError.notAVI }
        let riffEnd = min(source.length, 8 + UInt64(RIFFBytes.uint32(start, at: 4)))
        var lists: [Range<UInt64>] = []
        var movieOffset: UInt64?
        var indexRange: Range<UInt64>?
        var headerList: Data?
        try Self.walk(source, from: 12, to: riffEnd) { chunk in
            switch (chunk.id, chunk.listType) {
            case ("LIST", "hdrl"):
                guard chunk.size <= Self.headerLimit else { throw AVIError.malformed(
                    offset: chunk.offset
                ) }
                headerList = try source.read(at: chunk.dataOffset + 4, count: Int(chunk.size) - 4)
            case ("LIST", "movi"):
                movieOffset = chunk.offset
                // A recording cut short can leave the list's size at zero: its chunks run to the end.
                guard chunk.size > 4 else {
                    lists.append(chunk.dataOffset + 4..<riffEnd)
                    return false
                }
                lists.append(chunk.dataOffset + 4..<chunk.end)
            case ("idx1", _):
                indexRange = chunk.dataOffset..<chunk.end
            default:
                break
            }
            return true
        }
        guard let headerList else { throw AVIError.truncated }
        var next = riffEnd + (riffEnd & 1)
        while next + 12 <= source.length {
            let head = try source.read(at: next, count: 12)
            guard head.prefix(4) == Data("RIFF".utf8), head.suffix(4) == Data("AVIX".utf8) else { break }
            let end = min(source.length, next + 8 + UInt64(RIFFBytes.uint32(head, at: 4)))
            try Self.walk(source, from: next + 12, to: end) { chunk in
                if chunk.id == "LIST", chunk.listType == "movi" {
                    lists.append(chunk.dataOffset + 4..<chunk.end)
                }
                return true
            }
            next = end + (end & 1)
        }
        let headers = try AVIHeaderList(headerList)
        header = headers.main
        streams = headers.streams
        totalFrames = headers.totalFrames
        movieLists = lists
        firstMovieListOffset = movieOffset
        legacyIndex = indexRange
    }

    /// The length in seconds: the first picture stream's, or else the longest sound's, or else what
    /// the main header's frame count and frame time make.
    public var durationSeconds: Double? {
        if let video = streams.first(where: { $0.kind == .video }), let seconds = video.durationSeconds {
            return seconds
        }
        if let longest = streams.compactMap(\.durationSeconds).max() { return longest }
        guard header.microsecondsPerFrame > 0 else { return nil }
        return Double(totalFrames ?? header.totalFrames) * Double(header.microsecondsPerFrame) / 1_000_000
    }

    /// One chunk's bytes, at most 64 MiB of them.
    public func read(_ entry: AVIIndexEntry) throws -> Data {
        guard entry.size > 0 else { return Data() }
        return try source.read(at: entry.offset, count: min(Int(entry.size), 64 * 1024 * 1024))
    }

    /// A chunk's header, as the walk meets it.
    struct Chunk {
        let offset: UInt64
        let id: String
        let size: UInt32
        let listType: String?
        var dataOffset: UInt64 { offset + 8 }
        /// Where its data ends, held inside the parent.
        var end: UInt64
    }

    /// Visit the chunks from `start` to `end` while `visit` answers `true`. A chunk claiming more than
    /// its parent holds is cut to the parent, as a file cut short or still being written leaves its
    /// last list.
    static func walk(
        _ source: any RandomAccessByteSource,
        from start: UInt64,
        to end: UInt64,
        visit: (Chunk) throws -> Bool
    ) throws {
        var offset = start
        while offset + 8 <= end {
            let head = try source.read(at: offset, count: 12)
            guard head.count >= 8 else { break }
            let id = RIFFBytes.fourCC(head, at: 0)
            let size = RIFFBytes.uint32(head, at: 4)
            let isList = id == "LIST" || id == "RIFF"
            let chunkEnd = min(end, offset + 8 + UInt64(size))
            guard try visit(Chunk(
                offset: offset,
                id: id,
                size: size,
                listType: isList && head.count >= 12 ? RIFFBytes.fourCC(head, at: 8) : nil,
                end: chunkEnd
            )) else { break }
            guard offset + 8 + UInt64(size) < end else { break }
            offset += 8 + UInt64(size) + UInt64(size & 1)
        }
    }
}

/// Little-endian fields and four-character codes, as RIFF writes them.
enum RIFFBytes {
    static func uint32(_ data: Data, at index: Int) -> UInt32 {
        let start = data.startIndex + index
        guard start + 4 <= data.endIndex else { return 0 }
        return (0..<4).reduce(UInt32(0)) { $0 | UInt32(data[start + $1]) << (8 * UInt32($1)) }
    }

    static func uint16(_ data: Data, at index: Int) -> UInt16 {
        let start = data.startIndex + index
        guard start + 2 <= data.endIndex else { return 0 }
        return UInt16(data[start]) | UInt16(data[start + 1]) << 8
    }

    static func uint64(_ data: Data, at index: Int) -> UInt64 {
        UInt64(uint32(data, at: index)) | UInt64(uint32(data, at: index + 4)) << 32
    }

    static func int32(_ data: Data, at index: Int) -> Int32 {
        Int32(bitPattern: uint32(data, at: index))
    }

    /// Four bytes as text, each byte its own character, so a code with a byte outside ASCII still
    /// compares as itself.
    static func fourCC(_ data: Data, at index: Int) -> String {
        let start = data.startIndex + index
        guard start + 4 <= data.endIndex else { return "" }
        return String(data[start..<start + 4].map { Character(Unicode.Scalar($0)) })
    }
}
