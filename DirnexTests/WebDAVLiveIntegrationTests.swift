import DirnexCore
import Foundation
import Testing

@testable import Dirnex

/// WebDAV against real servers, through the real `WebDAVCurlTransport` → `WebDAVBackend` chain
/// (PLAN.md §M32 Slice 6). Every test runs once per endpoint the config names
/// (``WebDAVLiveEnvironment``), so one suite covers macOS's Apache over HTTP with Basic, Digest and
/// no account, over HTTPS with a pinned self-signed certificate, and whatever else joins the file:
/// the NAS over either port, or a second server family.
///
/// The core suites pin every rule against captured bytes. What only a live run can show is that
/// the requests those rules build are the ones a server acts on as intended: that a name with
/// every character a URL gives a meaning to arrives as itself, that `If-None-Match: *` and
/// `If-Match` are honoured, that a lock held elsewhere comes back as a lock, and that the batch's
/// guard against a wrong password still costs one failed login with this Mac's `curl`.
///
/// Two kinds of claim, kept apart. **The client's own** — how many requests a verb sent, and
/// which — is read off a counting wrapper around the transport, and holds whatever server answers.
/// **The server's** is checked only where the code relies on it (the create-if-absent leaves the
/// bytes alone because no `stat` guards it) or where the endpoint's config states it.
///
/// Every body runs inside ``offCooperativePool`` and hands its observations back, and the
/// assertions run outside it, so a failure is filed under its own test and endpoint rather than
/// under `Test «unknown»` (docs/NOTES.md ▸ Live suites).
@Suite("WebDAV live integration", .enabled(if: WebDAVLiveEnvironment.isEnabled))
struct WebDAVLiveIntegrationTests {
    /// The names PLAN.md §M32's done-when list asks to survive: Cyrillic, a **decomposed** é, and
    /// `# % ; + ? & = [ ]`, each of which means something in a URL or a form.
    static let awkwardFile = "cafe\u{301} #%;+?&=[] Жж.txt"
    static let awkwardFolder = "Новая [папка] #1 + e\u{301} & ;="
    static let renamedFile = "переименован %25 + e\u{301}? [x].txt"
    static let renamedFolder = "Папка #2 = [готово] %"

    // MARK: - Connecting

    @Test(
        "connects, settling the scheme the server asks for",
        arguments: WebDAVLiveEnvironment.endpoints
    )
    func connects(_ endpoint: WebDAVLiveEndpoint) async throws {
        let (connection, seconds, rootRows) = try await offCooperativePool {
            let probe = endpoint.transport(authentication: .some(nil))
            let start = Date()
            let connection = try WebDAVConnectProbe.connect(to: endpoint.location) {
                probe.authenticating(with: $0)
            }
            let seconds = Date().timeIntervalSince(start)
            let backend = WebDAVBackend(
                location: endpoint.location,
                transport: probe.authenticating(with: connection.authentication)
            )
            // The root lists under the scheme the probe settled, which is the connection the
            // pane goes on to use.
            let root = VFSPath(backend: endpoint.location.backendID, path: "/")
            return (connection, seconds, try backend.listDirectory(at: root).map(\.name))
        }
        #expect(connection.authentication == endpoint.expectedScheme)
        #expect(rootRows.allSatisfy { !$0.isEmpty })
        if let limit = endpoint.connectWithinSeconds {
            #expect(seconds < limit, "connect took \(seconds) s")
        }
    }

