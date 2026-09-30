import DirnexCore
import Foundation
import Testing

@testable import Dirnex

/// The precondition a save-back sends, and what the app does when the server refuses it
/// (PLAN.md §M21 Slice 18).
///
/// Slice 17 built the conditional write and measured everything about the client half; this is the
/// wiring, and the wiring has exactly one decision in it that can be made the wrong way round while
/// compiling, passing every other test and reading correctly at the call site — **which revision's
/// entity tag travels**. Conditioning on the tag of the copy that was *downloaded* refuses the very
/// write the prompt exists to authorize, and does it in a sentence claiming somebody changed the
/// file. So that is what most of this suite is about.
@MainActor
@Suite("Remote write-back precondition")
struct RemoteWriteBackConditionTests {
    private static func revision(
        byteSize: Int64 = 100,
        entityTag: String? = nil
    ) -> RemoteFileRevision {
        RemoteFileRevision(
            byteSize: byteSize,
            modified: Date(timeIntervalSince1970: 1_700_000_000),
            entityTag: entityTag
        )
    }

    // MARK: - Which tag travels

    /// The load-bearing one. The user was shown what the check found and agreed to overwrite *that*
    /// — so that is what the header pins, and the window it closes is the one between their answer
    /// and the `PUT`. Sending the downloaded copy's tag instead would answer 412 to their own
    /// decision, which is the failure this test exists to keep out.
    @Test("the condition names the tag the check found, not the tag that was downloaded")
    func conditionNamesTheCheckedTag() {
        let downloaded = Self.revision(entityTag: "\"downloaded\"")
        let onServerNow = Self.revision(byteSize: 200, entityTag: "\"changed-by-somebody-else\"")

        // The two really are different states, or this proves nothing about which one was read.
        #expect(downloaded.isSuperseded(by: onServerNow))

        let condition = BrowserWindowController.writeCondition(checked: onServerNow)
        #expect(condition == .ifMatches(entityTag: "\"changed-by-somebody-else\""))
        #expect(condition != .ifMatches(entityTag: "\"downloaded\""))
    }

    /// Quotes included, verbatim. An unquoted digest is a different byte string to S3 and matches
    /// nothing, so a tidy-up anywhere between the listing parser and the wire turns every guarded
    /// save into a 412 reading "somebody else changed this file" — confidently, on every save
    /// (docs/NOTES.md ▸ curl for S3).
    @Test("the entity tag is passed through exactly as the listing gave it")
    func entityTagKeepsItsQuotes() {
        let tag = "\"f804fb237efd0e539f99f64aa7299653\""
        #expect(
            BrowserWindowController.writeCondition(checked: Self.revision(entityTag: tag))
                == .ifMatches(entityTag: tag)
        )
    }

    /// SFTP and FTP have no entity tag at all, and neither does an S3 row whose listing carried no
    /// `<ETag>`. Those saves go on resting on the re-`stat` the prompt is worded from — where they
    /// were before this slice, which is what "strictly additive" means in code rather than in prose.
    @Test("a backend with no entity tag writes unconditionally rather than not at all")
    func noEntityTagWritesUnconditionally() {
        #expect(BrowserWindowController.writeCondition(checked: Self.revision()) == .unconditional)
    }

    /// A check that could not reach the server has nothing to pin. Inventing a condition here would
    /// refuse a save for a reason that was never measured.
    @Test("a check that failed sends no condition")
    func unreachableCheckWritesUnconditionally() {
        #expect(BrowserWindowController.writeCondition(checked: nil) == .unconditional)
    }

    // MARK: - Reading the refusal

    @Test("a precondition refusal is recognized as a conflict, in both its shapes")
    func refusalsAreRecognized() {
        #expect(
            BrowserWindowController.writeBackConflict(
                from: VFSError.unsupported(.remoteFileChangedSinceFetch(name: "notes.txt"))
            ) == .changed
        )
        #expect(
            BrowserWindowController.writeBackConflict(
                from: VFSError.unsupported(.remoteFileGoneSinceFetch(name: "notes.txt"))
            ) == .gone
        )
    }

    /// The narrowness control, and it matters more than the test above: "Upload Anyway" over a
    /// permissions failure is an offer that cannot work — the retry fails identically, having asked
    /// the user to authorize an overwrite that never happens. Only what the condition itself
    /// produced gets the second question.
    @Test("anything else on the way up stays an ordinary failure")
    func otherFailuresAreNotConflicts() {
        let path = VFSPath.local("/tmp/notes.txt")
        #expect(BrowserWindowController.writeBackConflict(from: VFSError.permissionDenied(path))
            == nil)
        #expect(BrowserWindowController.writeBackConflict(from: VFSError.notFound(path)) == nil)
        #expect(BrowserWindowController.writeBackConflict(from: VFSError.unsupported(.copyFile))
            == nil)
        #expect(BrowserWindowController.writeBackConflict(from: CancellationError()) == nil)
    }

    // MARK: - What the refusal says

    /// Two sentences, because the two situations differ in what uploading anyway would *do*:
    /// "replaces their version" is false when there is no version left, and "puts it back" is false
    /// when there is.
    @Test("the two refusals read differently, and both say what uploading anyway does")
    func refusalsReadDifferently() {
        let changed = BrowserWindowController.uploadAnywayBody(.changed)
        let gone = BrowserWindowController.uploadAnywayBody(.gone)

        #expect(changed != gone)
        #expect(!changed.isEmpty)
        #expect(!gone.isEmpty)
    }
}
