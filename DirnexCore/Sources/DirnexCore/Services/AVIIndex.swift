import Foundation

/// One chunk of a stream, as the index lists it.
public struct AVIIndexEntry: Equatable, Sendable {
    /// Where the chunk's data starts, past its eight-byte header.
    public let offset: UInt64
    public let size: UInt32
    public let isKeyframe: Bool

    public init(offset: UInt64, size: UInt32, isKeyframe: Bool) {
        self.offset = offset
        self.size = size
        self.isKeyframe = isKeyframe
    }
}

/// Each stream's chunks, in the order they are stored, by stream number (PLAN.md §M42 ▸ Slice 5).
public struct AVIIndex: Equatable, Sendable {
    public let streams: [[AVIIndexEntry]]
    /// Where the index came from, for a test to tell the routes apart.
    public let origin: Origin

    public enum Origin: Equatable, Sendable {
        case openDML
        case legacy
        case walk
    }

    public init(streams: [[AVIIndexEntry]], origin: Origin) {
        self.streams = streams
        self.origin = origin
    }

    /// Stream `number`'s chunks, or none for a stream the index does not name.
    public func entries(_ number: Int) -> [AVIIndexEntry] {
        streams.indices.contains(number) ? streams[number] : []
    }
}

extension AVIFile {
    /// The file's index: OpenDML's per-stream indexes when every picture and sound stream has one,
    /// since a file past a gigabyte keeps only its first RIFF in `idx1`; else `idx1`; else a walk of
    /// the `movi` lists, for a file cut short before its index was written.
    ///
    /// The walk reads every chunk's header, a few hundred thousand reads for a long film, so it is
    /// left to a file with nothing better. It tells a picture's key frames by their first bytes
    /// (`AVIStream.looksLikeKeyframe`).
    public func index() throws -> AVIIndex {
        let playable = streams.filter { $0.kind == .video || $0.kind == .audio }
        if !playable.isEmpty, playable.allSatisfy(
            { !$0.superIndex.isEmpty || $0.inlineIndex != nil }
        ) {
            return try AVIIndex(streams: streams.map(openDMLEntries), origin: .openDML)
        }
        if let legacy = try legacyEntries() { return AVIIndex(streams: legacy, origin: .legacy) }
        let walked = try walkedEntries()
        guard walked.contains(where: { !$0.isEmpty }) else { throw AVIError.noIndex }
        return AVIIndex(streams: walked, origin: .walk)
    }

    // MARK: - OpenDML

    private func openDMLEntries(_ stream: AVIStream) throws -> [AVIIndexEntry] {
        if let inline = stream.inlineIndex { return Self.standardEntries(inline) }
        var entries: [AVIIndexEntry] = []
        for part in stream.superIndex {
            guard part.size >= 32, part.size <= Self.headerLimit else { continue }
            let chunk = try source.read(at: part.offset, count: Int(part.size))
            guard chunk.count >= 32, RIFFBytes.fourCC(chunk, at: 0).hasPrefix("ix") else { continue }
            entries += Self.standardEntries(chunk.dropFirst(8))
        }
        return entries
    }

    /// A standard index's entries, from its body: each offset counts from the base offset and names
    /// a chunk's data, and a size's top bit marks a frame that is not a key frame.
    static func standardEntries(_ body: Data) -> [AVIIndexEntry] {
        guard body.count >= 24, body[body.startIndex + 3] == 1 else { return [] }
        let step = max(2, Int(RIFFBytes.uint16(body, at: 0))) * 4
        let count = Int(RIFFBytes.uint32(body, at: 4))
        let base = RIFFBytes.uint64(body, at: 12)
        return (0..<count).compactMap { index in
            let at = 24 + index * step
            guard at + 8 <= body.count else { return nil }
            let size = RIFFBytes.uint32(body, at: at + 4)
            return AVIIndexEntry(
                offset: base + UInt64(RIFFBytes.uint32(body, at: at)),
                size: size & 0x7FFF_FFFF,
                isKeyframe: size & 0x8000_0000 == 0
            )
        }
    }

    // MARK: - idx1

    /// `idx1`'s entries by stream, or `nil` when there is none or its offsets lead nowhere.
    ///
    /// Its offsets name each chunk's header, counted from the `movi` list's type code in every file
    /// seen, and from the start of the file in a few writers' (FFmpeg's reader checks both). The
    /// first entry decides: the base whose header there carries the entry's own code wins.
    private func legacyEntries() throws -> [[AVIIndexEntry]]? {
        guard let range = legacyIndex, range.count >= 16, range.count <= Self.headerLimit else { return nil }
        let data = try source.read(at: range.lowerBound, count: Int(range.count))
        struct Raw {
            let stream: Int
            let code: String
            let flags: UInt32
            let offset: UInt64
            let size: UInt32
        }
        var raw: [Raw] = []
        for at in stride(from: 0, to: data.count - 15, by: 16) {
            let code = RIFFBytes.fourCC(data, at: at)
            guard let stream = Int(code.prefix(2)), streams.indices.contains(stream) else { continue }
            raw.append(Raw(
                stream: stream,
                code: code,
                flags: RIFFBytes.uint32(data, at: at + 4),
                offset: UInt64(RIFFBytes.uint32(data, at: at + 8)),
                size: RIFFBytes.uint32(data, at: at + 12)
            ))
        }
        guard let first = raw.first else { return nil }
        let candidates = [
            firstMovieListOffset.map { $0 + 8 },
            0,
            firstMovieListOffset.map { $0 + 12 }
        ]
        var base: UInt64?
        for candidate in candidates.compactMap(\.self) {
            let head = try source.read(at: candidate + first.offset, count: 8)
            if head.count == 8, RIFFBytes.fourCC(head, at: 0) == first.code {
                base = candidate
                break
            }
        }
        guard let base else { return nil }
        var entries = Array(repeating: [AVIIndexEntry](), count: streams.count)
        for entry in raw {
            let isAudio = streams[entry.stream].kind == .audio
            entries[entry.stream].append(AVIIndexEntry(
                offset: base + entry.offset + 8,
                size: entry.size,
                isKeyframe: isAudio || entry.flags & 0x10 != 0
            ))
        }
        return entries
    }

    // MARK: - Walk

    private func walkedEntries() throws -> [[AVIIndexEntry]] {
        var entries = Array(repeating: [AVIIndexEntry](), count: streams.count)
        for list in movieLists {
            try walkChunks(from: list.lowerBound, to: list.upperBound, into: &entries)
        }
        return entries
    }

    private func walkChunks(
        from start: UInt64,
        to end: UInt64,
        into entries: inout [[AVIIndexEntry]]
    ) throws {
        try Self.walk(source, from: start, to: end) { chunk in
            if chunk.id == "LIST", chunk.listType == "rec " {
                try walkChunks(from: chunk.dataOffset + 4, to: chunk.end, into: &entries)
                return true
            }
            guard let number = Int(chunk.id.prefix(2)), streams.indices.contains(number),
                  !chunk.id.hasSuffix("pc")
            else { return true }
            let stream = streams[number]
            var isKey = true
            if stream.kind == .video, chunk.size > 0 {
                let prefix = try source.read(at: chunk.dataOffset, count: min(Int(chunk.size), 256))
                isKey = entries[number].isEmpty || stream.looksLikeKeyframe(prefix)
            }
            entries[number].append(
                AVIIndexEntry(offset: chunk.dataOffset, size: chunk.size, isKeyframe: isKey)
            )
            return true
        }
    }
}
