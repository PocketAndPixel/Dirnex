import Foundation
import Testing

@testable import DirnexCore

/// The primitives `SFTPListingParser`, `FTPListingParser` and `ArchiveTOCParser` share. Each of the
/// three has its own suite covering its dialect end to end; this one pins the pieces underneath,
/// where a change would land in all three at once.
@Suite("ColumnarListing")
struct ColumnarListingTests {
    // MARK: - Names

    @Test("the name is taken verbatim, so internal spaces survive")
    func nameKeepsInternalSpaces() throws {
        let line: Substring = "-rw-r--r-- 1 sa users 6 Jul 25 20:55 my report.txt"
        #expect(ColumnarListing.nameField(in: line, afterColumns: 8) == "my report.txt")
    }

    @Test("a line with fewer columns than asked for has no name")
    func shortLineHasNoName() {
        let line: Substring = "total 8"
        #expect(ColumnarListing.nameField(in: line, afterColumns: 8) == nil)
    }

    @Test("runs of spaces between columns are skipped, not counted as columns")
    func collapsesColumnPadding() {
        let line: Substring = "-rw-------   1 sa    users        6 Jul 25 20:55  spaced.txt"
        #expect(ColumnarListing.nameField(in: line, afterColumns: 8) == "spaced.txt")
    }

    // MARK: - The mode column

    @Test("a mode field is 10 characters, or 11 with an ACL + or xattr @")
    func recognizesModeFields() {
        #expect(ColumnarListing.isModeField("-rw-r--r--"))
        #expect(ColumnarListing.isModeField("drwxr-xr-x+"))
        #expect(ColumnarListing.isModeField("lrwxr-xr-x@"))
        #expect(!ColumnarListing.isModeField("sftp>"))
        #expect(!ColumnarListing.isModeField("total"))
    }

    @Test("the nine rwx characters map to POSIX mode bits")
    func mapsPermissions() {
        #expect(ColumnarListing.permissions(fromMode: "-rw-r--r--") == 0o644)
        #expect(ColumnarListing.permissions(fromMode: "drwxr-xr-x") == 0o755)
        #expect(ColumnarListing.permissions(fromMode: "----------") == 0)
        #expect(ColumnarListing.permissions(fromMode: "-rwxrwxrwx") == 0o777)
    }

    @Test("a set-uid/sticky character counts as the bit being set")
    func specialBitsCountAsSet() {
        #expect(ColumnarListing.permissions(fromMode: "-rwsr-xr-x") == 0o755)
        #expect(ColumnarListing.permissions(fromMode: "drwxrwxrwt") == 0o777)
    }

    @Test("a too-short mode field yields no bits rather than reading past its end")
    func shortModeFieldIsSafe() {
        #expect(ColumnarListing.permissions(fromMode: "-rw-") == 0)
    }

    // MARK: - Dates

    /// The trap docs/NOTES.md records: a `DateFormatter` fills a missing year from `defaultDate`,
    /// which defaults to a 2000 reference, so a year-less stamp would read as the year 2000.
    @Test("a year-less format defaults its year to now, not to the 2000 reference")
    func yearLessFormatDefaultsToNow() throws {
        let formatter = try #require(ColumnarListing.formatters(for: ["MMM d HH:mm"]).first)
        let parsed = try #require(formatter.date(from: "Jul 25 20:55"))
        let currentYear = Calendar(identifier: .gregorian).component(.year, from: Date())
        let parsedYear = Calendar(identifier: .gregorian).component(.year, from: parsed)
        #expect(parsedYear == currentYear)
    }

    /// The divergence the three copies had drifted into: two spelled the year test `contains("yyyy")`
    /// and only one `contains("y")`. A two-digit-year format carries a year and must not be handed a
    /// default — with `"yyyy"` this formatter would have been given one.
    @Test("a two-digit-year format is treated as carrying a year")
    func twoDigitYearIsAYear() throws {
        let formatter = try #require(ColumnarListing.formatters(for: ["MM-dd-yy HH:mm"]).first)
        #expect(formatter.defaultDate == nil)
        let parsed = try #require(formatter.date(from: "04-27-00 21:09"))
        #expect(Calendar(identifier: .gregorian).component(.year, from: parsed) == 2000)
    }

    @Test("a four-digit-year format is left alone too")
    func fourDigitYearIsAYear() throws {
        let formatter = try #require(ColumnarListing.formatters(for: ["MMM d yyyy"]).first)
        #expect(formatter.defaultDate == nil)
    }

    @Test("the first formatter that accepts the string wins")
    func firstMatchWins() throws {
        let formatters = ColumnarListing.formatters(for: ["MMM d yyyy", "MMM d HH:mm"])
        let parsed = ColumnarListing.date(from: "Jul 25 2019", formatters: formatters)
        #expect(Calendar(identifier: .gregorian).component(.year, from: parsed) == 2019)
    }

    @Test("a string no formatter accepts reads as the distant past")
    func unparsableIsDistantPast() {
        let formatters = ColumnarListing.formatters(for: ["MMM d yyyy"])
        #expect(ColumnarListing.date(from: "not a date", formatters: formatters) == .distantPast)
    }

