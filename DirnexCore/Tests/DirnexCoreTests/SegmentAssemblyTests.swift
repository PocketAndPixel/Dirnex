import Foundation
import Testing

@testable import DirnexCore

/// Joining a segmented download's pieces into the file the user asked for (docs/HISTORY.md ▸ After M19).
///
/// Two claims, and the second is the one that matters: the pieces splice in **number order** — which
/// is the whole correctness argument, since they are `Range` responses whose offsets are the plan's
/// — and a piece that is not its range's length is **refused**, in either direction. Nothing
/// downstream would notice a hole in the middle of a document, which is why it is caught here.
@Suite("Segment assembly")
struct SegmentAssemblyTests {
    // MARK: - Joining the pieces

    @Test("the pieces are spliced in order and each is deleted as it lands")
    func assemblesInOrder() throws {
        try withDirectory { directory in
            let object = Data((0..<1000).map { UInt8($0 % 251) })
            let plan = try #require(SegmentedDownloadPlan(totalSize: 1000, segmentSize: 300))
            let segments = plan.segments(under: directory)
            for segment in segments {
                try Self.slice(object, segment.range)
                    .write(to: URL(fileURLWithPath: segment.localPath))
            }
            let destination = directory.appendingPathComponent("out.bin").path

            let written = try SegmentAssembly.assemble(segments, into: destination)
            #expect(written == 1000)
            #expect(try Data(contentsOf: URL(fileURLWithPath: destination)) == object)
            // Peak disk is the object plus one segment, not the object twice, and this is what
            // makes that true rather than a claim.
            #expect(segments.allSatisfy { !FileManager.default.fileExists(atPath: $0.localPath) })
        }
    }

    /// A short piece is not a shorter file — it is a **hole**, with every later byte at the wrong
    /// offset, and nothing downstream would notice. Which is why assembly is where it is caught.
    @Test("a segment that is not its range's length is refused, by number")
    func refusesAShortSegment() throws {
        try withDirectory { directory in
            let plan = try #require(SegmentedDownloadPlan(totalSize: 300, segmentSize: 100))
            let segments = plan.segments(under: directory)
            for segment in segments {
                let short = segment.number == 2 ? 40 : 100
                try Data(repeating: 7, count: short)
                    .write(to: URL(fileURLWithPath: segment.localPath))
            }
            #expect(throws: SegmentAssemblyError.segmentLengthMismatch(
                number: 2,
                expected: 100,
                available: 40
            )) {
                _ = try SegmentAssembly.assemble(
                    segments,
                    into: directory.appendingPathComponent("out.bin").path
                )
            }
        }
    }

    /// The same check catches the opposite direction — an endpoint that answered a range request
    /// with the whole object writes a piece that is too *long*, which is a different bug wearing
    /// the same symptom.
    @Test("a segment longer than its range is refused too")
    func refusesALongSegment() throws {
        try withDirectory { directory in
            let plan = try #require(SegmentedDownloadPlan(totalSize: 200, segmentSize: 100))
            let segments = plan.segments(under: directory)
            for segment in segments {
                try Data(repeating: 7, count: 200)
                    .write(to: URL(fileURLWithPath: segment.localPath))
            }
            #expect(throws: SegmentAssemblyError.segmentLengthMismatch(
                number: 1,
                expected: 100,
                available: 200
            )) {
                _ = try SegmentAssembly.assemble(
                    segments,
                    into: directory.appendingPathComponent("out.bin").path
                )
            }
        }
    }

    @Test("a piece that is not there names itself")
    func refusesAMissingSegment() throws {
        try withDirectory { directory in
            let plan = try #require(SegmentedDownloadPlan(totalSize: 200, segmentSize: 100))
            let segments = plan.segments(under: directory)
            try Data(repeating: 1, count: 100)
                .write(to: URL(fileURLWithPath: segments[0].localPath))
            #expect(throws: SegmentAssemblyError.unreadableSegment(number: 2)) {
                _ = try SegmentAssembly.assemble(
                    segments,
                    into: directory.appendingPathComponent("out.bin").path
                )
            }
        }
    }

    // MARK: - Helpers

    private static func slice(_ object: Data, _ range: Range<Int64>) -> Data {
        object.subdata(in: Int(range.lowerBound)..<Int(range.upperBound))
    }

    private func withDirectory(_ body: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("dirnex-segasm-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory)
    }
}
