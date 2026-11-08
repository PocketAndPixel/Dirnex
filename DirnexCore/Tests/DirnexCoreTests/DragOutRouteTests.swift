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

    @Test("a file on this disk offers its own URL to every app, with nothing to make")
    func localFilesOfferTheirURL() {
        let file = route(entry(.local("/tmp/a.txt")))
        #expect(file == .fileURL)
        #expect(!file.isPromised)
        #expect(!file.isHandedOff)
        #expect(!file.zipsForOtherApps)
    }

    /// Gmail answers "Attachment failed" for a folder dropped from Chrome, so every app but Finder
    /// is handed a zip of one (2026-11-08). Finder still takes the folder by its own URL.
    @Test("a folder on this disk offers its URL to Finder and a zip to any other app")
    func localFolderIsZippedForOtherApps() {
        let folder = route(entry(.local("/tmp/dir"), kind: .directory))
        #expect(folder == .folderURL)
        #expect(!folder.isPromised)
        #expect(folder.isHandedOff)
        #expect(folder.zipsForOtherApps)
        // A link to a folder is still a link: its own URL, as before.
        #expect(route(entry(.local("/tmp/link"), kind: .symlink)) == .fileURL)
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

    /// Decision B, 2026-11-08: Finder is promised the folder and the queue stages it. Any other app
    /// is handed a zip of it, as a folder on this disk is.
    @Test("a folder on a server is promised to Finder and zipped for any other app")
    func serverFolderIsPromisedToFinderAndZippedForOthers() {
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
            #expect(folder.isHandedOff)
            #expect(folder.zipsForOtherApps)
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

    @Test("what the handoff has to make for another app, and which of it is a zip")
    func handedOffRows() {
        #expect(DragOutRoute.download.isHandedOff)
        #expect(DragOutRoute.extract.isHandedOff)
        #expect(DragOutRoute.downloadFolder.isHandedOff)
        #expect(DragOutRoute.folderURL.isHandedOff)
        #expect(!DragOutRoute.fileURL.isHandedOff)
        #expect(!DragOutRoute.insideDirnexOnly(.lockedArchive).isHandedOff)
        #expect(!DragOutRoute.insideDirnexOnly(.folder).zipsForOtherApps)
        #expect(!DragOutRoute.download.zipsForOtherApps)
        #expect(!DragOutRoute.extract.zipsForOtherApps)
    }

    @Test("a folder's zip is named after it, as a pack of one folder is")
    func zipName() {
        #expect(DragOutRoute.zipName(forFolderNamed: "photos") == "photos.zip")
        #expect(DragOutRoute.zipName(forFolderNamed: "photos.2024") == "photos.2024.zip")
        #expect(DragOutRoute.zipName(forFolderNamed: "Tool.app") == "Tool.app.zip")
        // Not `x.zip.zip`: a folder that already carries the suffix keeps its name.
        #expect(DragOutRoute.zipName(forFolderNamed: "x.zip") == "x.zip")
    }

    @Test("a row of a backend that is no place bytes come from offers nothing")
    func otherBackendsOfferNothing() {
        #expect(
            route(entry(VFSPath(backend: .search, path: "/results"))) == .insideDirnexOnly(.notAFile)
        )
    }
}
