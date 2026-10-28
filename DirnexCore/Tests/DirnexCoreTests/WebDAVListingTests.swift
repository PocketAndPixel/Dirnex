import Foundation
import Testing

@testable import DirnexCore

/// Splitting a `Depth: 1` answer into the folder and its rows, and turning the rows into entries
/// (PLAN.md §M32 Slice 1). The fixtures are the NAS's (``WebDAVFixtures``).
@Suite("WebDAVListing")
struct WebDAVListingTests {
    private static let folder = "/home/dirnex-webdav-fixture"
    private static let location = WebDAVLocation(host: "nas", port: 5006, username: "dirnex-test")
    private static let directory = VFSPath(backend: location.backendID, path: folder)

    private func body(_ hrefs: [String], collections: Set<String> = []) -> Data {
        let rows = hrefs.map { href in
            let type = collections.contains(href) ? "<D:collection/>" : ""
            return "<D:response><D:href>\(href)</D:href><D:propstat><D:prop><D:resourcetype>\(type)" +
                "</D:resourcetype></D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response>"
        }
        return Data(
            "<?xml version=\"1.0\"?><D:multistatus xmlns:D=\"DAV:\">\(rows.joined())</D:multistatus>".utf8
        )
    }

    @Test("the folder is found and every row inside it is a child")
    func splitsFolderAndChildren() throws {
        let listing = try WebDAVFixtures.parse("nas-folder-props").listing(of: Self.folder)
        #expect(listing.folder.path == Self.folder)
        #expect(listing.folder.isCollection)
        #expect(listing.children.count == 8)
        let names = listing.children.compactMap { WebDAVHref.name(of: $0.path) }
        #expect(Set(names.map { Array($0.utf8) }) == WebDAVFixtures.folderNames)
        #expect(listing.unreadableCount == 0)
    }

    @Test("the folder asked for with a trailing slash, or without, is the same folder")
    func folderSlashInsensitive() throws {
        let parsed = try WebDAVFixtures.parse("nas-folder-props")
        #expect(try parsed.listing(of: Self.folder + "/").children.count == 8)
        // A Depth 0 answer to the slash-less request is the folder alone.
        let alone = try WebDAVFixtures.parse("nas-folder-noslash-depth0-props").listing(
            of: Self.folder
        )
        #expect(alone.folder.isCollection)
        #expect(alone.children.isEmpty)
    }

    @Test("a listing of a file is the file, so the caller can say it is not a folder")
    func listingOfAFile() throws {
        let file = Self.folder + "/Привет мир.txt"
        let listing = try WebDAVFixtures.parse("nas-file-depth0-props").listing(of: file)
        #expect(!listing.folder.isCollection)
        #expect(listing.folder.byteSize == 6)
        #expect(listing.children.isEmpty)
    }

    @Test("the account root lists its shared folders as children")
    func accountRoot() throws {
        let listing = try WebDAVFixtures.parse("nas-root-props").listing(of: "/")
        #expect(listing.folder.path == "/")
        #expect(listing.children.map(\.path) == ["/media", "/share", "/home"])
        #expect(listing.children.allSatisfy { $0.isCollection })
    }

    @Test("behind a prefix the server does not know, the folder is the row everything sits in")
    func anchorsWhenTheServerOmitsAPrefix() throws {
        // A reverse proxy at `/dav` forwards to the NAS, which answers with its own paths.
        let listing = try WebDAVFixtures.parse("nas-folder-props").listing(of: "/dav" + Self.folder)
        #expect(listing.folder.path == Self.folder)
        #expect(listing.children.count == 8)
        // The entries are built from the folder the pane asked for, not the server's spelling.
        let proxied = VFSPath(backend: Self.location.backendID, path: "/dav" + Self.folder)
        let entries = listing.entries(in: proxied)
        #expect(entries.allSatisfy { $0.path.parent == proxied })
    }

