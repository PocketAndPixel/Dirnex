import Foundation

@testable import DirnexCore

/// Writes AVI files for the tests (PLAN.md §M42 ▸ Slice 5): the layouts real writers use, which this
/// Mac holds one sample of, and the ones it holds none of: OpenDML's indexes across two RIFFs, offsets
/// counted from the start of the file, no index at all, `rec ` lists.
enum AVITestWriter {
    struct Stream {
        var type = "vids"
        var handler = "H264"
        var scale: UInt32 = 1
        var rate: UInt32 = 25
        var start: UInt32 = 0
        var sampleSize: UInt32 = 0
        var flags: UInt32 = 0
        var format: [UInt8] = []
        var name: String?
        var chunks: [(data: [UInt8], isKey: Bool)] = []

        var code: String { type == "vids" ? "dc" : type == "auds" ? "wb" : "tx" }
    }

    /// Where something landed: a chunk's data, or a standard index chunk and how many entries it holds.
    struct Placed {
        var offset: Int
        var size: Int
        var isKey = true
        var count = 0
    }

    enum Index {
        /// `idx1`, its offsets from the `movi` list's type code, or from the start of the file.
        case legacy(fromFileStart: Bool)
        /// OpenDML: a super index in each stream's list, standard index chunks, and the chunks split
        /// across a RIFF `AVI ` and a RIFF `AVIX` after `split` rounds of chunks.
        case openDML(split: Int)
        /// Nothing: a recording cut short.
        case none
    }

    /// The file: headers, then the chunks interleaved a round at a time (each stream's first chunk,
    /// then each stream's second), each round in a `rec ` list when `records` is set.
    static func file(
        _ streams: [Stream],
        index: Index = .legacy(fromFileStart: false),
        records: Bool = false
    ) -> Data {
        let rounds = streams.map(\.chunks.count).max() ?? 0
        let split: Int? = if case let .openDML(split) = index { split } else { nil }
        let superIndexSize = split == nil ? 0 : 8 + 24 + 2 * 16
        let header = headerList(streams, superIndexSize: superIndexSize, totalFrames: rounds)
        var out = [UInt8]()
        out += Array("RIFF".utf8) + le32(0) + Array("AVI ".utf8)
        out += header
        // Where each chunk's data lands, by stream, and each standard index's offset.
        var placed = streams.map { _ in [Placed]() }
        var standardIndexes = streams.map { _ in [Placed]() }
        let moviStart = out.count
        func writeMovie(rounds range: Range<Int>, into out: inout [UInt8]) {
            let listStart = out.count
            out += Array("LIST".utf8) + le32(0) + Array("movi".utf8)
            for round in range {
                let recordStart = out.count
                if records { out += Array("LIST".utf8) + le32(0) + Array("rec ".utf8) }
                for (number, stream) in streams.enumerated() where round < stream.chunks.count {
                    let chunk = stream.chunks[round]
                    out += Array(String(format: "%02d%@", number, stream.code).utf8) + le32(
                        chunk.data.count
                    )
                    placed[number].append(
                        Placed(offset: out.count, size: chunk.data.count, isKey: chunk.isKey)
                    )
                    out += chunk.data
                    if chunk.data.count & 1 == 1 { out.append(0) }
                }
                if records { patch32(&out, at: recordStart + 4, out.count - recordStart - 8) }
            }
            if split != nil {
                for number in streams.indices {
                    let entries = placed[number].filter { entry in
                        entry.offset > listStart && entry.offset < out.count
                    }
                    let start = out.count
                    out += standardIndex(
                        number: number,
                        code: streams[number].code,
                        entries: entries
                    )
                    standardIndexes[number].append(
                        Placed(offset: start, size: out.count - start, count: entries.count)
                    )
                }
            }
            patch32(&out, at: listStart + 4, out.count - listStart - 8)
        }
        writeMovie(rounds: 0..<min(split ?? rounds, rounds), into: &out)
        if case let .legacy(fromFileStart) = index {
            let base = fromFileStart ? 0 : moviStart + 8
            var entries = [UInt8]()
            for round in 0..<rounds {
                for (number, stream) in streams.enumerated() where round < stream.chunks.count {
                    let chunk = placed[number][round]
                    entries += Array(String(format: "%02d%@", number, stream.code).utf8)
                    entries += le32(chunk.isKey ? 0x10 : 0) + le32(chunk.offset - 8 - base) + le32(
                        chunk.size
                    )
                }
            }
            out += Array("idx1".utf8) + le32(entries.count) + entries
        }
        patch32(&out, at: 4, out.count - 8)
        if let split, split < rounds {
            let riffStart = out.count
            out += Array("RIFF".utf8) + le32(0) + Array("AVIX".utf8)
            writeMovie(rounds: split..<rounds, into: &out)
            patch32(&out, at: riffStart + 4, out.count - riffStart - 8)
        }
        if split != nil { patchSuperIndexes(&out, standardIndexes) }
        return Data(out)
    }

