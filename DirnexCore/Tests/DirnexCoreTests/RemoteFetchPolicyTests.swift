import Foundation
import Testing

@testable import DirnexCore

/// The table that decides whether a remote fetch just happens (PLAN.md §M21 Slice 10).
///
/// These assertions are about the *shape* of the policy and not about the numbers in it — the
/// numbers are expected to move, and a test that pinned each one to a literal would be a second
/// copy of the table rather than a check on it. What must not move is the ordering, the boundary
/// behaviour, the unknown-size row, and the split between a refusal that asks and one that does not.
@Suite("Remote fetch policy")
struct RemoteFetchPolicyTests {
    /// What a refusal looks like for `purpose` — the one thing `isAutomatic` decides. Written out
    /// here rather than read from the code under test: borrowing `isAutomatic` would prove the two
    /// agree, not that either is right.
    private func expectedRefusal(for purpose: RemoteFetchPurpose) -> RemoteFetchDecision {
        purpose == .cursorPreview ? .decline : .confirm
    }

    @Test("a small file fetches without asking, for every gesture")
    func smallFileFetches() {
        for purpose in RemoteFetchPurpose.allCases {
            #expect(RemoteFetchPolicy.decision(forByteSize: 4096, purpose: purpose) == .fetch)
        }
    }

    @Test("an empty file fetches rather than being treated as unknown")
    func emptyFileFetches() {
        for purpose in RemoteFetchPurpose.allCases {
            #expect(RemoteFetchPolicy.decision(forByteSize: 0, purpose: purpose) == .fetch)
        }
    }

    @Test("a huge file is refused, for every gesture")
    func hugeFileIsRefused() {
        for purpose in RemoteFetchPurpose.allCases {
            let size = Int64(8) * 1024 * 1024 * 1024
            #expect(
                RemoteFetchPolicy.decision(forByteSize: size, purpose: purpose)
                    == expectedRefusal(for: purpose)
            )
        }
    }

    /// The threshold is inclusive, so a file of exactly the stated size is on the quiet side of it.
    /// Worth pinning because the off-by-one is invisible: both readings look correct, and only the
    /// file that sits exactly on the number can tell them apart.
    @Test("the threshold itself fetches, and one byte past it is refused")
    func boundaryIsInclusive() {
        for purpose in RemoteFetchPurpose.allCases {
            let threshold = RemoteFetchPolicy.threshold(for: purpose)
            #expect(RemoteFetchPolicy.decision(forByteSize: threshold, purpose: purpose) == .fetch)
            #expect(
                RemoteFetchPolicy.decision(forByteSize: threshold + 1, purpose: purpose)
                    == expectedRefusal(for: purpose)
            )
        }
    }

    /// Not knowing how much is about to be pulled is exactly when to ask — the row that is not a
    /// number at all, and the one a call-site constant could never have expressed.
    @Test("an unknown size is refused")
    func unknownSizeIsRefused() {
        for purpose in RemoteFetchPurpose.allCases {
            #expect(
                RemoteFetchPolicy.decision(forByteSize: nil, purpose: purpose)
                    == expectedRefusal(for: purpose)
            )
        }
    }

    /// A negative size can only come from a field that was not understood, which is the unknown case
    /// wearing a number. Clamping it to zero would fetch silently on exactly the reading nobody
    /// should trust.
    @Test("a negative size is the unknown case, not a small one")
    func negativeSizeIsRefused() {
        for purpose in RemoteFetchPurpose.allCases {
            #expect(
                RemoteFetchPolicy.decision(forByteSize: -1, purpose: purpose)
                    == expectedRefusal(for: purpose)
            )
        }
    }

    /// The whole reason ``RemoteFetchDecision/decline`` exists: an automatic fetch has nobody
    /// standing at a keystroke, so a size it will not spend must leave the caller's placeholder up
    /// rather than raise a dialog on an arrow key. Asserted in both directions in one test, since
    /// the pair is the claim — an explicit gesture over the same threshold must still ask.
    @Test("an automatic fetch declines where an explicit one confirms")
    func automaticDeclinesWhereExplicitConfirms() {
        let overPreviewThreshold = RemoteFetchPolicy.threshold(for: .preview) + 1

        #expect(
            RemoteFetchPolicy.decision(forByteSize: overPreviewThreshold, purpose: .cursorPreview)
                == .decline
        )
        #expect(
            RemoteFetchPolicy.decision(forByteSize: overPreviewThreshold, purpose: .preview)
                == .confirm
        )
        #expect(RemoteFetchPolicy.decision(forByteSize: nil, purpose: .cursorPreview) == .decline)
        #expect(RemoteFetchPolicy.decision(forByteSize: nil, purpose: .preview) == .confirm)
    }

    /// Exactly one gesture is automatic. Pinned because `isAutomatic` is what turns every refusal
    /// above into a silent one, so a second case answering `true` by accident would make a
    /// key-pressed gesture stop asking — a fetch the user is waiting for that quietly never starts.
    @Test("only the cursor-following preview is automatic")
    func onlyTheCursorPreviewIsAutomatic() {
        let automatic = RemoteFetchPurpose.allCases.filter(\.isAutomatic)

        #expect(automatic == [.cursorPreview])
    }

    /// Preview is the least committed gesture and the most expensive to get wrong, so it must be
    /// the first to ask. This is the one relationship between rows worth asserting: the numbers may
    /// move, and preview being at or below the others is the policy. The automatic row rides with
    /// it — it is the same act, and a fetch nobody asked for must never be the one that spends most.
    @Test("preview asks no later than opening or editing, and the automatic row no later than it")
    func previewIsTheLowestThreshold() {
        let preview = RemoteFetchPolicy.threshold(for: .preview)

        #expect(RemoteFetchPolicy.threshold(for: .cursorPreview) <= preview)
        #expect(preview <= RemoteFetchPolicy.threshold(for: .open))
        #expect(preview <= RemoteFetchPolicy.threshold(for: .edit))
    }

    /// Every threshold has to be a size a fetch can actually sit under; a zero or negative row would
    /// make its gesture confirm on every file, which reads as the feature being broken rather than
    /// as a bad number.
    @Test("every gesture has a usable threshold")
    func everyThresholdIsPositive() {
        for purpose in RemoteFetchPurpose.allCases {
            #expect(RemoteFetchPolicy.threshold(for: purpose) > 0)
        }
    }
}
