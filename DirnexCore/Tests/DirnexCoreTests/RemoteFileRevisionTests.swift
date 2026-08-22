import Foundation
import Testing

@testable import DirnexCore

/// The comparison that stands between a save and somebody else's work (PLAN.md §M21 Slice 10).
///
/// Everything here is a pure value comparison, so the fixtures are built rather than captured —
/// which is honest for once: the question is not what a server sends but what two readings of it
/// mean, and there is nothing for a corpus to be an oracle about. What the live suite adds later,
/// and this cannot, is that the second reading is taken at all.
@Suite("Remote file revision")
struct RemoteFileRevisionTests {
    private let noon = Date(timeIntervalSince1970: 1_700_000_000)

    private func entry(
        backend: VFSBackendID,
        byteSize: Int64 = 10,
        modified: Date,
        entityTag: String? = nil
    ) -> FileEntry {
        FileEntry(
            path: VFSPath(backend: backend, path: "/notes.txt"),
            name: "notes.txt",
            kind: .file,
            byteSize: byteSize,
            modificationDate: modified,
            creationDate: modified,
            isHidden: false,
            permissions: 0o644,
            inode: 0,
            entityTag: entityTag
        )
    }

    private var ftpBackend: VFSBackendID {
        .ftp(FTPLocation(host: "files.example.com", username: "oleg"))
    }

    private var s3Backend: VFSBackendID {
        .s3(S3Location(
            host: "s3.us-east-1.amazonaws.com",
            bucket: "dirnex-test",
            region: "us-east-1",
            accessKeyID: "AKIA"
        ))
    }

    // MARK: - Detecting a write

    @Test("an untouched object is not superseded")
    func unchangedIsNotSuperseded() {
        let downloaded = RemoteFileRevision(byteSize: 4096, modified: noon)

        #expect(!downloaded.isSuperseded(by: RemoteFileRevision(byteSize: 4096, modified: noon)))
    }

    @Test("a different size counts whatever the timestamps say")
    func sizeChangeIsSuperseded() {
        let downloaded = RemoteFileRevision(byteSize: 4096, modified: noon)

        #expect(downloaded.isSuperseded(by: RemoteFileRevision(byteSize: 4097, modified: noon)))
    }

    @Test("a different timestamp counts whatever the sizes say")
    func timestampChangeIsSuperseded() {
        let downloaded = RemoteFileRevision(byteSize: 4096, modified: noon)
        let rewritten = RemoteFileRevision(byteSize: 4096, modified: noon.addingTimeInterval(60))

        #expect(downloaded.isSuperseded(by: rewritten))
    }

