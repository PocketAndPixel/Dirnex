import Foundation
import Testing

@testable import DirnexCore

/// Which rows dragged in from a pane can become a pin, and what the pin carries (PLAN.md §M38).
///
/// The refusals are the point. Each one is a row that would otherwise land in the sidebar looking
/// fine and then fail when it is clicked, possibly only after a relaunch.
@Suite("A pin from a dragged row")
struct FavoriteDraggedRowTests {
    private static let sftpLocation = SFTPLocation(host: "example.com", username: "oleg")
    private static let sftpEndpoint = ServerEndpoint.sftp(
        location: sftpLocation,
        authentication: .key(identityFile: "/Users/oleg/.ssh/id_ed25519")
    )
    private static let ftpLocation = FTPLocation(host: "ftp.example.org", username: "oleg")
    private static let ftpEndpoint = ServerEndpoint.ftp(
        location: ftpLocation,
        authentication: .anonymous
    )
    private static var serverFolder: VFSPath {
        VFSPath(backend: .sftp(sftpLocation), path: "/var/log")
    }

    private func row(_ path: VFSPath, kind: FileEntry.Kind = .directory) -> FileEntry {
        FileEntry(
            path: path,
            name: path.lastComponent,
            kind: kind,
            byteSize: 0,
            modificationDate: FileEntry.unknownDate,
            creationDate: FileEntry.unknownDate,
            isHidden: false,
            permissions: nil,
            inode: 0,
            symlinkDestination: nil
        )
    }

    // MARK: - What makes a pin

    @Test("a folder on a server pins with its own account's endpoint")
    func serverFolderCarriesItsEndpoint() throws {
        let pin = try #require(
            FavoriteEntry(draggedRow: row(Self.serverFolder), endpoint: Self.sftpEndpoint)
        )
        #expect(pin.path == Self.serverFolder)
        #expect(pin.name == "log")
        #expect(pin.serverEndpoint == Self.sftpEndpoint)
    }

    /// The same pin the menu makes, so a pin does not depend on which gesture made it.
    @Test("the dragged pin equals the one the menu makes")
    func sameAsTheMenusPin() {
        let dragged = FavoriteEntry(draggedRow: row(Self.serverFolder), endpoint: Self.sftpEndpoint)
        #expect(dragged == FavoriteEntry(path: Self.serverFolder, endpoint: Self.sftpEndpoint))
    }

    /// A local pin writes no endpoint at all, which is what keeps it byte-identical to earlier builds.
    @Test("a local folder pins with no endpoint")
    func localFolderCarriesNothing() throws {
        let local = VFSPath.local("/Users/oleg/Documents")
        let pin = try #require(FavoriteEntry(draggedRow: row(local), endpoint: nil))
        #expect(pin.endpoint == nil)
        #expect(pin == FavoriteEntry(path: local))
    }

    /// There is one library and nothing about reaching it can change, so there is nothing to store.
    @Test("a folder in Photos pins with no endpoint")
    func photosFolderCarriesNothing() throws {
        let month = VFSPath(backend: .photos, path: "/2026/11")
        let pin = try #require(FavoriteEntry(draggedRow: row(month), endpoint: Self.sftpEndpoint))
        #expect(pin.path == month)
        #expect(pin.endpoint == nil)
    }

    // MARK: - What does not

    @Test("a folder on a server with no endpoint makes no pin")
    func noEndpointNoPin() {
        #expect(FavoriteEntry(draggedRow: row(Self.serverFolder), endpoint: nil) == nil)
    }

    /// One account connecting and another's path listing is a plausible listing under the wrong name.
    @Test("an endpoint for another account makes no pin")
    func anotherAccountsEndpointNoPin() {
        #expect(FavoriteEntry(draggedRow: row(Self.serverFolder), endpoint: Self.ftpEndpoint) == nil)
    }

    @Test("a file makes no pin", arguments: [FileEntry.Kind.file, .symlink, .other])
    func notADirectoryNoPin(kind: FileEntry.Kind) {
        #expect(
            FavoriteEntry(
                draggedRow: row(Self.serverFolder, kind: kind),
                endpoint: Self.sftpEndpoint
            )
                == nil
        )
    }

    @Test("a local symlink makes no pin, as a drag from Finder never has")
    func localSymlinkNoPin() {
        let link = row(.local("/Users/oleg/link"), kind: .symlink)
        #expect(FavoriteEntry(draggedRow: link, endpoint: nil) == nil)
    }

    @Test("a folder inside an archive makes no pin")
    func archiveFolderNoPin() {
        let inside = VFSPath(backend: .archive(forArchiveAt: "/Users/oleg/a.zip"), path: "/docs")
        #expect(FavoriteEntry(draggedRow: row(inside), endpoint: nil) == nil)
    }

    /// Listing `/bucket` on an account backend answers `notFound`: a bucket is reached by connecting.
    @Test("a bucket in an account pane makes no pin")
    func bucketRowNoPin() {
        let account = S3Account(
            host: "s3.eu-central-1.amazonaws.com",
            region: "eu-central-1",
            accessKeyID: "AKIAEXAMPLE"
        )
        let bucket = VFSPath(backend: .s3Account(account), path: "/photos")
        let endpoint = ServerEndpoint.s3Account(account)
        #expect(endpoint.backendID == bucket.backend)
        #expect(FavoriteEntry(draggedRow: row(bucket), endpoint: endpoint) == nil)
    }

    /// As with a bucket: listing `/share` on a server backend answers `notFound`.
    @Test("a share in a server pane makes no pin")
    func shareRowNoPin() {
        let server = SMBLocation(host: "nas.local", username: "oleg")
        let share = VFSPath(backend: .smbServer(server), path: "/media")
        #expect(FavoriteEntry(draggedRow: row(share), endpoint: .smb(server)) == nil)
    }
}
