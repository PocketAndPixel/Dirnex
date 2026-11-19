import Foundation
import Testing

@testable import DirnexCore

/// What the Matroska reader refuses, and how it says so (PLAN.md §M42 ▸ Slice 3): a file that is not
/// Matroska, one cut short, one missing its tracks, and an element too large to hold.
@Suite("Matroska refusals")
struct MatroskaRefusalTests {
    @Test("what is not Matroska or WebM is refused as such")
    func notMatroska() {
        #expect(throws: MatroskaError.notMatroska) { try MatroskaFile(source: DataByteSource(Data())) }
        #expect(throws: MatroskaError.notMatroska) {
            try MatroskaFile(source: DataByteSource(Data("RIFF\u{0}\u{0}\u{0}\u{0}AVI LIST".utf8)))
        }
        #expect(throws: MatroskaError.notMatroska) {
            try MatroskaFile(source: MKV.file(docType: "other", [MKV.plainTracks]))
        }
    }

    @Test("a file cut before its tracks are whole is truncated")
    func cutBeforeTracks() throws {
        let whole = MKV.file([MKV.info(), MKV.plainTracks])
        let cut = DataByteSource(whole.data.prefix(whole.data.count - 10))
        #expect(throws: MatroskaError.truncated) { try MatroskaFile(source: cut) }
        // Cut inside the segment's own header.
        let header = MKV.header().count
        #expect(throws: MatroskaError.truncated) {
            try MatroskaFile(source: DataByteSource(whole.data.prefix(header + 6)))
        }
    }

    @Test("a whole segment with no tracks is malformed, not truncated")
    func noTracks() throws {
        let source = MKV.file([MKV.info()])
        let segment = UInt64(MKV.header().count)
        #expect(throws: MatroskaError.malformed(offset: segment)) { try MatroskaFile(source: source) }
    }

    @Test("a Tracks element larger than the head's limit is refused rather than read")
    func hugeTracks() throws {
        // A header claiming 32 MiB of tracks, in a file that holds a few bytes of them.
        let claim = EBMLWriter.idBytes(0x1654AE6B) + EBMLWriter.variableInteger(
            32 * 1024 * 1024,
            length: 8
        )
        let bytes = MKV.header() + EBMLWriter.idBytes(0x18538067) + EBMLWriter.variableInteger(
            64 * 1024 * 1024,
            length: 8
        )
            + claim + Array(repeating: 0, count: 64)
        #expect(throws: MatroskaError.truncated) { try MatroskaFile(
            source: DataByteSource(Data(bytes))
        ) }
        // The same claim inside a file long enough to hold it is too large to read into memory.
        let long = ZeroPaddedSource(
            data: Data(bytes),
            length: UInt64(bytes.count) + 32 * 1024 * 1024
        )
        let offset = UInt64(MKV.header().count + 12)
        #expect(throws: MatroskaError.tooLarge(offset: offset)) { try MatroskaFile(source: long) }
    }
}

/// `data`, then zeros to `length`, without holding the zeros.
private struct ZeroPaddedSource: RandomAccessByteSource {
    let data: Data
    let length: UInt64

    func read(at offset: UInt64, count: Int) throws -> Data {
        guard count > 0, offset < length else { return Data() }
        let end = min(length, offset + UInt64(count))
        var result = Data(count: Int(end - offset))
        if offset < UInt64(data.count) {
            let held = data[Int(offset)..<min(data.count, Int(end))]
            result.replaceSubrange(0..<held.count, with: held)
        }
        return result
    }
}
