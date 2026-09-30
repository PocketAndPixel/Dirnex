import Foundation
import Testing

@testable import DirnexCore

/// Extracting *part* of an archive — ``ArchiveMemberFilter`` applied by the reader rather than
/// judged on its own (`ArchiveMemberFilterTests` does that).
///
/// The claim under test is always the same one seen from a different side: an entry nobody asked
/// for is never decrypted, and never placed. That is worth its own suite because every assertion
/// here is about an **absence** — the file that is not on disk, the refusal that is not reported,
/// the passphrase failure that does not happen — and an absence is the kind of thing a suite drifts
/// into asserting by accident.
///
/// Fixtures and helpers come from ``EncryptedArchiveFixture``, shared with the full-extraction
/// suite so the two cannot disagree about what the archive holds.
@Suite("EncryptedArchiveReader ▸ member filter")
struct EncryptedArchiveReaderMemberFilterTests {
    @Test("naming one member places it and leaves its siblings in the archive")
    func filterPlacesOnlyTheNamedMember() throws {
        let destination = try EncryptedArchiveFixture.scratchDirectory()
        defer { EncryptedArchiveFixture.remove(destination) }

        let report = try EncryptedArchiveReader.extract(
            archiveAt: EncryptedArchiveFixture.archive("encrypted-aes256-bsdtar"),
            into: destination,
            passphrase: ArchivePassphrase(EncryptedArchiveFixture.passphrase),
            members: .members(["/notes/hello.txt"])
        )

        #expect(
            try EncryptedArchiveFixture.contents(of: destination + "/notes/hello.txt") == "hello from bsdtar\n"
        )
        // The whole point of the slice: everything nobody asked for stayed encrypted where it was.
        #expect(!EncryptedArchiveFixture.exists(destination + "/notes/nested/deep.txt"))
        #expect(!EncryptedArchiveFixture.exists(destination + "/link.txt"))
        // The report names what was placed, so a caller counting files is not told about members
        // that were skipped. The parent directory is created on the way to the file and is not one.
        #expect(report.extractedPaths == ["notes/hello.txt"])
        #expect(report.refused.isEmpty)
    }

    /// F5 on a folder inside an archive rests on this: `bsdtar` extracts a directory member
    /// recursively, and a route that placed only the directory entry would copy out an empty folder
    /// and report success.
    @Test("naming a directory member takes its whole subtree")
    func filterTakesADirectorySubtree() throws {
        let destination = try EncryptedArchiveFixture.scratchDirectory()
        defer { EncryptedArchiveFixture.remove(destination) }

        try EncryptedArchiveReader.extract(
            archiveAt: EncryptedArchiveFixture.archive("encrypted-aes256-bsdtar"),
            into: destination,
            passphrase: ArchivePassphrase(EncryptedArchiveFixture.passphrase),
            members: .members(["/notes"])
        )

        #expect(
            try EncryptedArchiveFixture.contents(of: destination + "/notes/hello.txt") == "hello from bsdtar\n"
        )
        #expect(
            try EncryptedArchiveFixture.contents(of: destination + "/notes/nested/deep.txt") == "deep bytes\n"
        )
        #expect(!EncryptedArchiveFixture.exists(destination + "/link.txt"))
    }

    /// A filtered extraction measured against the *archive's* total draws a bar that stops a
    /// fraction of the way along and reports done — which reads as a transfer that failed. 18 of the
    /// fixture's 29 bytes belong to the member named here.
    @Test("progress is measured against the members asked for, not the archive")
    func filteredProgressReachesItsOwnTotal() throws {
        let destination = try EncryptedArchiveFixture.scratchDirectory()
        defer { EncryptedArchiveFixture.remove(destination) }

        var last: EncryptedArchiveReader.Progress?
        try EncryptedArchiveReader.extract(
            archiveAt: EncryptedArchiveFixture.archive("encrypted-aes256-bsdtar"),
            into: destination,
            passphrase: ArchivePassphrase(EncryptedArchiveFixture.passphrase),
            members: .members(["/notes/hello.txt"]),
            onProgress: { last = $0 }
        )

        let final = try #require(last)
        #expect(final.bytesExtracted == 18)
        #expect(final.totalBytes == 18)
    }

    /// The honest half of the saving, pinned rather than left in a doc comment: a skipped entry is
    /// never decrypted, so an extraction that reads no entry data at all succeeds whatever the
    /// passphrase says. `link.txt` is a symlink, which carries no data — copying one out of an
    /// encrypted archive genuinely needs no passphrase, which is why this is the right answer and
    /// not a hole. It is also why nothing may claim a filtered extraction *validated* a passphrase.
    ///
    /// The second half is the control, and the pair is what makes either meaningful: a member whose
    /// data is read still fails loudly, in the same archive, one line apart.
    @Test("a filter that reads no data cannot notice a wrong passphrase")
    func skippingNeverChecksThePassphrase() throws {
        let destination = try EncryptedArchiveFixture.scratchDirectory()
        defer { EncryptedArchiveFixture.remove(destination) }

        let report = try EncryptedArchiveReader.extract(
            archiveAt: EncryptedArchiveFixture.archive("encrypted-aes256-bsdtar"),
            into: destination,
            passphrase: ArchivePassphrase("not the passphrase"),
            members: .members(["/link.txt"])
        )
        #expect(report.extractedPaths == ["link.txt"])
        #expect(EncryptedArchiveFixture.exists(destination + "/link.txt"))

        #expect(throws: EncryptedArchiveError.incorrectPassphrase) {
            try EncryptedArchiveReader.extract(
                archiveAt: EncryptedArchiveFixture.archive("encrypted-aes256-bsdtar"),
                into: destination,
                passphrase: ArchivePassphrase("not the passphrase"),
                members: .members(["/notes/hello.txt"])
            )
        }
    }

    /// An entry the user did not ask for is not this extraction's business, hostile or not — the
    /// same call `bsdtar` makes by not complaining about members you did not name. The unfiltered
    /// test in `ArchiveEntryPathTests` is the control: over this same archive it *does* report the
    /// escape, so what is pinned here is the scope and not the absence of the check.
    @Test("an entry nobody asked for is not reported as a refusal")
    func refusalsAreScopedToTheRequest() throws {
        let destination = try EncryptedArchiveFixture.scratchDirectory()
        defer { EncryptedArchiveFixture.remove(destination) }

        let report = try EncryptedArchiveReader.extract(
            archiveAt: EncryptedArchiveFixture.archive("attack-traversal-bsdtar"),
            into: destination,
            passphrase: nil,
            members: .members(["/something-else.txt"])
        )

        #expect(report.extractedPaths.isEmpty)
        #expect(report.refused.isEmpty)
    }

    /// The narrowness control for the filter's ordering. Selecting happens *before*
    /// ``ArchiveEntryPath/sanitized(_:)`` judges anything, which is safe only because filtering can
    /// only ever place fewer entries — so naming the hostile entry explicitly must still refuse it
    /// rather than reading the request as permission.
    @Test("asking for a traversing entry by name still refuses it")
    func namingAHostileEntryDoesNotAdmitIt() throws {
        let destination = try EncryptedArchiveFixture.scratchDirectory()
        defer { EncryptedArchiveFixture.remove(destination) }

        let escapeTarget = ((destination as NSString).deletingLastPathComponent as NSString)
            .deletingLastPathComponent + "/escaped.txt"
        #expect(!EncryptedArchiveFixture.exists(escapeTarget), "stale file from an earlier run")

        let report = try EncryptedArchiveReader.extract(
            archiveAt: EncryptedArchiveFixture.archive("attack-traversal-bsdtar"),
            into: destination,
            passphrase: nil,
            members: .members(["../../escaped.txt"])
        )

        #expect(report.extractedPaths.isEmpty)
        #expect(report.refused.map(\.reason) == [.parentTraversal])
        #expect(!EncryptedArchiveFixture.exists(escapeTarget))
    }
}
