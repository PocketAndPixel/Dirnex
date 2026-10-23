import Foundation
import Testing

@testable import DirnexCore

/// F4's save-back over WebDAV (PLAN.md §M32 Slice 4): `If-Match` with the tag the check read, and a
/// refusal read as changed, gone or locked, against the runs captured from macOS's Apache.
@Suite("WebDAV backend: the save-back")
struct WebDAVSaveBackTests {
    private static let location = WebDAVLocation(host: "nas", port: 5006, username: "dirnex-test")
    private static let file = "/home/dirnex-webdav-fixture/Привет мир.txt"
    private static let strongTag = #""bb8-65e8621628fc0""#

    private func path(_ path: String) -> VFSPath {
        VFSPath(backend: Self.location.backendID, path: path)
    }

    private func backend(_ transport: FakeWebDAVTransport) -> WebDAVBackend {
        WebDAVBackend(location: Self.location, transport: transport)
    }

    private func transport(answering name: String, body: String = "") -> FakeWebDAVTransport {
        let transport = FakeWebDAVTransport()
        transport.answerWrite = { _ in try WebDAVBackendWriteTests.apache(name, body: body) }
        return transport
    }

    private func localFile(in scratch: WebDAVScratch) throws -> String {
        let local = scratch.path("payload.bin")
        try Data(repeating: 7, count: 3000).write(to: URL(fileURLWithPath: local))
        return local
    }

    @Test("a guarded save-back sends its tag and says the guard went; an unguarded one says not")
    func guardedSaveBack() throws {
        let scratch = try WebDAVScratch()
        defer { scratch.remove() }
        let local = try localFile(in: scratch)
        let transport = transport(answering: "put-ifmatch-strong-204")
        let dav = backend(transport)

        let guarded = try dav.writeBack(
            localPath: local,
            to: path(Self.file),
            condition: .ifMatches(entityTag: Self.strongTag),
            progress: { _ in },
            isCancelled: { false }
        )
        let unguarded = try dav.writeBack(
            localPath: local,
            to: path(Self.file),
            condition: .unconditional,
            progress: { _ in },
            isCancelled: { false }
        )
        #expect(guarded && !unguarded)
        #expect(transport.writes.first == .upload(
            localPath: local,
            path: Self.file,
            condition: .ifMatches(entityTag: Self.strongTag)
        ))
        // A save replaces the file: there is nothing of the old one's to have kept.
        #expect(dav.metadataTally(at: path(Self.file)) == .zero)
    }

    /// Apache answers `If-Match` onto a deleted file with 412 too (measured), so the server is asked.
    @Test("a refused guard is a change when the file is there, and gone when it is not")
    func refusedGuard() throws {
        let scratch = try WebDAVScratch()
        defer { scratch.remove() }
        let local = try localFile(in: scratch)
        let condition = S3WriteCondition.ifMatches(entityTag: Self.strongTag)

        let changed = transport(answering: "put-ifmatch-stale-412", body: "html")
        changed.respond = { _ in try WebDAVFixtures.multistatus("nas-file-depth0-props") }
        #expect(throws: VFSError.unsupported(.remoteFileChangedSinceFetch(name: "Привет мир.txt"))) {
            try backend(changed).writeBack(
                localPath: local,
                to: path(Self.file),
                condition: condition,
                progress: { _ in },
                isCancelled: { false }
            )
        }

        let gone = transport(answering: "put-ifmatch-stale-412", body: "html")
        gone.respond = { _ in
            try WebDAVFixtures.run(
                "curl-exit0-nas-propfind-404",
                body: "nas-missing-404",
                bodyExtension: "html"
            )
        }
        #expect(throws: VFSError.unsupported(.remoteFileGoneSinceFetch(name: "Привет мир.txt"))) {
            try backend(gone).writeBack(
                localPath: local,
                to: path(Self.file),
                condition: condition,
                progress: { _ in },
                isCancelled: { false }
            )
        }
    }

    @Test("a save-back onto a locked file says it is locked, not that it changed")
    func saveBackLocked() throws {
        let scratch = try WebDAVScratch()
        defer { scratch.remove() }
        let local = try localFile(in: scratch)
        let transport = transport(answering: "put-locked-423", body: "html")
        #expect(throws: VFSError.unsupported(.lockedOnServer(name: "Привет мир.txt"))) {
            try backend(transport).writeBack(
                localPath: local,
                to: path(Self.file),
                condition: .ifMatches(entityTag: Self.strongTag),
                progress: { _ in },
                isCancelled: { false }
            )
        }
        #expect(transport.propfinds.isEmpty)
    }
}
