import Foundation
import Testing

@testable import DirnexCore

/// The ceiling a preview learns from a Download the user already agreed to (2026-09-12), and the
/// one place `RemoteFetchPolicy` reads it.
///
/// The expected values are written out as byte counts rather than derived from
/// ``RemotePreviewAllowance/headroomFactor``: borrowing the constant would prove the code agrees with
/// itself, where the claim worth pinning is what the reported folder needs.
@Suite("Remote preview allowance")
struct RemotePreviewAllowanceTests {
    /// Two buckets on one account — two connections, since each is its own backend.
    private static let bucketA = VFSBackendID.s3(Self.location(bucket: "photos"))
    private static let bucketB = VFSBackendID.s3(Self.location(bucket: "archive"))

    private static func location(bucket: String) -> S3Location {
        S3Location(
            host: "s3.eu-north-1.amazonaws.com",
            port: 443,
            bucket: bucket,
            region: "eu-north-1",
            accessKeyID: "AKIAPROBEKEYEXAMPLE",
            addressing: .virtualHost,
            usesTLS: true
        )
    }

    private static let megabyte: Int64 = 1_000_000
    /// The Settings limit a fresh install has.
    private static let limit = RemoteFetchPolicy.defaultPreviewLimit

    // MARK: - Learning

    @Test("nothing agreed yet allows nothing beyond the Settings limit")
    func startsEmpty() {
        let allowance = RemotePreviewAllowance()
        #expect(allowance.isEmpty)
        #expect(allowance.ceiling(for: Self.bucketA) == 0)
        let decision = RemoteFetchPolicy.decision(
            forByteSize: 23 * Self.megabyte,
            purpose: .cursorPreview,
            previewLimit: Self.limit,
            sessionAllowance: allowance.ceiling(for: Self.bucketA)
        )
        #expect(decision == .decline)
    }

    /// The reported folder, pinned as itself: after one Download on the 23.1 MB CR2, the rest of the
    /// RAW files arrive on their own — and a file past twice that still waits for a click.
    @Test("one agreement covers the reported folder of RAW files")
    func reportedFolderNeedsOneClick() {
        var allowance = RemotePreviewAllowance()
        allowance.recordAgreement(toFetch: 23_100_000, on: Self.bucketA, previewLimit: Self.limit)
        #expect(allowance.ceiling(for: Self.bucketA) == 46_200_000)

        for size: Int64 in [22_900_000, 28_500_000, 36_100_000] {
            let decision = RemoteFetchPolicy.decision(
                forByteSize: size,
                purpose: .cursorPreview,
                previewLimit: Self.limit,
                sessionAllowance: allowance.ceiling(for: Self.bucketA)
            )
            #expect(decision == .fetch, "\(size) bytes should arrive on its own")
        }
        // Still an automatic gesture: over the ceiling it declines, never asks.
        let past = RemoteFetchPolicy.decision(
            forByteSize: 46_200_001,
            purpose: .cursorPreview,
            previewLimit: Self.limit,
            sessionAllowance: allowance.ceiling(for: Self.bucketA)
        )
        #expect(past == .decline)
    }

    /// The narrowness control on learning: an explicit preview of a file the limit already covered
    /// agreed to nothing new, and must not double the limit behind the user's back.
    @Test("an agreement the Settings limit already covered raises nothing")
    func agreementWithinTheLimitIsIgnored() {
        var allowance = RemotePreviewAllowance()
        allowance.recordAgreement(
            toFetch: 9 * Self.megabyte,
            on: Self.bucketA,
            previewLimit: Self.limit
        )
        allowance.recordAgreement(toFetch: Self.limit, on: Self.bucketA, previewLimit: Self.limit)
        #expect(allowance.isEmpty)
    }

    @Test("a limit of zero ignores every agreement and every allowance")
    func zeroLimitIsRespected() {
        var allowance = RemotePreviewAllowance()
        allowance.recordAgreement(toFetch: 50 * Self.megabyte, on: Self.bucketA, previewLimit: 0)
        #expect(allowance.isEmpty)
        // And a ceiling learned before the limit went to zero cannot reopen it either.
        for purpose: RemoteFetchPurpose in [.cursorPreview, .preview] {
            let threshold = RemoteFetchPolicy.threshold(
                for: purpose, previewLimit: 0, sessionAllowance: 500 * Self.megabyte
            )
            #expect(threshold == 0)
        }
    }

    @Test("the largest agreement wins, and a smaller later one lowers nothing")
    func largestAgreementWins() {
        var allowance = RemotePreviewAllowance()
        allowance.recordAgreement(
            toFetch: 30 * Self.megabyte,
            on: Self.bucketA,
            previewLimit: Self.limit
        )
        allowance.recordAgreement(
            toFetch: 20 * Self.megabyte,
            on: Self.bucketA,
            previewLimit: Self.limit
        )
        #expect(allowance.ceiling(for: Self.bucketA) == 60 * Self.megabyte)
        allowance.recordAgreement(
            toFetch: 40 * Self.megabyte,
            on: Self.bucketA,
            previewLimit: Self.limit
        )
        #expect(allowance.ceiling(for: Self.bucketA) == 80 * Self.megabyte)
    }

