import Foundation
import Testing

@testable import DirnexCore

/// MPEG-4 Part 2's headers and planes, and Motion JPEG's tables (PLAN.md §M42 ▸ Slice 5).
@Suite("MPEG-4 visual and Motion JPEG")
struct MPEG4VisualTests {
    /// The headers Xvid wrote into the 3GP sample's `esds`: visual object sequence, visual object,
    /// video object, video object layer (time increment resolution 25), and Xvid's user data.
    static let xvidHeaders = H264BitstreamTests.bytes(
        "000001b003000001b509000001000000012000bc0406c400670ca01168518f000001b25876694430303639"
    )
    /// The sample's whole `esds` atom, as AVFoundation hands it out.
    static let xvidESDS = H264BitstreamTests.bytes(
        "00000000038080804b000100048080803d2011000000003b3f7b003b3f7b058080802b"
            + "000001b003000001b509000001000000012000bc0406c400670ca01168518f000001b25876694430303639"
            + "068080800102"
    )

    /// A plane: its start code, then the coding type, no whole seconds, a marker, a 5-bit time
    /// increment, a marker and whether it is coded, then some data.
    static func plane(_ type: Int, increment: Int = 3, coded: Bool = true, seconds: Int = 0) -> Data {
        var bits = GolombBitWriter()
        bits.write(type, bits: 2)
        for _ in 0..<seconds {
            bits.write(1, bits: 1)
        }
        bits.write(0, bits: 1)
        bits.write(1, bits: 1)
        bits.write(increment, bits: 5)
        bits.write(1, bits: 1)
        bits.flag(coded)
        return Data([0, 0, 1, 0xB6]) + bits.finish() + (coded ? [0x55, 0x66, 0x77] : [])
    }

    @Test(
        "the configuration is the headers before the first plane, and only when a layer is among them"
    )
    func configuration() {
        let frame = Self.xvidHeaders + Self.plane(0)
        #expect(MPEG4Visual.configuration(frame) == Self.xvidHeaders)
        #expect(MPEG4Visual.configuration(Self.plane(1)) == nil)
        let withGroup = Self.xvidHeaders + Data([0, 0, 1, 0xB3, 0, 0, 0]) + Self.plane(0)
        #expect(MPEG4Visual.configuration(withGroup) == Self.xvidHeaders)
    }

    @Test("Xvid's layer counts time in 25ths, which takes 5 bits")
    func timeIncrementBits() {
        #expect(MPEG4Visual.timeIncrementBits(configuration: Self.xvidHeaders) == 5)
        #expect(MPEG4Visual.timeIncrementBits(configuration: Data([0, 0, 1, 0xB0, 3])) == nil)
    }

    @Test("the esds made from the headers is the 3GP's own, but for its stream ID and bit rates")
    func esds() {
        var expected = [UInt8](Self.xvidESDS)
        // ES_ID 1 (bytes 9 and 10), and the two bit rates Xvid filled in (22 to 29), which no decoder
        // reads.
        expected[10] = 0
        expected.replaceSubrange(22..<30, with: [UInt8](repeating: 0, count: 8))
        #expect([UInt8](MPEG4Visual.esds(configuration: Self.xvidHeaders)) == expected)
    }

