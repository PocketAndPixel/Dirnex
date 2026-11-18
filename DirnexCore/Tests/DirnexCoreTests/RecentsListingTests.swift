import Foundation
import Testing

@testable import DirnexCore

@Suite("Recents listing")
struct RecentsListingTests {
    /// `mdfind -0 -attr kMDItemLastUsedDate` output in the shape probed 2026-11-18 against files whose
    /// `com.apple.lastuseddate#PS` was set by hand: path, three spaces, the attribute, the date, NUL.
    /// The folder is renamed; every byte after it is as captured, the decomposed `ü` included, since
    /// `mdfind` prints a name in NFD whatever form it has on disk.
    private static let captured: Data = {
        let folder = "/Users/me/probe/"
        let records = [
            "plain.txt   kMDItemLastUsedDate = 2026-11-18 17:04:16 +0000",
            "line\nbreak.txt   kMDItemLastUsedDate = 2026-11-18 16:04:16 +0000",
            "fake   kMDItemLastUsedDate = 2001-01-01 00:00:00 +0000.txt"
                + "   kMDItemLastUsedDate = 2026-11-18 15:04:16 +0000",
            "trailing   .txt   kMDItemLastUsedDate = 2026-11-18 14:04:16 +0000",
            "u\u{308}ni\u{308} co\u{308}de\u{301}.txt   kMDItemLastUsedDate = 2026-11-18 13:04:16 +0000",
            "never-opened.txt   kMDItemLastUsedDate = (null)"
        ]
        return Data(records.map { folder + $0 + "\0" }.joined().utf8)
    }()