    @Test("an unknown size agrees to nothing")
    func unknownSizeAgreesToNothing() {
        var allowance = RemotePreviewAllowance()
        allowance.recordAgreement(toFetch: -1, on: Self.bucketA, previewLimit: Self.limit)
        #expect(allowance.isEmpty)
    }

    @Test("an absurd size saturates rather than wrapping to no allowance")
    func hugeSizeSaturates() {
        var allowance = RemotePreviewAllowance()
        allowance.recordAgreement(
            toFetch: Int64.max / 2 + 1,
            on: Self.bucketA,
            previewLimit: Self.limit
        )
        #expect(allowance.ceiling(for: Self.bucketA) == Int64.max)
    }

    @Test("connections do not share an allowance")
    func connectionsAreSeparate() {
        var allowance = RemotePreviewAllowance()
        allowance.recordAgreement(
            toFetch: 23 * Self.megabyte,
            on: Self.bucketA,
            previewLimit: Self.limit
        )
        #expect(allowance.ceiling(for: Self.bucketA) == 46 * Self.megabyte)
        #expect(allowance.ceiling(for: Self.bucketB) == 0)
    }

    // MARK: - Withdrawing

    @Test("stopping a file only the allowance admitted withdraws it on that connection only")
    func stopWithdrawsTheConnection() {
        var allowance = RemotePreviewAllowance()
        allowance.recordAgreement(
            toFetch: 23 * Self.megabyte,
            on: Self.bucketA,
            previewLimit: Self.limit
        )
        allowance.recordAgreement(
            toFetch: 23 * Self.megabyte,
            on: Self.bucketB,
            previewLimit: Self.limit
        )

        allowance.recordStop(
            ofByteSize: 28 * Self.megabyte,
            on: Self.bucketA,
            previewLimit: Self.limit
        )

        #expect(allowance.ceiling(for: Self.bucketA) == 0)
        #expect(allowance.ceiling(for: Self.bucketB) == 46 * Self.megabyte)
    }

    /// The narrowness control on withdrawing: a Stop on a file the Settings limit would have fetched
    /// anyway is not a statement about the allowance.
    @Test("stopping a file the Settings limit covers keeps the allowance")
    func stopWithinTheLimitKeepsIt() {
        var allowance = RemotePreviewAllowance()
        allowance.recordAgreement(
            toFetch: 23 * Self.megabyte,
            on: Self.bucketA,
            previewLimit: Self.limit
        )
        allowance.recordStop(
            ofByteSize: 5 * Self.megabyte,
            on: Self.bucketA,
            previewLimit: Self.limit
        )
        #expect(allowance.ceiling(for: Self.bucketA) == 46 * Self.megabyte)
    }

    @Test("forgetting everything clears every connection")
    func removeAllClearsEverything() {
        var allowance = RemotePreviewAllowance()
        allowance.recordAgreement(
            toFetch: 23 * Self.megabyte,
            on: Self.bucketA,
            previewLimit: Self.limit
        )
        allowance.recordAgreement(
            toFetch: 23 * Self.megabyte,
            on: Self.bucketB,
            previewLimit: Self.limit
        )
        allowance.removeAll()
        #expect(allowance.isEmpty)
    }

    // MARK: - Where the policy reads it

    /// The rule that keeps one click on a large photograph from reaching ⌥F5, checksums or ⏎: every
    /// row but the two preview rows is expressed against the Settings limit and must not move.
    @Test("only the two preview rows read the allowance")
    func onlyPreviewRowsReadTheAllowance() {
        let huge: Int64 = 4_000_000_000_000
        for limit: Int64 in [Self.limit, 300 * Self.megabyte] {
            for purpose in RemoteFetchPurpose.allCases {
                let without = RemoteFetchPolicy.threshold(for: purpose, previewLimit: limit)
                let with = RemoteFetchPolicy.threshold(
                    for: purpose, previewLimit: limit, sessionAllowance: huge
                )
                switch purpose {
                case .cursorPreview, .preview:
                    #expect(with == huge, "\(purpose) should reach the allowance")
                default:
                    #expect(with == without, "\(purpose) must ignore the allowance")
                }
            }
        }
    }

    /// And an allowance below the Settings limit never lowers it: it can only widen.
    @Test("an allowance below the Settings limit changes nothing")
    func smallAllowanceNeverLowersTheLimit() {
        for purpose: RemoteFetchPurpose in [.cursorPreview, .preview] {
            let threshold = RemoteFetchPolicy.threshold(
                for: purpose, previewLimit: 300 * Self.megabyte,
                sessionAllowance: 20 * Self.megabyte
            )
            #expect(threshold == 300 * Self.megabyte)
        }
    }
}