    @Test("a plane's type and whether it is coded, past any whole seconds")
    func planeHeaders() {
        #expect(
            MPEG4Visual.planeHeader(Self.plane(0), timeIncrementBits: 5) == .init(
                type: .intra,
                isCoded: true
            )
        )
        #expect(MPEG4Visual.planeHeader(Self.plane(2, seconds: 2), timeIncrementBits: 5)
            == .init(type: .bidirectional, isCoded: true))
        #expect(MPEG4Visual.planeHeader(Self.plane(1, coded: false), timeIncrementBits: 5)
            == .init(type: .predicted, isCoded: false))
        #expect(MPEG4Visual.planeHeader(Data([1, 2, 3]), timeIncrementBits: 5) == nil)
    }

    @Test("a packed chunk splits into its planes, the headers before the first staying with it")
    func split() {
        let packed = Self.xvidHeaders + Self.plane(1) + Self.plane(2)
        let planes = MPEG4Visual.split(packed)
        #expect(planes == [Self.xvidHeaders + Self.plane(1), Self.plane(2)])
        #expect(MPEG4Visual.split(Self.plane(0)) == [Self.plane(0)])
    }

    // MARK: - Motion JPEG

    static func lavcHead() throws -> Data {
        let url = try #require(Bundle.module.url(
            forResource: "lavc-mjpeg-head",
            withExtension: "jpg",
            subdirectory: "Fixtures/AVI"
        ))
        return try Data(contentsOf: url)
    }

    /// `head` without its `DHT` segment.
    static func withoutTables(_ head: Data) -> Data {
        let bytes = [UInt8](head)
        var out = Data(bytes[0..<2])
        var index = 2
        while index + 4 <= bytes.count {
            let marker = bytes[index + 1]
            let length = Int(bytes[index + 2]) << 8 | Int(bytes[index + 3])
            if marker == 0xDA {
                out.append(contentsOf: bytes[index...])
                break
            }
            if marker != 0xC4 { out.append(contentsOf: bytes[index..<index + 2 + length]) }
            index += 2 + length
        }
        return out
    }

    /// Lavc writes its tables before the frame header and the insertion puts them before the scan,
    /// where a camera's `AVI1` frame would have had them; both are valid places.
    @Test("a frame without Huffman tables gets back the very segment Lavc writes, and nothing else")
    func standardTables() throws {
        let head = try Self.lavcHead()
        let segment = head.subdata(in: 0x59..<0x59 + 420)
        #expect(segment.prefix(4) == Data([0xFF, 0xC4, 0x01, 0xA2]))
        let stripped = Self.withoutTables(head)
        #expect(stripped.count == head.count - 420)
        let fixed = MotionJPEG.withStandardTables(stripped)
        #expect(fixed.count == head.count)
        #expect(fixed.range(of: segment) != nil)
        #expect(Self.withoutTables(fixed) == stripped)
        let scan = try #require(fixed.range(of: Data([0xFF, 0xDA])))
        #expect(fixed.range(of: segment)?.upperBound == scan.lowerBound)
    }

    @Test("a frame with tables, or no JPEG at all, is left as it is")
    func untouched() throws {
        let head = try Self.lavcHead()
        #expect(MotionJPEG.withStandardTables(head) == head)
        #expect(MotionJPEG.withStandardTables(Data([1, 2, 3, 4, 5])) == Data([1, 2, 3, 4, 5]))
    }
}

/// The reorder window: decoding order in, the same order out, with the ticks pictures are shown at.
@Suite("Presentation reorder")
struct PresentationReorderTests {
    /// Push `keys` (each picture's place in showing order) at ticks 0, 1, 2 …, and give back each
    /// picture's tick in the order they came out, with the key as payload.
    static func run(_ keys: [Int64], depth: Int) -> [(key: Int64, tick: Int64)] {
        var window = PresentationReorder<Int64>(depth: depth)
        var out: [(Int64, Int64)] = []
        for (tick, key) in keys.enumerated() {
            out += window.push(key: key, tick: Int64(tick), payload: key)
        }
        return out + window.flush()
    }

    @Test("I P B B: the P-frame shows third, and the pictures still leave in decoding order")
    func oneBFrame() {
        let out = Self.run([0, 3, 1, 2], depth: 1)
        #expect(out.map(\.key) == [0, 3, 1, 2])
        #expect(out.map(\.tick) == [0, 3, 1, 2])
    }

    @Test("x264's B-pyramid as the AVI sample has it: depth 2 and depth 16 agree, depth 1 does not")
    func pyramid() {
        let keys: [Int64] = [0, 8, 4, 2, 6, 16, 12, 10, 14]
        let expected: [Int64] = [0, 4, 2, 1, 3, 8, 6, 5, 7]
        #expect(Self.run(keys, depth: 2).map(\.tick) == expected)
        #expect(Self.run(keys, depth: 16).map(\.tick) == expected)
        #expect(
            Self.run(keys, depth: 1).map(\.tick) != expected,
            "too shallow a window misorders the pyramid"
        )
    }

    @Test("an anchor waits for the B-frames shown before it; flush and reset empty the window")
    func waiting() {
        var window = PresentationReorder<Int>(depth: 2)
        #expect(window.push(key: 0, tick: 0, payload: 0).isEmpty)
        #expect(window.push(key: 8, tick: 1, payload: 1).isEmpty)
        #expect(window.push(key: 4, tick: 2, payload: 2).map(\.payload) == [0])
        #expect(
            window.push(key: 2, tick: 3, payload: 3).isEmpty,
            "the anchor at key 8 still has no tick"
        )
        #expect(window.flush().map(\.payload) == [1, 2, 3])
        #expect(window.isEmpty)
        _ = window.push(key: 5, tick: 9, payload: 9)
        window.reset()
        #expect(window.isEmpty && window.flush().isEmpty)
    }
}
