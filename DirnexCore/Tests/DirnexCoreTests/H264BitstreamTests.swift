import Foundation
import Testing

@testable import DirnexCore

/// H.264's units, parameter sets, configuration record and picture order (PLAN.md §M42 ▸ Slice 5).
@Suite("H.264 bitstream")
struct H264BitstreamTests {
    static func bytes(_ hex: String) -> Data {
        var data = Data()
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            data.append(UInt8(hex[index..<next], radix: 16)!)
            index = next
        }
        return data
    }

    /// The AVI sample's sequence parameter set, x264 core 164 at 1920×1080.
    static let sampleSequence = bytes("67640028acd940780227e59a808080a0000003002000000641e30632c0")
    /// The 1440p MP4 sample's parameter sets, and the record Lavf wrote beside them.
    static let mp4Sequence = bytes("67640032acd9802800b5a6a02020280000030008000003019078c18cd0")
    static let mp4Picture = bytes("68e97b2c8b")
    static let mp4Record = bytes(
        "01640032ffe1001d67640032acd9802800b5a6a02020280000030008000003019078c18cd001000568e97b2c8bfdf8f800"
    )

    @Test("units behind three- and four-byte start codes, without the zeros padding them")
    func annexB() {
        let data = Data([0, 0, 0, 1, 0x67, 1, 2, 0, 0, 1, 0x68, 3, 0, 0, 0, 0, 1, 0x65, 4, 0, 0])
        #expect(H264NALUnits.annexB(data) == [Data([0x67, 1, 2]), Data([0x68, 3]), Data([0x65, 4])])
        #expect(H264NALUnits.annexB(Data([1, 2, 3])).isEmpty)
    }

    @Test("lengths in front of each unit, read back, and a length running past the end refused")
    func lengthPrefixed() {
        let units = [Data([0x67, 1, 2]), Data([0x65, 9])]
        let data = H264NALUnits.lengthPrefixed(units)
        #expect(data == Data([0, 0, 0, 3, 0x67, 1, 2, 0, 0, 0, 2, 0x65, 9]))
        #expect(H264NALUnits.lengthPrefixed(data, lengthSize: 4) == units)
        #expect(H264NALUnits.lengthPrefixed(Data([0, 9, 0x65]), lengthSize: 2) == nil)
        // A frame behind start codes reads as a length too long for it.
        #expect(H264NALUnits.lengthPrefixed(Data([0, 0, 0, 1, 0x65, 1]), lengthSize: 4) == nil)
    }

    @Test("emulation prevention bytes are taken out of a payload")
    func emulationPrevention() {
        #expect(
            H264NALUnits.payload(Data([0x67, 0, 0, 3, 1, 5, 0, 0, 3, 0])) == [0, 0, 1, 5, 0, 0, 0]
        )
    }

    @Test(
        "the sample's sequence parameter set: High at 4.0, 1920×1080, picture order type 0, reorder depth 2"
    )
    func sampleSequenceParameters() throws {
        let sequence = try #require(H264SequenceParameters(Self.sampleSequence))
        #expect(sequence.profile == 100)
        #expect(sequence.level == 40)
        #expect(sequence.chromaFormat == 1)
        #expect(sequence.width == 1920)
        #expect(sequence.height == 1080, "68 rows of macroblocks, 8 rows cropped off")
        #expect(sequence.pictureOrderType == 0)
        #expect(sequence.log2MaxFrameNumber == 4)
        #expect(sequence.log2MaxPictureOrderLSB == 6)
        #expect(sequence.reorderDepth == 2, "x264's bframes=3 b_pyramid=2")
        #expect(H264SequenceParameters(Self.mp4Picture) == nil)
    }

    @Test("a written sequence parameter set reads back, cropping and reorder depth included")
    func writtenSequence() throws {
        var written = H264TestWriter.Sequence()
        written.crop = [0, 2, 0, 4]
        written.reorderDepth = 3
        let sequence = try #require(H264SequenceParameters(H264TestWriter.sequence(written)))
        #expect(sequence.width == 320 - 4)
        #expect(sequence.height == 240 - 8)
        #expect(sequence.reorderDepth == 3)
        written.reorderDepth = nil
        #expect(H264SequenceParameters(H264TestWriter.sequence(written))?.reorderDepth == nil)
    }

    @Test("the configuration record made from the MP4's parameter sets is the one Lavf wrote")
    func recordMatchesLavf() {
        #expect(
            H264Configuration.record(sequence: Self.mp4Sequence, picture: Self.mp4Picture) == Self.mp4Record
        )
    }

    @Test("a baseline record ends after its picture parameter set")
    func baselineRecord() throws {
        let sequence = H264TestWriter.sequence()
        let picture = H264TestWriter.picture()
        let record = try #require(H264Configuration.record(sequence: sequence, picture: picture))
        #expect(record.count == 6 + 2 + sequence.count + 3 + picture.count)
        #expect(record.prefix(6) == Data([1, 66, 0, 30, 0xFF, 0xE1]))
    }
}

/// Picture order counts from slice headers, for each of the three ways H.264 counts.
@Suite("H.264 picture order")
struct H264PictureOrderTests {
    static func orders(
        _ sequence: H264TestWriter.Sequence,
        bottomFieldOrderPresent: Bool = false,
        _ slices: [Data]
    ) -> [Int?] {
        var order = H264PictureOrder()
        order.learn([
            H264TestWriter.sequence(sequence),
            H264TestWriter.picture(bottomFieldOrderPresent: bottomFieldOrderPresent)
        ])
        return slices.map { order.picture(in: [$0])?.order }
    }