    @Test("rows that share no folder are refused rather than guessed at")
    func noFolderRefused() {
        let unrelated = body(["/a/x", "/b/y"])
        #expect(throws: WebDAVParseError.listingDoesNotNameItsFolder) {
            try WebDAVMultistatusParser.parse(unrelated).listing(of: "/c")
        }
    }

    @Test("a second row for the folder is not a child of it")
    func duplicateFolderRow() throws {
        let data = body(["/d/", "/d", "/d/a.txt"], collections: ["/d/", "/d"])
        let listing = try WebDAVMultistatusParser.parse(data).listing(of: "/d")
        #expect(listing.children.map(\.path) == ["/d/a.txt"])
    }

    @Test("a row deeper than one level is not in the listing")
    func deeperRowsLeftOut() throws {
        // What a server that ignores `Depth: 1` sends.
        let data = body(
            ["/d/", "/d/sub/", "/d/sub/deep.txt", "/d/a.txt"],
            collections: ["/d/", "/d/sub/"]
        )
        let listing = try WebDAVMultistatusParser.parse(data).listing(of: "/d")
        #expect(listing.children.map(\.path) == ["/d/sub", "/d/a.txt"])
    }

    @Test("two names that differ only in normalization stay two rows; a repeated name does not")
    func duplicateNames() throws {
        let data = body(
            ["/d/", "/d/caf%c3%a9", "/d/cafe%cc%81", "/d/caf%C3%A9"],
            collections: ["/d/"]
        )
        let listing = try WebDAVMultistatusParser.parse(data).listing(of: "/d")
        #expect(listing.children.count == 2)
    }

    @Test("an operation's outcome rows are not read as resources")
    func outcomeRowsIgnored() throws {
        let parsed = try WebDAVFixtures.parse("nas-delete-locked-member-424")
        #expect(throws: WebDAVParseError.listingDoesNotNameItsFolder) {
            try parsed.listing(of: Self.folder)
        }
    }

    // MARK: - Entries

    @Test("rows become entries named by their decoded bytes, inside the folder asked for")
    func entries() throws {
        let entries = try WebDAVFixtures.parse("nas-folder-props").listing(of: Self.folder)
            .entries(in: Self.directory)
        #expect(entries.count == 8)
        #expect(Set(entries.map { Array($0.name.utf8) }) == WebDAVFixtures.folderNames)
        #expect(entries.allSatisfy { $0.path.parent == Self.directory })
        #expect(entries.allSatisfy { $0.path.lastComponent == $0.name })

        let cafe = try #require(entries.first { $0.name.unicodeScalars.contains("\u{301}") })
        #expect(Array(cafe.name.utf8) == Array("cafe\u{301}.txt".utf8))
    }

    @Test("a file entry carries size, dates and tag; a folder entry a zero size")
    func entryFields() throws {
        let entries = try WebDAVFixtures.parse("nas-folder-props").listing(of: Self.folder)
            .entries(in: Self.directory)
        let file = try #require(entries.first { $0.name == "日本語.txt" })
        #expect(file.kind == .file)
        #expect(file.byteSize == 6)
        #expect(file.modificationDate == WebDAVFixtures.nasStamp)
        #expect(file.creationDate == WebDAVFixtures.nasStamp)
        #expect(file.entityTag == "\"6-65e73fc59e468\"")
        #expect(file.permissions == nil)

        let folder = try #require(entries.first { $0.name == "Папка" })
        #expect(folder.kind == .directory)
        #expect(folder.byteSize == 0)
    }

    @Test("a leading dot hides a row; a leading space does not")
    func hiddenRows() throws {
        let entries = try WebDAVFixtures.parse("nas-folder-props").listing(of: Self.folder)
            .entries(in: Self.directory)
        #expect(entries.first { $0.name == ".hidden" }?.isHidden == true)
        #expect(entries.first { $0.name == " leading space.txt" }?.isHidden == false)
    }

    @Test("a row with no dates gets the unknown date, and no creation date falls back to the other")
    func missingDates() {
        let path = Self.directory.appending("x")
        let bare = WebDAVResponse(path: "/x").entry(at: path)
        #expect(bare.modificationDate == FileEntry.unknownDate)
        #expect(bare.creationDate == FileEntry.unknownDate)
        let modifiedOnly = WebDAVResponse(path: "/x", modified: WebDAVFixtures.nasStamp).entry(
            at: path
        )
        #expect(modifiedOnly.creationDate == WebDAVFixtures.nasStamp)
        #expect(bare.name == "x")
    }
}
