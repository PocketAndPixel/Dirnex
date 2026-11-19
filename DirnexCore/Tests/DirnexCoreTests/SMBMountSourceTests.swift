import Foundation
import Testing

@testable import DirnexCore

/// Reading an SMB mount's source from the mount table (PLAN.md §M40 Slice 8).
///
/// The first case is what this Mac's mount table held for the NAS share Finder mounted, measured
/// 2026-11-19. The rest follow the escaping Apple's SMB client applies when it writes the source
/// (`CreateSMBFromName`, `smb_dictionary_to_urlstring` in apple-oss-distributions/SMBClient's
/// `lib/smb/parse_url.c`), since no share on the NAS has a name that needs it.
@Suite("SMB mount source")
struct SMBMountSourceTests {
    private static func share(_ source: String) -> SMBLocation? {
        SMBMountSource(source: source)?.share
    }

    @Test("Finder's mount of the NAS share names its server, account and share")
    func measuredSource() throws {
        let source = try #require(SMBMountSource(source: "//olegasd@nas/media"))
        #expect(source.share == SMBLocation(host: "nas", share: "media", username: "olegasd"))
        #expect(source.isWholeShare)
        #expect(source.share.server.url == "smb://olegasd@nas")
    }

    @Test("a guest mount, or an account spelled guest in any case, is a guest")
    func guests() {
        #expect(Self.share("//GUEST:@nas/Public") == SMBLocation(host: "nas", share: "Public"))
        #expect(Self.share("//guest@nas/Public") == SMBLocation(host: "nas", share: "Public"))
        #expect(Self.share("//nas/Public") == SMBLocation(host: "nas", share: "Public"))
    }

    @Test("an account with an empty password keeps its name, without the colon")
    func emptyPassword() {
        #expect(Self.share("//oleg:@nas/media")?.username == "oleg")
    }

