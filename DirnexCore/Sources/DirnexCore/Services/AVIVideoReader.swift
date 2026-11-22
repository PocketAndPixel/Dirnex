import Foundation

/// One AVI picture stream's frames, as a decoder takes them and timed as they are shown (PLAN.md §M42
/// ▸ Slice 5).
///
/// An AVI times each chunk as the next tick of the stream's clock, in the order the chunks are stored,
/// which is decoding order; an empty chunk is a tick with nothing new to show. Pictures go to the
/// decoder in that order, and their presentation times come from putting them in showing order
/// (`PresentationReorder`): H.264's from each slice's picture order count, MPEG-4 Part 2's from its
/// plane types, where a B-frame is shown before the anchor decoded ahead of it. Motion JPEG has no
/// order to restore.
struct AVIVideoReader: Sendable {
    let file: AVIFile
    let stream: AVIStream
    let entries: [AVIIndexEntry]
    private let tickNanoseconds: Double
    private var codec: Codec
    private var window: PresentationReorder<Pending>
    private var cursor = 0
    private var ready: [MediaPacket] = []
    private var head = 0
    /// Where the last seek wants playback to start, in nanoseconds: earlier pictures are preroll.
    private var target: Int64?
    /// Set by a seek: frames before the next key frame lean on frames the decoder never saw.
    private var awaitsKeyframe = false

    private enum Codec: Sendable {
        case h264(H264State)
        case mpeg4(MPEG4Order)
        case motionJPEG
    }

    /// H.264's picture order. `lengthSize` is `nil` for frames behind start codes, else the bytes of
    /// each unit's length. After a seek, `cutoff` is the key frame's order: pictures shown before it
    /// lean on what came before it, and are passed over.
    private struct H264State: Sendable {
        var order: H264PictureOrder
        let lengthSize: Int?
        var cutoff: Int?
    }

    /// MPEG-4 Part 2's plane order: anchors (I and P) count up, and a B-frame sorts after the anchor
    /// before the last one. `held` is a packed B-frame waiting for the next chunk's tick.
    private struct MPEG4Order: Sendable {
        var timeIncrementBits: Int?
        var anchors: Int64 = 0
        var bidirectionals: Int64 = 0
        var held: Data?
        var anchorsSinceSeek = 2
    }

    private struct Pending: Sendable {
        let data: Data
        let isKeyframe: Bool
    }

    init?(file: AVIFile, stream: AVIStream, entries: [AVIIndexEntry], firstFrame: Data?) {
        guard let tick = stream.tickSeconds else { return nil }
        self.file = file
        self.stream = stream
        self.entries = entries
        tickNanoseconds = tick * 1_000_000_000
        switch stream.videoCodec {
        case .h264:
            var order = H264PictureOrder()
            var lengthSize: Int?
            let record = stream.extraData
            if record.first == 1, record.count > 7 {
                lengthSize = Int(record[record.startIndex + 4] & 3) + 1
                order.learn(Self.parameterSets(record))
            } else {
                order.learn(
                    H264NALUnits.annexB(stream.extraData) + (
                        firstFrame.map(H264NALUnits.annexB) ?? []
                    )
                )
            }
            let depth = order.sequence?.reorderDepth ?? 16
            order = order.withoutCounts()
            codec = .h264(H264State(order: order, lengthSize: lengthSize))
            window = PresentationReorder(depth: depth)
        case .mpeg4:
            let configuration = MPEG4Visual.configuration(stream.extraData)
                ?? firstFrame.flatMap(MPEG4Visual.configuration)
            codec = .mpeg4(MPEG4Order(
                timeIncrementBits: configuration.flatMap(MPEG4Visual.timeIncrementBits)
            ))
            window = PresentationReorder(depth: 1)
        case .motionJPEG:
            codec = .motionJPEG
            window = PresentationReorder(depth: 0)
        case .other:
            return nil
        }
    }

    /// The next frame, or `nil` once the stream has no more.
    mutating func next() throws -> MediaPacket? {
        while head == ready.count {
            ready = []
            head = 0
            guard cursor < entries.count else {
                ready = window.flush().map { packet($0) }
                if ready.isEmpty { return nil }
                break
            }
            let index = cursor
            cursor += 1
            try read(index)
        }
        let packet = ready[head]
        head += 1
        return packet
    }

    /// Start again at the last key frame at or before `nanoseconds`. Pictures before it come back as
    /// preroll.
    mutating func seek(to nanoseconds: Int64) {
        let wanted = Int((Double(max(0, nanoseconds)) / tickNanoseconds).rounded(.down)) - Int(
            stream.start
        )
        var index = min(max(0, wanted), max(0, entries.count - 1))
        while index > 0, !entries[index].isKeyframe {
            index -= 1
        }
        cursor = index
        target = max(0, nanoseconds)
        awaitsKeyframe = true
        ready = []
        head = 0
        window.reset()
        switch codec {
        case let .h264(state):
            codec = .h264(
                H264State(order: state.order.withoutCounts(), lengthSize: state.lengthSize)
            )
        case let .mpeg4(state):
            codec = .mpeg4(
                MPEG4Order(timeIncrementBits: state.timeIncrementBits, anchorsSinceSeek: 0)
            )
        case .motionJPEG:
            break
        }
    }

