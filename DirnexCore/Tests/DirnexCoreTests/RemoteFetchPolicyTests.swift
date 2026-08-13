import Foundation
import Testing

@testable import DirnexCore

/// The table that decides whether an explicit remote fetch just happens (PLAN.md §M21 Slice 10).
///
/// These assertions are about the *shape* of the policy and not about the numbers in it — the
/// numbers are expected to move, and a test that pinned each one to a literal would be a second
/// copy of the table rather than a check on it. What must not move is the ordering, the boundary
/// behaviour, and the unknown-size row.
@Suite("Remote fetch policy")
struct RemoteFetchPolicyTests {
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

    @Test("a huge file confirms, for every gesture")
    func hugeFileConfirms() {
        for purpose in RemoteFetchPurpose.allCases {
            let size = Int64(8) * 1024 * 1024 * 1024
            #expect(RemoteFetchPolicy.decision(forByteSize: size, purpose: purpose) == .confirm)
        }
    }

    /// The threshold is inclusive, so a file of exactly the stated size is on the quiet side of it.
    /// Worth pinning because the off-by-one is invisible: both readings look correct, and only the
    /// file that sits exactly on the number can tell them apart.
    @Test("the threshold itself fetches, and one byte past it confirms")
    func boundaryIsInclusive() {
        for purpose in RemoteFetchPurpose.allCases {
            let threshold = RemoteFetchPolicy.threshold(for: purpose)
            #expect(RemoteFetchPolicy.decision(forByteSize: threshold, purpose: purpose) == .fetch)
            #expect(
                RemoteFetchPolicy.decision(forByteSize: threshold + 1, purpose: purpose)
                    == .confirm
            )
        }
    }

    /// Not knowing how much is about to be pulled is exactly when to ask — the row that is not a
    /// number at all, and the one a call-site constant could never have expressed.
    @Test("an unknown size confirms")
    func unknownSizeConfirms() {
        for purpose in RemoteFetchPurpose.allCases {
            #expect(RemoteFetchPolicy.decision(forByteSize: nil, purpose: purpose) == .confirm)
        }
    }

    /// A negative size can only come from a field that was not understood, which is the unknown case
    /// wearing a number. Clamping it to zero would fetch silently on exactly the reading nobody
    /// should trust.
    @Test("a negative size is the unknown case, not a small one")
    func negativeSizeConfirms() {
        for purpose in RemoteFetchPurpose.allCases {
            #expect(RemoteFetchPolicy.decision(forByteSize: -1, purpose: purpose) == .confirm)
        }
    }

    /// Preview is the least committed gesture and the most expensive to get wrong, so it must be
    /// the first to ask. This is the one relationship between rows worth asserting: the numbers may
    /// move, and preview being at or below the others is the policy.
    @Test("preview asks no later than opening or editing")
    func previewIsTheLowestThreshold() {
        let preview = RemoteFetchPolicy.threshold(for: .preview)

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
