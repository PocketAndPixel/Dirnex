import Foundation
import Testing

@testable import DirnexCore

/// The EBML primitives under the Matroska reader (PLAN.md §M42 ▸ Slice 3): variable integers, the
/// values an element holds, and the window that keeps reading element by element cheap.
@Suite("EBML reader")
struct EBMLReaderTests {
    private func makeReader(_ bytes: [UInt8], window: Int = 16 * 1024) -> EBMLReader {
        EBMLReader(source: DataByteSource(Data(bytes)), windowSize: window)
    }

    @Test("a size reads the same in every width the format allows", arguments: 1...8)
    func sizeWidths(length: Int) throws {
        let written = EBMLWriter.variableInteger(100, length: length)
        let read = try #require(EBMLReader.variableInteger(written[...], keepingMarker: false))
        #expect(read.value == 100)
        #expect(read.length == length)
        #expect(!read.isUnknown)
    }

    @Test("an ID keeps its marker; a size of all ones is unknown; a zero byte is no integer")
    func markersAndUnknown() throws {
        let id = try #require(
            EBMLReader.variableInteger([0x1A, 0x45, 0xDF, 0xA3], keepingMarker: true)
        )
        #expect(id.value == 0x1A45DFA3)
        #expect(id.length == 4)
        let unknownOne = try #require(EBMLReader.variableInteger([0xFF], keepingMarker: false))
        #expect(unknownOne.isUnknown)
        let unknownEight = try #require(EBMLReader.variableInteger(
            [0x01, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF],
            keepingMarker: false
        ))
        #expect(unknownEight.isUnknown)
        // One short of all ones is a size.
        let large = try #require(EBMLReader.variableInteger([0x40, 0xFE][...], keepingMarker: false))
        #expect(large.value == 0xFE)
        #expect(!large.isUnknown)
        #expect(EBMLReader.variableInteger([0x00, 0x81], keepingMarker: false) == nil)
        #expect(EBMLReader.variableInteger([0x40], keepingMarker: false) == nil, "cut short")
    }

    @Test(
        "an element's header gives its ID, where its data starts and its size, or none when unknown"
    )
    func headers() throws {
        var known = makeReader(EBMLWriter.element(0x4282, Array("webm".utf8), size: .eight))
        let element = try #require(try known.element(at: 0))
        #expect(element.id == 0x4282)
        #expect(element.dataOffset == 10)
        #expect(element.size == 4)
        #expect(element.end == 14)

        var unknown = makeReader(EBMLWriter.parent(0x1F43B675, [], size: .unknown))
        let cluster = try #require(try unknown.element(at: 0))
        #expect(cluster.size == nil)
        #expect(cluster.end == nil)
        #expect(try unknown.element(at: 12) == nil, "the end of the file")
    }

    @Test("a header the file ends inside is truncated; one that cannot be a header is malformed")
    func badHeaders() {
        var cut = makeReader([0x1A, 0x45, 0xDF])
        #expect(throws: MatroskaError.truncated) { try cut.element(at: 0) }
        var cutSize = makeReader([0x1A, 0x45, 0xDF, 0xA3, 0x01, 0x00])
        #expect(throws: MatroskaError.truncated) { try cutSize.element(at: 0) }
        var zero = makeReader([0x00, 0x81, 0x00])
        #expect(throws: MatroskaError.malformed(offset: 0)) { try zero.element(at: 0) }
        var zeroSize = makeReader([0x42, 0x82, 0x00, 0x00])
        #expect(throws: MatroskaError.malformed(offset: 0)) { try zeroSize.element(at: 0) }
        // Five bytes of ID, past the four Matroska allows.
        var long = makeReader(
            [0x08, 0x01, 0x02, 0x03, 0x04, 0x81, 0x00] + Array(repeating: 0, count: 8)
        )
        #expect(throws: MatroskaError.malformed(offset: 0)) { try long.element(at: 0) }
    }

    @Test("integers, floats and strings read as written, and an empty one as its default")
    func values() throws {
        let bytes = EBMLWriter.uint(0xD7, 0x0102_0304_0506)
            + EBMLWriter.sint(0xFB, -67, width: 2)
            + EBMLWriter.sint(0xFB, -1, width: 1)
            + EBMLWriter.sint(0x75A2, 300, width: 4)
            + EBMLWriter.float(0x4489, 5_723_872.5)
            + EBMLWriter.float32(0xB5, 48000)
            + EBMLWriter.element(0x4282, Array("webm".utf8) + [0, 0])
            + EBMLWriter.element(0xD7, [])
            + EBMLWriter.element(0x7BA9, [0x41, 0xFF, 0x42])
        var reader = makeReader(bytes)
        var elements: [EBMLElement] = []
        var offset: UInt64 = 0
        while let element = try reader.element(at: offset) {
            elements.append(element)
            offset = try #require(element.end)
        }
        try #require(elements.count == 9)
        #expect(try reader.unsigned(elements[0]) == 0x0102_0304_0506)
        #expect(try reader.signed(elements[1]) == -67)
        #expect(try reader.signed(elements[2]) == -1)
        #expect(try reader.signed(elements[3]) == 300)
        #expect(try reader.float(elements[4]) == 5_723_872.5)
        #expect(try reader.float(elements[5]) == 48000)
        #expect(try reader.string(elements[6]) == "webm", "the NULs after a string are padding")
        #expect(try reader.unsigned(elements[7]) == nil, "an empty integer takes its default")
        #expect(
            try reader.string(elements[8]) == "A\u{FFFD}B",
            "bytes that are not UTF-8 are repaired"
        )
    }

    @Test("a float of a width other than four or eight bytes is malformed")
    func oddFloat() throws {
        var reader = makeReader(EBMLWriter.element(0x4489, [0, 0, 0]))
        let element = try #require(try reader.element(at: 0))
        #expect(throws: MatroskaError.malformed(offset: 0)) { try reader.float(element) }
    }

    @Test("a master's children are listed in order, and one running past its parent is malformed")
    func children() throws {
        let parent = EBMLWriter.parent(
            0xAE,
            [EBMLWriter.uint(0xD7, 1), EBMLWriter.string(0x86, "A_AC3")]
        )
        var reader = makeReader(parent)
        let element = try #require(try reader.element(at: 0))
        let children = try reader.children(of: element)
        #expect(children.map(\.id) == [0xD7, 0x86])

        // The parent's size says 4, and its one child claims 5.
        var overrun = makeReader([0xAE, 0x84, 0xD7, 0x85, 0x01, 0x02, 0x03, 0x04, 0x05])
        let outer = try #require(try overrun.element(at: 0))
        #expect(throws: MatroskaError.malformed(offset: 2)) { try overrun.children(of: outer) }
    }

    @Test("a hundred small elements inside one window cost one read of the source")
    func window() throws {
        let bytes = (0..<100).flatMap { EBMLWriter.uint(0xD7, UInt64($0)) }
        let source = CountingByteSource(DataByteSource(Data(bytes)))
        var reader = EBMLReader(source: source, windowSize: 4096)
        var offset: UInt64 = 0
        var values: [UInt64] = []
        while let element = try reader.element(at: offset) {
            values.append(try reader.unsigned(element) ?? 0)
            offset = try #require(element.end)
        }
        #expect(values == Array(0..<100))
        #expect(source.reads.count == 1)
    }

    @Test("the file source reads what is there, fewer bytes at the end, and none past it")
    func fileSource() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ebml-\(UUID().uuidString)"
        )
        try Data(0..<200).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let source = try FileByteSource(url: url)
        #expect(source.length == 200)
        #expect(try source.read(at: 10, count: 3) == Data([10, 11, 12]))
        #expect(try source.read(at: 198, count: 10) == Data([198, 199]))
        #expect(try source.read(at: 200, count: 10).isEmpty)
        #expect(throws: POSIXError.self) { try FileByteSource(
            url: url.appendingPathExtension("missing")
        ) }
    }
}
