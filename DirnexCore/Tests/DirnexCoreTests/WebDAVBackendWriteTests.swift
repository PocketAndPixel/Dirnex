import Foundation
import Testing

@testable import DirnexCore

/// The write verbs of the WebDAV backend (PLAN.md §M32 Slice 4) against a fake fed the answers
/// macOS's Apache gave the shipped arguments on 2026-10-23 (`curl-exit0-apache-…`), and the NAS's
/// where a stat is needed: MKCOL, the create-if-absent PUT, MOVE and DELETE, and what each refusal
/// becomes.
@Suite("WebDAV backend: create, move, delete")
struct WebDAVBackendWriteTests {
    private static let location = WebDAVLocation(host: "nas", port: 5006, username: "dirnex-test")
    private static let folder = "/home/dirnex-webdav-fixture"

    private func path(_ path: String) -> VFSPath {
        VFSPath(backend: Self.location.backendID, path: path)
    }

    private func backend(_ transport: FakeWebDAVTransport) -> WebDAVBackend {
        WebDAVBackend(location: Self.location, transport: transport)
    }

    /// A captured Apache run, and its body when the run kept one.
    static func apache(_ name: String, body: String = "html") throws -> WebDAVHTTPResponse {
        try WebDAVFixtures.run(
            "curl-exit0-apache-\(name)",
            body: body.isEmpty ? nil : "apache-\(name)",
            bodyExtension: body
        )
    }

    private func transport(answering name: String, body: String = "html") -> FakeWebDAVTransport {
        let transport = FakeWebDAVTransport()
        transport.answerWrite = { _ in try Self.apache(name, body: body) }
        return transport
    }

    // MARK: - MKCOL

    @Test("a folder is one MKCOL")
    func createsAFolder() throws {
        let transport = transport(answering: "mkcol-201", body: "")
        try backend(transport).createDirectory(at: path("/fx"))
        #expect(transport.writes == [.mkcol("/fx")])
    }

