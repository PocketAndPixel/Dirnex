import Foundation

/// Why cutting one part out of a local file failed.
public enum S3PartSliceError: Error, Sendable, Equatable {
    case unreadableSource
    case unwritableDestination
    /// The source held fewer bytes than the plan expected — it shrank, or was replaced, while the
    /// upload was running. Raised rather than tolerated: a short part is not a smaller upload, it is
    /// an object assembled out of bytes that no longer describe the file, and S3 will accept it
    /// without complaint.
    case sourceChanged(expected: Int64, available: Int64)
}

/// Cuts one part out of a local file and writes it where the uploader can send it (PLAN.md §M21).
///
/// **Two callers, one primitive, and the name is S3's because the measurements are.** A segmented
/// *SFTP* upload cuts its parts the same way (``SFTPBackend/uploadInSegments(_:plan:progress:isCancelled:)``),
/// and for the same reason one layer along: `sftp put` takes a path, so a part has to be a real file
/// there too. Everything below is about why that is not merely convenient — it is `curl`'s
/// arithmetic, and it is kept here rather than generalised into prose that would have lost it.
///
/// **A part has to be a real file, and that is a measurement rather than a preference.** `curl -T`
/// is the only upload shape this backend can afford — 5.3 MB resident against `--data-binary`'s
/// 1.08 GB on a 512 MiB file — and it needs something it can `fstat` to state a `Content-Length`.
/// Probed 2026-08-13 against an endpoint that verifies SigV4: a part piped to `-T -` is sent
/// `Transfer-Encoding: chunked`, which S3 rejects for an `UNSIGNED-PAYLOAD` upload, and adding
/// `-H "Content-Length: N"` does **not** fix it — `curl` then sends *both* headers, a contradictory
/// pair, while still chunking. A slice on disk sends exactly `Content-Length: <part>` and exactly
/// the part's bytes.
///
/// Two alternatives measured working in the same run and deliberately not taken:
///
/// - **The body on stdin** (`--data-binary @-` with the credential moved to `-K /dev/fd/3`, which
///   was confirmed to work, secret and all, by the wrong-secret control still being refused). It
///   sends a *real* payload signature rather than `UNSIGNED-PAYLOAD`, which is strictly better —
///   but `Foundation.Process` exposes only stdin, stdout and stderr, so fd 3 means dropping to raw
///   `posix_spawn` file actions, and feeding a body while draining two pipes turns a transport whose
///   deadlock behaviour is already settled into a three-way pump.
/// - **An APFS clone** (`clonefile`, truncate the tail, `-C` to skip the head, `-H "Content-Range:"`
///   to strip the header `-C` adds). Zero bytes copied, and it produced the exact range. It is
///   APFS-only, needs a writable spot on the *source* volume — which a mounted disk image or a
///   read-only share does not have — and so needs this path as its fallback anyway.
///
/// What the copy costs is worth stating plainly rather than waving at: one part of temporary space,
/// and the file's bytes written and read once more than the network reads them. Against the transfer
/// it pays for, that is noise — a 100 GB upload over a 100 Mbit link is about two hours, where the
/// extra disk traffic on an SSD is on the order of a minute.
public enum S3PartSlice {
    /// How much is held in memory at a time. Flat, and independent of both the part size and the
    /// file size — which is the whole property the streaming upload was chosen for and would be
    /// thrown away by reading a part in one go.
    static let bufferSize = 1024 * 1024

    /// Copy `range` of `localPath` into a new file at `destinationPath`, returning the byte count.
    ///
    /// The count is checked against the range rather than reported: a source that shrank mid-upload
    /// produces ``S3PartSliceError/sourceChanged(expected:available:)``, because S3 would otherwise
    /// assemble the short part into the object and call it a success.
    public static func write(
        from localPath: String,
        range: Range<Int64>,
        to destinationPath: String
    ) throws -> Int64 {
        guard let source = FileHandle(forReadingAtPath: localPath) else {
            throw S3PartSliceError.unreadableSource
        }
        defer { try? source.close() }

        guard FileManager.default.createFile(atPath: destinationPath, contents: nil),
              let destination = FileHandle(forWritingAtPath: destinationPath) else {
            throw S3PartSliceError.unwritableDestination
        }
        defer { try? destination.close() }

        do {
            try source.seek(toOffset: UInt64(range.lowerBound))
        } catch {
            throw S3PartSliceError.sourceChanged(
                expected: range.upperBound - range.lowerBound,
                available: 0
            )
        }

        let wanted = range.upperBound - range.lowerBound
        var written: Int64 = 0
        while written < wanted {
            let chunk = Int(min(Int64(bufferSize), wanted - written))
            guard let data = try? source.read(upToCount: chunk), !data.isEmpty else { break }
            do {
                try destination.write(contentsOf: data)
            } catch {
                throw S3PartSliceError.unwritableDestination
            }
            written += Int64(data.count)
        }
        guard written == wanted else {
            throw S3PartSliceError.sourceChanged(expected: wanted, available: written)
        }
        return written
    }
}
