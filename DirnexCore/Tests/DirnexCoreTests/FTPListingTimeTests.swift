import Foundation
import Testing

@testable import DirnexCore

/// Where an FTP row's time comes from: `LIST`'s stamp read on the server's clock, or `MLSD`'s exact
/// one where the two listings agree what the row is.
@Suite("FTP listing times")
struct FTPListingTimeTests {
    private static let paris = TimeZone(identifier: "Europe/Paris")
    private static let kyiv = TimeZone(identifier: "Europe/Kyiv")

    /// The year-less row from the report: a Paris server lists a file written at 16:41 its time.
    private static let row = "-rw-r--r-- 1 oleg wheel 2936012 Oct 19 16:41 Agences_SYNERGIE_ATS.xml"

    /// One wall-clock stamp, two clocks, two instants an hour apart — Paris is UTC+2 and Kyiv UTC+3
    /// on that date. Asserted as the gap between them rather than as either instant, so the year the
    /// parser lends a year-less stamp cannot make it pass or fail.
    @Test("a LIST stamp is read on the server's clock")
    func listStampUsesServerZone() throws {
        let paris = try #require(Self.paris)
        let kyiv = try #require(Self.kyiv)
        let inParis = try #require(FTPListingParser.parse(Self.row, timeZone: paris).first)
        let inKyiv = try #require(FTPListingParser.parse(Self.row, timeZone: kyiv).first)
        #expect(inParis.modificationDate.timeIntervalSince(inKyiv.modificationDate) == 3600)

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = paris
        let parts = calendar.dateComponents([.hour, .minute], from: inParis.modificationDate)
        #expect(parts.hour == 16)
        #expect(parts.minute == 41)
    }

    /// `nil` is what every listing meant before a server had a zone: this Mac's own.
    @Test("no zone reads the stamp as this Mac's clock, as before")
    func noZoneIsThisMac() throws {
        let unset = try #require(FTPListingParser.parse(Self.row).first)
        let current = try #require(FTPListingParser.parse(Self.row, timeZone: .current).first)
        #expect(unset.modificationDate == current.modificationDate)
    }

    /// The DOS dialect has its own formatters, and they must take the zone too.
    @Test("the DOS dialect is read on the server's clock as well")
    func dosStampUsesServerZone() throws {
        let line = "10-19-26  04:41PM              1173 readme.txt"
        let parisZone = try #require(Self.paris)
        let kyivZone = try #require(Self.kyiv)
        let paris = try #require(FTPListingParser.parse(line, timeZone: parisZone).first)
        let kyiv = try #require(FTPListingParser.parse(line, timeZone: kyivZone).first)
        #expect(paris.modificationDate.timeIntervalSince(kyiv.modificationDate) == 3600)
    }

    /// The zone moves the instant and nothing else: a year-less stamp still carries zero seconds,
    /// the property that keeps two parses of one row equal (docs/NOTES.md ▸ Parsing a year-less
    /// timestamp).
    @Test("a zone does not reintroduce seconds into a year-less stamp")
    func zoneKeepsWholeMinutes() throws {
        let paris = try #require(Self.paris)
        let entry = try #require(FTPListingParser.parse(Self.row, timeZone: paris).first)
        #expect(
            entry.modificationDate.timeIntervalSince1970.truncatingRemainder(dividingBy: 60) == 0
        )
    }

    // MARK: - Applying MLSD

    private static let listing = """
    -rw-r--r--   1 oleg     wheel           3 Oct 19 16:41 a.txt
    lrwxr-xr-x   1 oleg     wheel           3 Oct 19 17:51 linkdir -> sub
    lrwxr-xr-x   1 oleg     wheel           5 Oct 19 17:51 linkfile -> a.txt
    drwxr-xr-x   2 oleg     wheel          64 Oct 19 17:47 sub
    """

    @Test("an MLSD time replaces the LIST stamp where the kinds agree")
    func factsReplaceTimes() throws {
        let rows = FTPListingParser.parse(Self.listing)
        let timed = FTPListingParser.applyingFacts(
            FTPFactsParser.parse(FTPFactsParserTests.realReply),
            to: rows
        )
        let file = try #require(timed.first { $0.name == "a.txt" })
        let folder = try #require(timed.first { $0.name == "sub" })
        #expect(file.modificationDate.timeIntervalSince1970 == 1_792_428_060) // 16:41:00 UTC
        #expect(folder.modificationDate.timeIntervalSince1970 == 1_792_432_067) // 17:47:47 UTC
        // Only the time moved — the row is still LIST's.
        #expect(file.permissions == 0o644)
        #expect(file.ownerName == "oleg")
    }

    /// **The case the whole design rests on.** This server follows links in `MLSD`, so it reports
    /// `linkdir` as the folder it points at. That row describes the target, so its time must not be
    /// lent to the link — and the link must stay a link, which is what keeps a recursive delete from
    /// walking through it.
    @Test("a followed symlink keeps its kind, its target and its own LIST stamp")
    func followedLinkKeepsListStamp() throws {
        let rows = FTPListingParser.parse(Self.listing)
        let timed = FTPListingParser.applyingFacts(
            FTPFactsParser.parse(FTPFactsParserTests.realReply),
            to: rows
        )
        for name in ["linkdir", "linkfile"] {
            let before = try #require(rows.first { $0.name == name })
            let after = try #require(timed.first { $0.name == name })
            #expect(after == before)
            #expect(after.kind == .symlink)
        }
    }

    @Test("a server that reports the link itself does time it")
    func reportedLinkIsTimed() throws {
        let rows = FTPListingParser.parse(Self.listing)
        let facts = FTPFactsParser.parse("type=OS.unix=slink:sub;modify=20261019155100; linkdir")
        let link = try #require(FTPListingParser.applyingFacts(facts, to: rows).first {
            $0.name == "linkdir"
        })
        #expect(link.modificationDate.timeIntervalSince1970 == 1_792_425_060) // 15:51:00 UTC
        #expect(link.kind == .symlink)
        #expect(link.symlinkDestination == "sub")
    }

    @Test("a kind MLSD does not map vetoes nothing; a missing time or row changes nothing")
    func unmappedKindAndGaps() throws {
        let rows = FTPListingParser.parse(Self.listing)
        let facts = FTPFactsParser.parse("""
        type=OS.unix=weird;modify=20260101000000; a.txt
        type=dir; sub
        """)
        let timed = FTPListingParser.applyingFacts(facts, to: rows)
        let file = try #require(timed.first { $0.name == "a.txt" })
        #expect(file.modificationDate.timeIntervalSince1970 == 1_767_225_600)
        // `sub` had no modify fact, and the links were not mentioned at all.
        #expect(timed.filter { $0.name != "a.txt" } == rows.filter { $0.name != "a.txt" })
    }
}
