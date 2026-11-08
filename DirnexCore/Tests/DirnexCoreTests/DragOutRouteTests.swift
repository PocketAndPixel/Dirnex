import Foundation
import Testing

@testable import DirnexCore

/// What a dragged row offers another application (PLAN.md §M36 Slice 2).
///
/// The archive member is the new row of the table, and decision A is its one condition: a member of
/// an encrypted archive goes out only once this session holds the passphrase. The rest pins what the
/// three places in the app used to answer for themselves, so moving the answer here changed nothing
/// about a local or a server row.
@Suite("Drag-out route")
struct DragOutRouteTests {
    private let sftp = VFSBackendID("sftp://user@host")
    private let zip = VFSBackendID.archive(forArchiveAt: "/Users/oleg/pkg.zip")

    private func entry(_ path: VFSPath, kind: FileEntry.Kind = .file) -> FileEntry {
        FileEntry(
            path: path,
            name: path.lastComponent,
            kind: kind,
            byteSize: 12,
            modificationDate: Date(timeIntervalSince1970: 1_700_000_000),
            creationDate: Date(timeIntervalSince1970: 1_700_000_000),
            isHidden: false,
            permissions: 0o644,
            inode: 1
        )
    }

    private func route(
        _ entry: FileEntry,
        locked: Set<String> = []
    ) -> DragOutRoute {
        DragOutRoute.route(for: entry) { locked.contains($0) }
    }

    // MARK: - The archive member, the row M36 adds

    @Test("a file in an archive this session can open is extracted for another app")
    func memberIsExtracted() {
        let member = entry(VFSPath(backend: zip, path: "/docs/x.md"))
        #expect(route(member) == .extract)
        #expect(route(member).isPromised)
    }

    /// Decision A, 2026-11-08: no passphrase sheet behind somebody else's drop.
    @Test("a file in a locked archive stays a drag inside Dirnex")
    func lockedMemberStaysInside() {
        let member = entry(VFSPath(backend: zip, path: "/docs/x.md"))
        #expect(route(member, locked: ["/Users/oleg/pkg.zip"]) == .insideDirnexOnly(.lockedArchive))
        #expect(!route(member, locked: ["/Users/oleg/pkg.zip"]).isPromised)
        // Narrow: another archive being locked says nothing about this one.
        #expect(route(member, locked: ["/Users/oleg/other.zip"]) == .extract)
    }

    @Test("a folder or a link inside an archive is not promised, whether or not it is locked")
    func memberFolderIsNotPromised() {
        let folder = entry(VFSPath(backend: zip, path: "/docs"), kind: .directory)
        let link = entry(VFSPath(backend: zip, path: "/latest"), kind: .symlink)
        #expect(route(folder) == .insideDirnexOnly(.folder))
        #expect(route(link) == .insideDirnexOnly(.notAFile))
    }

    /// A drag of rows on this disk must not read an archive header to decide nothing.
    @Test("the lock is asked only of a member file's own archive")
    func lockIsAskedOnlyWhereItMatters() {
        var asked: [String] = []
        let ask: (String) -> Bool = { path in
            asked.append(path)
            return false
        }
        _ = DragOutRoute.route(for: entry(.local("/tmp/a.txt")), archiveIsLocked: ask)
        _ = DragOutRoute.route(
            for: entry(VFSPath(backend: sftp, path: "/srv/a")),
            archiveIsLocked: ask
        )
        _ = DragOutRoute.route(
            for: entry(VFSPath(backend: zip, path: "/docs"), kind: .directory), archiveIsLocked: ask
        )
        #expect(asked.isEmpty)
        _ = DragOutRoute.route(
            for: entry(VFSPath(backend: zip, path: "/x.md")),
            archiveIsLocked: ask
        )
        #expect(asked == ["/Users/oleg/pkg.zip"])
    }

    // MARK: - What the app answered before, unchanged

    @Test("a row on this disk offers its own URL, a folder included")
    func localRowsOfferTheirURL() {
        #expect(route(entry(.local("/tmp/a.txt"))) == .fileURL)
        #expect(route(entry(.local("/tmp/dir"), kind: .directory)) == .fileURL)
        #expect(!route(entry(.local("/tmp/a.txt"))).isPromised)
    }

    @Test("a file on a server is downloaded, and handed to other apps as well as to Finder")
    func serverRows() {
        let file = route(entry(VFSPath(backend: sftp, path: "/srv/report.pdf")))
        #expect(file == .download)
        #expect(file.isPromised)
        #expect(file.isHandedOff)
        #expect(route(entry(VFSPath(backend: sftp, path: "/srv/link"), kind: .symlink))
            == .insideDirnexOnly(.notAFile))
    }

    // MARK: - A folder on a server, the row Slice 3 adds

    /// Decision B, 2026-11-08: Finder is promised the folder and the queue stages it, while an app
    /// that takes no promise is offered nothing for it until probe P2 says one takes a folder.
    @Test("a folder on a server is promised to Finder and handed to no other app")
    func serverFolderIsPromisedToFinderOnly() {
        let backends = [
            sftp,
            VFSBackendID("ftp://user@host"),
            S3Location(host: "s3.example.com", bucket: "b", region: "eu-west-1", accessKeyID: "K")
                .backendID
        ]
        for backend in backends {
            let folder = route(
                entry(VFSPath(backend: backend, path: "/srv/photos"), kind: .directory)
            )
            #expect(folder == .downloadFolder, "\(backend.rawValue)")
            #expect(folder.isPromised)
            #expect(!folder.isHandedOff)
        }
    }

    /// An account pane's rows are buckets and a server pane's are shares: places, not folders the
    /// queue's copy can walk from where they are listed.
    @Test("a bucket or a share listed at an account's top level is not promised")
    func accountLevelRowsAreNotPromised() {
        let account = S3Location(
            host: "s3.example.com", bucket: "b", region: "eu-west-1", accessKeyID: "K"
        ).account.backendID
        let server = VFSBackendID.smbServer(SMBLocation(host: "nas"))
        #expect(account.isRemoteConnection)
        #expect(server.isRemoteConnection)
        for backend in [account, server] {
            #expect(route(entry(VFSPath(backend: backend, path: "/media"), kind: .directory))
                == .insideDirnexOnly(.folder))
        }
    }

    @Test("only a file on a server or in an archive is handed to other apps")
    func handedOffRows() {
        #expect(DragOutRoute.download.isHandedOff)
        #expect(DragOutRoute.extract.isHandedOff)
        #expect(!DragOutRoute.downloadFolder.isHandedOff)
        #expect(!DragOutRoute.fileURL.isHandedOff)
        #expect(!DragOutRoute.insideDirnexOnly(.lockedArchive).isHandedOff)
    }

    @Test("a row of a backend that is no place bytes come from offers nothing")
    func otherBackendsOfferNothing() {
        #expect(
            route(entry(VFSPath(backend: .search, path: "/results"))) == .insideDirnexOnly(.notAFile)
        )
    }
}
