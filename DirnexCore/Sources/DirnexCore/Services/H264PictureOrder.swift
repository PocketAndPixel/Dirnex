import Foundation

/// The order H.264 pictures are shown in, read from their slice headers (ITU-T H.264 §8.2.1), for a
/// container that keeps only the order they are decoded in (PLAN.md §M42 ▸ Slice 5).
///
/// An AVI gives each frame one tick of its clock in the order the frames are stored, which is the
/// decoding order. A stream with B-frames shows them in another: the AVI sample's x264 stream (three
/// B-frames, a B-pyramid) decodes I P B B B and shows I B B B P, as picture order counts 0, 8, 4, 2, 6.
/// FFmpeg reads those counts from each slice to put the frames back; so does this.
///
/// Not handled: `memory_management_control_operation` 5, which restarts the count mid-sequence as an
/// IDR picture does. Finding it means reading every slice header to its end; x264 never writes it.
public struct H264PictureOrder: Sendable {
    /// What one frame's first slice says.
    public struct Picture: Equatable, Sendable {
        /// The picture order count: pictures are shown in its order, which an IDR picture restarts.
        public let order: Int
        public let isIDR: Bool
        public let isReference: Bool
        /// Whether its first slice is intra-coded, which a decoder can start from.
        public let isIntra: Bool
    }

    private var sequences: [Int: H264SequenceParameters] = [:]
    private var pictures: [Int: H264PictureParameters] = [:]
    /// The most and least significant parts of the last reference picture's count (order type 0).
    private var previousMSB = 0
    private var previousLSB = 0
    /// The frame number and its offset of the last picture (order types 1 and 2).
    private var previousFrameNumber = 0
    private var previousFrameNumberOffset = 0

    public init() {}

    /// Take the parameter sets among `units`, as a configuration record or a frame carries them.
    public mutating func learn(_ units: [Data]) {
        for unit in units {
            if let sequence = H264SequenceParameters(unit) {
                sequences[sequence.id] = sequence
            } else if let picture = H264PictureParameters(unit) {
                pictures[picture.id] = picture
            }
        }
    }

    /// Whether a picture can be read yet: a stream whose parameter sets come with its first frame
    /// has none before it.
    public var knowsParameters: Bool {
        !sequences.isEmpty && !pictures.isEmpty
    }

    /// The first sequence parameter set seen.
    public var sequence: H264SequenceParameters? {
        sequences.keys.min().flatMap { sequences[$0] }
    }

    /// The picture in `units`, one frame's units, after taking any parameter sets among them; `nil`
    /// for a frame with no slice, or one naming parameter sets never seen.
    public mutating func picture(in units: [Data]) -> Picture? {
        learn(units)
        guard let unit = units.first(where: { [1, 5].contains(H264NALUnits.type($0)) }) else {
            return nil
        }
        return picture(slice: unit)
    }

    /// Forget the counts, as after a seek, which lands on a key frame that sets them again.
    public mutating func restart() {
        previousMSB = 0
        previousLSB = 0
        previousFrameNumber = 0
        previousFrameNumberOffset = 0
    }

    private struct SliceHeader {
        var type = 0
        var frameNumber = 0
        var isField = false
        var isBottomField = false
        var orderLSB = 0
        var deltaBottom = 0
        var delta: (Int, Int) = (0, 0)
    }