    /// The refusals a connect must name, each tried only where it is safe and its answer is a fact
    /// about the endpoint. No user and a wrong pin cost no login anywhere: the first request goes
    /// without credentials whatever happens, and a pin is weighed before any HTTP is sent.
    @Test(
        "refuses no user, a wrong password, a wrong pin and no pin",
        arguments: WebDAVLiveEnvironment.endpoints
    )
    func connectRefusals(_ endpoint: WebDAVLiveEndpoint) async throws {
        let wrongPin = Data(repeating: 0, count: 32).base64EncodedString()
        let refusals = try await offCooperativePool { () -> [String: WebDAVConnectError?] in
            func refusal(
                _ location: WebDAVLocation,
                password: String = endpoint.password,
                pin: String?
            ) -> WebDAVConnectError? {
                let probe = WebDAVCurlTransport(
                    location: location,
                    password: password,
                    trustedPublicKey: pin,
                    authentication: nil
                )
                do {
                    _ = try WebDAVConnectProbe.connect(to: location) { probe.authenticating(with: $0) }
                    return nil
                } catch {
                    return error as? WebDAVConnectError
                }
            }
            let location = endpoint.location
            var refusals: [String: WebDAVConnectError?] = [:]
            if endpoint.expectedScheme != nil {
                let anonymous = WebDAVLocation(
                    host: location.host,
                    port: location.port,
                    username: "",
                    usesTLS: location.usesTLS,
                    rootPath: location.rootPath
                )
                refusals["no user"] = refusal(anonymous, pin: endpoint.trustedPublicKey)
                if endpoint.mayTryWrongPassword {
                    refusals["wrong password"] = refusal(
                        location,
                        password: "not-" + endpoint.password,
                        pin: endpoint.trustedPublicKey
                    )
                }
            }
            if location.usesTLS {
                refusals["wrong pin"] = refusal(location, pin: wrongPin)
                if endpoint.isSelfSigned { refusals["no pin"] = refusal(location, pin: nil) }
            }
            return refusals
        }
        if endpoint.expectedScheme != nil {
            #expect(refusals["no user"] == .some(.credentialsRequired))
            if endpoint.mayTryWrongPassword {
                #expect(refusals["wrong password"] == .some(.credentialsRefused))
            }
        }
        if endpoint.location.usesTLS {
            #expect(refusals["wrong pin"] == .some(.transport(.pinnedKeyMismatch)))
            if endpoint.isSelfSigned {
                #expect(refusals["no pin"] == .some(.transport(.certificateNotTrusted)))
            }
        }
    }

    // MARK: - Names

    /// A name with every awkward character, through create, list, rename, copy, move and delete —
    /// the done-when list's third line. Names are compared as bytes, and where the server's folder
    /// is on this disk the bytes on disk are read as a second witness.
    @Test(
        "an awkward name survives create, list, rename, copy and delete",
        arguments: WebDAVLiveEnvironment.endpoints
    )
    func awkwardNamesSurvive(_ endpoint: WebDAVLiveEndpoint) async throws {
        let payload = WebDAVLive.payload(3000)
        let run = try await offCooperativePool { () -> NameRun in
            let (backend, counting) = endpoint.backend()
            let root = try endpoint.scratchFolder(backend, "names")
            defer { endpoint.discard(root, on: backend) }
            let names = { (path: VFSPath) in
                try backend.listDirectory(at: path).map { WebDAVLive.bytes($0.name) }
            }
            var run = NameRun()

            let folder = root.appending(Self.awkwardFolder)
            try backend.createDirectory(at: folder)
            let file = folder.appending(Self.awkwardFile)
            try WebDAVLive.upload(payload, to: file, on: backend)
            run.rootRows = try names(root)
            run.folderRows = try names(folder)
            if let served = endpoint.servedFrom {
                run.onDisk = try FileManager.default
                    .contentsOfDirectory(atPath: served + folder.path)
                    .map(WebDAVLive.bytes)
            }

            let renamed = folder.appending(Self.renamedFile)
            counting.reset()
            try backend.moveItem(at: file, to: renamed)
            run.renameRequests = counting.requests
            run.afterRename = try names(folder)

            let copy = root.appending(Self.awkwardFile)
            counting.reset()
            try backend.copyFile(at: renamed, to: copy, progress: { _ in }, isCancelled: { false })
            run.copyRequests = counting.requests

            let movedFolder = root.appending(Self.renamedFolder)
            counting.reset()
            try backend.moveItem(at: folder, to: movedFolder)
            run.folderMoveRequests = counting.requests
            run.movedFolderRows = try names(movedFolder)
            run.renamedBytes = try WebDAVLive.download(
                movedFolder.appending(Self.renamedFile),
                on: backend
            )
            run.copyBytes = try WebDAVLive.download(copy, on: backend)

            counting.reset()
            try backend.removeItem(at: root)
            run.deleteRequests = counting.requests
            run.afterDelete = try WebDAVLive.caught { _ = try backend.stat(at: root) }
            run.root = root
            return run
        }
        let file = WebDAVLive.bytes(Self.awkwardFile)
        #expect(run.rootRows == [WebDAVLive.bytes(Self.awkwardFolder)])
        #expect(run.folderRows == [file])
        if endpoint.servedFrom != nil { #expect(run.onDisk == [file]) }
        #expect(run.renameRequests == [.move], "a rename is one MOVE")
        #expect(run.afterRename == [WebDAVLive.bytes(Self.renamedFile)])
        #expect(run.copyRequests.contains(.copy))
        #expect(
            !run.copyRequests.contains { $0.movesBytes },
            "a copy in the account is the server's"
        )
        #expect(run.folderMoveRequests == [.move], "a folder moves in one MOVE")
        #expect(run.movedFolderRows == [WebDAVLive.bytes(Self.renamedFile)])
        #expect(run.renamedBytes == payload)
        #expect(run.copyBytes == payload)
        #expect(run.deleteRequests == [.delete], "a tree is deleted in one DELETE")
        #expect(run.afterDelete == run.root.map(VFSError.notFound))
    }

