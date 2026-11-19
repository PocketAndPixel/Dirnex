import Foundation

@testable import DirnexCore

/// Writes EBML for the Matroska tests (PLAN.md §M42 ▸ Slice 3): just enough of RFC 8794 and the
/// Matroska layout to build the shapes real muxers were not found writing on this Mac — every lacing,
/// header stripping, clusters of unknown size — and to put known bytes in every frame, so a test reads
/// them back rather than trusting an offset.
enum EBMLWriter {
    /// How an element's size is written.
    enum Size {
        /// As few bytes as hold it.
        case minimal
        /// Eight bytes, as NCH Prism writes every size.
        case eight
        /// All ones: the writer did not know it, as a live recording's segment and clusters.
        case unknown
    }

    static func element(_ id: UInt32, _ body: [UInt8], size: Size = .minimal) -> [UInt8] {
        idBytes(id) + sizeBytes(UInt64(body.count), size) + body
    }

    static func parent(_ id: UInt32, _ children: [[UInt8]], size: Size = .minimal) -> [UInt8] {
        element(id, children.flatMap(\.self), size: size)
    }

    /// An unsigned integer in `width` bytes, so an element's length does not depend on its value: a
    /// `SeekHead` written before the positions it names are known keeps its size.
    static func uint(_ id: UInt32, _ value: UInt64, width: Int) -> [UInt8] {
        element(
            id,
            (0..<width).map { UInt8(truncatingIfNeeded: value >> (8 * UInt64(width - 1 - $0))) }
        )
    }

    static func uint(_ id: UInt32, _ value: UInt64) -> [UInt8] {
        var bytes: [UInt8] = []
        var rest = value
        repeat {
            bytes.insert(UInt8(rest & 0xFF), at: 0)
            rest >>= 8
        } while rest > 0
        return element(id, bytes)
    }

    static func sint(_ id: UInt32, _ value: Int64, width: Int = 8) -> [UInt8] {
        let bits = UInt64(bitPattern: value)
        return element(
            id,
            (0..<width).map { UInt8(truncatingIfNeeded: bits >> (8 * UInt64(width - 1 - $0))) }
        )
    }

    static func string(_ id: UInt32, _ text: String) -> [UInt8] {
        element(id, Array(text.utf8))
    }

    static func float(_ id: UInt32, _ value: Double) -> [UInt8] {
        let bits = value.bitPattern
        return element(id, (0..<8).map { UInt8(truncatingIfNeeded: bits >> (56 - 8 * UInt64($0))) })
    }

    static func float32(_ id: UInt32, _ value: Float) -> [UInt8] {
        let bits = value.bitPattern
        return element(id, (0..<4).map { UInt8(truncatingIfNeeded: bits >> (24 - 8 * UInt32($0))) })
    }

    /// An ID's bytes, marker included, as IDs are written down.
    static func idBytes(_ id: UInt32) -> [UInt8] {
        let length = max(1, (32 - id.leadingZeroBitCount + 7) / 8)
        return (0..<length).map { UInt8(truncatingIfNeeded: id >> (8 * UInt32(length - 1 - $0))) }
    }

    static func sizeBytes(_ value: UInt64, _ size: Size) -> [UInt8] {
        switch size {
        case .minimal: variableInteger(value)
        case .eight: variableInteger(value, length: 8)
        case .unknown: [0x01, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF]
        }
    }

    /// `value` as an EBML variable integer of `length` bytes, or the fewest that hold it without
    /// reading as "unknown".
    static func variableInteger(_ value: UInt64, length: Int? = nil) -> [UInt8] {
        let length = length ?? (1...8).first { value < (UInt64(1) << (7 * UInt64($0))) - 1 } ?? 8
        let marked = value | (UInt64(1) << (7 * UInt64(length)))
        return (0..<length).map { UInt8(truncatingIfNeeded: marked >> (8 * UInt64(length - 1 - $0))) }
    }
}

/// Matroska's elements, by name, over `EBMLWriter`.
enum MKV {
    typealias Size = EBMLWriter.Size

