import Foundation
import Testing

@testable import DirnexCore

@Suite("FTPFactsParser")
struct FTPFactsParserTests {
    /// **Real bytes.** `curl -X MLSD` against pyftpdlib 2.2.0 on 2026-10-19, over a folder holding a
    /// file, a folder, and a symlink to each. The server follows the links: `linkdir` is a `dir`
    /// carrying `sub`'s own `unique`, which is the reason the rows stay `LIST`'s.
    static let realReply = """
    modify=20261019164100;perm=radfwMT;size=3;type=file;unique=1000011g519a280; linkfile
    modify=20261019174747;perm=eldfmMTcp;size=64;type=dir;unique=1000011g519a27f; sub
    modify=20261019164100;perm=radfwMT;size=3;type=file;unique=1000011g519a280; a.txt
    modify=20261019174747;perm=eldfmMTcp;size=64;type=dir;unique=1000011g519a27f; linkdir

    """

    private static func utc(_ text: String) throws -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return try #require(formatter.date(from: text) ?? ISO8601DateFormatter().date(from: text))
    }

    @Test("parses the real reply: names, kinds and exact UTC times")
    func parsesRealReply() throws {
        let entries = FTPFactsParser.parse(Self.realReply)
        #expect(entries.map(\.name) == ["linkfile", "sub", "a.txt", "linkdir"])
        #expect(entries.map(\.kind) == [.file, .directory, .file, .directory])

        let file = try #require(entries.first { $0.name == "a.txt" })
        #expect(file.modificationDate == (try Self.utc("2026-10-19T16:41:00Z")))
    }

    /// The time is **UTC** whatever this Mac's zone is — the whole point of asking for it. A parse
    /// in the local zone would pass on a machine set to UTC, so the instant is compared, not the
    /// wall clock.
    @Test("modify is read as UTC, not as this Mac's clock")
    func modifyIsUTC() throws {
        let date = try #require(FTPFactsParser.date(fromModifyFact: "20260101000000"))
        #expect(date.timeIntervalSince1970 == 1_767_225_600)
    }

    @Test("a fraction of a second is kept")
    func fractionIsKept() throws {
        let date = try #require(FTPFactsParser.date(fromModifyFact: "20260101000000.250"))
        #expect(date.timeIntervalSince1970 == 1_767_225_600.25)
    }

    /// `Calendar.date(from:)` turns month 13 into next January rather than failing, so without the
    /// validity check a malformed stamp would arrive as a plausible wrong date.
    @Test("a malformed modify fact is nil, never a normalized guess", arguments: [
        "2026101916410", "202610191641000", "20261319164100", "20261032164100",
        "20261019250000", "2026101916410x", "20261019164100.", "20261019164100.5x", ""
    ])
    func malformedModify(_ value: String) {
        #expect(FTPFactsParser.date(fromModifyFact: value[...]) == nil)
    }

    /// The first space ends the facts, so a name keeps every space and semicolon it has — RFC 3659
    /// allows no space inside a fact.
    @Test("a name keeps its spaces and semicolons")
    func nameIsVerbatim() {
        let entries = FTPFactsParser.parse("type=file;modify=20260101000000; my report; v2 .txt\r\n")
        #expect(entries.map(\.name) == ["my report; v2 .txt"])
    }

    @Test("the folder itself and its parent are dropped")
    func dropsCdirAndPdir() {
        let reply = """
        type=cdir;modify=20260101000000; .
        type=pdir;modify=20260101000000; ..
        type=cdir;modify=20260101000000; /pub
        type=file;modify=20260101000000; kept.txt
        """
        #expect(FTPFactsParser.parse(reply).map(\.name) == ["kept.txt"])
    }

    @Test("fact names and type values are case-insensitive")
    func caseInsensitive() throws {
        let entry = try #require(FTPFactsParser.parse("Type=DIR;Modify=20260101000000; Docs").first)
        #expect(entry.kind == .directory)
        #expect(entry.modificationDate != nil)
    }

    /// Both spellings say the server reported the link itself rather than following it.
    @Test("both unix symlink spellings read as a link", arguments: [
        "OS.unix=symlink", "OS.unix=slink:/srv/target", "os.unix=slink"
    ])
    func symlinkSpellings(_ type: String) throws {
        let entry = try #require(FTPFactsParser.parse("type=\(type);modify=20260101000000; l").first)
        #expect(entry.kind == .symlink)
    }

    @Test("an unmapped type is no kind at all, and a row without facts still has its name")
    func unknownTypeAndBareRow() {
        let entries = FTPFactsParser.parse(
            "type=OS.unix=chr-13/29;modify=20260101000000; tty\n bare\n"
        )
        #expect(entries.map(\.name) == ["tty", "bare"])
        #expect(entries.map(\.kind) == [nil, nil])
        #expect(entries[1].modificationDate == nil)
    }
}
