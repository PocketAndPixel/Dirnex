import Foundation
import Testing

@testable import DirnexCore

@Suite("SFTPListingParser")
struct SFTPListingParserTests {
    /// A real `sftp` batch `ls -la` block (captured from a live server): the `?` link column, names
    /// printed as full paths, `.`/`..` rows kept, a symlink with no ` -> target`, a name with a
    /// space, and an old (year-stamped) entry.
    private let sampleListing = """
    drwxr-xr-x    ? oleg     staff         192 Jul 13 00:09 /home/oleg/docs/.
    drwxr-xr-x    ? oleg     staff        3072 Jul  9 10:00 /home/oleg/docs/..
    lrwxr-xr-x    ? oleg     staff           9 Jul 13 00:09 /home/oleg/docs/latest
    -rw-r--r--    ? oleg     staff          11 Jul 13 00:09 /home/oleg/docs/my report.txt
    -rw-r--r--    ? oleg     staff           5 Jul 13 00:09 /home/oleg/docs/notes.txt
    drwxr-xr-x    ? oleg     staff          64 Jul 13 00:09 /home/oleg/docs/photos
    -rw-r--r--    ? oleg     staff         512 Jan  3  2021 /home/oleg/docs/archive.log
    """

    private func byName(_ text: String) -> [String: SFTPListingParser.Entry] {
        Dictionary(uniqueKeysWithValues: SFTPListingParser.parse(text).map { ($0.name, $0) })
    }

    @Test("reduces full-path names to their last component and keeps the . and .. rows")
    func basenamesAndKeepsDots() {
        let entries = SFTPListingParser.parse(sampleListing)
        let names = entries.map(\.name)
        #expect(names.contains("."))
        #expect(names.contains(".."))
        #expect(names.contains("notes.txt"))
        #expect(names.contains("photos"))
        #expect(entries.count == 7)
    }

    @Test("classifies files, directories, and symlinks by mode (the ? link column is ignored)")
    func classifiesKinds() {
        let entries = byName(sampleListing)
        #expect(entries["notes.txt"]?.kind == .file)
        #expect(entries["photos"]?.kind == .directory)
        #expect(entries["latest"]?.kind == .symlink)
    }

    @Test("a symlink parses with no destination (sftp omits the target)")
    func symlinkHasNoTarget() {
        let link = byName(sampleListing)["latest"]
        #expect(link?.kind == .symlink)
        #expect(link?.symlinkDestination == nil)
    }

    @Test("preserves internal spaces in a name")
    func nameWithSpaces() {
        let entry = byName(sampleListing)["my report.txt"]
        #expect(entry != nil)
        #expect(entry?.byteSize == 11)
    }

    @Test("reads the byte size column")
    func byteSize() {
        #expect(byName(sampleListing)["notes.txt"]?.byteSize == 5)
    }

    @Test("parses a recent HH:mm date and an old year-stamped date")
    func dates() {
        let entries = byName(sampleListing)
        #expect(entries["notes.txt"]?.modificationDate != .distantPast)

        // Read components in the local zone — the parser formats with no explicit time zone, so a
        // year-stamped entry lands at local midnight; forcing UTC here would shift the day.
        let calendar = Calendar(identifier: .gregorian)
        if let date = entries["archive.log"]?.modificationDate {
            #expect(date != .distantPast)
            #expect(calendar.component(.year, from: date) == 2021)
            #expect(calendar.component(.month, from: date) == 1)
            #expect(calendar.component(.day, from: date) == 3)
        }
    }

    @Test("a recent no-year date gets the current year, not the 2000 default")
    func recentDateUsesCurrentYear() {
        let calendar = Calendar(identifier: .gregorian)
        let currentYear = calendar.component(.year, from: Date())
        // A recent entry prints as "MMM d HH:mm" with no year; it must resolve to (about) now,
        // never the formatter's 2000 reference.
        let listing = "-rw-r--r--    ? oleg staff 5 Jul 13 00:09 /home/oleg/notes.txt"
        let date = try? #require(SFTPListingParser.parse(listing).first?.modificationDate)
        if let date {
            let year = calendar.component(.year, from: date)
            #expect(year != 2000)
            #expect(abs(year - currentYear) <= 1) // current year, or last year via boundary rollback
        }
    }

    @Test("parses permission bits from the mode string")
    func permissions() {
        let entries = byName(sampleListing)
        #expect(entries["notes.txt"]?.permissions == 0o644) // -rw-r--r--
        #expect(entries["photos"]?.permissions == 0o755) // drwxr-xr-x
    }

    @Test("classifies non-regular entries as other")
    func otherKinds() {
        let listing = """
        srwxr-xr-x    ? oleg staff 0 Jul 10 16:19 /run/daemon.sock
        prw-r--r--    ? oleg staff 0 Jul 10 16:19 /run/pipe
        """
        let entries = byName(listing)
        #expect(entries["daemon.sock"]?.kind == .other)
        #expect(entries["pipe"]?.kind == .other)
    }

    @Test("tolerates an ACL '+' or xattr '@' mode suffix")
    func modeSuffix() {
        let listing = """
        -rw-r--r--@   ? oleg staff 10 Jul 10 16:19 /home/oleg/tagged.txt
        drwxr-xr-x+   ? oleg staff  4 Jul 10 16:19 /home/oleg/acldir
        """
        let entries = byName(listing)
        #expect(entries["tagged.txt"]?.kind == .file)
        #expect(entries["acldir"]?.kind == .directory)
    }

    @Test("still handles a ' -> target' from a plain shell ls -la")
    func shellSymlinkTarget() {
        // A plain `ls -la` over a shell (not sftp) does print the target; keep supporting it.
        let listing = "lrwxrwxrwx 1 oleg staff 7 Jul 10 16:19 latest -> notes.txt"
        let link = byName(listing)["latest"]
        #expect(link?.kind == .symlink)
        #expect(link?.symlinkDestination == "notes.txt")
    }

    @Test("ignores the sftp prompt echo, blank lines, and error text")
    func ignoresJunk() {
        #expect(SFTPListingParser.parse("").isEmpty)
        #expect(SFTPListingParser.parse("sftp> ls -la /home/oleg").isEmpty)
        #expect(SFTPListingParser.parse("Can't ls: \"/x\" not found").isEmpty)
        #expect(SFTPListingParser.parse("Remote working directory: /home/oleg").isEmpty)
    }
}
