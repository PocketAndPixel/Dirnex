import Foundation
import Testing

@testable import DirnexCore

/// The byte copies of the WebDAV backend (PLAN.md §M32 Slice 4): an upload is one unconditional PUT,
/// a copy inside the account one COPY tried before it is promised, and a download carries the
/// server's date onto this disk. Answers are the runs captured from macOS's Apache. The save-back
/// is `WebDAVSaveBackTests`.
@Suite("WebDAV backend: copies")
struct WebDAVBackendTransferTests {
    private static let location = WebDAVLocation(host: "nas", port: 5006, username: "dirnex-test")
    private static let file = "/home/dirnex-webdav-fixture/Привет мир.txt"
    /// 2020-01-02 12:00 UTC: a date no transfer here could produce by itself.
    private static let past = Date(timeIntervalSince1970: 1_577_966_400)

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

    /// A 3000-byte local file dated ``past``, the size the captured uploads sent.
    private func localFile(in scratch: WebDAVScratch) throws -> String {
        let local = scratch.path("payload.bin")
        try Data(repeating: 7, count: 3000).write(to: URL(fileURLWithPath: local))
        try FileManager.default.setAttributes([.modificationDate: Self.past], ofItemAtPath: local)
        return local
    }

    private func dated(_ size: Int64? = 3000) -> CopySourceHint {
        CopySourceHint(
            expectedSize: size,
            metadata: RemoteSourceMetadata(permissions: nil, modificationTime: Self.past)
        )
    }

    // MARK: - Upload

