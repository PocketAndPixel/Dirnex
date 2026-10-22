import Foundation
import Testing

@testable import DirnexCore

/// Classifying a WebDAV refusal (PLAN.md §M32 Slice 1). Statuses and bodies are the NAS's, measured
/// 2026-10-22: MKCOL answered 405 on an existing folder and 409 under a missing one, PUT with
/// `If-None-Match: *` and COPY with `Overwrite: F` 412 on an existing file, PUT 423 on a locked
/// file, and DELETE and MOVE of a folder holding a locked file 424 with the member named in the body.
@Suite("WebDAVResponseError")
struct WebDAVResponseErrorTests {
    private static let backend = WebDAVLocation(host: "nas", port: 5006, username: "dirnex-test").backendID
    private static let folder = VFSPath(backend: backend, path: "/home/x")
    private static let file = folder.appending("a.txt")
    private static let target = VFSPath(backend: backend, path: "/home/y/b.txt")

    private func error(_ status: Int, _ method: WebDAVMethod, body: Data = Data()) -> WebDAVServiceError {
        WebDAVServiceError.parse(body, status: status, method: method)
    }

    // MARK: - The member that refused

    @Test("a 424 says nothing on its own; its body names the locked member")
    func failedDependencyIsALock() throws {
        let body = try WebDAVFixtures.data("nas-delete-locked-member-424")
        let refusal = error(424, .delete, body: body)
        #expect(refusal.members.count == 1)
        #expect(refusal.effectiveStatus == 423)
        #expect(refusal.isLocked)
        let locked = try #require(refusal.lockedMemberPaths.first)
        #expect(WebDAVHref.samePath(locked, "/home/dirnex-webdav-fixture/Папка/inside.txt"))
        #expect(refusal.vfsError(for: Self.folder) == .io(path: Self.folder, code: EBUSY))

        // The negative control: the same status without the body is not a lock.
        let bare = error(424, .delete)
        #expect(!bare.isLocked)
        #expect(bare.vfsError(for: Self.folder) == .io(path: Self.folder, code: EIO))
    }

    @Test("a 423 is a lock without any body, and Apache's HTML body adds no members")
    func lockedResource() throws {
        let refusal = error(
            423,
            .put,
            body: try WebDAVFixtures.data("nas-put-locked-423", extension: "html")
        )
        #expect(refusal.members.isEmpty)
        #expect(refusal.isLocked)
    }

    @Test("a 207 defers to its first failing member, and 2xx members are not failures")
    func multiStatusDefersToMembers() {
        let body = Data("""
        <?xml version="1.0"?><D:multistatus xmlns:D="DAV:"><D:response><D:href>/home/x/ok</D:href>\
        <D:status>HTTP/1.1 204 No Content</D:status></D:response><D:response><D:href>/home/x/no\
        </D:href><D:status>HTTP/1.1 403 Forbidden</D:status></D:response></D:multistatus>
        """.utf8)
        let refusal = error(207, .delete, body: body)
        #expect(refusal.members.map(\.path) == ["/home/x/no"])
        #expect(refusal.effectiveStatus == 403)
        #expect(refusal.vfsError(for: Self.folder) == .permissionDenied(Self.folder))
    }

    // MARK: - Statuses by method

    @Test("405 is an existing folder only for MKCOL")
    func methodNotAllowed() {
        #expect(error(405, .mkcol).vfsError(for: Self.folder) == .alreadyExists(Self.folder))
        #expect(
            error(405, .propfind).vfsError(for: Self.folder) == .io(path: Self.folder, code: EIO)
        )
    }

    @Test("409 on a method that creates names the missing folder it goes in")
    func conflictNamesTheMissingParent() {
        #expect(error(409, .mkcol).vfsError(for: Self.file) == .notFound(Self.folder))
        #expect(error(409, .put).vfsError(for: Self.file) == .notFound(Self.folder))
        // For COPY and MOVE that is the destination's folder, not the source's.
        #expect(error(409, .move).vfsError(for: Self.file, destination: Self.target)
            == .notFound(VFSPath(backend: Self.backend, path: "/home/y")))
        #expect(error(409, .propfind).vfsError(for: Self.file) == .io(path: Self.file, code: EIO))
    }

    @Test("412 is something already at the place being created")
    func preconditionFailed() {
        let put = error(412, .put)
        #expect(put.isPreconditionFailed)
        #expect(put.vfsError(for: Self.file) == .alreadyExists(Self.file))
        #expect(error(412, .copy).vfsError(for: Self.file, destination: Self.target)
            == .alreadyExists(Self.target))
    }

    @Test("a missing source of a MOVE is the source")
    func missingSource() {
        #expect(
            error(404, .move).vfsError(for: Self.file, destination: Self.target) == .notFound(
                Self.file
            )
        )
    }

    @Test("the plain statuses", arguments: [
        (401, VFSError.permissionDenied(file)),
        (403, VFSError.permissionDenied(file)),
        (404, VFSError.notFound(file)),
        (413, VFSError.io(path: file, code: EFBIG)),
        (507, VFSError.io(path: file, code: ENOSPC)),
        (400, VFSError.io(path: file, code: EIO)),
        (500, VFSError.io(path: file, code: EIO)),
        (502, VFSError.io(path: file, code: EIO))
    ])
    func plainStatuses(_ status: Int, _ expected: VFSError) {
        #expect(error(status, .get).vfsError(for: Self.file) == expected)
    }

    @Test("only a 401 asks for the password again")
    func credentialFailure() {
        #expect(error(401, .propfind).isCredentialFailure)
        #expect(!error(403, .propfind).isCredentialFailure)
    }

    @Test("curl's exit codes below HTTP")
    func transportFailures() {
        #expect(WebDAVTransportFailure.classify(curlExit: 6) == .couldNotResolveHost)
        #expect(WebDAVTransportFailure.classify(curlExit: 7) == .couldNotConnect)
        #expect(WebDAVTransportFailure.classify(curlExit: 28) == .operationTimedOut)
        // Both measured against the NAS's HTTPS port: no trust, and a wrong pin.
        #expect(WebDAVTransportFailure.classify(curlExit: 60) == .certificateNotTrusted)
        #expect(WebDAVTransportFailure.classify(curlExit: 90) == .pinnedKeyMismatch)
        #expect(WebDAVTransportFailure.classify(curlExit: 22) == .other)
    }
}