    @Test("type 0: I P B B shows I B B P")
    func typeZero() {
        let sequence = H264TestWriter.Sequence()
        let orders = Self.orders(sequence, [
            H264TestWriter.slice(sequence, idr: true, type: 2, orderLSB: 0),
            H264TestWriter.slice(sequence, type: 0, frameNumber: 1, orderLSB: 6),
            H264TestWriter.slice(sequence, reference: false, type: 1, frameNumber: 2, orderLSB: 2),
            H264TestWriter.slice(sequence, reference: false, type: 1, frameNumber: 2, orderLSB: 4)
        ])
        #expect(orders == [0, 6, 2, 4])
    }

    @Test("type 0: the low bits wrap and the count carries on; an IDR picture starts it again")
    func typeZeroWraps() {
        let sequence = H264TestWriter.Sequence()
        let lsbs = [0, 4, 8, 12, 0, 4, 14]
        var slices = lsbs.enumerated().map { number, lsb in
            H264TestWriter.slice(
                sequence,
                idr: number == 0,
                type: number == 0 ? 2 : 0,
                frameNumber: number,
                orderLSB: lsb
            )
        }
        slices.append(H264TestWriter.slice(sequence, idr: true, type: 2, orderLSB: 2))
        // After 16 + 4, a 14 is nearer going back across the wrap than forward, so it is 14, before 16.
        #expect(Self.orders(sequence, slices) == [0, 4, 8, 12, 16, 20, 14, 2])
    }

    @Test("type 0: a picture nothing refers to does not move the base the next one is counted from")
    func typeZeroNonReference() {
        let sequence = H264TestWriter.Sequence()
        let orders = Self.orders(sequence, [
            H264TestWriter.slice(sequence, idr: true, type: 2, orderLSB: 0),
            H264TestWriter.slice(sequence, type: 0, frameNumber: 1, orderLSB: 6),
            H264TestWriter.slice(sequence, reference: false, type: 1, frameNumber: 2, orderLSB: 14),
            H264TestWriter.slice(sequence, type: 0, frameNumber: 2, orderLSB: 2)
        ])
        // The last 2 is counted from the P-frame's 6, which makes it 2. Counted from the B-frame's 14
        // it would have wrapped forward to 18.
        #expect(orders == [0, 6, 14, 2])
    }

    @Test("type 0: a frame's count is the earlier of its two fields'; a field picture's is its own")
    func typeZeroFields() {
        var sequence = H264TestWriter.Sequence()
        let frame = Self.orders(sequence, bottomFieldOrderPresent: true, [
            H264TestWriter.slice(sequence, idr: true, type: 2, orderLSB: 4, deltaBottom: -1)
        ])
        #expect(frame == [3])
        sequence.frameMacroblocksOnly = false
        let fields = Self.orders(sequence, [
            H264TestWriter.slice(sequence, idr: true, type: 2, orderLSB: 0, bottomField: false),
            H264TestWriter.slice(sequence, type: 0, orderLSB: 1, bottomField: true)
        ])
        #expect(fields == [0, 1])
    }

    @Test("type 1: counts from the frame number and the cycle of offsets; a B-frame falls between")
    func typeOne() {
        var sequence = H264TestWriter.Sequence()
        sequence.pictureOrderType = 1
        sequence.alwaysZero = true
        sequence.offsetForNonReference = -1
        sequence.cycle = [2]
        let orders = Self.orders(sequence, [
            H264TestWriter.slice(sequence, idr: true, type: 2, frameNumber: 0),
            H264TestWriter.slice(sequence, type: 0, frameNumber: 1),
            H264TestWriter.slice(sequence, reference: false, type: 1, frameNumber: 2),
            H264TestWriter.slice(sequence, type: 0, frameNumber: 2)
        ])
        #expect(orders == [0, 2, 1, 4])
    }

    @Test("type 2: twice the frame number, one less for a picture nothing refers to, across a wrap")
    func typeTwo() {
        var sequence = H264TestWriter.Sequence()
        sequence.pictureOrderType = 2
        let orders = Self.orders(sequence, [
            H264TestWriter.slice(sequence, idr: true, type: 2, frameNumber: 0),
            H264TestWriter.slice(sequence, type: 0, frameNumber: 1),
            H264TestWriter.slice(sequence, reference: false, type: 0, frameNumber: 2),
            H264TestWriter.slice(sequence, type: 0, frameNumber: 15),
            H264TestWriter.slice(sequence, type: 0, frameNumber: 0)
        ])
        #expect(orders == [0, 2, 3, 30, 32])
    }

    @Test("a frame carrying its own parameter sets is read; one naming sets never seen is not")
    func parameterSetsInTheFrame() {
        let sequence = H264TestWriter.Sequence()
        var order = H264PictureOrder()
        #expect(!order.knowsParameters)
        let slice = H264TestWriter.slice(sequence, idr: true, type: 2, orderLSB: 0)
        #expect(order.picture(in: [slice]) == nil)
        let picture = order.picture(
            in: [H264TestWriter.sequence(sequence), H264TestWriter.picture(), slice]
        )
        #expect(picture == .init(order: 0, isIDR: true, isReference: true, isIntra: true))
        #expect(order.knowsParameters)
    }
}