    /// Fill each stream's super index, which `headerList` left empty, now that the standard indexes
    /// have places.
    private static func patchSuperIndexes(
        _ out: inout [UInt8],
        _ indexes: [[Placed]]
    ) {
        var search = 0
        for parts in indexes {
            guard let found = find(Array("indx".utf8), in: out, from: search) else { return }
            var at = found + 8
            patch32(&out, at: at + 4, parts.count)
            at += 24
            for part in parts.prefix(2) {
                out.replaceSubrange(at..<at + 8, with: le64(part.offset))
                patch32(&out, at: at + 8, part.size)
                patch32(&out, at: at + 12, part.count)
                at += 16
            }
            search = found + 4
        }
    }

    private static func standardIndex(
        number: Int,
        code: String,
        entries: [Placed]
    ) -> [UInt8] {
        let base = entries.first.map { $0.offset - 8 } ?? 0
        var body = [UInt8]()
        body += le16(2) + [0, 1] + le32(entries.count) + Array(
            String(format: "%02d%@", number, code).utf8
        )
        body += le64(base) + le32(0)
        for entry in entries {
            body += le32(entry.offset - base) + le32(entry.size | (entry.isKey ? 0 : 0x8000_0000))
        }
        return Array(String(format: "ix%02d", number).utf8) + le32(body.count) + body
    }

    private static func headerList(_ streams: [Stream], superIndexSize: Int, totalFrames: Int) -> [
        UInt8
    ] {
        var avih = le32(40000) + le32(0) + le32(0) + le32(0x10) + le32(totalFrames) + le32(0)
        avih += le32(streams.count) + le32(0) + le32(320) + le32(240) + [UInt8](
            repeating: 0,
            count: 16
        )
        var body = Array("hdrl".utf8) + chunk("avih", avih)
        for stream in streams {
            var strh = Array(stream.type.utf8) + Array(stream.handler.utf8) + le32(stream.flags) + le32(
                0
            ) + le32(0)
            strh += le32(stream.scale) + le32(stream.rate) + le32(stream.start) + le32(
                stream.chunks.count
            )
            strh += le32(0) + le32(UInt32.max) + le32(stream.sampleSize) + [UInt8](
                repeating: 0,
                count: 8
            )
            var list = Array("strl".utf8) + chunk("strh", strh) + chunk("strf", stream.format)
            if let name = stream.name { list += chunk("strn", Array(name.utf8) + [0]) }
            if superIndexSize > 0 {
                var indx = le16(4) + [0, 0] + le32(0) + Array("00\(stream.code)".utf8) + [UInt8](
                    repeating: 0,
                    count: 12
                )
                indx += [UInt8](repeating: 0, count: superIndexSize - 8 - 24)
                list += chunk("indx", indx)
            }
            body += chunk("LIST", list)
        }
        if superIndexSize > 0 { body += chunk(
            "LIST",
            Array("odml".utf8) + chunk("dmlh", le32(totalFrames))
        ) }
        return chunk("LIST", body)
    }

    /// A `BITMAPINFOHEADER` with `extra` after it.
    static func videoFormat(
        width: Int = 320,
        height: Int = 240,
        compression: String = "H264",
        extra: [UInt8] = []
    ) -> [UInt8] {
        var format = le32(40 + extra.count) + le32(width) + le32(height) + le16(1) + le16(24)
        format += Array(compression.utf8) + le32(width * height * 3) + [UInt8](
            repeating: 0,
            count: 16
        )
        return format + extra
    }

    /// A `WAVEFORMATEX` with `extra` after it.
    static func audioFormat(
        tag: UInt16,
        channels: Int = 2,
        rate: Int = 48000,
        bytesPerSecond: Int = 16000,
        blockAlign: Int = 1,
        bits: Int = 16,
        extra: [UInt8] = []
    ) -> [UInt8] {
        le16(Int(tag)) + le16(channels) + le32(rate) + le32(bytesPerSecond) + le16(blockAlign) + le16(
            bits
        )
            + le16(extra.count) + extra
    }

    static func chunk(_ id: String, _ body: [UInt8]) -> [UInt8] {
        Array(id.utf8) + le32(body.count) + body + (body.count & 1 == 1 ? [0] : [])
    }

    static func le16(_ value: Int) -> [UInt8] {
        [UInt8(value & 0xFF), UInt8(value >> 8 & 0xFF)]
    }

    static func le32<T: BinaryInteger>(_ value: T) -> [UInt8] {
        let bits = UInt32(truncatingIfNeeded: value)
        return [0, 8, 16, 24].map { UInt8(truncatingIfNeeded: bits >> $0) }
    }

    static func le64(_ value: Int) -> [UInt8] {
        let bits = UInt64(value)
        return (0..<8).map { UInt8(truncatingIfNeeded: bits >> (8 * UInt64($0))) }
    }

    private static func patch32(_ out: inout [UInt8], at index: Int, _ value: Int) {
        out.replaceSubrange(index..<index + 4, with: le32(value))
    }

    private static func find(_ needle: [UInt8], in haystack: [UInt8], from start: Int) -> Int? {
        guard haystack.count >= needle.count else { return nil }
        for index in start...(haystack.count - needle.count) where Array(
            haystack[index..<index + needle.count]
        ) == needle {
            return index
        }
        return nil
    }
}
