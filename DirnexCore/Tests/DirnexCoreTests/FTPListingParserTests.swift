import Foundation
import Testing

@testable import DirnexCore

@Suite("FTPListingParser")
struct FTPListingParserTests {
    /// **Real bytes.** Captured verbatim from the FTP server probed on 2026-07-25 (`curl
    /// ftp://…/probe13/`), including the exact column spacing, the file names created to exercise
    /// spaces and quotes, and the LF-only line endings.
    static let realUnixListing = """
    -rw------- 1 sa users          6 Jul 25 20:55 .hidden
    -rw------- 1 sa users    3145728 Jul 25 20:53 big.bin
    -rw------- 1 sa users          6 Jul 25 20:55 dash-file.txt
    -rw------- 1 sa users          6 Jul 25 20:55 my report.txt
    -rw------- 1 sa users          6 Jul 25 20:55 quote'name.txt
    drwx------ 2 sa users          0 Jul 25 20:55 sub dir
    """

    @Test("parses the real captured Unix listing, names and sizes intact")
    func parsesRealUnixListing() throws {
        let entries = FTPListingParser.parse(Self.realUnixListing)
        #expect(entries.count == 6)
        #expect(entries.map(\.name) == [
            ".hidden", "big.bin", "dash-file.txt", "my report.txt", "quote'name.txt", "sub dir"
        ])

        let big = try #require(entries.first { $0.name == "big.bin" })
        #expect(big.kind == .file)
        #expect(big.byteSize == 3_145_728)

        let directory = try #require(entries.first { $0.name == "sub dir" })
        #expect(directory.kind == .directory)
        #expect(directory.byteSize == 0)
    }

    /// The two names that would break a naive split-on-whitespace parser. Both were created on the
    /// real server precisely to produce these bytes.
    @Test("keeps spaces and quotes inside a name")
    func keepsAwkwardCharactersInNames() throws {
        let entries = FTPListingParser.parse(Self.realUnixListing)
        #expect(entries.contains { $0.name == "my report.txt" })
        #expect(entries.contains { $0.name == "quote'name.txt" })
        // A directory name with a space is the one a wrong parser truncates to "sub".
        let directory = try #require(entries.first { $0.kind == .directory })
        #expect(directory.name == "sub dir")
    }

    @Test("reads the mode column into permission bits and a kind")
    func readsModeColumn() throws {
        let listing = """
        -rw-r--r-- 1 sa users 6 Jul 25 20:55 readable.txt
        drwxr-xr-x 2 sa users 0 Jul 25 20:55 folder
        lrwxrwxrwx 1 sa users 9 Jul 25 20:55 latest -> big.bin
        """
        let entries = FTPListingParser.parse(listing)
        #expect(entries.count == 3)

        let file = try #require(entries.first { $0.name == "readable.txt" })
        #expect(file.permissions == 0o644)

        let folder = try #require(entries.first { $0.name == "folder" })
        #expect(folder.kind == .directory)
        #expect(folder.permissions == 0o755)

        // Unlike `sftp`'s `ls`, a real FTP server does print the link target.
        let link = try #require(entries.first { $0.name == "latest" })
        #expect(link.kind == .symlink)
        #expect(link.symlinkDestination == "big.bin")
    }

    @Test("skips banners, totals and blank lines rather than guessing")
    func skipsNonEntryLines() {
        let listing = """
        total 12

        drwx------ 2 sa users 0 Jul 25 20:55 real
        220 Some server banner
        """
        let entries = FTPListingParser.parse(listing)
        #expect(entries.map(\.name) == ["real"])
    }

    @Test("tolerates CRLF line endings")
    func tolerationOfCRLF() {
        let listing = "-rw------- 1 sa users 6 Jul 25 20:55 a.txt\r\ndrwx------ 2 sa users 0 Jul 25 20:55 d\r\n"
        let entries = FTPListingParser.parse(listing)
        #expect(entries.map(\.name) == ["a.txt", "d"])
    }

    // MARK: - DOS / IIS dialect

    /// The IIS `LIST` format. **Not captured** — the servers probed on 2026-07-25 both emit the Unix
    /// form, and this dialect could not be elicited from them (`SITE DIRSTYLE` is answered
    /// `502 not implemented`). These lines are the documented IIS shape, so this dialect is
    /// supported but, unlike the Unix one above, unverified against a live server.
    @Test("parses the DOS/IIS dialect, directories and sizes alike")
    func parsesDOSListing() throws {
        let listing = """
        04-27-00  09:09PM       <DIR>          licensed
        07-18-00  10:16AM       <DIR>          pub
        02-21-00  10:57AM              1173 readme.txt
        """
        let entries = FTPListingParser.parse(listing)
        #expect(entries.map(\.name) == ["licensed", "pub", "readme.txt"])

        let directory = try #require(entries.first { $0.name == "pub" })
        #expect(directory.kind == .directory)

        let file = try #require(entries.first { $0.name == "readme.txt" })
        #expect(file.kind == .file)
        #expect(file.byteSize == 1173)

        let calendar = Calendar(identifier: .gregorian)
        #expect(calendar.component(.year, from: file.modificationDate) == 2000)
        #expect(calendar.component(.month, from: file.modificationDate) == 2)
        #expect(calendar.component(.day, from: file.modificationDate) == 21)
    }

    @Test("parses a four-digit-year DOS listing and a name containing spaces")
    func parsesDOSListingVariants() throws {
        let listing = """
        12-31-2024  11:59PM       <DIR>          my folder
        01-02-2025  01:05AM              42 my notes.txt
        """
        let entries = FTPListingParser.parse(listing)
        #expect(entries.map(\.name) == ["my folder", "my notes.txt"])

        let file = try #require(entries.first { $0.name == "my notes.txt" })
        #expect(file.byteSize == 42)
        #expect(
            Calendar(identifier: .gregorian).component(.year, from: file.modificationDate) == 2025
        )
    }

    // MARK: - Dates

    @Test("a year-less stamp lands in the current year, read in the local calendar")
    func yearLessStampUsesCurrentYear() throws {
        // A date parsed from a year-less stamp lands at local midnight-relative time (the formatter
        // sets no zone), so it must be read in the local calendar — docs/NOTES.md.
        let calendar = Calendar(identifier: .gregorian)
        let now = Date()
        let month = calendar.component(.month, from: now)
        let day = calendar.component(.day, from: now)
        // The month names are spelled here rather than taken from `Calendar.shortMonthSymbols`,
        // which follows the *current locale* — on a machine whose `AppleLanguages` is pinned to
        // another language (docs/NOTES.md: the test target inherits that pin) it hands back
        // "июл" and the parser, which is `en_US_POSIX` by design, correctly rejects it. That
        // failure is the test's, not the code's.
        let names = [
            "Jan",
            "Feb",
            "Mar",
            "Apr",
            "May",
            "Jun",
            "Jul",
            "Aug",
            "Sep",
            "Oct",
            "Nov",
            "Dec"
        ]
        let stamp = "\(names[month - 1]) \(day) 00:30"

        let entries = FTPListingParser.parse("-rw------- 1 sa users 6 \(stamp) today.txt")
        let entry = try #require(entries.first)
        #expect(
            calendar.component(.year, from: entry.modificationDate) == calendar.component(
                .year,
                from: now
            )
        )
        #expect(calendar.component(.day, from: entry.modificationDate) == day)
    }

    @Test("a year-stamped older entry keeps its own year")
    func yearStampedEntryKeepsItsYear() throws {
        let entries = FTPListingParser.parse("-rw-r--r-- 1 sa users 6 Mar 3 2019 old.txt")
        let entry = try #require(entries.first)
        #expect(
            Calendar(identifier: .gregorian).component(.year, from: entry.modificationDate) == 2019
        )
    }

    @Test("an unparseable stamp yields distantPast rather than a wrong date")
    func unparseableStampIsDistantPast() throws {
        let entries = FTPListingParser.parse("-rw-r--r-- 1 sa users 6 Xxx ?? ????? weird.txt")
        let entry = try #require(entries.first)
        #expect(entry.modificationDate == .distantPast)
    }
}
