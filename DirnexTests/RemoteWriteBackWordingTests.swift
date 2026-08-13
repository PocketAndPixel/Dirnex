import DirnexCore
import Foundation
import Testing

@testable import Dirnex

/// What the write-back prompt tells the user the pre-upload check found (PLAN.md §M21 Slice 10).
///
/// The wording is the feature here, not decoration around it. None of the three remote protocols has
/// a lock and an upload is a whole-file write, so the user is being asked to authorize something
/// irreversible on the strength of one sentence — and how much that sentence is *worth* differs by
/// protocol. `RemoteRevisionEvidence` names four different blind spots; if two of them produced the
/// same sentence, one of the two would be a claim stronger than the evidence behind it.
///
/// Six distinct bodies, asserted as six distinct strings rather than by matching phrases: a test that
/// looked for "changed" would pass on the sentence saying the opposite.
@MainActor
@Suite("Remote write-back wording")
struct RemoteWriteBackWordingTests {
    private static func revision(
        byteSize: Int64 = 100,
        modified: Date? = Date(timeIntervalSince1970: 1_700_000_000),
        entityTag: String? = nil,
        approximate: Bool = false
    ) -> RemoteFileRevision {
        RemoteFileRevision(
            byteSize: byteSize,
            modified: modified,
            entityTag: entityTag,
            timestampIsApproximate: approximate
        )
    }

    private static func body(
        recorded: RemoteFileRevision?,
        current: RemoteFileRevision?
    ) -> String {
        BrowserWindowController.writeBackBody(recorded: recorded, current: current)
    }

    /// Every state the check can end in, so "these are all different" is one assertion rather than
    /// fifteen pairwise ones — and so a sixth state added later has to be named here to compile.
    private static var everyBody: [String] {
        [
            body(recorded: revision(), current: nil),
            body(recorded: nil, current: revision()),
            body(recorded: revision(), current: revision(byteSize: 200)),
            body(recorded: revision(entityTag: "a"), current: revision(entityTag: "a")),
            body(recorded: revision(), current: revision()),
            body(
                recorded: revision(approximate: true),
                current: revision(approximate: true)
            ),
            body(recorded: revision(modified: nil), current: revision(modified: nil))
        ]
    }

    @Test("every outcome of the check reads differently")
    func everyOutcomeIsDistinct() {
        let bodies = Self.everyBody
        #expect(Set(bodies).count == bodies.count)
        #expect(bodies.allSatisfy { !$0.isEmpty })
    }

    /// The one sentence every body carries, because it is the thing being authorized rather than the
    /// thing being reported. A body that omitted it would be a diagnosis with no consequence in it.
    @Test("every outcome says the upload replaces the server's copy and cannot be undone")
    func everyOutcomeStatesTheConsequence() {
        let consequence = String(
            localized: "Uploading replaces the copy on the server and can’t be undone.",
            comment: "Sentence appended to every remote write-back prompt."
        )
        for body in Self.everyBody {
            #expect(body.hasSuffix(consequence))
        }
    }

    // MARK: - The two that must never be confused

    /// The failure this whole mechanism exists to prevent, and the only sentence in it that is
    /// actively dangerous if wrong: telling someone their colleague's edit is still there.
    @Test("a server-side change is reported as a change")
    func changeIsReported() {
        let recorded = Self.revision()
        let changed = Self.revision(byteSize: 200)

        #expect(recorded.isSuperseded(by: changed))
        #expect(Self.body(recorded: recorded, current: changed)
            != Self.body(recorded: recorded, current: recorded))
    }

    /// The FTP caveat, which is the reason the evidence enum exists at all: `LIST` stamps are
    /// year-less, zone-less and on the server's clock, so "same size and date" there misses most of a
    /// working day. Same two revisions, same verdict, and it must not read the same.
    @Test("the same unchanged verdict reads differently over FTP than over a trustworthy clock")
    func approximateTimestampsAreCalledOut() {
        let exact = Self.body(recorded: Self.revision(), current: Self.revision())
        let ftp = Self.body(
            recorded: Self.revision(approximate: true),
            current: Self.revision(approximate: true)
        )

        #expect(exact != ftp)
    }

    /// And the third weakness, from the other side: with no date at all only the length could be
    /// compared, which the FTP sentence would describe wrongly — it would name a weakness in a
    /// timestamp there is none of.
    @Test("a server that reports no date says so rather than borrowing the FTP caveat")
    func missingTimestampHasItsOwnSentence() {
        let sizeOnly = Self.body(
            recorded: Self.revision(modified: nil),
            current: Self.revision(modified: nil)
        )
        let ftp = Self.body(
            recorded: Self.revision(approximate: true),
            current: Self.revision(approximate: true)
        )

        #expect(sizeOnly != ftp)
    }

    /// A check that could not be made must not be dressed up as one that passed — the quiet
    /// direction, since the user is about to overwrite something on the strength of it.
    @Test("an unreachable server is not reported as an unchanged one")
    func unreachableIsNotUnchanged() {
        #expect(Self.body(recorded: Self.revision(), current: nil)
            != Self.body(recorded: Self.revision(), current: Self.revision()))
    }
}
