import DirnexCore
import Foundation
import Testing

@testable import Dirnex

/// The guards: what stops Dirnex writing over somebody else's work, and what stops a wrong
/// password locking an account. Each needs a second party — another client, or the server's own
/// log — so they sit apart from the verbs.
extension WebDAVLiveIntegrationTests {
    // MARK: - The save-back

    /// F4's save-back over a file a colleague changed since it was read: refused by its tag, and
    /// the colleague's bytes left standing — the done-when list's fourth line. Then the same save
    /// with the tag the server holds now goes through, and against a file deleted meanwhile it is
    /// refused as gone, creating nothing.
    ///
    /// The tags are waited on until strong: Apache hands out a weak one for the second after any
    /// write, and a weak tag sends no condition at all (`RemoteFileRevision.preconditionTag`), so
    /// a test that did not wait would be checking the unconditional save instead.
    @Test(
        "a save-back over a file changed on the server is refused by its tag",
        arguments: WebDAVLiveEnvironment.endpoints
    )
    func saveBackIsGuardedByTheTag(_ endpoint: WebDAVLiveEndpoint) async throws {
        let mine = Data("my edit\n".utf8)
        let theirs = Data("their edit, which is longer\n".utf8)
        let run = try await offCooperativePool { () -> SaveBackRun in
            let (backend, counting) = endpoint.backend()
            let root = try endpoint.scratchFolder(backend, "etag")
            defer { endpoint.discard(root, on: backend) }
            let file = root.appending("notes.txt")
            try WebDAVLive.upload(Data("as read\n".utf8), to: file, on: backend)
            let local = WebDAVLive.scratchFile()
            try mine.write(to: local)
            defer { try? FileManager.default.removeItem(at: local) }
            let save = { (tag: String) in
                try backend.writeBack(
                    localPath: local.path,
                    to: file,
                    condition: .ifMatches(entityTag: tag),
                    progress: { _ in },
                    isCancelled: { false }
                )
            }
            var run = SaveBackRun(file: file)

            guard let read = try WebDAVLive.strongTag(of: file, on: backend) else { return run }
            // A different length, so even a tag made of the size and a time cut to the second
            // moves when the colleague saves inside the same second.
            run.outsideStatus = try WebDAVOutsideClient(endpoint: endpoint).put(
                theirs,
                at: file.path
            )
            counting.reset()
            run.overChanged = try WebDAVLive.caught { try save(read) }
            run.overChangedRequests = counting.requests
            run.afterRefusal = try WebDAVLive.download(file, on: backend)

            guard let current = try WebDAVLive.strongTag(of: file, on: backend) else { return run }
            run.sentCondition = try save(current)
            run.afterSave = try WebDAVLive.download(file, on: backend)

            try backend.removeItem(at: file)
            run.overGone = try WebDAVLive.caught { try save(current) }
            run.afterGone = try WebDAVLive.caught { _ = try backend.stat(at: file) }
            run.sawStrongTags = true
            return run
        }
        try #require(run.sawStrongTags, "no strong entity tag within five seconds of a write")
        #expect(
            [200, 201, 204].contains(run.outsideStatus),
            "the colleague's save: \(run.outsideStatus)"
        )
        #expect(run.overChanged == .unsupported(.remoteFileChangedSinceFetch(name: "notes.txt")))
        #expect(run.overChangedRequests.first.map {
            if case .put(.ifMatches) = $0 { true } else { false }
        } == true, "the save carried If-Match")
        #expect(run.afterRefusal == theirs)
        #expect(run.sentCondition)
        #expect(run.afterSave == mine)
        #expect(run.overGone == .unsupported(.remoteFileGoneSinceFetch(name: "notes.txt")))
        #expect(run.afterGone == .notFound(run.file), "a refused save creates nothing")
    }

    struct SaveBackRun: Sendable {
        let file: VFSPath
        var sawStrongTags = false
        var outsideStatus = 0
        var overChanged: VFSError?
        var overChangedRequests: [CountingWebDAVTransport.Request] = []
        var afterRefusal = Data()
        var sentCondition = false
        var afterSave = Data()
        var overGone: VFSError?
        var afterGone: VFSError?
    }

    // MARK: - Locks

    /// A file locked by another client: a write says it is locked, by name, and a delete of the
    /// folder holding it names the file and deletes nothing. Reads pass a write lock. Once it is
    /// released, the same delete is one request.
    @Test(
        "a file locked by another client says it is locked",
        arguments: WebDAVLiveEnvironment.endpoints
    )
    func aLockHeldElsewhereIsNamed(_ endpoint: WebDAVLiveEndpoint) async throws {
        let original = Data("held\n".utf8)
        let run = try await offCooperativePool { () -> LockRun in
            let (backend, counting) = endpoint.backend()
            let outside = WebDAVOutsideClient(endpoint: endpoint)
            let root = try endpoint.scratchFolder(backend, "lock")
            let held = root.appending("held.txt")
            var run = LockRun(root: root)
            try WebDAVLive.upload(original, to: held, on: backend)
            guard let token = try outside.lock(held.path) else {
                endpoint.discard(root, on: backend)
                return run
            }
            run.locked = true
            defer {
                _ = try? outside.unlock(held.path, token: token)
                endpoint.discard(root, on: backend)
            }

            run.write = try WebDAVLive.caught {
                try WebDAVLive.upload(Data("overwritten\n".utf8), to: held, on: backend)
            }
            run.delete = try WebDAVLive.caught { try backend.removeItem(at: root) }
            run.rowsAfterDelete = try backend.listDirectory(at: root).map(\.name)
            run.read = try WebDAVLive.download(held, on: backend)

            run.unlockStatus = try outside.unlock(held.path, token: token)
            counting.reset()
            try backend.removeItem(at: root)
            run.deleteRequests = counting.requests
            run.afterDelete = try WebDAVLive.caught { _ = try backend.stat(at: root) }
            return run
        }
        try #require(run.locked, "the outside client could not take the lock")
        #expect(run.write == .unsupported(.lockedOnServer(name: "held.txt")))
        #expect(run.delete == .unsupported(.lockedOnServer(name: "held.txt")))
        #expect(run.rowsAfterDelete == ["held.txt"], "a refused delete deletes nothing")
        #expect(run.read == original)
        #expect(run.unlockStatus == 204)
        #expect(run.deleteRequests == [.delete])
        #expect(run.afterDelete == .notFound(run.root))
    }

    struct LockRun: Sendable {
        let root: VFSPath
        var locked = false
        var write: VFSError?
        var delete: VFSError?
        var rowsAfterDelete: [String] = []
        var read = Data()
        var unlockStatus = 0
        var deleteRequests: [CountingWebDAVTransport.Request] = []
        var afterDelete: VFSError?
    }

    // MARK: - Resume

    /// A download onto a partial copy resumes from its end, byte-identical, and one onto a
    /// complete copy starts over rather than asking for a range past the end, which answers 416
    /// (PLAN.md §M32). Which of the two was sent is the client's own claim; the bytes are the
    /// server's half.
    @Test(
        "a download resumes a partial copy and restarts a complete one",
        arguments: WebDAVLiveEnvironment.endpoints
    )
    func downloadResumesAPartialCopy(_ endpoint: WebDAVLiveEndpoint) async throws {
        let payload = WebDAVLive.payload(200_000)
        let outcome = try await offCooperativePool {
            let (backend, counting) = endpoint.backend()
            let root = try endpoint.scratchFolder(backend, "resume")
            defer { endpoint.discard(root, on: backend) }
            let remote = root.appending("random.bin")
            try WebDAVLive.upload(payload, to: remote, on: backend)
            let local = WebDAVLive.scratchFile()
            defer { try? FileManager.default.removeItem(at: local) }
            let fetch = {
                counting.reset()
                try backend.copyFile(
                    at: remote,
                    to: .local(local.path),
                    progress: { _ in },
                    isCancelled: { false }
                )
                return (counting.requests, try Data(contentsOf: local))
            }

            try payload.prefix(60000).write(to: local)
            let partial = try fetch()
            let complete = try fetch()
            return (partial: partial, complete: complete)
        }
        #expect(outcome.partial.0.contains(.get(resume: true)))
        #expect(outcome.partial.1 == payload)
        #expect(outcome.complete.0.contains(.get(resume: false)))
        #expect(outcome.complete.1 == payload)
    }

    // MARK: - A wrong password

    /// A tree refresh with a password changed on the server costs **one** failed login, not one per
    /// folder — what keeps the NAS's Account Protection from locking the account on a timer. The
    /// count is the server's: the access log's 401s that carry a user, which is a failed login,
    /// where a Digest challenge is a 401 with none (docs/NOTES.md ▸ curl (WebDAV)).
    ///
    /// Only where a wrong password may be sent and the log is a file on this Mac.
    @Test(
        "a batch with a wrong password costs one failed login",
        arguments: WebDAVLiveEnvironment.endpoints.filter {
            $0.mayTryWrongPassword && $0.accessLog != nil && $0.expectedScheme != nil
        }
    )
    func aWrongPasswordCostsOneLogin(_ endpoint: WebDAVLiveEndpoint) async throws {
        let log = try #require(endpoint.accessLog)
        let outcome = try await offCooperativePool {
            let (backend, _) = endpoint.backend()
            let root = try endpoint.scratchFolder(backend, "logins")
            defer { endpoint.discard(root, on: backend) }
            let folders = (1...4).map { root.appending("f\($0)") }
            for folder in folders {
                try backend.createDirectory(at: folder)
            }

            let offset = try FileManager.default.attributesOfItem(atPath: log)[.size] as? Int ?? 0
            let (refused, counting) = endpoint.backend(password: "not-" + endpoint.password)
            let answers = try refused.listDirectories(at: folders, isCancelled: { false })
            let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: log))
            defer { try? handle.close() }
            try handle.seek(toOffset: UInt64(offset))
            let lines = SubprocessText.lossyUTF8(handle.readDataToEndOfFile())
                .split(separator: "\n")
                .filter { $0.contains(root.lastComponent) }
            return (answers, counting.requests, lines.filter(Self.isFailedLogin).count)
        }
        #expect(outcome.0.allSatisfy { $0 == nil })
        #expect(outcome.1 == [.propfindBatch(folders: 4)])
        #expect(outcome.2 == 1, "failed logins in the server's log")
    }

    /// Whether an access-log line from `scripts/live_test_servers.sh`'s format
    /// (`%h %{remote}p %u "%r" %>s`) is a refused login: a 401 with a user.
    static func isFailedLogin(_ line: Substring) -> Bool {
        let parts = line.split(separator: "\"", omittingEmptySubsequences: false)
        guard parts.count >= 3,
              parts[parts.count - 1].trimmingCharacters(in: .whitespaces) == "401" else {
            return false
        }
        let fields = parts[0].split(separator: " ")
        return fields.count >= 3 && fields[2] != "-"
    }
}