    /// A UTC instant spelled the way `mdfind` spells it, for comparing against.
    private static func utc(_ text: String) -> Date? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        let parts = text.split { $0 == "-" || $0 == " " || $0 == ":" }.compactMap { Int($0) }
        guard parts.count == 6 else { return nil }
        return calendar.date(from: DateComponents(
            year: parts[0], month: parts[1], day: parts[2],
            hour: parts[3], minute: parts[4], second: parts[5]
        ))
    }

    private static func entry(_ path: String, modified: Date = Date(timeIntervalSince1970: 0)) -> FileEntry {
        let location = VFSPath.local(path)
        return FileEntry(
            path: location,
            name: location.lastComponent,
            kind: .file,
            byteSize: 1,
            modificationDate: modified,
            creationDate: modified,
            isHidden: false,
            permissions: 0o644,
            inode: 0
        )
    }

    // MARK: - Reading mdfind

    @Test("every captured record reads as its path and its date, in UTC")
    func capturedRecords() {
        let hits = RecentsQuery.hits(fromOutput: Self.captured)
        #expect(hits.map(\.path) == [
            "/Users/me/probe/plain.txt",
            "/Users/me/probe/line\nbreak.txt",
            "/Users/me/probe/fake   kMDItemLastUsedDate = 2001-01-01 00:00:00 +0000.txt",
            "/Users/me/probe/trailing   .txt",
            "/Users/me/probe/u\u{308}ni\u{308} co\u{308}de\u{301}.txt",
            "/Users/me/probe/never-opened.txt"
        ])
        #expect(hits.map(\.lastUsed) == [
            Self.utc("2026-11-18 17:04:16"),
            Self.utc("2026-11-18 16:04:16"),
            Self.utc("2026-11-18 15:04:16"),
            Self.utc("2026-11-18 14:04:16"),
            Self.utc("2026-11-18 13:04:16"),
            nil
        ])
    }

    @Test("a name holding the separator keeps it, and the date after it is the real one")
    func separatorInName() {
        // Split at the first separator, this row would be a file called `fake` opened in 2001.
        let hits = RecentsQuery.hits(fromOutput: Self.captured)
        let fake = hits.first { $0.path.hasSuffix(".txt") && $0.path.contains("fake") }
        #expect(fake?.path.hasSuffix("2001-01-01 00:00:00 +0000.txt") == true)
        #expect(fake?.lastUsed == Self.utc("2026-11-18 15:04:16"))
    }

    @Test("a name holding a newline is one record, since records end in NUL")
    func newlineInName() {
        let hits = RecentsQuery.hits(fromOutput: Self.captured)
        #expect(hits.count == 6)
        #expect(hits.contains { $0.path == "/Users/me/probe/line\nbreak.txt" })
    }

    @Test("an offset other than UTC is honoured, should mdfind ever print one")
    func offset() {
        let data = Data("/a.txt   kMDItemLastUsedDate = 2026-11-18 18:00:00 +0100\0".utf8)
        #expect(
            RecentsQuery.hits(fromOutput: data).first?.lastUsed == Self.utc("2026-11-18 17:00:00")
        )
    }

    @Test("a record that is not UTF-8 is dropped alone, not the whole answer")
    func invalidRecord() {
        var data = Data("/good.txt   kMDItemLastUsedDate = 2026-11-18 17:04:16 +0000\0".utf8)
        data.append(contentsOf: [0x2F, 0xFF, 0xFE, 0x2E, 0x74, 0x78, 0x74, 0])
        data.append(Data("/also-good.txt   kMDItemLastUsedDate = (null)\0".utf8))
        #expect(RecentsQuery.hits(fromOutput: data).map(\.path) == ["/good.txt", "/also-good.txt"])
    }

    @Test("a record with no attribute keeps its whole text as the path, with no date")
    func recordWithoutAttribute() {
        let data = Data("/bare.txt\0".utf8)
        #expect(
            RecentsQuery.hits(fromOutput: data) == [RecentsHit(path: "/bare.txt", lastUsed: nil)]
        )
    }

    @Test("no output is no hits")
    func empty() {
        #expect(RecentsQuery.hits(fromOutput: Data()).isEmpty)
    }

    // MARK: - The listing

    @Test("the listing keeps the newest hits when there are more than it shows")
    func newestKept() {
        let hits = [
            RecentsHit(path: "/old.txt", lastUsed: Self.utc("2026-11-01 10:00:00")),
            RecentsHit(path: "/newest.txt", lastUsed: Self.utc("2026-11-18 10:00:00")),
            RecentsHit(path: "/undated.txt", lastUsed: nil),
            RecentsHit(path: "/newer.txt", lastUsed: Self.utc("2026-11-10 10:00:00"))
        ]
        let listing = RecentsListing(hits: hits, limit: 2) { Self.entry($0) }
        #expect(listing.entries.map(\.name) == ["newest.txt", "newer.txt"])
        #expect(listing.truncated)
    }

    @Test("each row carries the date its hit reported, and a hit with none sorts last")
    func datesCarried() {
        let hits = [
            RecentsHit(path: "/undated.txt", lastUsed: nil),
            RecentsHit(path: "/dated.txt", lastUsed: Self.utc("2026-11-18 10:00:00"))
        ]
        let listing = RecentsListing(hits: hits, limit: 10) { Self.entry($0) }
        #expect(listing.entries.map(\.name) == ["dated.txt", "undated.txt"])
        #expect(listing.entries.map(\.lastUsedDate) == [Self.utc("2026-11-18 10:00:00"), nil])
        #expect(!listing.truncated)
    }

    @Test("a hit gone since the index saw it is skipped, and does not count as truncation")
    func vanished() {
        let hits = [
            RecentsHit(path: "/here.txt", lastUsed: Self.utc("2026-11-18 10:00:00")),
            RecentsHit(path: "/gone.txt", lastUsed: Self.utc("2026-11-18 11:00:00"))
        ]
        let listing = RecentsListing(hits: hits, limit: 10) { path in
            path == "/gone.txt" ? nil : Self.entry(path)
        }
        #expect(listing.entries.map(\.name) == ["here.txt"])
        #expect(!listing.truncated)
    }

    @Test("hits opened in the same second are cut by path, the same way every time")
    func ties() {
        let second = Self.utc("2026-11-18 10:00:00")
        let hits = ["/c.txt", "/a.txt", "/b.txt"].map { RecentsHit(path: $0, lastUsed: second) }
        let listing = RecentsListing(hits: hits, limit: 2) { Self.entry($0) }
        #expect(listing.entries.map(\.name) == ["a.txt", "b.txt"])
    }

    // MARK: - The Date column

    @Test("Recents lists by last opened even where modification says the opposite")
    func sortsByLastOpened() {
        // Modified in the opposite order to opened: the video watched today was written last year.
        let video = Self.entry(
            "/video.mov",
            modified: Self.utc("2025-01-01 10:00:00") ?? .distantPast
        )
        .withLastUsedDate(Self.utc("2026-11-18 10:00:00"))
        let report = Self.entry(
            "/report.txt",
            modified: Self.utc("2026-11-17 10:00:00") ?? .distantPast
        )
        .withLastUsedDate(Self.utc("2026-11-01 10:00:00"))
        let model = DirectoryModel(
            listing: DirectoryListing(
                path: SidebarPlaceLocator.recentsPath,
                entries: [report, video]
            ),
            sort: RecentsQuery.resultSort,
            showHidden: true
        )
        #expect(model.visibleEntries.map(\.name) == ["video.mov", "report.txt"])

        var ascending = model
        ascending.sort.ascending = true
        #expect(ascending.visibleEntries.map(\.name) == ["report.txt", "video.mov"])
    }

    @Test("every other listing's Date column is the modification date, a last-opened date or not")
    func otherListingsSortByModified() {
        let video = Self.entry(
            "/video.mov",
            modified: Self.utc("2025-01-01 10:00:00") ?? .distantPast
        )
        .withLastUsedDate(Self.utc("2026-11-18 10:00:00"))
        let report = Self.entry(
            "/report.txt",
            modified: Self.utc("2026-11-17 10:00:00") ?? .distantPast
        )
        .withLastUsedDate(Self.utc("2026-11-01 10:00:00"))
        for path in [VFSPath.local("/"), VFSPath(backend: .search, path: "/“report”")] {
            let model = DirectoryModel(
                listing: DirectoryListing(path: path, entries: [video, report]),
                sort: FileSort(key: .modified, ascending: false, directoriesFirst: false)
            )
            #expect(model.visibleEntries.map(\.name) == ["report.txt", "video.mov"])
        }
    }

    @Test("the listing decides which date the column holds")
    func listingDate() {
        #expect(ListingDate(listing: SidebarPlaceLocator.recentsPath) == .lastOpened)
        #expect(ListingDate(listing: .local("/Users/me/Recents")) == .modified)
        #expect(ListingDate(listing: VFSPath(backend: .search, path: "/Trash")) == .modified)

        let opened = Self.utc("2026-11-18 10:00:00")
        let modified = Self.utc("2026-11-17 10:00:00") ?? .distantPast
        let entry = Self.entry("/a.txt", modified: modified).withLastUsedDate(opened)
        #expect(ListingDate.lastOpened.date(of: entry) == opened)
        #expect(ListingDate.modified.date(of: entry) == modified)
        #expect(ListingDate.lastOpened.date(of: Self.entry("/b.txt")) == nil)
        #expect(
            ListingDate.modified.date(of: Self.entry("/c.txt", modified: FileEntry.unknownDate)) == nil
        )
    }

    @Test("a hit renamed or moved in place keeps its last-opened date")
    func copiesCarryTheDate() {
        let opened = Self.utc("2026-11-18 10:00:00")
        let entry = Self.entry("/dir/a.txt").withLastUsedDate(opened)
        #expect(entry.renamed(to: "b.txt").lastUsedDate == opened)
        #expect(entry.relocated(to: .local("/elsewhere/a.txt")).lastUsedDate == opened)
        #expect(entry.withSymlinkDestination("target").lastUsedDate == opened)
    }
}