    static func header(docType: String = "matroska") -> [UInt8] {
        EBMLWriter.parent(0x1A45DFA3, [
            EBMLWriter.uint(0x4286, 1), EBMLWriter.uint(0x42F7, 1),
            EBMLWriter.uint(0x42F2, 4), EBMLWriter.uint(0x42F3, 8),
            EBMLWriter.string(0x4282, docType),
            EBMLWriter.uint(0x4287, 4), EBMLWriter.uint(0x4285, 2)
        ])
    }

    static func segment(_ children: [[UInt8]], size: Size = .minimal) -> [UInt8] {
        EBMLWriter.parent(0x18538067, children, size: size)
    }

    static func info(scale: UInt64? = 1_000_000, duration: Double? = nil, title: String? = nil) -> [
        UInt8
    ] {
        var children: [[UInt8]] = []
        if let scale { children.append(EBMLWriter.uint(0x2AD7B1, scale)) }
        if let duration { children.append(EBMLWriter.float(0x4489, duration)) }
        if let title { children.append(EBMLWriter.string(0x7BA9, title)) }
        return EBMLWriter.parent(0x1549A966, children)
    }

    static func tracks(_ entries: [[UInt8]]) -> [UInt8] {
        EBMLWriter.parent(0x1654AE6B, entries)
    }

    /// A `TrackEntry` with a number, a type and a codec, and whatever else `extra` adds.
    static func track(_ number: UInt64, type: UInt64, codec: String, _ extra: [[UInt8]] = []) -> [
        UInt8
    ] {
        EBMLWriter.parent(0xAE, [
            EBMLWriter.uint(0xD7, number), EBMLWriter.uint(0x73C5, number * 1000),
            EBMLWriter.uint(0x83, type), EBMLWriter.string(0x86, codec)
        ] + extra)
    }

    static func video(width: UInt64, height: UInt64, _ extra: [[UInt8]] = []) -> [UInt8] {
        EBMLWriter.parent(
            0xE0,
            [EBMLWriter.uint(0xB0, width), EBMLWriter.uint(0xBA, height)] + extra
        )
    }

    /// A `ContentEncodings` holding one compression with `algorithm` and `settings`, or an empty
    /// `ContentCompression` when both are `nil`, as mkvmerge 6.8 wrote for PGS.
    static func compression(algorithm: UInt64?, settings: [UInt8]? = nil, scope: UInt64? = nil) -> [
        UInt8
    ] {
        var compression: [[UInt8]] = []
        if let algorithm { compression.append(EBMLWriter.uint(0x4254, algorithm)) }
        if let settings { compression.append(EBMLWriter.element(0x4255, settings)) }
        var encoding: [[UInt8]] = [EBMLWriter.parent(0x5034, compression)]
        if let scope { encoding.insert(EBMLWriter.uint(0x5032, scope), at: 0) }
        return EBMLWriter.parent(0x6D80, [EBMLWriter.parent(0x6240, encoding)])
    }

    static func cluster(time: UInt64, _ children: [[UInt8]], size: Size = .minimal) -> [UInt8] {
        EBMLWriter.parent(0x1F43B675, [EBMLWriter.uint(0xE7, time)] + children, size: size)
    }

    /// How a block's frames are laced.
    enum Lacing: UInt8, CaseIterable, Sendable {
        case none = 0
        case xiph = 1
        case fixed = 2
        case ebml = 3
    }

    /// A block's data: track, time, flags with `lacing` in them, the lacing header, the frames.
    static func blockBody(
        track: UInt64,
        time: Int16,
        flags: UInt8 = 0,
        lacing: Lacing = .none,
        frames: [[UInt8]]
    ) -> [UInt8] {
        var body = EBMLWriter.variableInteger(track)
        body += [
            UInt8(truncatingIfNeeded: UInt16(bitPattern: time) >> 8),
            UInt8(truncatingIfNeeded: time)
        ]
        body.append(flags | lacing.rawValue << 1)
        if lacing != .none {
            body.append(UInt8(frames.count - 1))
            body += laceSizes(lacing, frames.map(\.count))
        }
        return body + frames.flatMap(\.self)
    }

