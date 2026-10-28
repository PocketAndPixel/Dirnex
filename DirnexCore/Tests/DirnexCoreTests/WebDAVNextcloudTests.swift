import Foundation
import Testing

@testable import DirnexCore

/// The second server family (PLAN.md §M32's risk row): Nextcloud 34's sabre/dav, a PHP codebase
/// that shares nothing with Apache's `mod_dav` but the RFC. Every answer here was captured from a
/// throwaway Nextcloud through the shipped argument builders on 2026-10-24, with the container's
/// session cookies removed from the headers.
///
/// What it differs in, and so what these tests pin: the `d:` prefix with `oc:` and `nc:` declared
/// beside it, **names stored in NFC**, a `creationdate` at the Unix epoch on every row, errors as a
/// sabre `<d:error>` document rather than an HTML page, a 412 for `If-None-Match: *` onto a folder,
/// and a 404 for a PUT into a missing folder. `X-OC-Mtime` is `WebDAVModificationTimeTests`.
@Suite("WebDAV: Nextcloud's sabre/dav")
struct WebDAVNextcloudTests {
    static let location = WebDAVLocation(
        host: "127.0.0.1",
        port: 8089,
        username: "probe",
        usesTLS: false,
        rootPath: "/remote.php/dav/files/probe"
    )
    static let folder = "/dirnex-webdav-fixture"
    /// The folder's names as Nextcloud stores them: the ones the NAS fixture holds, sent as they
    /// are, and composed by the server.
    private static let storedNames = Set(WebDAVFixtures.folderNames.compactMap {
        String(bytes: $0, encoding: .utf8).map { Array($0.precomposedStringWithCanonicalMapping.utf8) }
    })

    private func path(_ path: String) -> VFSPath {
        VFSPath(backend: Self.location.backendID, path: path)
    }

    private func backend(_ transport: FakeWebDAVTransport) -> WebDAVBackend {
        WebDAVBackend(location: Self.location, transport: transport)
    }

    static func nextcloud(_ name: String, body: Bool = true) throws -> WebDAVHTTPResponse {
        try WebDAVFixtures.run(
            "curl-exit0-nextcloud-\(name)",
            body: body ? "nextcloud-\(name)" : nil
        )
    }

    private func transport(answering name: String, body: Bool = true) -> FakeWebDAVTransport {
        let transport = FakeWebDAVTransport()
        transport.answerWrite = { _ in try Self.nextcloud(name, body: body) }
        return transport
    }

    // MARK: - Listing

    @Test("its listing reads by namespace, with every name as the server stored it")
    func listsTheFolder() throws {
        let text = try WebDAVFixtures.text("nextcloud-folder-props")
        #expect(text.hasPrefix(#"<?xml version="1.0"?>"#))
        #expect(text.contains(#"<d:multistatus xmlns:d="DAV:""#))
        #expect(text.contains(#"xmlns:oc="http://owncloud.org/ns""#))

        let transport = FakeWebDAVTransport { _ in
            try WebDAVFixtures.run(
                "curl-exit0-nextcloud-propfind-207",
                body: "nextcloud-folder-props"
            )
        }
        let entries = try backend(transport).listDirectory(at: path(Self.folder))
        let byName = Dictionary(uniqueKeysWithValues: entries.map { ($0.name, $0) })

        #expect(Set(entries.map { Array($0.name.utf8) }) == Self.storedNames)
        #expect(byName["Папка"]?.kind == .directory)
        #expect(byName["Папка"]?.byteSize == 0)
        #expect(byName["empty.txt"]?.byteSize == 0)
        #expect(byName["a#b%c;d+e?f&g=h[1].txt"] != nil, "a + is a plus, not a space")
        #expect(byName[".hidden"]?.isHidden == true)
        #expect(byName[" leading space.txt"] != nil)
    }

    /// The server composes what it stores: `cafe\u{301}.txt` was sent decomposed and is listed as
    /// `caf%c3%a9`. The set of names is therefore not the one sent, which is the half that shows
    /// the fixture can tell the two spellings apart.
    @Test("a decomposed name comes back composed, and the fixture tells the two apart")
    func namesAreComposed() throws {
        let text = try WebDAVFixtures.text("nextcloud-folder-props")
        #expect(text.contains("caf%c3%a9.txt"))
        #expect(!text.contains("cafe%cc%81"))
        #expect(Self.storedNames != WebDAVFixtures.folderNames)
    }

