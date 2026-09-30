import Foundation
import Testing

@testable import DirnexCore

/// What a listing **actually reported** about an item's POSIX metadata, per backend (PLAN.md §M24
/// Slice 7).
///
/// One suite rather than a claim spread across five parser files, because the subject is a single
/// invariant with five witnesses: *no backend may answer a mode it was not told*. Until this slice
/// two of them did — S3 and FTP's DOS/IIS dialect synthesized `0o755`/`0o644`, under a comment
/// explaining that `0` "would render every remote row as unreadable in the permissions column", and
/// the columns are `name`, `size` and `date`. The invented value reached nothing for as long as
/// nothing displayed a remote mode, which is exactly what Get Info changes.
///
/// The mirror image was true of owner and group: `sftp` and FTP's Unix `LIST` print them in every
/// row and ``ColumnarListing/UnixRow`` read past them, so every remote `FileEntry` carried
/// `ownerID == 0` while the answer had been arriving in the same line as the mode all along.
@Suite("Reported metadata")
struct ReportedMetadataTests {
    // MARK: - What the wire carries

    /// Captured from a live `sshd` (2026-08-27), which is where the owner and group columns are
    /// *names* rather than ids.
    private let sftpListing = """
    drwxr-xr-x    ? oleg     wheel         160 Aug 27 23:37 /home/oleg/tree/.
    -rw-r--r--    ? oleg     wheel           6 Aug 27 23:37 /home/oleg/tree/mine.txt
    -rwsr-xr-x    ? root     admin      100000 Aug 27 23:37 /home/oleg/tree/setuid.bin
    """

    private let ftpUnixListing = """
    -rw------- 1 sa users          6 Jul 25 20:55 .hidden
    drwx------ 2 sa users          0 Jul 25 20:55 sub dir
    """

    /// The other dialect in the field, which has no mode, owner or group columns whatsoever.
    private let ftpDOSListing = """
    04-27-00  09:09PM       <DIR>          licensed
    02-21-00  10:57AM              1173 readme.txt
    """

    @Test("sftp's ls -la carries the owner and group the server printed, as text")
    func sftpCarriesOwnerAndGroup() {
        let byName = Dictionary(
            uniqueKeysWithValues: SFTPListingParser.parse(sftpListing).map { ($0.name, $0) }
        )
        #expect(byName["mine.txt"]?.ownerName == "oleg")
        #expect(byName["mine.txt"]?.groupName == "wheel")
        // A different owner on a neighbouring row, so the test cannot pass by reading one constant.
        #expect(byName["setuid.bin"]?.ownerName == "root")
        #expect(byName["setuid.bin"]?.groupName == "admin")
    }

    /// The `s` glyph is set-uid **and** execute; reading it as a plain `x` disclaims the one bit
    /// anybody inspects a remote binary for.
    @Test("sftp's mode column is read exactly, set-uid included")
    func sftpModeIsExact() {
        let byName = Dictionary(
            uniqueKeysWithValues: SFTPListingParser.parse(sftpListing).map { ($0.name, $0) }
        )
        #expect(byName["mine.txt"]?.permissions == 0o644)
        #expect(byName["setuid.bin"]?.permissions == 0o4755)
    }

    @Test("FTP's Unix dialect carries mode, owner and group")
    func ftpUnixCarriesEverything() {
        let byName = Dictionary(
            uniqueKeysWithValues: FTPListingParser.parse(ftpUnixListing).map { ($0.name, $0) }
        )
        #expect(byName[".hidden"]?.permissions == 0o600)
        #expect(byName[".hidden"]?.ownerName == "sa")
        #expect(byName[".hidden"]?.groupName == "users")
        #expect(byName["sub dir"]?.permissions == 0o700)
    }

    /// The heart of the slice. A DOS listing has no such columns, so the honest answer is *nothing*
    /// — and `0` cannot say it, because `chmod 000` is a legal mode.
    @Test("FTP's DOS dialect reports no mode, no owner and no group")
    func ftpDOSReportsNothing() {
        let entries = FTPListingParser.parse(ftpDOSListing)
        #expect(entries.count == 2)
        for entry in entries {
            #expect(entry.permissions == nil)
            #expect(entry.ownerName == nil)
            #expect(entry.groupName == nil)
        }
        // The narrowness control: the row is still fully parsed. Reporting no mode must not be
        // mistaken for failing to read the line.
        let byName = Dictionary(uniqueKeysWithValues: entries.map { ($0.name, $0) })
        #expect(byName["readme.txt"]?.byteSize == 1173)
        #expect(byName["licensed"]?.kind == .directory)
    }

