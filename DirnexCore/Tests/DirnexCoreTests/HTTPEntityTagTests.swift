import Foundation
import Testing

@testable import DirnexCore

/// RFC 9110's two readings of an entity tag (PLAN.md §M32 Slice 4), against one file macOS's Apache
/// served twice on 2026-10-23: read in the second it was written (`W/"bb8-65e8621628fc0"`), and 2.2 s
/// later, untouched (`"bb8-65e8621628fc0"`). `If-Match` with the first answered 412 and with the
/// second 204 (`curl-exit0-apache-put-ifmatch-{weak-412,strong-204}`).
@Suite("HTTP entity tags")
struct HTTPEntityTagTests {
    private static let file = "/fx/fresh.bin"

    private func revision(_ fixture: String) throws -> RemoteFileRevision {
        let row = try WebDAVFixtures.parse(fixture).listing(of: Self.file).folder
        let location = WebDAVLocation(
            host: "127.0.0.1",
            port: 8088,
            username: "probe",
            usesTLS: false
        )
        return RemoteFileRevision(
            row.entry(at: VFSPath(backend: location.backendID, path: Self.file))
        )
    }

    @Test("one untouched file, read weak and then strong, has not changed")
    func weakThenStrongIsTheSameFile() throws {
        let weak = try revision("apache-propfind-fresh-weak-207")
        let strong = try revision("apache-propfind-settled-strong-207")
        #expect(weak.entityTag == #"W/"bb8-65e8621628fc0""#)
        #expect(strong.entityTag == #""bb8-65e8621628fc0""#)
        #expect(!weak.isSuperseded(by: strong))
        #expect(!strong.isSuperseded(by: weak))
        // What a string comparison would have said: the rebaseline taken right after Dirnex's own
        // upload, read as somebody else's edit on the next save.
        #expect(weak.entityTag != strong.entityTag)
    }

    @Test("a different opaque tag is a different file, whichever is weak")
    func differentOpaqueIsChanged() {
        let before = RemoteFileRevision(
            byteSize: 3000,
            modified: nil,
            entityTag: #"W/"bb8-65e8621628fc0""#
        )
        let after = RemoteFileRevision(
            byteSize: 3000,
            modified: nil,
            entityTag: #""bb8-65e8621728fc0""#
        )
        #expect(before.isSuperseded(by: after))
        #expect(after.isSuperseded(by: before))
    }

    @Test("only a strong tag may guard a write")
    func preconditionTag() throws {
        #expect(try revision("apache-propfind-fresh-weak-207").preconditionTag == nil)
        #expect(
            try revision("apache-propfind-settled-strong-207").preconditionTag == #""bb8-65e8621628fc0""#
        )
        #expect(RemoteFileRevision(byteSize: 1, modified: nil).preconditionTag == nil)
    }

    /// The evidence for ``RemoteFileRevision/preconditionTag``: the server's own answers to each tag
    /// as a guard, replayed through the shipped reader.
    @Test("the server refused the weak tag as a guard, and took the strong one")
    func serverAnswers() throws {
        let weak = try WebDAVFixtures.run(
            "curl-exit0-apache-put-ifmatch-weak-412",
            body: "apache-put-ifmatch-weak-412",
            bodyExtension: "html"
        )
        let strong = try WebDAVFixtures.run("curl-exit0-apache-put-ifmatch-strong-204")
        #expect(weak.status == 412)
        #expect(strong.status == 204)
    }

    @Test("the marker is RFC 9110's W/, exactly, and never part of an opaque tag")
    func markerSpelling() {
        #expect(HTTPEntityTag.isWeak(#"W/"x""#))
        #expect(!HTTPEntityTag.isWeak(#""W/x""#))
        #expect(!HTTPEntityTag.isWeak(#"w/"x""#))
        #expect(HTTPEntityTag.opaque(#"W/"x""#) == #""x""#)
        #expect(HTTPEntityTag.opaque(#""W/x""#) == #""W/x""#)
        #expect(!HTTPEntityTag.weaklyEqual(#""W/x""#, #""x""#))
    }

    /// S3 never sends a weak tag, so both readings are the plain ones it always had.
    @Test("an S3 tag compares and guards exactly as before")
    func s3TagsUnchanged() {
        let read = RemoteFileRevision(
            byteSize: 1,
            modified: nil,
            entityTag: #""9b2cf535f27731c974343645a3985328""#
        )
        let same = RemoteFileRevision(
            byteSize: 2,
            modified: nil,
            entityTag: #""9b2cf535f27731c974343645a3985328""#
        )
        let other = RemoteFileRevision(
            byteSize: 1,
            modified: nil,
            entityTag: #""9b2cf535f27731c974343645a3985329""#
        )
        #expect(!read.isSuperseded(by: same))
        #expect(read.isSuperseded(by: other))
        #expect(read.preconditionTag == read.entityTag)
    }
}