    /// A "Dec 30 12:00" entry read on Jan 2 means *last* December, and the day of slack also absorbs
    /// a server clock running ahead of ours.
    @Test("a clearly-future year-less date is rolled back a year")
    func rollsFutureDateBack() throws {
        let calendar = Calendar(identifier: .gregorian)
        let soon = try #require(calendar.date(byAdding: .day, value: 30, to: Date()))
        let stamp = DateFormatter()
        stamp.locale = Locale(identifier: "en_US_POSIX")
        stamp.dateFormat = "MMM d HH:mm"

        let formatters = ColumnarListing.formatters(for: ["MMM d HH:mm"])
        let parsed = ColumnarListing.date(from: stamp.string(from: soon), formatters: formatters)

        #expect(parsed < Date(), "a stamp 30 days ahead must be read as last year's")
        #expect(calendar.component(.year, from: parsed) == calendar.component(.year, from: soon) - 1)
    }

    @Test("a date inside the day of slack is kept as-is")
    func keepsNearFutureDate() throws {
        let calendar = Calendar(identifier: .gregorian)
        let nearly = try #require(calendar.date(byAdding: .hour, value: 2, to: Date()))
        let stamp = DateFormatter()
        stamp.locale = Locale(identifier: "en_US_POSIX")
        stamp.dateFormat = "MMM d HH:mm"

        let formatters = ColumnarListing.formatters(for: ["MMM d HH:mm"])
        let parsed = ColumnarListing.date(from: stamp.string(from: nearly), formatters: formatters)

        #expect(calendar.component(.year, from: parsed) == calendar.component(.year, from: nearly))
    }

    // MARK: - The Unix row

    private static let unixFormatters = ColumnarListing.unixDateFormatters()

    @Test("a full Unix row reads every fixed column")
    func readsUnixRow() throws {
        let line: Substring = "-rw-r--r-- 1 sa users 3145728 Jul 25 2019 my report.txt"
        let row = try #require(ColumnarListing.unixRow(line, formatters: Self.unixFormatters))
        let year = Calendar(identifier: .gregorian).component(.year, from: row.modificationDate)

        #expect(row.kind == .file)
        #expect(row.byteSize == 3_145_728)
        #expect(row.permissions == 0o644)
        #expect(row.name == "my report.txt")
        #expect(row.symlinkDestination == nil)
        #expect(year == 2019)
    }

    @Test("a directory row reads as a directory")
    func readsDirectoryRow() throws {
        let line: Substring = "drwxr-xr-x 2 sa users 0 Jul 25 20:55 sub dir"
        let row = try #require(ColumnarListing.unixRow(line, formatters: Self.unixFormatters))

        #expect(row.kind == .directory)
        #expect(row.name == "sub dir")
        #expect(row.permissions == 0o755)
    }

    /// The mode gate is what makes this safe: a file legitimately named `a -> b` must not be read as
    /// a symlink pointing at `b`, so the ` -> ` split is reached only for an `l` mode.
    @Test("a symlink's target is split off, and a file named like one is left alone")
    func splitsTargetOnlyForSymlinks() throws {
        let link: Substring = "lrwxr-xr-x 1 sa users 9 Jul 25 20:55 latest -> releases/1.2"
        let linkRow = try #require(ColumnarListing.unixRow(link, formatters: Self.unixFormatters))
        #expect(linkRow.kind == .symlink)
        #expect(linkRow.name == "latest")
        #expect(linkRow.symlinkDestination == "releases/1.2")

        let file: Substring = "-rw-r--r-- 1 sa users 9 Jul 25 20:55 a -> b"
        let fileRow = try #require(ColumnarListing.unixRow(file, formatters: Self.unixFormatters))
        #expect(fileRow.kind == .file)
        #expect(fileRow.name == "a -> b")
        #expect(fileRow.symlinkDestination == nil)
    }

    /// The name is handed back **raw**, full path and all. Reducing it is `SFTPListingParser`'s job
    /// and would be wrong for FTP, which prints bare names — that difference is the reason this
    /// returns a name rather than an entry.
    @Test("a full-path name is not reduced here")
    func leavesFullPathNameAlone() throws {
        let line: Substring = "-rw-r--r-- ? oleg staff 11 Jul 13 00:09 /home/oleg/docs/notes.txt"
        let row = try #require(ColumnarListing.unixRow(line, formatters: Self.unixFormatters))
        #expect(row.name == "/home/oleg/docs/notes.txt")
    }

    /// The difference that keeps `ArchiveTOCParser` on its own scan: it reads an unrecognized mode
    /// as a file, where both remote dialects read it as `.other` — a device, socket or FIFO is shown
    /// but is not navigable.
    @Test("an unrecognized mode reads as other, not as a file")
    func unknownModeIsOther() throws {
        for mode in ["b", "c", "s", "p"] {
            let line = "\(mode)rw-r--r-- 1 sa users 0 Jul 25 20:55 dev0"
            let row = try #require(
                ColumnarListing.unixRow(line[...], formatters: Self.unixFormatters)
            )
            #expect(row.kind == .other, "mode \(mode)")
        }
    }

    @Test("a line that is not a row is rejected rather than guessed at")
    func rejectsNonRows() {
        let formatters = Self.unixFormatters
        #expect(ColumnarListing.unixRow("", formatters: formatters) == nil)
        #expect(ColumnarListing.unixRow("total 8", formatters: formatters) == nil)
        #expect(ColumnarListing.unixRow("sftp> ls -la /home/oleg", formatters: formatters) == nil)
        #expect(ColumnarListing.unixRow("Can't ls: \"/x\" not found", formatters: formatters) == nil)
        // Nine columns but no mode field: the shape `ArchiveTOCParser` accepts and this rejects.
        #expect(
            ColumnarListing.unixRow("x 0 501 20 11 Jul 10 16:19 f", formatters: formatters) == nil
        )
    }
}