    @Test("an upload is one unconditional PUT, its bar settled on curl's own count")
    func uploads() throws {
        let scratch = try WebDAVScratch()
        defer { scratch.remove() }
        let local = try localFile(in: scratch)
        let transport = transport(answering: "put-201")
        transport.streamedUploadProgress = [1000, 1000]
        var reported: [Int64] = []

        try backend(transport).copyFile(
            at: .local(local),
            to: path("/fx/up.bin"),
            progress: { reported.append($0) },
            isCancelled: { false }
        )
        #expect(
            transport.writes == [
                .upload(localPath: local, path: "/fx/up.bin", condition: .unconditional)
            ]
        )
        #expect(reported == [1000, 1000, 1000])
    }

    /// The checksum manifest and the pack delivery both rely on an upload replacing what is there.
    @Test("an upload over an existing file replaces it: Apache's 204 is success")
    func uploadReplaces() throws {
        let scratch = try WebDAVScratch()
        defer { scratch.remove() }
        let transport = transport(answering: "put-replace-204")
        try backend(transport).copyFile(
            at: .local(localFile(in: scratch)),
            to: path("/fx/up.bin"),
            progress: { _ in },
            isCancelled: { false }
        )
        #expect(transport.writes.count == 1)
    }

    /// No request sets a time, so the copy reads as the moment it arrived. WebDAV has no mode at
    /// all, so the local file's 0644 is not counted as lost.
    @Test("an upload counts its date as not kept, and nothing about its mode")
    func uploadLosesTheDate() throws {
        let scratch = try WebDAVScratch()
        defer { scratch.remove() }
        let dav = backend(transport(answering: "put-201"))

        try dav.copyFile(
            at: .local(localFile(in: scratch)),
            to: path("/fx/up.bin"),
            progress: { _ in },
            isCancelled: { false }
        )
        let loss = try #require(dav.metadataTally(at: path("/fx/up.bin")).loss)
        #expect(loss.aspects == [.modificationTime])
        #expect(loss.itemCount == 1)
        #expect(dav.metadataTally(at: .local("/tmp")) == .zero)
    }

    @Test("an upload onto a locked file says so, and counts nothing")
    func uploadLocked() throws {
        let scratch = try WebDAVScratch()
        defer { scratch.remove() }
        let dav = backend(transport(answering: "put-locked-423", body: "html"))
        #expect(throws: VFSError.unsupported(.lockedOnServer(name: "locked.txt"))) {
            try dav.copyFile(
                at: .local(localFile(in: scratch)),
                to: path("/fx/sub/locked.txt"),
                progress: { _ in },
                isCancelled: { false }
            )
        }
        #expect(dav.metadataTally(at: path("/fx")) == .zero)
    }

    @Test("a stopped copy asks nothing")
    func stopped() {
        let transport = FakeWebDAVTransport()
        #expect(throws: CancellationError.self) {
            try backend(transport).copyFile(
                at: .local("/tmp/a"),
                to: path("/fx/a"),
                progress: { _ in },
                isCancelled: { true }
            )
        }
        #expect(transport.writes.isEmpty)
    }

    // MARK: - COPY on the server

    @Test("a copy inside the account is one COPY, reporting the size the listing gave")
    func duplicates() throws {
        let dav = backend(transport(answering: "copy-201"))
        var reported: [Int64] = []
        try dav.copyFile(
            at: path("/fx/moved.bin"),
            to: path("/fx/copy.bin"),
            hint: dated(),
            progress: { reported.append($0) },
            isCancelled: { false }
        )
        #expect(reported == [3000])
        // Apache's COPY stamps the copy with today (measured), as SFTP's `cp` does.
        #expect(dav.metadataTally(at: path("/fx")).loss?.aspects == [.modificationTime])
    }

    @Test("a server without COPY is asked once, and later copies are refused without asking")
    func copyNotAllowedLatches() {
        let transport = transport(answering: "copy-not-allowed-405", body: "html")
        let dav = backend(transport)
        let copy = { try dav.copyFile(
            at: path("/nocopy/a.txt"),
            to: path("/nocopy/b.txt"),
            hint: dated(),
            progress: { _ in },
            isCancelled: { false }
        ) }
        #expect(throws: VFSError.unsupported(.remoteToRemoteCopy)) { try copy() }
        #expect(!dav.mayAttemptInternalCopy(from: path("/nocopy/a.txt"), to: path("/nocopy/b.txt")))
        #expect(throws: VFSError.unsupported(.remoteToRemoteCopy)) { try copy() }
        #expect(transport.writes.count == 1)
    }

    @Test("a refusal about the two files says nothing about the server")
    func copyRefusalDoesNotLatch() {
        let dav = backend(transport(answering: "copy-exists-412", body: "html"))
        #expect(throws: VFSError.alreadyExists(path("/fx/copy.bin"))) {
            try dav.copyFile(
                at: path("/fx/moved.bin"),
                to: path("/fx/copy.bin"),
                hint: dated(),
                progress: { _ in },
                isCancelled: { false }
            )
        }
        #expect(dav.mayAttemptInternalCopy(from: path("/fx/moved.bin"), to: path("/fx/copy.bin")))
    }

    // MARK: - Dates onto this disk

    @Test("a download carries the server's date onto the local copy")
    func downloadCarriesTheDate() throws {
        let scratch = try WebDAVScratch()
        defer { scratch.remove() }
        let transport = FakeWebDAVTransport()
        transport.fileBytes = Data("Привет".utf8)
        let dav = backend(transport)
        let destination = scratch.path("copy.txt")

        try dav.copyFile(
            at: path(Self.file),
            to: .local(destination),
            hint: dated(12),
            progress: { _ in },
            isCancelled: { false }
        )
        let modified = try FileManager.default.attributesOfItem(atPath: destination)[
            .modificationDate
        ] as? Date
        #expect(modified == Self.past)
        #expect(dav.metadataTally(at: path(Self.file)) == .zero)
    }

    @Test("a recreated folder takes the server's date here, and counts it lost on the server")
    func folderMetadata() throws {
        let scratch = try WebDAVScratch()
        defer { scratch.remove() }
        let dav = backend(FakeWebDAVTransport())
        let date = RemoteSourceMetadata(permissions: nil, modificationTime: Self.past)

        try dav.copyMetadata(
            at: path("/fx/sub"),
            to: .local(scratch.directory.path),
            sourceMetadata: date
        )
        let modified = try FileManager.default.attributesOfItem(atPath: scratch.directory.path)[
            .modificationDate
        ]
        #expect(modified as? Date == Self.past)
        #expect(dav.metadataTally(at: path("/fx")) == .zero)

        let local = RemoteSourceMetadata(permissions: 0o755, modificationTime: Self.past)
        try dav.copyMetadata(
            at: .local(scratch.directory.path),
            to: path("/fx/sub2"),
            sourceMetadata: local
        )
        #expect(dav.metadataTally(at: path("/fx")).loss?.aspects == [.modificationTime])
    }
}