    /// Asked for by the decomposed name, the file is found, and its row is named the way it was
    /// asked for: sabre echoes the request's own spelling for the resource it was asked about.
    @Test("a stat by the decomposed name finds the file under the spelling it asked by")
    func statByDecomposedName() throws {
        let text = try WebDAVFixtures.text("nextcloud-stat-decomposed-207")
        #expect(text.contains("cafe%cc%81.txt"))
        let file = Self.folder + "/cafe\u{301}.txt"
        let transport = FakeWebDAVTransport { _ in
            try WebDAVFixtures.multistatus("nextcloud-stat-decomposed-207")
        }
        let entry = try backend(transport).stat(at: path(file))
        #expect(Array(entry.name.utf8) == Array("cafe\u{301}.txt".utf8))
        #expect(entry.kind == .file)
    }

    @Test("a file entry carries the date it was given, a strong tag, and no epoch creation date")
    func fileEntries() throws {
        let text = try WebDAVFixtures.text("nextcloud-folder-props")
        #expect(text.contains("<d:creationdate>1970-01-01T00:00:00+00:00</d:creationdate>"))

        let transport = FakeWebDAVTransport { _ in try WebDAVFixtures.multistatus(
            "nextcloud-folder-props"
        ) }
        let entries = try backend(transport).listDirectory(at: path(Self.folder))
        let file = try #require(entries.first { $0.name == "Привет мир.txt" })
        // Uploaded with `X-OC-Mtime` at the NAS fixture's stamp, through the shipped builder.
        #expect(file.modificationDate == WebDAVFixtures.nasStamp)
        #expect(file.creationDate == WebDAVFixtures.nasStamp, "the epoch is no date")
        let tag = try #require(file.entityTag)
        #expect(!tag.hasPrefix("W/"))
        #expect(RemoteFileRevision(file).preconditionTag == tag)
        let folder = try #require(entries.first { $0.name == "Папка" })
        #expect(folder.creationDate == folder.modificationDate)
    }