    private func packet(_ picture: (payload: Pending, tick: Int64)) -> MediaPacket {
        let time = Int64((Double(picture.tick) * tickNanoseconds).rounded())
        return MediaPacket(
            track: UInt64(stream.number),
            time: time,
            duration: Int64(tickNanoseconds.rounded()),
            data: picture.payload.data,
            isKeyframe: picture.payload.isKeyframe,
            frameCount: nil,
            isPreroll: target.map { time < $0 } ?? false
        )
    }

    private mutating func read(_ index: Int) throws {
        let entry = entries[index]
        let tick = Int64(stream.start) + Int64(index)
        let data = try file.read(entry)
        switch codec {
        case var .h264(state):
            readH264(data, entry: entry, tick: tick, state: &state)
            codec = .h264(state)
        case var .mpeg4(state):
            readMPEG4(data, entry: entry, tick: tick, state: &state)
            codec = .mpeg4(state)
        case .motionJPEG:
            guard !data.isEmpty else { return }
            awaitsKeyframe = false
            push(
                key: tick,
                tick: tick,
                Pending(data: MotionJPEG.withStandardTables(data), isKeyframe: true)
            )
        }
    }

    private mutating func push(key: Int64, tick: Int64, _ pending: Pending) {
        ready += window.push(key: key, tick: tick, payload: pending).map { packet($0) }
    }
}

/// How each codec's chunks become pictures.
extension AVIVideoReader {
    /// The parameter sets in an `avcC` record.
    static func parameterSets(_ record: Data) -> [Data] {
        let bytes = [UInt8](record)
        guard bytes.count > 6 else { return [] }
        var units: [Data] = []
        var index = 6
        var remaining = Int(bytes[5] & 0x1F)
        var pictureSets = false
        while index + 2 <= bytes.count {
            if remaining == 0 {
                guard !pictureSets else { break }
                pictureSets = true
                remaining = Int(bytes[index])
                index += 1
                continue
            }
            let length = Int(bytes[index]) << 8 | Int(bytes[index + 1])
            index += 2
            guard index + length <= bytes.count else { break }
            units.append(Data(bytes[index..<index + length]))
            index += length
            remaining -= 1
        }
        return units
    }

    private mutating func readH264(
        _ data: Data,
        entry: AVIIndexEntry,
        tick: Int64,
        state: inout H264State
    ) {
        guard !data.isEmpty else { return }
        let units = state.lengthSize.flatMap { H264NALUnits.lengthPrefixed(data, lengthSize: $0) }
            ?? H264NALUnits.annexB(data)
        guard let picture = state.order.picture(in: units) else { return }
        if awaitsKeyframe {
            guard picture.isIDR || picture.isIntra || entry.isKeyframe else { return }
            awaitsKeyframe = false
            state.cutoff = picture.isIDR ? nil : picture.order
        }
        if picture.isIDR {
            state.cutoff = nil
            ready += window.flush().map { packet($0) }
        }
        if let cutoff = state.cutoff, picture.order < cutoff { return }
        let decodable = state.lengthSize == 4 ? data : H264NALUnits.lengthPrefixed(
            units.filter { H264NALUnits.type($0) != 9 }
        )
        push(
            key: Int64(picture.order),
            tick: tick,
            Pending(data: decodable, isKeyframe: picture.isIDR || picture.isIntra)
        )
    }

    private mutating func readMPEG4(
        _ data: Data,
        entry: AVIIndexEntry,
        tick: Int64,
        state: inout MPEG4Order
    ) {
        let planes = data.isEmpty ? [] : MPEG4Visual.split(data)
        let headers = planes.map { plane in
            state.timeIncrementBits.flatMap { MPEG4Visual.planeHeader(plane, timeIncrementBits: $0) }
        }
        if let held = state.held {
            state.held = nil
            pushPlane(held, type: .bidirectional, tick: tick, state: &state)
            // DivX leaves the next chunk a plane with nothing coded, whose tick the B-frame takes.
            if planes.isEmpty || planes.count == 1 && headers[0]?.isCoded == false { return }
        }
        for (number, plane) in planes.enumerated() {
            let header = headers[number]
            if header?.isCoded == false { continue }
            if number > 0 {
                state.held = plane
                continue
            }
            let type = header?.type ?? (entry.isKeyframe ? .intra : .predicted)
            if awaitsKeyframe {
                guard type == .intra else { return }
                awaitsKeyframe = false
            }
            pushPlane(plane, type: type, tick: tick, state: &state)
        }
    }

    private mutating func pushPlane(
        _ plane: Data,
        type: MPEG4Visual.PlaneType,
        tick: Int64,
        state: inout MPEG4Order
    ) {
        guard !awaitsKeyframe else { return }
        let key: Int64
        if type.isAnchor {
            state.anchors += 1
            state.bidirectionals = 0
            state.anchorsSinceSeek += 1
            key = state.anchors << 20
        } else {
            // A B-frame right after a seek leans on the anchor before the key frame.
            guard state.anchorsSinceSeek >= 2 else { return }
            state.bidirectionals += 1
            key = (state.anchors - 1) << 20 + state.bidirectionals
        }
        push(key: key, tick: tick, Pending(data: plane, isKeyframe: type == .intra))
    }
}

extension H264PictureOrder {
    /// The same parameter sets with the counts forgotten.
    func withoutCounts() -> H264PictureOrder {
        var copy = self
        copy.restart()
        return copy
    }
}
