import DirnexCore
import Foundation
import Testing

@testable import Dirnex

/// Whether a saved remote file interrupts the user, and what it says when it does (PLAN.md §M21
/// Slice 10; the silent path 2026-08-23).
///
/// Two claims, and the first is the one with teeth. `EditedFileRegistry` raises this on the user's
/// own ⌘S and keeps watching after an upload, so anything asked here is asked *per save* for the
/// life of the edit — which makes "the file is as you left it" a question about an intent already
/// stated, on the ordinary path, forever. It now uploads instead, and the check earns its request by
/// the three answers that carry something no other surface would tell them.
///
/// The wording of those three is the second claim, and it is the feature rather than decoration
/// around it: none of the three protocols has a lock and an upload is a whole-file write, so the
/// user is authorizing something irreversible on the strength of one sentence. Asserted as distinct
/// *strings* rather than by matching phrases — a test looking for "changed" passes on the sentence
/// saying the opposite.
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

    private static func concern(
        recorded: RemoteFileRevision?,
        current: RemoteFileRevision?
    ) -> String? {
        BrowserWindowController.writeBackConcern(recorded: recorded, current: current)
    }

    // MARK: - Whether anybody is interrupted

    /// The rule the whole change rests on, over **every** shape an unchanged verdict can have —
    /// `RemoteRevisionEvidence`'s four, spelled out rather than sampled, because the weak ones are
    /// exactly where the argument for asking used to live. An FTP row is the third of them, and is
    /// the case this was reported from.
    @Test("a check that found nothing does not interrupt, whatever it was able to compare")
    func unchangedAsksNothing() {
        let unchanged: [(String, RemoteFileRevision)] = [
            ("entity tags matched", Self.revision(entityTag: "\"a\"")),
            ("size and a trustworthy date matched", Self.revision()),
            ("size and an FTP date matched", Self.revision(approximate: true)),
            ("only the size could be compared", Self.revision(modified: nil))
        ]
        for (evidence, revision) in unchanged {
            #expect(
                Self.concern(recorded: revision, current: revision) == nil,
                "\(evidence): an unchanged file must upload without asking"
            )
        }
    }

    /// The narrowness control, and the half that keeps "don't interrupt" from quietly becoming
    /// "never interrupt": each of the three answers that carries a fact still stops the user.
    @Test("each answer the user has to weigh still interrupts")
    func concernsInterrupt() {
        let concerns = [
            Self.concern(recorded: Self.revision(), current: Self.revision(byteSize: 200)),
            Self.concern(recorded: Self.revision(), current: nil),
            Self.concern(recorded: nil, current: Self.revision())
        ]
        #expect(concerns.allSatisfy { $0 != nil })
    }

    // MARK: - What those three say

    private static var everyConcern: [String] {
        [
            Self.concern(recorded: Self.revision(), current: Self.revision(byteSize: 200)),
            Self.concern(recorded: Self.revision(), current: nil),
            Self.concern(recorded: nil, current: Self.revision())
        ].compactMap { $0 }
    }

    /// Three states, three sentences — so a fourth added later has to be named here to compile, and
    /// two of them collapsing into one sentence fails rather than reading as a tidy-up.
    @Test("every outcome that interrupts reads differently")
    func everyOutcomeIsDistinct() {
        let bodies = Self.everyConcern
        #expect(bodies.count == 3)
        #expect(Set(bodies).count == bodies.count)
        #expect(bodies.allSatisfy { !$0.isEmpty })
    }

    /// The one sentence each carries, because it is the thing being authorized rather than the thing
    /// being reported. A body that omitted it would be a diagnosis with no consequence in it.
    @Test("every outcome says the upload replaces the server's copy and cannot be undone")
    func everyOutcomeStatesTheConsequence() {
        let consequence = String(
            localized: "Uploading replaces the copy on the server and can’t be undone.",
            comment: "Sentence appended to every remote write-back prompt."
        )
        for body in Self.everyConcern {
            #expect(body.hasSuffix(consequence))
        }
    }

    /// The failure this whole mechanism exists to prevent, and the only sentence in it that is
    /// actively dangerous if wrong: telling someone their colleague's edit is still there.
    @Test("a server-side change is reported as a change")
    func changeIsReported() {
        let recorded = Self.revision()
        let changed = Self.revision(byteSize: 200)

        #expect(recorded.isSuperseded(by: changed))
        #expect(Self.concern(recorded: recorded, current: changed) != nil)
        #expect(Self.concern(recorded: recorded, current: recorded) == nil)
    }

    /// A check that could not be made must not be dressed up as one that passed — the quiet
    /// direction, since the user is about to overwrite something on the strength of it. Now the
    /// difference is a dialog against no dialog at all, which is why it is worth asserting twice.
    @Test("an unreachable server is not treated as an unchanged one")
    func unreachableIsNotUnchanged() {
        let unreachable = Self.concern(recorded: Self.revision(), current: nil)
        let unchanged = Self.concern(recorded: Self.revision(), current: Self.revision())

        #expect(unreachable != nil)
        #expect(unchanged == nil)
    }

    /// And nothing recorded to compare against is its own state rather than a borrowed one: it is
    /// not a failed request, and it is certainly not a clean bill of health.
    @Test("having nothing to compare against has its own sentence")
    func missingRecordHasItsOwnSentence() throws {
        let noRecord = try #require(Self.concern(recorded: nil, current: Self.revision()))
        let unreachable = try #require(Self.concern(recorded: Self.revision(), current: nil))

        #expect(noRecord != unreachable)
    }
}