    @Test("a file asked for as a folder is the file, so a listing of it is notADirectory")
    func fileAsCollection() {
        let file = Self.folder + "/Привет мир.txt"
        let transport = FakeWebDAVTransport { _ in
            try WebDAVFixtures.multistatus("nextcloud-file-as-collection-207")
        }
        #expect(throws: VFSError.notADirectory(path(file))) {
            try backend(transport).listDirectory(at: path(file))
        }
    }

    @Test("a missing folder is notFound, and sabre's error document names no members")
    func missingFolder() throws {
        let missing = Self.folder + "/no such folder"
        let transport = FakeWebDAVTransport { _ in
            try WebDAVFixtures.run(
                "curl-exit0-nextcloud-propfind-missing-404",
                body: "nextcloud-missing-404"
            )
        }
        #expect(throws: VFSError.notFound(path(missing))) {
            try backend(transport).listDirectory(at: path(missing))
        }
        let refusal = WebDAVServiceError.parse(
            try WebDAVFixtures.data("nextcloud-missing-404"),
            status: 404,
            method: .propfind
        )
        #expect(refusal.members.isEmpty)
    }

    // MARK: - Connecting

    @Test("asked with nothing, it names Basic with a charset, and Basic opens its root")
    func connects() throws {
        let server = FakeWebDAVServer()
        server.answers[nil] = { _ in try Self.nextcloud("propfind-401", body: false) }
        server.answers[.basic] = { _ in try WebDAVFixtures.multistatus("nextcloud-root-depth0-props") }
        let connection = try WebDAVConnectProbe.connect(to: Self.location, over: server.transport)
        #expect(connection == WebDAVConnection(authentication: .basic))
        #expect(server.asked == [nil, .basic])
    }

    // MARK: - Refusals

    /// The 423 names the file by a **relative** href (`files/probe/…`), which Slice 1 refuses to
    /// read, and it sits in an error document rather than a multistatus, so it is not a member.
    /// The name comes from the request instead, which is the same file.
    @Test("a locked file says it is locked, by its own name, on a write and on a delete")
    func lockedFile() throws {
        let text = try WebDAVFixtures.text("nextcloud-put-locked-423")
        #expect(text.contains("<d:href>files/probe/dirnex-webdav-fixture/w/held.txt</d:href>"))
        let scratch = try WebDAVScratch()
        defer { scratch.remove() }
        let local = scratch.path("payload.bin")
        try Data("x".utf8).write(to: URL(fileURLWithPath: local))
        let held = path(Self.folder + "/w/held.txt")

        #expect(throws: VFSError.unsupported(.lockedOnServer(name: "held.txt"))) {
            try backend(transport(answering: "put-locked-423"))
                .copyFile(at: .local(local), to: held, progress: { _ in }, isCancelled: { false })
        }
        #expect(throws: VFSError.unsupported(.lockedOnServer(name: "held.txt"))) {
            try backend(transport(answering: "delete-locked-423")).removeItem(at: held)
        }
    }

    /// Apache answers `If-None-Match: *` onto a folder with 409, which needs a `stat` to tell from
    /// a missing parent; sabre answers 412, which needs none.
    @Test("a create onto a folder is alreadyExists from the 412 alone, with no stat")
    func createOntoAFolder() throws {
        let target = path(Self.folder + "/Папка")
        let transport = transport(answering: "put-onto-folder-412")
        #expect(throws: VFSError.alreadyExists(target)) { try backend(transport).createFile(
            at: target
        ) }
        #expect(transport.propfinds.isEmpty)

        let taken = path(Self.folder + "/w/dated.txt")
        #expect(throws: VFSError.alreadyExists(taken)) {
            try backend(self.transport(answering: "put-ifabsent-412")).createFile(at: taken)
        }
    }

    @Test("an upload into a missing folder names the folder, from sabre's 404")
    func uploadIntoAMissingFolder() throws {
        let scratch = try WebDAVScratch()
        defer { scratch.remove() }
        let local = scratch.path("payload.bin")
        try Data("x".utf8).write(to: URL(fileURLWithPath: local))
        let parent = path(Self.folder + "/w/no parent")
        #expect(throws: VFSError.notFound(parent)) {
            try backend(transport(answering: "put-noparent-404")).copyFile(
                at: .local(local),
                to: parent.appending("x.txt"),
                progress: { _ in },
                isCancelled: { false }
            )
        }
    }

    @Test("MKCOL and MOVE refuse as Apache's do: taken, missing parent, occupied destination")
    func folderAndMoveRefusals() {
        let made = path(Self.folder + "/w")
        #expect(throws: VFSError.alreadyExists(made)) {
            try backend(transport(answering: "mkcol-exists-405")).createDirectory(at: made)
        }
        let missing = path(Self.folder + "/w/no parent")
        #expect(throws: VFSError.notFound(missing)) {
            try backend(transport(answering: "mkcol-noparent-409"))
                .createDirectory(at: missing.appending("deeper"))
        }
        let source = path(Self.folder + "/w/undated.txt")
        let destination = path(Self.folder + "/w/dated.txt")
        #expect(throws: VFSError.alreadyExists(destination)) {
            try backend(transport(answering: "move-exists-412")).moveItem(
                at: source,
                to: destination
            )
        }
        #expect(throws: VFSError.notFound(missing)) {
            try backend(transport(answering: "move-noparent-409"))
                .moveItem(at: source, to: missing.appending("u.txt"))
        }
    }

    /// sabre answers a stale `If-Match` with 412, as Apache does, and the backend asks once whether
    /// the file is still there before it says which.
    @Test("a save-back over a changed file is refused as changed, by sabre's 412")
    func staleSaveBack() throws {
        let scratch = try WebDAVScratch()
        defer { scratch.remove() }
        let local = scratch.path("edited.txt")
        try Data("edit".utf8).write(to: URL(fileURLWithPath: local))
        let file = Self.folder + "/Привет мир.txt"
        let transport = FakeWebDAVTransport { _ in
            try WebDAVFixtures.multistatus("nextcloud-file-depth0-props")
        }
        transport.answerWrite = { _ in try Self.nextcloud("put-ifmatch-stale-412") }
        #expect(throws: VFSError.unsupported(.remoteFileChangedSinceFetch(name: "Привет мир.txt"))) {
            try backend(transport).writeBack(
                localPath: local,
                to: path(file),
                condition: .ifMatches(entityTag: #""0000""#),
                progress: { _ in },
                isCancelled: { false }
            )
        }
        #expect(transport.propfinds == [.init(path: file, depth: .zero, isCollection: false)])
    }
}