    @Test("escaped parts read as their names")
    func escapes() {
        #expect(Self.share("//oleg@nas/My%20Share")?.share == "My Share")
        #expect(Self.share("//oleg@nas/Open%2FSpace")?.share == "Open/Space")
        #expect(Self.share("//oleg@nas/%D0%9F%D0%B0%D0%BD%D0%BE%D1%80%D0%B0%D0%BC%D0%B0")?.share
            == "Панорама")
        #expect(Self.share("//first.last%40example.com@server/share")?.username
            == "first.last@example.com")
        #expect(Self.share("//oleg@Oleg%27s%20NAS._smb._tcp.local/media")?.host
            == "Oleg's NAS._smb._tcp.local")
        // An escape that does not decode is read as written rather than dropped.
        #expect(Self.share("//oleg@nas/100%zz")?.share == "100%zz")
    }

    @Test("a domain account is spelled as the Connect sheet's own parse spells it")
    func domainAccount() {
        let mounted = Self.share("//CORP;jdoe@fs1/Projects")
        #expect(mounted?.username == "CORP;jdoe")
        #expect(mounted == SMBLocation(url: "smb://CORP;jdoe@fs1/Projects"))
    }

    @Test("a port is read, and the default port stays out of the URL")
    func ports() {
        #expect(Self.share("//oleg@nas:1445/media")?.port == 1445)
        #expect(Self.share("//oleg@nas:1445/media")?.server.url == "smb://oleg@nas:1445")
        #expect(Self.share("//oleg@nas/media")?.port == SMBLocation.defaultPort)
        #expect(Self.share("//oleg@[fe80::1]/media")?.host == "[fe80::1]")
        #expect(Self.share("//oleg@[fe80::1]:1445/media")?.port == 1445)
    }

    @Test("a mount of a folder inside a share names the share and the folder")
    func folderInsideAShare() throws {
        let source = try #require(SMBMountSource(source: "//oleg@nas/media/Movies/Old%20Films"))
        #expect(source.share.share == "media")
        #expect(source.folder == ["Movies", "Old Films"])
        #expect(!source.isWholeShare)
    }

    @Test("anything that names no share on a server is not a share's source")
    func notASource() {
        #expect(SMBMountSource(source: "/dev/disk3s1") == nil)
        #expect(SMBMountSource(source: "") == nil)
        #expect(SMBMountSource(source: "//nas") == nil)
        #expect(SMBMountSource(source: "//nas/") == nil)
        #expect(SMBMountSource(source: "//oleg@/media") == nil)
        #expect(SMBMountSource(source: "//oleg@nas:smb/media") == nil)
    }

    @Test("only a network smbfs entry is read")
    func entries() {
        let share = MountTableEntry(
            mountPoint: "/Volumes/media",
            isLocal: false,
            fileSystemType: "smbfs",
            source: "//olegasd@nas/media"
        )
        #expect(SMBMountSource(entry: share)?.share.share == "media")
        let disk = MountTableEntry(
            mountPoint: "/Volumes/media",
            isLocal: true,
            fileSystemType: "apfs",
            source: "//olegasd@nas/media"
        )
        #expect(SMBMountSource(entry: disk) == nil)
        let webdav = MountTableEntry(
            mountPoint: "/Volumes/media",
            isLocal: false,
            fileSystemType: "webdav",
            source: "//olegasd@nas/media"
        )
        #expect(SMBMountSource(entry: webdav) == nil)
    }

    @Test("the mount table reads each file system's type and source")
    func mountTableFields() throws {
        let root = try #require(MountTable.current().first { $0.mountPoint == "/" })
        #expect(root.fileSystemType == "apfs")
        #expect(root.source.hasPrefix("/dev/disk"))
    }

    // MARK: - Reusing a mount

    @Test("a mount is reused for its share whoever mounted it, in any case")
    func reuse() throws {
        let source = try #require(SMBMountSource(source: "//olegasd@nas/media"))
        #expect(source.mounts(SMBLocation(host: "nas", share: "media", username: "dirnex-test")))
        #expect(source.mounts(SMBLocation(host: "NAS", share: "Media")))
        #expect(!source.mounts(SMBLocation(host: "nas", share: "home")))
        #expect(!source.mounts(SMBLocation(host: "nas", share: "media", port: 1445)))
        #expect(!source.mounts(SMBLocation(host: "nas")))
    }

    @Test("a share whose name the source escapes is still the mount's share")
    func reuseEscapedShare() throws {
        let source = try #require(SMBMountSource(source: "//oleg@nas/My%20Share"))
        #expect(source.mounts(SMBLocation(host: "nas", share: "My Share")))
    }

    @Test("a mount of a folder inside a share is not a share of the folder's name")
    func folderMountIsNotAShare() throws {
        let source = try #require(SMBMountSource(source: "//oleg@nas/media/Movies"))
        #expect(!source.mounts(SMBLocation(host: "nas", share: "Movies")))
        #expect(!source.mounts(SMBLocation(host: "nas", share: "media")))
    }

    @Test("a server typed as its NetBIOS name reuses Finder's Bonjour mount of it")
    func bonjourHost() throws {
        let source = try #require(SMBMountSource(source: "//oleg@nas._smb._tcp.local/media"))
        #expect(source.mounts(SMBLocation(host: "nas", share: "media")))
    }
}

@Suite("File entry comment")
struct FileEntryCommentTests {
    private static func entry(comment: String?) -> FileEntry {
        FileEntry(
            path: .local("/x"),
            name: "x",
            kind: .file,
            byteSize: 0,
            modificationDate: .distantPast,
            creationDate: .distantPast,
            isHidden: false,
            permissions: nil,
            inode: 0,
            comment: comment
        )
    }

    @Test("an empty comment is none, and the copies keep a comment")
    func comments() {
        #expect(Self.entry(comment: "").comment == nil)
        #expect(Self.entry(comment: nil).comment == nil)
        let entry = Self.entry(comment: "Films")
        #expect(entry.withSymlinkDestination("/y").comment == "Films")
        #expect(entry.withLastUsedDate(.now).comment == "Films")
    }
}
