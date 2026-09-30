import Foundation
import Testing

@testable import DirnexCore

/// The table that decides whether a remote fetch just happens (PLAN.md §M21 Slice 10).
///
/// These assertions are about the *shape* of the policy and not about the numbers in it — the
/// numbers are expected to move, one of them on every visit to Settings, and a test that pinned each
/// to a literal would be a second copy of the table rather than a check on it. What must not move is
/// the ordering, the boundary behaviour, the unknown-size row, and the split between a refusal that
/// asks and one that does not.
///
/// Every shape test runs at **four** preview limits rather than at the default, because the default
/// is the one value that cannot expose an edge: zero is a real setting ("never"), and the top of the
/// band is where the ordering against open and edit inverts if it is going to.
@Suite("Remote fetch policy")
struct RemoteFetchPolicyTests {
    /// Never, the default, a photographer's 300 MB, and the top of the band.
    private static let limits: [Int64] = [
        0,
        RemoteFetchPolicy.defaultPreviewLimit,
        300 * 1_000_000,
        RemoteFetchPolicy.previewLimitRange.upperBound
    ]

    /// What a refusal looks like for `purpose` — the one thing `isAutomatic` decides. Written out
    /// here rather than read from the code under test: borrowing `isAutomatic` would prove the two
    /// agree, not that either is right.
    private func expectedRefusal(for purpose: RemoteFetchPurpose) -> RemoteFetchDecision {
        purpose == .cursorPreview ? .decline : .confirm
    }

    // MARK: - The size rows

    @Test("a file under the limit fetches without asking, for every gesture")
    func smallFileFetches() {
        for limit in Self.limits where limit > 0 {
            for purpose in RemoteFetchPurpose.allCases {
                let decision = RemoteFetchPolicy.decision(
                    forByteSize: 4096, purpose: purpose, previewLimit: limit
                )
                #expect(decision == .fetch)
            }
        }
    }

    /// Empty is not unknown, and it holds even at a limit of zero: there is nothing to spend.
    @Test("an empty file fetches rather than being treated as unknown")
    func emptyFileFetches() {
        for limit in Self.limits {
            for purpose in RemoteFetchPurpose.allCases {
                let decision = RemoteFetchPolicy.decision(
                    forByteSize: 0, purpose: purpose, previewLimit: limit
                )
                #expect(decision == .fetch)
            }
        }
    }

    @Test("a file past every threshold is refused, for every gesture")
    func hugeFileIsRefused() {
        let size = RemoteFetchPolicy.previewLimitRange.upperBound * 2
        for limit in Self.limits {
            for purpose in RemoteFetchPurpose.allCases {
                let decision = RemoteFetchPolicy.decision(
                    forByteSize: size, purpose: purpose, previewLimit: limit
                )
                #expect(decision == expectedRefusal(for: purpose))
            }
        }
    }

    /// The threshold is inclusive, so a file of exactly the stated size is on the quiet side of it.
    /// Worth pinning because the off-by-one is invisible: both readings look correct, and only the
    /// file that sits exactly on the number can tell them apart.
    @Test("the threshold itself fetches, and one byte past it is refused")
    func boundaryIsInclusive() {
        for limit in Self.limits {
            for purpose in RemoteFetchPurpose.allCases {
                let threshold = RemoteFetchPolicy.threshold(for: purpose, previewLimit: limit)
                let at = RemoteFetchPolicy.decision(
                    forByteSize: threshold, purpose: purpose, previewLimit: limit
                )
                let past = RemoteFetchPolicy.decision(
                    forByteSize: threshold + 1, purpose: purpose, previewLimit: limit
                )
                #expect(at == .fetch)
                #expect(past == expectedRefusal(for: purpose))
            }
        }
    }

    /// Not knowing how much is about to be pulled is exactly when to ask — the row that is not a
    /// number at all, and the one a call-site constant could never have expressed.
    @Test("an unknown size is refused")
    func unknownSizeIsRefused() {
        for limit in Self.limits {
            for purpose in RemoteFetchPurpose.allCases {
                let decision = RemoteFetchPolicy.decision(
                    forByteSize: nil, purpose: purpose, previewLimit: limit
                )
                #expect(decision == expectedRefusal(for: purpose))
            }
        }
    }

    /// A negative size can only come from a field that was not understood, which is the unknown case
    /// wearing a number. Clamping it to zero would fetch silently on exactly the reading nobody
    /// should trust.
    @Test("a negative size is the unknown case, not a small one")
    func negativeSizeIsRefused() {
        for limit in Self.limits {
            for purpose in RemoteFetchPurpose.allCases {
                let decision = RemoteFetchPolicy.decision(
                    forByteSize: -1, purpose: purpose, previewLimit: limit
                )
                #expect(decision == expectedRefusal(for: purpose))
            }
        }
    }

    // MARK: - Asking versus declining

    /// The whole reason ``RemoteFetchDecision/decline`` exists: an automatic fetch has nobody
    /// standing at a keystroke, so a size it will not spend must leave the caller's placeholder up
    /// rather than raise a dialog on an arrow key. Asserted in both directions in one test, since
    /// the pair is the claim — an explicit gesture over the same threshold must still ask.
    @Test("an automatic fetch declines where an explicit one confirms")
    func automaticDeclinesWhereExplicitConfirms() {
        for limit in Self.limits {
            let over = RemoteFetchPolicy.threshold(for: .preview, previewLimit: limit) + 1
            let automatic = RemoteFetchPolicy.decision(
                forByteSize: over, purpose: .cursorPreview, previewLimit: limit
            )
            let explicit = RemoteFetchPolicy.decision(
                forByteSize: over, purpose: .preview, previewLimit: limit
            )
            #expect(automatic == .decline)
            #expect(explicit == .confirm)
        }
    }