    static func simpleBlock(
        track: UInt64,
        time: Int16,
        flags: UInt8 = 0x80,
        lacing: Lacing = .none,
        frames: [[UInt8]]
    ) -> [UInt8] {
        EBMLWriter.element(
            0xA3,
            blockBody(track: track, time: time, flags: flags, lacing: lacing, frames: frames)
        )
    }

    static func blockGroup(
        track: UInt64,
        time: Int16,
        frame: [UInt8],
        duration: UInt64? = nil,
        reference: Int64? = nil,
        padding: Int64? = nil
    ) -> [UInt8] {
        var children = [
            EBMLWriter.element(0xA1, blockBody(track: track, time: time, frames: [frame]))
        ]
        if let duration { children.append(EBMLWriter.uint(0x9B, duration)) }
        if let reference { children.append(EBMLWriter.sint(0xFB, reference, width: 2)) }
        if let padding { children.append(EBMLWriter.sint(0x75A2, padding, width: 4)) }
        return EBMLWriter.parent(0xA0, children)
    }

    private static func laceSizes(_ lacing: Lacing, _ sizes: [Int]) -> [UInt8] {
        switch lacing {
        case .none, .fixed:
            return []
        case .xiph:
            return sizes.dropLast().flatMap { size in
                Array(repeating: UInt8(255), count: size / 255) + [UInt8(size % 255)]
            }
        case .ebml:
            var bytes = EBMLWriter.variableInteger(UInt64(sizes[0]))
            for index in sizes.indices.dropFirst().dropLast() {
                bytes += signedVariableInteger(Int64(sizes[index] - sizes[index - 1]))
            }
            return bytes
        }
    }

    /// A signed lace difference, biased by half the range of the fewest bytes that hold it.
    private static func signedVariableInteger(_ value: Int64) -> [UInt8] {
        let length = (1...8).first { value.magnitude < (UInt64(1) << (7 * UInt64($0) - 1)) - 1 } ?? 8
        let bias = (Int64(1) << (7 * Int64(length) - 1)) - 1
        return EBMLWriter.variableInteger(UInt64(value + bias), length: length)
    }

    static func void(_ count: Int) -> [UInt8] {
        EBMLWriter.element(0xEC, Array(repeating: 0, count: count))
    }

    /// A `SeekHead` naming each `(id, segment-relative position)`.
    static func seekHead(_ entries: [(UInt32, UInt64)]) -> [UInt8] {
        EBMLWriter.parent(0x114D9B74, entries.map { id, position in
            EBMLWriter.parent(0x4DBB, [
                EBMLWriter.element(0x53AB, EBMLWriter.idBytes(id)),
                EBMLWriter.uint(0x53AC, position, width: 8)
            ])
        })
    }

    /// `Cues` with a point per `(time, [(track, segment-relative cluster position)])`.
    static func cues(_ points: [(UInt64, [(UInt64, UInt64)])]) -> [UInt8] {
        EBMLWriter.parent(0x1C53BB6B, points.map { time, positions in
            EBMLWriter.parent(0xBB, [EBMLWriter.uint(0xB3, time)] + positions.map { track, cluster in
                EBMLWriter.parent(
                    0xB7,
                    [EBMLWriter.uint(0xF7, track), EBMLWriter.uint(0xF1, cluster, width: 8)]
                )
            })
        })
    }

    /// One audio and one video track, for files whose tracks are not the subject.
    static let plainTracks = tracks([
        track(1, type: 1, codec: "V_MPEG4/ISO/AVC", [video(width: 640, height: 360)]),
        track(2, type: 2, codec: "A_AC3", [EBMLWriter.uint(0x23E383, 32_000_000)])
    ])

    /// A whole file: the EBML header, then a segment of `children`.
    static func file(
        docType: String = "matroska",
        segmentSize: Size = .minimal,
        _ children: [[UInt8]]
    ) -> DataByteSource {
        DataByteSource(Data(header(docType: docType) + segment(children, size: segmentSize)))
    }