    // MARK: - Creating

    /// ⇧F4 and F7 against a taken name. The create-if-absent is **one** PUT with
    /// `If-None-Match: *` and no `stat` before it (`WebDAVBackend.createFile`), so whether the
    /// existing file's bytes survive is the server honouring the header — which is exactly the
    /// claim that decision rests on, checked here per endpoint.
    @Test(
        "a taken name is refused, and the file there keeps its bytes",
        arguments: WebDAVLiveEnvironment.endpoints
    )
    func takenNamesAreRefused(_ endpoint: WebDAVLiveEndpoint) async throws {
        let original = Data("hello".utf8)
        let outcome = try await offCooperativePool {
            let (backend, counting) = endpoint.backend()
            let root = try endpoint.scratchFolder(backend, "create")
            defer { endpoint.discard(root, on: backend) }
            let file = root.appending("notes.txt")
            try WebDAVLive.upload(original, to: file, on: backend)
            let folder = root.appending("photos")
            try backend.createDirectory(at: folder)
            let orphan = root.appending("no_such_parent/child")
            let other = root.appending("other.txt")
            try WebDAVLive.upload(Data("other".utf8), to: other, on: backend)

            counting.reset()
            let ontoFile = try WebDAVLive.caught { try backend.createFile(at: file) }
            let createRequests = counting.requests
            return (
                ontoFile: ontoFile,
                createRequests: createRequests,
                bytes: try WebDAVLive.download(file, on: backend),
                ontoFolder: try WebDAVLive.caught { try backend.createFile(at: folder) },
                folderAgain: try WebDAVLive.caught { try backend.createDirectory(at: folder) },
                orphan: try WebDAVLive.caught { try backend.createDirectory(at: orphan) },
                moveOnto: try WebDAVLive.caught { try backend.moveItem(at: other, to: file) },
                afterMove: try WebDAVLive.download(file, on: backend),
                otherAfterMove: try WebDAVLive.download(other, on: backend),
                paths: (file, folder, orphan)
            )
        }
        let (file, folder, orphan) = outcome.paths
        #expect(outcome.ontoFile == .alreadyExists(file))
        #expect(outcome.createRequests == [.putEmpty(.ifAbsent)], "no stat guards the create")
        #expect(outcome.bytes == original)
        #expect(outcome.ontoFolder == .alreadyExists(folder))
        #expect(outcome.folderAgain == .alreadyExists(folder))
        #expect(outcome.orphan == .notFound(try #require(orphan.parent)))
        #expect(outcome.moveOnto == .alreadyExists(file), "MOVE carries Overwrite: F")
        #expect(outcome.afterMove == original)
        #expect(outcome.otherAfterMove == Data("other".utf8))
    }
}

// MARK: - Listing

