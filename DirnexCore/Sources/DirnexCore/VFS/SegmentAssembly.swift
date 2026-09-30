import Foundation

/// Why joining a segmented download's pieces into one file failed.
public enum SegmentAssemblyError: Error, Sendable, Equatable {
    case unreadableSegment(number: Int)
    case unwritableDestination
    /// A segment does not hold the bytes its range asked for. Raised rather than tolerated: the
    /// pieces are spliced in order, so one that is **short** is not a shorter file — it is a hole in
    /// the middle of the user's document, with every later byte at the wrong offset — and one that
    /// is **long** is an endpoint that answered a `Range` request with something else. Nothing
    /// downstream would notice either, which is the whole reason this is checked.
    case segmentLengthMismatch(number: Int, expected: Int64, available: Int64)
}

/// Joins a segmented download's pieces into the file the user asked for (docs/HISTORY.md ▸ After M19).
///
/// **Each piece is deleted as soon as it has been appended**, which is the only reason a temp-file
/// shape is affordable for a large object: peak disk is then the object plus one segment, rather
/// than the object twice. That is the same accounting ``S3PartSlice`` makes on the way up, in the
/// opposite direction — there a slice is cut out of a file that already exists, here a file is built
/// out of slices that already exist.
///
/// It is a plain append in segment order, and the ordering is the whole correctness argument: the
/// pieces are `Range` responses whose offsets are the plan's, so concatenating them in number order
/// reproduces the object exactly. Probed against a real bucket 2026-08-20 — four sections
/// reassembled to bytes **SHA-256 identical** to a single-stream download of the same object.
public enum SegmentAssembly {
    /// How much is held in memory at a time. Flat, and independent of both the segment size and the
    /// object size — the same property the streaming upload was chosen for, and it would be thrown
    /// away by reading a segment in one go.
    static let bufferSize = 1024 * 1024

    /// Append every segment, in number order, into a fresh file at `destinationPath`, returning the
    /// byte count. Each segment's own file is removed the moment its bytes are in.
    ///
    /// The destination is **created**, not appended to: a segmented download never resumes (a
    /// partial on disk is what sends a download down the single-stream path instead), so anything
    /// already at that path is a previous attempt's and is replaced rather than grown.
    @discardableResult
    public static func assemble(
        _ segments: [DownloadSegment],
        into destinationPath: String
    ) throws -> Int64 {
        guard FileManager.default.createFile(atPath: destinationPath, contents: nil),
              let destination = FileHandle(forWritingAtPath: destinationPath) else {
            throw SegmentAssemblyError.unwritableDestination
        }
        defer { try? destination.close() }

        var written: Int64 = 0
        for segment in segments.sorted(by: { $0.number < $1.number }) {
            written += try append(segment, to: destination)
            // Immediately, not in a sweep at the end: this is what keeps the peak at one copy.
            try? FileManager.default.removeItem(atPath: segment.localPath)
        }
        return written
    }

    /// Stream one segment into the open destination, and refuse one that is not its range's length.
    private static func append(_ segment: DownloadSegment, to destination: FileHandle) throws -> Int64 {
        guard let source = FileHandle(forReadingAtPath: segment.localPath) else {
            throw SegmentAssemblyError.unreadableSegment(number: segment.number)
        }
        defer { try? source.close() }

        var moved: Int64 = 0
        while true {
            guard let data = try? source.read(upToCount: bufferSize), !data.isEmpty else { break }
            do {
                try destination.write(contentsOf: data)
            } catch {
                throw SegmentAssemblyError.unwritableDestination
            }
            moved += Int64(data.count)
        }
        guard moved == segment.length else {
            throw SegmentAssemblyError.segmentLengthMismatch(
                number: segment.number,
                expected: segment.length,
                available: moved
            )
        }
        return moved
    }
}
