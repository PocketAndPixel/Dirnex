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
}