    /// The case size and time cannot see, and the whole reason the field exists: a file rewritten
    /// to the same length inside the same timestamp resolution.
    @Test("a differing entity tag catches a rewrite of identical size and time")
    func entityTagCatchesIdenticalSizeAndTime() {
        let downloaded = RemoteFileRevision(byteSize: 4096, modified: noon, entityTag: "\"aaa\"")
        let rewritten = RemoteFileRevision(byteSize: 4096, modified: noon, entityTag: "\"bbb\"")

        #expect(downloaded.isSuperseded(by: rewritten))
        // The negative control for the same rule: without the tags this pair is invisible.
        #expect(!RemoteFileRevision(byteSize: 4096, modified: noon)
            .isSuperseded(by: RemoteFileRevision(byteSize: 4096, modified: noon)))
    }

    /// A matching tag is proof, so nothing else is consulted. Falling through to size and time here
    /// would let a same-size rewrite past on the one comparison that could have caught it — the
    /// mirror of the case above, and the reason the tags short-circuit rather than merely joining
    /// the disjunction.
    @Test("a matching entity tag settles it, even against a differing size")
    func matchingEntityTagWins() {
        let downloaded = RemoteFileRevision(byteSize: 4096, modified: noon, entityTag: "\"aaa\"")
        let restated = RemoteFileRevision(byteSize: 8192, modified: noon, entityTag: "\"aaa\"")

        #expect(!downloaded.isSuperseded(by: restated))
    }

    @Test("a tag on only one side falls back to size and time")
    func oneSidedEntityTagFallsBack() {
        let downloaded = RemoteFileRevision(byteSize: 4096, modified: noon, entityTag: "\"aaa\"")
        let untagged = RemoteFileRevision(byteSize: 4096, modified: noon)

        #expect(!downloaded.isSuperseded(by: untagged))
        #expect(downloaded.isSuperseded(by: RemoteFileRevision(byteSize: 99, modified: noon)))
    }

    /// Two files that were never dated must not read as "both unchanged" through a sentinel that
    /// compares equal to itself — which is exactly what `.distantPast` would do if it survived into
    /// the comparison as a date.
    @Test("no timestamp on either side still compares by size")
    func undatedComparesBySize() {
        let downloaded = RemoteFileRevision(byteSize: 4096, modified: nil)

        #expect(!downloaded.isSuperseded(by: RemoteFileRevision(byteSize: 4096, modified: nil)))
        #expect(downloaded.isSuperseded(by: RemoteFileRevision(byteSize: 5000, modified: nil)))
    }

    @Test("gaining a timestamp counts as a change")
    func acquiringATimestampIsSuperseded() {
        let downloaded = RemoteFileRevision(byteSize: 4096, modified: nil)

        #expect(downloaded.isSuperseded(by: RemoteFileRevision(byteSize: 4096, modified: noon)))
    }

    // MARK: - Building one from a listing

    @Test("an entry's unknown date becomes no timestamp, not a date in year 1")
    func unknownDateBecomesNil() {
        let folder = entry(backend: s3Backend, modified: FileEntry.unknownDate)

        #expect(RemoteFileRevision(folder).modified == nil)
    }

    @Test("a real date survives the trip from the entry")
    func realDateIsCarried() {
        #expect(RemoteFileRevision(entry(backend: s3Backend, modified: noon)).modified == noon)
        #expect(RemoteFileRevision(entry(backend: s3Backend, modified: noon)).byteSize == 10)
    }

    /// The field's producer, which it shipped without: S3 sends an `<ETag>` in the very listing a
    /// row is built from, so the strongest comparison available costs no request of its own.
    @Test("an S3 entry's ETag reaches the revision")
    func entityTagIsCarriedFromTheEntry() {
        let tagged = entry(backend: s3Backend, modified: noon, entityTag: "\"aaa\"")

        #expect(RemoteFileRevision(tagged).entityTag == "\"aaa\"")
        // And a backend that has no such notion still says so, rather than inventing one.
        #expect(RemoteFileRevision(entry(backend: ftpBackend, modified: noon)).entityTag == nil)
    }

    /// The whole point of carrying it, in the form that matters: two readings of one object that
    /// agree on size and second, taken from **entries** the way the app takes them. Without the
    /// producer this pair is indistinguishable from an untouched file, which is the quiet
    /// direction — a save that silently overwrites somebody's work.
    @Test("a rewrite of identical size and time is caught once the entries carry tags")
    func entryTagsCatchAnInvisibleRewrite() {
        let downloaded = RemoteFileRevision(
            entry(backend: s3Backend, modified: noon, entityTag: "\"aaa\"")
        )
        let rewritten = RemoteFileRevision(
            entry(backend: s3Backend, modified: noon, entityTag: "\"bbb\"")
        )

        #expect(downloaded.isSuperseded(by: rewritten))
        // The control that says the pair really is invisible to everything else: strip the tags
        // and the same two readings compare equal.
        let untagged = RemoteFileRevision(entry(backend: s3Backend, modified: noon))
        #expect(!untagged.isSuperseded(by: RemoteFileRevision(
            entry(backend: s3Backend, modified: noon)
        )))
    }
}