    /// Exactly one gesture is automatic. Pinned because `isAutomatic` is what turns every refusal
    /// above into a silent one, so a second case answering `true` by accident would make a
    /// key-pressed gesture stop asking — a fetch the user is waiting for that quietly never starts.
    @Test("only the cursor-following preview is automatic")
    func onlyTheCursorPreviewIsAutomatic() {
        let automatic = RemoteFetchPurpose.allCases.filter(\.isAutomatic)

        #expect(automatic == [.cursorPreview])
    }

    // MARK: - The limit the user owns

    /// The feature, in the form a test can hold: a file the default declines is fetched once the
    /// user says files that large are fine. Both directions, because a policy that ignored the
    /// parameter would pass either one alone.
    @Test("raising the limit turns a declined file into an automatic fetch")
    func raisingTheLimitAdmitsLargerFiles() {
        let photograph: Int64 = 250 * 1_000_000

        let atDefault = RemoteFetchPolicy.decision(
            forByteSize: photograph,
            purpose: .cursorPreview,
            previewLimit: RemoteFetchPolicy.defaultPreviewLimit
        )
        let raised = RemoteFetchPolicy.decision(
            forByteSize: photograph, purpose: .cursorPreview, previewLimit: 300 * 1_000_000
        )

        #expect(atDefault == .decline)
        #expect(raised == .fetch)
    }

    /// Zero is a setting, not a broken value: "never download a preview I did not ask for" is the
    /// honest answer on a metered connection, and it is what Quick View did before the limit
    /// existed. The explicit gestures must go on working, or the setting would quietly disable ⌘Y.
    @Test("a limit of zero declines every non-empty preview and still lets a key ask")
    func zeroMeansNever() {
        let automatic = RemoteFetchPolicy.decision(
            forByteSize: 1, purpose: .cursorPreview, previewLimit: 0
        )
        let explicit = RemoteFetchPolicy.decision(forByteSize: 1, purpose: .preview, previewLimit: 0)
        let opening = RemoteFetchPolicy.decision(forByteSize: 1, purpose: .open, previewLimit: 0)

        #expect(automatic == .decline)
        #expect(explicit == .confirm)
        // Opening keeps its own floor, so turning previews off does not start confirming every ⏎.
        #expect(opening == .fetch)
    }

    /// A value from a hand-edited defaults domain, or from a build whose band was wider, has to land
    /// inside the range rather than being honoured — one funnel, so Settings and the restore path
    /// cannot disagree about what is allowed.
    @Test("a limit outside the band is clamped, and one inside is left alone")
    func limitsAreClamped() {
        let range = RemoteFetchPolicy.previewLimitRange

        #expect(RemoteFetchPolicy.clampedPreviewLimit(-1) == range.lowerBound)
        #expect(RemoteFetchPolicy.clampedPreviewLimit(range.upperBound * 4) == range.upperBound)
        #expect(RemoteFetchPolicy.clampedPreviewLimit(300 * 1_000_000) == 300 * 1_000_000)
        // And the thresholds are computed through it, so an out-of-band value cannot reach the
        // decision by going round the clamp.
        let threshold = RemoteFetchPolicy.threshold(for: .cursorPreview, previewLimit: -1)
        #expect(threshold == range.lowerBound)
    }

    @Test("the default limit sits inside the band the Settings field offers")
    func defaultIsInsideTheBand() {
        #expect(RemoteFetchPolicy.previewLimitRange.contains(RemoteFetchPolicy.defaultPreviewLimit))
    }

    // MARK: - The ordering between rows

    /// Preview is the least committed gesture and the most expensive to get wrong, so it must be
    /// the first to ask — at **every** limit, which is the half a fixed-number table never had to
    /// prove. Raise the preview limit past open's own floor and the two must move together, or a
    /// user who has agreed to a 300 MB preview is asked about opening the same file.
    @Test("preview asks no later than opening or editing, at every limit")
    func previewIsTheLowestThreshold() {
        for limit in Self.limits {
            let preview = RemoteFetchPolicy.threshold(for: .preview, previewLimit: limit)
            let automatic = RemoteFetchPolicy.threshold(for: .cursorPreview, previewLimit: limit)

            #expect(automatic <= preview)
            #expect(preview <= RemoteFetchPolicy.threshold(for: .open, previewLimit: limit))
            #expect(preview <= RemoteFetchPolicy.threshold(for: .edit, previewLimit: limit))
        }
    }

    /// Opening keeps a floor of its own rather than merely tracking the preview limit, so turning
    /// previews down — or off — never makes ⏎ start confirming files it used to just open.
    @Test("opening and editing keep their own floor when the preview limit is below it")
    func openingKeepsItsFloor() {
        let atZero = RemoteFetchPolicy.threshold(for: .open, previewLimit: 0)
        let atDefault = RemoteFetchPolicy.threshold(
            for: .open, previewLimit: RemoteFetchPolicy.defaultPreviewLimit
        )

        #expect(atZero == atDefault)
        #expect(atZero > RemoteFetchPolicy.defaultPreviewLimit)
    }
}