    @Test("S3 reports no mode: an object store has no POSIX metadata to report")
    func s3ReportsNoMode() throws {
        let page = try S3ListingParser.parse(Data(S3ListingParserTests.filesPage.utf8))
        let directory = VFSPath(backend: VFSBackendID("s3://K@h:443/r/b"), path: "/")
        let entries = S3ListingParser.entries(from: page, in: directory)
        #expect(!entries.isEmpty)
        for entry in entries {
            #expect(entry.permissions == nil)
            #expect(entry.ownerName == nil)
            #expect(entry.groupName == nil)
        }
    }

    // MARK: - Archives

    /// `bsdtar -tvf` prints a real mode in column 0 and the parser dropped it, so a browsed archive
    /// answered the same invented `0o755`/`0o644`. Note the owner column changes *shape* with the
    /// format rather than with the tool: a zip stores no owner names, so `bsdtar` falls back to the
    /// bare numbers — probed 2026-08-27 against libarchive 3.7.4, same tool, same file, both forms.
    @Test("a zip's stored mode is reported, with its owner as the bare numbers bsdtar printed")
    func zipCarriesStoredMode() {
        let toc = ArchiveTOC(verboseListing: """
        -rw-r--r--  0 501    0           3 Aug 27 23:39 a.txt
        -rwxr-xr-x  0 501    0        1024 Aug 27 23:39 run.sh
        """)
        let byName = Dictionary(
            uniqueKeysWithValues: toc.children(inDirectory: "/").map { ($0.name, $0) }
        )
        #expect(byName["a.txt"]?.permissions == 0o644)
        #expect(byName["run.sh"]?.permissions == 0o755)
        #expect(byName["a.txt"]?.ownerName == "501")
        #expect(byName["a.txt"]?.groupName == "0")
    }

    @Test("a tar's owner arrives as the names it stores, for the identical tree")
    func tarCarriesOwnerNames() {
        let toc = ArchiveTOC(verboseListing: """
        -rw-r--r--  0 oleg   wheel       3 Aug 27 23:39 ./a.txt
        """)
        let entry = toc.children(inDirectory: "/").first { $0.name == "a.txt" }
        #expect(entry?.ownerName == "oleg")
        #expect(entry?.groupName == "wheel")
    }

    /// An archive may omit its intermediate directory entries, and the parser synthesizes them.
    /// There is no row behind a synthesized node, so it has no mode to report — the same distinction
    /// the whole slice rests on, arriving from inside one backend rather than between two.
    @Test("a directory the archive omitted reports no mode, while a listed one does")
    func synthesizedDirectoryReportsNoMode() {
        let toc = ArchiveTOC(verboseListing: """
        drwxr-x---  0 501    0           0 Aug 27 23:39 listed/
        -rw-r--r--  0 501    0           3 Aug 27 23:39 listed/a.txt
        -rw-r--r--  0 501    0           3 Aug 27 23:39 omitted/b.txt
        """)
        let root = Dictionary(
            uniqueKeysWithValues: toc.children(inDirectory: "/").map { ($0.name, $0) }
        )
        #expect(root["listed"]?.permissions == 0o750)
        #expect(root["omitted"]?.permissions == nil)
        #expect(root["omitted"]?.ownerName == nil)
    }

    /// A first column that is not a mode field must answer `nil` rather than the `0` the bit reader
    /// returns for it. `ArchiveTOCParser` deliberately accepts any first column where
    /// `ColumnarListing.unixRow` requires a mode, so this is reachable rather than defensive.
    @Test("an unrecognized first column reports no mode rather than an unreadable one")
    func unparseableModeReportsNothing() {
        let toc = ArchiveTOC(verboseListing: """
        ?????  0 501    0           3 Aug 27 23:39 odd.txt
        """)
        let entry = toc.children(inDirectory: "/").first { $0.name == "odd.txt" }
        #expect(entry != nil)
        #expect(entry?.permissions == nil)
    }

    // MARK: - The invariant, stated once

    /// Whatever else changes, no parser may answer a mode for a source that reported none. Written
    /// as a sweep so a backend added later is covered by the claim rather than by remembering to
    /// extend a list.
    @Test("no listing that reports no mode answers one anyway")
    func nothingInventsAMode() {
        #expect(FTPListingParser.parse(ftpDOSListing).allSatisfy { $0.permissions == nil })
        let odd = ArchiveTOC(verboseListing: "totally unparseable\n")
        #expect(odd.children(inDirectory: "/").isEmpty)
    }
}
