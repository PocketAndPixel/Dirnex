import Foundation
import Testing
import UniformTypeIdentifiers

@testable import DirnexCore

/// Which icon a row gets (``RowIcon/of(_:mounts:showsPreviews:)``): the item's own and a picture of
/// the content only for an item on this Mac's storage with its bytes here, the type icon otherwise.
@Suite("Row icon")
struct RowIconTests {
    /// The boot disk, a share, and a local drive whose name starts like the share's, so a prefix match
    /// that ignored component boundaries would put it on the network.
    private static let mounts = [
        MountTableEntry(mountPoint: "/", isLocal: true),
        MountTableEntry(mountPoint: "/Volumes/NAS", isLocal: false),
        MountTableEntry(mountPoint: "/Volumes/NASBackup", isLocal: true)
    ]

    private static func entry(
        _ path: String,
        kind: FileEntry.Kind = .file,
        target: FileEntry.Kind? = nil,
        dataless: Bool = false,
        backend: VFSBackendID = .local
    ) -> FileEntry {
        FileEntry(
            path: VFSPath(backend: backend, path: path),
            name: (path as NSString).lastPathComponent,
            kind: kind,
            byteSize: 1,
            modificationDate: Date(timeIntervalSince1970: 0),
            creationDate: Date(timeIntervalSince1970: 0),
            isHidden: false,
            permissions: 0o644,
            inode: 0,
            symlinkTargetKind: target,
            isDataless: dataless
        )
    }

    private static func icon(_ entry: FileEntry, previews: Bool = true) -> RowIcon {
        RowIcon.of(entry, mounts: mounts, showsPreviews: previews)
    }

    private static let sftp = VFSBackendID("sftp://probe@example.com:22")

    // MARK: - Folders

    @Test("a folder on this Mac is asked for its own icon, a package or a plain one alike")
    func localFolderIsItem() {
        let app = Self.entry("/Applications/Xcode.app", kind: .directory)
        #expect(Self.icon(app) == .item(packageType: .applicationBundle))
        #expect(
            Self.icon(Self.entry("/Users/probe/Music", kind: .directory)) == .item(packageType: nil)
        )
        let drive = Self.entry("/Volumes/NASBackup/Photos", kind: .directory)
        #expect(Self.icon(drive) == .item(packageType: nil))
    }

    @Test("asking for a folder's own icon does not depend on the previews setting")
    func folderIgnoresPreviews() {
        let app = Self.entry("/Applications/Xcode.app", kind: .directory)
        #expect(Self.icon(app, previews: false) == .item(packageType: .applicationBundle))
    }

    @Test("a folder off this Mac is the generic folder, and a package keeps its type")
    func remoteFolder() {
        let share = Self.entry("/Volumes/NAS/Projects", kind: .directory)
        #expect(Self.icon(share) == .folder)
        let app = Self.entry("/Volumes/NAS/Tools.app", kind: .directory)
        #expect(Self.icon(app) == .type(.applicationBundle))
        let overSFTP = Self.entry("/home/probe/Tools.app", kind: .directory, backend: Self.sftp)
        #expect(Self.icon(overSFTP) == .type(.applicationBundle))
        let inArchive = Self.entry(
            "/inner",
            kind: .directory,
            backend: .archive(forArchiveAt: "/Users/probe/a.zip")
        )
        #expect(Self.icon(inArchive) == .folder)
    }

    @Test("a dataless folder is not read for its icon")
    func datalessFolder() {
        let drive = "/Users/probe/Library/Mobile Documents/com~apple~CloudDocs/"
        #expect(Self.icon(Self.entry(drive + "Old", kind: .directory, dataless: true)) == .folder)
        let bundle = Self.entry(drive + "Notes.rtfd", kind: .directory, dataless: true)
        #expect(Self.icon(bundle) == .type(.rtfd))
    }

    @Test("a symlink to a folder is the generic folder, never followed")
    func symlinkToFolder() {
        #expect(
            Self.icon(Self.entry("/Users/probe/link", kind: .symlink, target: .directory)) == .folder
        )
    }

    // MARK: - Files

    @Test("an image, a movie and a PDF on this Mac get a picture of the content")
    func previewedTypes() {
        #expect(Self.icon(Self.entry("/Users/probe/a.png")) == .thumbnail(fallback: .png))
        #expect(Self.icon(Self.entry("/Users/probe/IMG_0234.HEIC")) == .thumbnail(fallback: .heic))
        #expect(
            Self.icon(Self.entry("/Users/probe/clip.mov")) == .thumbnail(fallback: .quickTimeMovie)
        )
        #expect(Self.icon(Self.entry("/Users/probe/receipt.pdf")) == .thumbnail(fallback: .pdf))
        #expect(Self.icon(Self.entry("/Volumes/NASBackup/a.jpg")) == .thumbnail(fallback: .jpeg))
    }

    @Test("text and audio keep their type icon, which says more at row size")
    func notPreviewed() {
        #expect(Self.icon(Self.entry("/Users/probe/notes.txt")) == .type(.plainText))
        #expect(Self.icon(Self.entry("/Users/probe/data.json")) == .type(.json))
        #expect(Self.icon(Self.entry("/Users/probe/voice.wav")) == .type(.wav))
        #expect(Self.icon(Self.entry("/Users/probe/archive.zip")) == .type(.zip))
    }

    @Test("the previews setting turns the picture off")
    func previewsOff() {
        #expect(Self.icon(Self.entry("/Users/probe/a.png"), previews: false) == .type(.png))
    }

    @Test("an image off this Mac, or not downloaded, keeps its type icon")
    func imageNotHere() {
        #expect(Self.icon(Self.entry("/Volumes/NAS/a.png")) == .type(.png))
        #expect(Self.icon(Self.entry("/home/probe/a.png", backend: Self.sftp)) == .type(.png))
        #expect(
            Self.icon(Self.entry("/Users/probe/Library/CloudStorage/Box-Box/a.png", dataless: true))
                == .type(.png)
        )
        let inArchive = Self.entry("/a.png", backend: .archive(forArchiveAt: "/Users/probe/a.zip"))
        #expect(Self.icon(inArchive) == .type(.png))
    }

    @Test("a symlink to an image keeps its type icon")
    func symlinkToImage() {
        #expect(
            Self.icon(Self.entry("/Users/probe/a.png", kind: .symlink, target: .file)) == .type(.png)
        )
    }

    @Test("a name with no extension is plain data")
    func noExtension() {
        #expect(Self.icon(Self.entry("/Users/probe/Makefile")) == .type(.data))
    }

    @Test("an unreadable mount table is treated as a share")
    func noMounts() {
        let entry = Self.entry("/Users/probe/a.png")
        #expect(RowIcon.of(entry, mounts: [], showsPreviews: true) == .type(.png))
        let folder = Self.entry("/Users/probe/Music", kind: .directory)
        #expect(RowIcon.of(folder, mounts: [], showsPreviews: true) == .folder)
    }
}