    @Test("MKCOL's 405 is something already there, and its 409 a missing parent")
    func folderRefusals() {
        #expect(throws: VFSError.alreadyExists(path("/fx"))) {
            try backend(transport(answering: "mkcol-exists-405")).createDirectory(at: path("/fx"))
        }
        #expect(throws: VFSError.notFound(path("/nope"))) {
            try backend(transport(answering: "mkcol-noparent-409")).createDirectory(
                at: path("/nope/sub")
            )
        }
    }

    @Test("the root is already there, and nothing is asked")
    func rootFolder() {
        let transport = FakeWebDAVTransport()
        #expect(throws: VFSError.alreadyExists(path("/"))) {
            try backend(transport).createDirectory(at: path("/"))
        }
        #expect(transport.writes.isEmpty)
    }

    // MARK: - The create-if-absent PUT

    /// No `stat` first: `If-None-Match: *` makes the check and the write one act on the server.
    @Test("an empty file is one PUT, only if nothing is there")
    func createsAnEmptyFile() throws {
        let transport = transport(answering: "put-empty-201", body: "")
        try backend(transport).createFile(at: path("/fx/new.txt"))
        #expect(transport.writes == [.putEmpty("/fx/new.txt", condition: .ifAbsent)])
        #expect(transport.propfinds.isEmpty)
    }

    @Test("a file already there refuses the create, and is left alone")
    func createOverAFile() {
        let transport = transport(answering: "put-ifabsent-412")
        #expect(throws: VFSError.alreadyExists(path("/fx/new.txt"))) {
            try backend(transport).createFile(at: path("/fx/new.txt"))
        }
        #expect(transport.propfinds.isEmpty)
    }

    /// Apache answers `If-None-Match: *` onto a folder with 409, which RFC 4918 also spends on a
    /// missing parent. One stat tells them apart.
    @Test(
        "a 409 is a folder in the way when the server has one there, and a missing parent otherwise"
    )
    func createOverAFolder() {
        let overFolder = transport(answering: "put-onto-folder-409")
        overFolder.respond = { _ in try WebDAVFixtures.multistatus("nas-folder-noslash-depth0-props") }
        #expect(throws: VFSError.alreadyExists(path(Self.folder))) {
            try backend(overFolder).createFile(at: path(Self.folder))
        }
        #expect(
            overFolder.propfinds == [.init(path: Self.folder, depth: .zero, isCollection: false)]
        )

        let noParent = transport(answering: "put-onto-folder-409")
        noParent.respond = { _ in
            try WebDAVFixtures.run(
                "curl-exit0-nas-propfind-404",
                body: "nas-missing-404",
                bodyExtension: "html"
            )
        }
        #expect(throws: VFSError.notFound(path("/nope"))) {
            try backend(noParent).createFile(at: path("/nope/new.txt"))
        }
    }

    // MARK: - MOVE

    @Test("a rename is one MOVE, a folder and all")
    func moves() throws {
        let transport = transport(answering: "move-201", body: "")
        try backend(transport).moveItem(at: path("/fx/up.bin"), to: path("/fx/moved.bin"))
        #expect(transport.writes == [.move("/fx/up.bin", to: "/fx/moved.bin")])
    }

    @Test("an occupied destination refuses the move and names the destination")
    func moveOntoSomething() {
        #expect(throws: VFSError.alreadyExists(path("/fx/moved.bin"))) {
            try backend(transport(answering: "move-exists-412"))
                .moveItem(at: path("/fx/new.txt"), to: path("/fx/moved.bin"))
        }
    }

    /// The app refuses this before it asks (`TransferAdmission`); the server refuses it too.
    @Test("a folder moved into itself is refused by the server, and nothing moves")
    func moveIntoItself() {
        #expect(throws: VFSError.permissionDenied(path("/fx/sub"))) {
            try backend(transport(answering: "move-into-itself-403"))
                .moveItem(at: path("/fx/sub"), to: path("/fx/sub/inner"))
        }
    }

    /// Apache answers a MOVE into a missing folder with 500 rather than RFC 4918's 409 (the NAS,
    /// captured 2026-10-24 through the shipped arguments). Put Back rebuilds a folder only on
    /// `notFound`, so one stat of the folder decides which the 500 was.
    @Test("a 500 into a folder the server says is gone is notFound for that folder")
    func moveIntoMissingFolder() {
        let transport = FakeWebDAVTransport()
        transport.answerWrite = { _ in
            try WebDAVFixtures.run(
                "curl-exit0-nas-move-noparent-500",
                body: "nas-move-noparent-500",
                bodyExtension: "html"
            )
        }
        transport.respond = { _ in
            try WebDAVFixtures.run(
                "curl-exit0-nas-propfind-404",
                body: "nas-missing-404",
                bodyExtension: "html"
            )
        }
        #expect(throws: VFSError.notFound(path("/fx/missing"))) {
            try backend(transport).moveItem(at: path("/fx/c.txt"), to: path("/fx/missing/c.txt"))
        }
        #expect(transport.writes == [.move("/fx/c.txt", to: "/fx/missing/c.txt")])
        #expect(
            transport.propfinds == [.init(path: "/fx/missing", depth: .zero, isCollection: false)]
        )
    }

    /// The control: the same 500 with the folder still there is the server failing, and stays an
    /// I/O error rather than sending anybody to rebuild a folder that exists.
    @Test("a 500 into a folder that is there stays an I/O error")
    func moveFailsOnTheServer() {
        let transport = FakeWebDAVTransport()
        transport.answerWrite = { _ in
            try WebDAVFixtures.run(
                "curl-exit0-nas-move-noparent-500",
                body: "nas-move-noparent-500",
                bodyExtension: "html"
            )
        }
        transport.respond = { _ in try WebDAVFixtures.multistatus("nas-folder-noslash-depth0-props") }
        #expect(throws: VFSError.io(path: path("/fx/c.txt"), code: EIO)) {
            try backend(transport).moveItem(at: path("/fx/c.txt"), to: path(Self.folder + "/c.txt"))
        }
    }

    @Test("a folder holding a locked file does not move, and the file is named")
    func moveLockedMember() {
        #expect(throws: VFSError.unsupported(.lockedOnServer(name: "locked.txt"))) {
            try backend(transport(answering: "move-locked-member-424", body: "xml"))
                .moveItem(at: path("/fx/sub"), to: path("/fx/sub2"))
        }
    }

    @Test("another backend is EXDEV and the root is not movable, both without a request")
    func moveRefusedLocally() {
        let transport = FakeWebDAVTransport()
        // Another root on the same server is another backend.
        let share = WebDAVLocation(
            host: "nas",
            port: 5006,
            username: "dirnex-test",
            rootPath: "/share"
        )
        let other = VFSPath(backend: share.backendID, path: "/a")
        #expect(throws: VFSError.io(path: path("/a"), code: EXDEV)) {
            try backend(transport).moveItem(at: path("/a"), to: other)
        }
        #expect(throws: VFSError.unsupported(.deleteConnectionRoot)) {
            try backend(transport).moveItem(at: path("/"), to: path("/b"))
        }
        #expect(transport.writes.isEmpty)
    }

    // MARK: - DELETE

    @Test("a delete is one DELETE, recursive on the server")
    func deletes() throws {
        let transport = transport(answering: "delete-204", body: "")
        try backend(transport).removeItem(at: path("/fx/sub"))
        #expect(transport.writes == [.delete("/fx/sub")])
        #expect(throws: VFSError.notFound(path("/fx/sub"))) {
            try backend(self.transport(answering: "delete-missing-404")).removeItem(
                at: path("/fx/sub")
            )
        }
    }

    /// Measured on the NAS and on macOS's Apache alike: 424, nothing deleted, the member named.
    @Test("a folder holding a locked file is not deleted, and the file is named")
    func deleteLockedMember() {
        #expect(throws: VFSError.unsupported(.lockedOnServer(name: "locked.txt"))) {
            try backend(transport(answering: "delete-locked-member-424", body: "xml"))
                .removeItem(at: path("/fx/sub"))
        }
    }

    /// RFC 4918's partial failure. A reader of the status alone would call it deleted.
    @Test("a 207 from a delete is a refusal when a member failed, and success when none did")
    func multiStatusDelete() throws {
        let failed = Data("""
        <?xml version="1.0"?><D:multistatus xmlns:D="DAV:"><D:response><D:href>/fx/sub/a</D:href>\
        <D:status>HTTP/1.1 403 Forbidden</D:status></D:response></D:multistatus>
        """.utf8)
        let refused = FakeWebDAVTransport()
        refused.answerWrite = { _ in WebDAVHTTPResponse(status: 207, body: failed) }
        #expect(throws: VFSError.permissionDenied(path("/fx/sub"))) {
            try backend(refused).removeItem(at: path("/fx/sub"))
        }

        let clean = Data("""
        <?xml version="1.0"?><D:multistatus xmlns:D="DAV:"><D:response><D:href>/fx/sub</D:href>\
        <D:status>HTTP/1.1 204 No Content</D:status></D:response></D:multistatus>
        """.utf8)
        let fine = FakeWebDAVTransport()
        fine.answerWrite = { _ in WebDAVHTTPResponse(status: 207, body: clean) }
        try backend(fine).removeItem(at: path("/fx/sub"))

        let unreadable = FakeWebDAVTransport()
        unreadable.answerWrite = { _ in WebDAVHTTPResponse(status: 207, body: Data("<html>".utf8)) }
        #expect(throws: VFSError.io(path: path("/fx/sub"), code: EIO)) {
            try backend(unreadable).removeItem(at: path("/fx/sub"))
        }
    }

    @Test("the root is never deleted")
    func rootDelete() {
        let transport = FakeWebDAVTransport()
        #expect(throws: VFSError.unsupported(.deleteConnectionRoot)) {
            try backend(transport).removeItem(at: path("/"))
        }
        #expect(transport.writes.isEmpty)
    }
}