    private mutating func picture(slice unit: Data) -> Picture? {
        let isIDR = H264NALUnits.type(unit) == 5
        let isReference = unit[unit.startIndex] & 0x60 != 0
        var bits = ForwardBitReader(H264NALUnits.payload(unit, limit: 48))
        var header = SliceHeader()
        _ = bits.readUnsignedGolomb()
        header.type = bits.readUnsignedGolomb() % 5
        guard let picture = pictures[bits.readUnsignedGolomb()],
              let sequence = sequences[picture.sequenceID]
        else { return nil }
        if sequence.separateColourPlanes { _ = bits.read(2) }
        header.frameNumber = bits.read(sequence.log2MaxFrameNumber)
        if !sequence.frameMacroblocksOnly {
            header.isField = bits.read(1) == 1
            if header.isField { header.isBottomField = bits.read(1) == 1 }
        }
        if isIDR { _ = bits.readUnsignedGolomb() }
        let bottomPresent = picture.bottomFieldOrderPresent && !header.isField
        if sequence.pictureOrderType == 0 {
            header.orderLSB = bits.read(sequence.log2MaxPictureOrderLSB)
            if bottomPresent { header.deltaBottom = bits.readSignedGolomb() }
        } else if sequence.pictureOrderType == 1, !sequence.deltaPictureOrderAlwaysZero {
            header.delta.0 = bits.readSignedGolomb()
            if bottomPresent { header.delta.1 = bits.readSignedGolomb() }
        }
        guard !bits.isExhausted else { return nil }
        let order = switch sequence.pictureOrderType {
        case 0: typeZeroOrder(header, sequence: sequence, isIDR: isIDR, isReference: isReference)
        default: frameNumberOrder(header, sequence: sequence, isIDR: isIDR, isReference: isReference)
        }
        return Picture(
            order: order,
            isIDR: isIDR,
            isReference: isReference,
            isIntra: header.type == 2 || header.type == 4
        )
    }

    /// §8.2.1.1: the count's low bits are in the slice, and its high bits follow the last reference
    /// picture's, stepping when the low bits wrap.
    private mutating func typeZeroOrder(
        _ header: SliceHeader,
        sequence: H264SequenceParameters,
        isIDR: Bool,
        isReference: Bool
    ) -> Int {
        if isIDR {
            previousMSB = 0
            previousLSB = 0
        }
        let maximum = 1 << sequence.log2MaxPictureOrderLSB
        let lsb = header.orderLSB
        var msb = previousMSB
        if lsb < previousLSB, previousLSB - lsb >= maximum / 2 {
            msb += maximum
        } else if lsb > previousLSB, lsb - previousLSB > maximum / 2 {
            msb -= maximum
        }
        if isReference {
            previousMSB = msb
            previousLSB = lsb
        }
        let top = msb + lsb
        guard !header.isField else { return top }
        return min(top, top + header.deltaBottom)
    }

    /// §8.2.1.2 and §8.2.1.3: the count follows from the frame number, with offsets the sequence
    /// parameter set lists (type 1), or as twice the frame number (type 2).
    private mutating func frameNumberOrder(
        _ header: SliceHeader,
        sequence: H264SequenceParameters,
        isIDR: Bool,
        isReference: Bool
    ) -> Int {
        let maxFrameNumber = 1 << sequence.log2MaxFrameNumber
        var offset = previousFrameNumberOffset
        if isIDR {
            offset = 0
        } else if previousFrameNumber > header.frameNumber {
            offset += maxFrameNumber
        }
        previousFrameNumber = header.frameNumber
        previousFrameNumberOffset = offset
        if sequence.pictureOrderType == 2 {
            guard !isIDR else { return 0 }
            return 2 * (offset + header.frameNumber) - (isReference ? 0 : 1)
        }
        let cycle = sequence.offsetsForReferenceFrames
        var absolute = cycle.isEmpty ? 0 : offset + header.frameNumber
        if !isReference, absolute > 0 { absolute -= 1 }
        var expected = 0
        if absolute > 0 {
            let cycles = (absolute - 1) / cycle.count
            let inCycle = (absolute - 1) % cycle.count
            expected = cycles * cycle.reduce(0, +) + cycle[0...inCycle].reduce(0, +)
        }
        if !isReference { expected += sequence.offsetForNonReference }
        if header.isField {
            return header.isBottomField
                ? expected + sequence.offsetTopToBottom + header.delta.0
                : expected + header.delta.0
        }
        let top = expected + header.delta.0
        return min(top, top + sequence.offsetTopToBottom + header.delta.1)
    }
}
