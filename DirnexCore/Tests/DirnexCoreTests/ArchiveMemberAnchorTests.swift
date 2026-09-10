import Foundation
import Testing

@testable import DirnexCore

/// Finding a member again after its name has been re-decoded (PLAN.md §M27).
@Suite("ArchiveMemberAnchor")
struct ArchiveMemberAnchorTests {
    private static func entry(
        _ path: String,
        size: Int64 = 64,
        seconds: TimeInterval = 1_700_000_000,
        kind: FileEntry.Kind = .file
    ) -> FileEntry {
        FileEntry(
            path: VFSPath(backend: .archive(forArchiveAt: "/tmp/a.zip"), path: path),
            name: (path as NSString).lastPathComponent,
            kind: kind,
            byteSize: size,
            modificationDate: Date(timeIntervalSince1970: seconds),
            creationDate: Date(timeIntervalSince1970: seconds),
            isHidden: false,
            permissions: 0o644,
            inode: 0
        )
    }

    @Test("the same member under its decoded name is found")
    func findsTheRenamedMember() throws {
        let before = Self.entry("/\u{FFFD}\u{FFFD}.txt")
        let after = [Self.entry("/plain.txt", size: 18), Self.entry("/Панорама.txt")]

        #expect(ArchiveMemberAnchor.match(before, in: after)?.name == "Панорама.txt")
    }

    /// Most of any real archive: a name that was already ASCII is spelled identically either way, so
    /// it matches outright and never reaches the size-and-date comparison.
    @Test("an unchanged name matches on its path")
    func findsAnUnchangedMember() throws {
        let plain = Self.entry("/plain.txt", size: 18)
        let after = [plain, Self.entry("/Панорама.txt")]

        #expect(ArchiveMemberAnchor.match(plain, in: after)?.path == plain.path)
    }

    /// The safety property, and the reason this returns an optional at all: two files of one size
    /// and timestamp in a folder are ordinary, nothing left after the name can separate them, and a
    /// confident wrong answer here would open a rename on the wrong file.
    @Test("an ambiguous match is refused rather than guessed")
    func refusesAnAmbiguousMatch() throws {
        let before = Self.entry("/\u{FFFD}\u{FFFD}.txt")
        let after = [Self.entry("/Один.txt"), Self.entry("/Два.txt")]

        #expect(ArchiveMemberAnchor.match(before, in: after) == nil)
    }

    /// The date is **not** part of the match, and this pins the omission rather than leaving it to a
    /// comment: the listing before a declaration is read by `bsdtar -tvf`, whose date column carries
    /// no seconds, and the one after it by libarchive, which reports the real `mtime`. Comparing
    /// them means never matching, which is how this was first written — its own test then reproduced
    /// the very bug it exists to fix.
    @Test("a member whose timestamp reads differently in the two engines still matches")
    func ignoresTheModificationDate() throws {
        let before = Self.entry("/\u{FFFD}\u{FFFD}.txt", seconds: 1_700_000_000)
        let after = [Self.entry("/Панорама.txt", seconds: 1_700_000_037)]

        #expect(ArchiveMemberAnchor.match(before, in: after)?.name == "Панорама.txt")
    }

    @Test("nothing of the right shape is no match")
    func refusesWhenNothingMatches() throws {
        let before = Self.entry("/\u{FFFD}\u{FFFD}.txt", size: 64)
        let after = [Self.entry("/other.txt", size: 999)]

        #expect(ArchiveMemberAnchor.match(before, in: after) == nil)
    }

    /// Each half of the comparison is load-bearing: a directory and a file of the same size, and a
    /// sibling in another folder, are both things a listing really holds.
    @Test("kind and directory are part of the match")
    func kindAndDirectorySeparate() throws {
        let before = Self.entry("/docs/x.txt")
        let wrongKind = Self.entry("/docs/other", kind: .directory)
        let wrongDirectory = Self.entry("/elsewhere/other.txt")

        #expect(ArchiveMemberAnchor.match(before, in: [wrongKind, wrongDirectory]) == nil)
        let right = Self.entry("/docs/Панорама.txt")
        #expect(
            ArchiveMemberAnchor.match(before, in: [wrongKind, wrongDirectory, right])?.path
                == right.path
        )
    }
}