extension WebDAVLiveIntegrationTests {
    /// `subtreeListing` against the walk it stands in for, on a real tree: its contract is that
    /// the two are indistinguishable, so the walk is written out here rather than borrowed from a
    /// caller of the code under test (`FTPLiveIntegrationTests` makes the same argument).
    @Test(
        "the subtree shortcut answers exactly what walking the same tree does",
        arguments: WebDAVLiveEnvironment.endpoints
    )
    func subtreeListingMatchesTheWalk(_ endpoint: WebDAVLiveEndpoint) async throws {
        let (listing, walked) = try await offCooperativePool {
            let (backend, _) = endpoint.backend()
            let root = try endpoint.scratchFolder(backend, "subtree")
            defer { endpoint.discard(root, on: backend) }
            try backend.createFile(at: root.appending("top.txt"))
            let docs = root.appending("docs")
            try backend.createDirectory(at: docs)
            try WebDAVLive.upload(Data("report".utf8), to: docs.appending("report.txt"), on: backend)
            let images = docs.appending("images")
            try backend.createDirectory(at: images)
            try backend.createFile(at: images.appending("photo.txt"))
            // Empty: what separates "listed, and empty" from "could not be listed".
            try backend.createDirectory(at: root.appending("empty"))

            let listing = try backend.subtreeListing(at: root, isCancelled: { false })
            var walked: [FileEntry] = []
            var queue = [root]
            var head = 0
            while head < queue.count {
                let directory = queue[head]
                head += 1
                guard let entries = try? backend.listDirectory(at: directory) else { continue }
                for entry in entries {
                    walked.append(entry)
                    if entry.isDirectory { queue.append(entry.path) }
                }
            }
            return (listing, walked)
        }
        let shortcut = try #require(listing)
        #expect(shortcut.isComplete)
        #expect(shortcut.entries.count == 6)
        #expect(Set(shortcut.entries.map(\.path.path)) == Set(walked.map(\.path.path)))
        for entry in shortcut.entries {
            let match = try #require(walked.first { $0.path == entry.path })
            #expect(entry.kind == match.kind)
            #expect(entry.byteSize == match.byteSize)
            #expect(entry.modificationDate == match.modificationDate)
            #expect(entry.entityTag == match.entityTag)
        }
    }

    /// A tree refresh's batch, with a folder deleted since it was listed: in the middle it is that
    /// section's own answer, and **first** it stops the run, so the rest go out once more
    /// (`WebDAVBackend.listLevel`, docs/NOTES.md ▸ curl (WebDAV)).
    @Test(
        "a batched listing reads a missing folder as that folder's answer",
        arguments: WebDAVLiveEnvironment.endpoints
    )
    func batchedListingSeparatesAMissingFolder(_ endpoint: WebDAVLiveEndpoint) async throws {
        let outcome = try await offCooperativePool {
            let (backend, counting) = endpoint.backend()
            let root = try endpoint.scratchFolder(backend, "batch")
            defer { endpoint.discard(root, on: backend) }
            let empty = root.appending("empty")
            try backend.createDirectory(at: empty)
            let missing = root.appending("no_such_folder")

            counting.reset()
            let middle = try backend.listDirectories(
                at: [empty, missing, root],
                isCancelled: { false }
            )
            let middleRequests = counting.requests
            counting.reset()
            let first = try backend.listDirectories(
                at: [missing, empty, root],
                isCancelled: { false }
            )
            return (middle, middleRequests, first, counting.requests)
        }
        let names = { (rows: [FileEntry]?) in rows.map { $0.map(\.name) } }
        #expect(outcome.0.map(names) == [[], nil, ["empty"]])
        #expect(outcome.1 == [.propfindBatch(folders: 3)])
        #expect(outcome.2.map(names) == [nil, [], ["empty"]])
        #expect(outcome.3.count == 2, "the run stopped at the first folder and the rest went again")
        #expect(outcome.3.first == .propfindBatch(folders: 3))
    }

    /// What ``awkwardNamesSurvive(_:)`` saw, handed out of the blocking body to be asserted on.
    struct NameRun: Sendable {
        var rootRows: [[UInt8]] = []
        var folderRows: [[UInt8]] = []
        var onDisk: [[UInt8]]?
        var renameRequests: [CountingWebDAVTransport.Request] = []
        var afterRename: [[UInt8]] = []
        var copyRequests: [CountingWebDAVTransport.Request] = []
        var folderMoveRequests: [CountingWebDAVTransport.Request] = []
        var movedFolderRows: [[UInt8]] = []
        var renamedBytes = Data()
        var copyBytes = Data()
        var deleteRequests: [CountingWebDAVTransport.Request] = []
        var afterDelete: VFSError?
        var root: VFSPath?
    }
}