    /// Where each of `children` starts relative to the segment's data, which is how a `SeekHead` and
    /// `Cues` name positions.
    static func positions(_ children: [[UInt8]]) -> [UInt64] {
        var positions: [UInt64] = []
        var offset: UInt64 = 0
        for child in children {
            positions.append(offset)
            offset += UInt64(child.count)
        }
        return positions
    }

    /// Where the segment's data starts in `file(_:)`'s output, which positions are counted from.
    static func segmentDataOffset(_ children: [[UInt8]], segmentSize: Size = .minimal) -> UInt64 {
        let length = UInt64(children.reduce(0) { $0 + $1.count })
        return UInt64(header().count + 4 + EBMLWriter.sizeBytes(length, segmentSize).count)
    }
}

/// A source that counts what is read from it, for the tests that hold the reader to reading little.
final class CountingByteSource: RandomAccessByteSource, @unchecked Sendable {
    private let inner: any RandomAccessByteSource
    private let lock = NSLock()
    private var ranges: [Range<UInt64>] = []

    init(_ inner: any RandomAccessByteSource) {
        self.inner = inner
    }

    var length: UInt64 { inner.length }

    var reads: [Range<UInt64>] {
        lock.withLock { ranges }
    }

    func read(at offset: UInt64, count: Int) throws -> Data {
        let data = try inner.read(at: offset, count: count)
        lock.withLock { ranges.append(offset..<offset + UInt64(data.count)) }
        return data
    }

    /// Whether any read touched `range`.
    func touched(_ range: Range<UInt64>) -> Bool {
        reads.contains { $0.overlaps(range) }
    }
}

/// A file captured from a real one as the bytes a reader needs and nothing else, with the gaps read as
/// zeros (PLAN.md §M42 ▸ Slice 3). A zero is never the first byte of an EBML header, so a reader that
/// strays into bytes nobody captured fails rather than reading a plausible element.
///
/// The format is `DXSPARS1`, the real file's length, then pieces of offset, count and bytes, all
/// big-endian. The capture script is described in PLAN.md's Slice 3 note.
struct SparseCaptureSource: RandomAccessByteSource {
    let length: UInt64
    private let pieces: [(offset: UInt64, bytes: Data)]

    init(fixture name: String) throws {
        guard let url = Bundle.module.url(
            forResource: name,
            withExtension: "sparse",
            subdirectory: "Fixtures/Matroska"
        )
        else { throw CocoaError(.fileNoSuchFile) }
        let data = try Data(contentsOf: url)
        guard data.prefix(8) == Data("DXSPARS1".utf8) else { throw CocoaError(.fileReadCorruptFile) }
        func number(at index: Int, width: Int) -> UInt64 {
            data[data.startIndex + index..<data.startIndex + index + width].reduce(0) { $0 << 8 | UInt64(
                $1
            ) }
        }
        length = number(at: 8, width: 8)
        var pieces: [(UInt64, Data)] = []
        var index = 16
        while index < data.count {
            let offset = number(at: index, width: 8)
            let count = Int(number(at: index + 8, width: 4))
            let start = data.startIndex + index + 12
            pieces.append((offset, data.subdata(in: start..<start + count)))
            index += 12 + count
        }
        self.pieces = pieces
    }

    func read(at offset: UInt64, count: Int) throws -> Data {
        guard count > 0, offset < length else { return Data() }
        let end = min(length, offset + UInt64(count))
        var result = Data(count: Int(end - offset))
        for piece in pieces {
            let pieceEnd = piece.offset + UInt64(piece.bytes.count)
            let from = max(offset, piece.offset)
            let upTo = min(end, pieceEnd)
            guard from < upTo else { continue }
            let source = piece.bytes.startIndex + Int(from - piece.offset)
            result.replaceSubrange(
                Int(from - offset)..<Int(upTo - offset),
                with: piece.bytes[source..<source + Int(upTo - from)]
            )
        }
        return result
    }
}
