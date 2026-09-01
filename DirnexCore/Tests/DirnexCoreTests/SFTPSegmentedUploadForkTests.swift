import Foundation
import Testing

@testable import DirnexCore

/// What becomes of a segmented SFTP upload's parts, and the fork that decides whether one happens
/// (PLAN.md §4 ▸ *Still open*, "No multipart upload over SFTP or FTP").
///
/// Three of this route's rules have no equivalent on the download side, and each has a test whose
/// failure would otherwise be silent: the exec channel is asked for **before** any bytes are sent
/// (a refusal found afterwards costs the whole upload); the joined size is checked **before** the
/// rename (a short part joins perfectly happily, since `cat` has nothing to compare against); and
/// the destination is created by `cat` rather than by a transfer verb, so `put -p` carries nothing
/// and the loss is reported rather than assumed away.
/// The fork that decides whether an upload is split at all, and what happens when the route does not
/// work (PLAN.md §4 ▸ *Still open*).
///
/// Three of these rules have no equivalent on the download side. The exec channel is asked for
/// **before** any bytes are sent, because a refusal found afterwards would cost the whole upload
/// rather than one download. The joined size is checked **before** the rename, because a short part
/// joins perfectly happily — `cat` has nothing to compare against. And a refusal is latched, so an
/// account confined to the `sftp` subsystem pays for the discovery once rather than once per file.
@Suite("SFTP segmented upload: the fork")
struct SFTPSegmentedUploadForkTests {
    @Test("a file under the threshold takes the single stream, and nothing is asked of the server")
    func belowTheThresholdNothingIsAsked() throws {
        let transport = SegmentedUploadFixture.readyTransport()
        let backend = SegmentedUploadFixture.backend(transport)

        try SegmentedUploadFixture.withFile(Data(repeating: 1, count: 400)) { localPath in
            _ = try backend.uploadFile(
                fromLocal: localPath,
                remote: SegmentedUploadFixture.destination(on: backend),
                source: RemoteSourceMetadata(permissions: nil, modificationTime: nil),
                progress: { _ in },
                isCancelled: { false }
            )
        }
        #expect(transport.partRuns.isEmpty)
        #expect(transport.uploads.count == 1)
        // Not even the exec probe: a small file must cost exactly what it always did.
        #expect(transport.commands.isEmpty)
    }

    /// Sized against the shipped ``SFTPBackend/resumeUploadThreshold`` rather than the tiny limits
    /// the rest of this suite uses: a remote `stat` is only worth a round trip above 1 MiB, so a
    /// 1000-byte fixture could not reach the resume decision at all and would measure the fork's
    /// second condition while claiming to measure its first.
    private static let megabyteLimits = SegmentedUploadLimits(
        threshold: 1 << 20,
        minimumPartSize: 256 * 1024,
        preferredPartSize: 512 * 1024,
        maximumPartsInFlight: 4,
        stagingBudget: 8 << 20,
        maximumParts: 10_000
    )

    @Test("a resumable remote partial takes the resuming route untouched")
    func aPartialResumesRatherThanSplitting() throws {
        let source = 2 << 20
        let partial = 1 << 20
        let transport = SegmentedUploadFixture.readyTransport()
        transport.listings["/srv/disk.img"] =
            "-rw-r--r--    ? u  g \(partial) Jul 14 00:00 /srv/disk.img"
        transport.uploadBytes = Int64(source)
        let backend = SegmentedUploadFixture.backend(
            transport,
            limits: SegmentedUploadFixture.megabyteLimits
        )

        try SegmentedUploadFixture.withFile(Data(repeating: 1, count: source)) { localPath in
            let moved = try backend.uploadFile(
                fromLocal: localPath,
                remote: SegmentedUploadFixture.destination(on: backend),
                source: RemoteSourceMetadata(permissions: nil, modificationTime: nil),
                progress: { _ in },
                isCancelled: { false }
            )
            // Only the remainder, exactly as it was before this route existed — parts are sent under
            // names of their own and have nothing to continue from.
            #expect(moved == Int64(source - partial))
        }
        #expect(transport.partRuns.isEmpty)
        #expect(transport.uploads.map(\.resume) == [true])
    }

    @Test("with no remote partial the same file is split")
    func withoutAPartialTheSameFileSplits() throws {
        // The control that keeps "a partial resumes" from passing because nothing ever splits at
        // this size: same limits, same fixture, no listing for the destination.
        let transport = SegmentedUploadFixture.readyTransport()
        transport.uploadBytes = Int64(2 << 20)
        let backend = SegmentedUploadFixture.backend(
            transport,
            limits: SegmentedUploadFixture.megabyteLimits
        )

        try SegmentedUploadFixture.withFile(Data(repeating: 1, count: 2 << 20)) { localPath in
            _ = try backend.uploadFile(
                fromLocal: localPath,
                remote: SegmentedUploadFixture.destination(on: backend),
                source: RemoteSourceMetadata(permissions: nil, modificationTime: nil),
                progress: { _ in },
                isCancelled: { false }
            )
        }
        #expect(transport.partRuns == [[1, 2, 3, 4]])
        #expect(transport.uploads.isEmpty)
    }

    @Test("an account with no exec channel is asked once and then left alone")
    func theRefusalIsLatched() throws {
        let transport = SegmentedUploadFixture.readyTransport()
        // What an account confined to the sftp subsystem answers: prose, on stdout, exit 1.
        transport.hasNoExecChannel = true
        let backend = SegmentedUploadFixture.backend(transport)

        try SegmentedUploadFixture.withFile(Data(repeating: 1, count: 1000)) { localPath in
            for _ in 0..<3 {
                _ = try backend.uploadFile(
                    fromLocal: localPath,
                    remote: SegmentedUploadFixture.destination(on: backend),
                    source: RemoteSourceMetadata(permissions: nil, modificationTime: nil),
                    progress: { _ in },
                    isCancelled: { false }
                )
            }
        }
        // The whole point of the latch: asked once, not once per file — and nothing was ever sent in
        // parts, so no upload was wasted discovering it.
        #expect(transport.commands.count == 1)
        #expect(transport.partRuns.isEmpty)
        #expect(transport.uploads.count == 3)
        #expect(backend.segmentedUpload.isRefused)
    }

    @Test("a transport that does not send parts at once is not offered the route")
    func aSequentialTransportIsNotSplit() throws {
        let transport = SegmentedUploadFixture.readyTransport()
        // The protocol's own default. A transport on it would send the parts one at a time and still
        // pay for the slices, the connections, the server-side scratch and the join — every cost of
        // the route with none of its benefit, which is worse than the `put` it replaced.
        transport.sendsPartsConcurrently = false
        let backend = SegmentedUploadFixture.backend(transport)

        try SegmentedUploadFixture.withFile(Data(repeating: 1, count: 1000)) { localPath in
            _ = try backend.uploadFile(
                fromLocal: localPath,
                remote: SegmentedUploadFixture.destination(on: backend),
                source: RemoteSourceMetadata(permissions: nil, modificationTime: nil),
                progress: { _ in },
                isCancelled: { false }
            )
        }
        #expect(transport.partRuns.isEmpty)
        #expect(transport.uploads.count == 1)
        // Read before the exec probe, so a transport that cannot serve the route costs no round trip
        // finding out.
        #expect(transport.commands.isEmpty)
    }

    @Test("the exec channel is asked before a byte is sent")
    func theProbeComesFirst() throws {
        let transport = SegmentedUploadFixture.readyTransport()
        let backend = SegmentedUploadFixture.backend(transport)
        var probedBeforeAnyPart = false
        transport.beforeUploadingParts = { _ in
            probedBeforeAnyPart = transport.commands.contains { $0.hasPrefix("/usr/bin/env echo ") }
        }

        try SegmentedUploadFixture.withFile(Data(repeating: 1, count: 1000)) { localPath in
            _ = try backend.uploadFile(
                fromLocal: localPath,
                remote: SegmentedUploadFixture.destination(on: backend),
                source: RemoteSourceMetadata(permissions: nil, modificationTime: nil),
                progress: { _ in },
                isCancelled: { false }
            )
        }
        // The asymmetry with the download: there a refusal costs one download, here it would cost
        // the whole upload, because the parts cross the network before the join is needed.
        #expect(probedBeforeAnyPart)
    }

    // MARK: - The failures

    @Test("a short part is caught by the size, and the destination is never written")
    func aShortJoinNeverReachesTheDestination() throws {
        let transport = SegmentedUploadFixture.readyTransport()
        transport.truncatesParts = true
        let backend = SegmentedUploadFixture.backend(transport)

        try SegmentedUploadFixture.withFile(Data(repeating: 5, count: 1000)) { localPath in
            _ = try backend.uploadFile(
                fromLocal: localPath,
                remote: SegmentedUploadFixture.destination(on: backend),
                source: RemoteSourceMetadata(permissions: nil, modificationTime: nil),
                progress: { _ in },
                isCancelled: { false }
            )
        }
        // `cat` cannot tell a truncated part from a small one, so nothing on the server complains:
        // the reported size is the only evidence, and it is checked before the rename. The
        // single-stream retry is what actually delivers the file.
        #expect(transport.uploads.count == 1)
        #expect(transport.remoteFiles["/srv/disk.img"] == nil)
        #expect(transport.commands.contains { $0.hasPrefix("/usr/bin/env rm -f ") })
    }

    @Test("a part that could not be sent falls back to one stream and leaves nothing behind")
    func aFailedPartFallsBack() throws {
        let transport = SegmentedUploadFixture.readyTransport()
        transport.failsPartNumber = 3
        let backend = SegmentedUploadFixture.backend(transport)

        try SegmentedUploadFixture.withFile(Data(repeating: 5, count: 1000)) { localPath in
            let moved = try backend.uploadFile(
                fromLocal: localPath,
                remote: SegmentedUploadFixture.destination(on: backend),
                source: RemoteSourceMetadata(permissions: nil, modificationTime: nil),
                progress: { _ in },
                isCancelled: { false }
            )
            #expect(moved == 1000)
        }
        #expect(transport.uploads.count == 1)
        #expect(SegmentedUploadFixture.everyPartFileIsGone(transport))
        #expect(transport.remoteFiles.keys.filter { $0.contains(".dirnex-upload-") }.isEmpty)
    }

    @Test("the retry after a refused run reports nothing, so one file is not counted twice")
    func theRetryReportsNothing() throws {
        let transport = SegmentedUploadFixture.readyTransport()
        transport.failsPartNumber = 1
        transport.streamedProgress = [1000]
        let backend = SegmentedUploadFixture.backend(transport)
        var reported: Int64 = 0

        try SegmentedUploadFixture.withFile(Data(repeating: 5, count: 1000)) { localPath in
            _ = try backend.uploadFile(
                fromLocal: localPath,
                remote: SegmentedUploadFixture.destination(on: backend),
                source: RemoteSourceMetadata(permissions: nil, modificationTime: nil),
                progress: { reported += $0 },
                isCancelled: { false }
            )
        }
        // The queue's total only ever adds, so a retry that re-reported what the parts already
        // reported would count this file twice. `copyFile`'s tail is what tops it up.
        #expect(reported == 0)
    }

    @Test("a cancellation travels out rather than being retried, and sweeps the server")
    func cancellationIsNotRetried() throws {
        let transport = SegmentedUploadFixture.readyTransport()
        let backend = SegmentedUploadFixture.backend(transport)
        var sentParts = 0
        transport.beforeUploadingParts = { _ in sentParts += 1 }

        try SegmentedUploadFixture.withFile(Data(repeating: 5, count: 1000)) { localPath in
            #expect(throws: CancellationError.self) {
                _ = try backend.uploadFile(
                    fromLocal: localPath,
                    remote: SegmentedUploadFixture.destination(on: backend),
                    source: RemoteSourceMetadata(permissions: nil, modificationTime: nil),
                    progress: { _ in },
                    isCancelled: { sentParts >= 1 }
                )
            }
        }
        // Retrying what somebody just stopped is the one fallback never wanted.
        #expect(transport.uploads.isEmpty)
        #expect(transport.commands.contains { $0.hasPrefix("/usr/bin/env rm -f ") })
    }

    // MARK: - What the join cannot carry

    @Test("the mode is applied after the join, and the times are reported lost")
    func theCarryIsAppliedAndTheLossReported() throws {
        let transport = SegmentedUploadFixture.readyTransport()
        transport.metadataCapabilities = .sftp
        let backend = SegmentedUploadFixture.backend(transport)
        let stamp = Date(timeIntervalSince1970: 1_500_000_000)

        try SegmentedUploadFixture.withFile(Data(repeating: 5, count: 1000)) { localPath in
            _ = try backend.uploadFile(
                fromLocal: localPath,
                remote: SegmentedUploadFixture.destination(on: backend),
                source: RemoteSourceMetadata(permissions: 0o640, modificationTime: stamp),
                progress: { _ in },
                isCancelled: { false }
            )
        }
        // The destination is created by `cat`, so there is no transfer verb for `-p` to ride on: the
        // mode goes as its own batch and the time has no route over this protocol at all. That is
        // the trade §M25 Slice 3 already shipped for the server-side `cp`, bought the same way.
        #expect(transport.appliedMetadata.map(\.path) == ["/srv/disk.img"])
        #expect(
            transport.appliedMetadata.first?.steps == [.setMode(POSIXPermissions(rawValue: 0o640))]
        )
        #expect(backend.metadataTally(at: SegmentedUploadFixture.destination(on: backend))
            .perAspect[.modificationTime] == 1)
    }

    @Test("a single-stream upload still carries everything it always did")
    func theNarrowness() throws {
        let transport = SegmentedUploadFixture.readyTransport()
        transport.metadataCapabilities = .sftp
        let backend = SegmentedUploadFixture.backend(transport)
        let stamp = Date(timeIntervalSince1970: 1_500_000_000)

        try SegmentedUploadFixture.withFile(Data(repeating: 5, count: 100)) { localPath in
            _ = try backend.uploadFile(
                fromLocal: localPath,
                remote: SegmentedUploadFixture.destination(on: backend),
                source: RemoteSourceMetadata(permissions: 0o640, modificationTime: stamp),
                progress: { _ in },
                isCancelled: { false }
            )
        }
        // The control that keeps "a split upload cannot carry the times" from quietly becoming
        // "an upload cannot carry the times".
        #expect(transport.carriedPlans.first?.steps == [.preserveDuringTransfer])
        #expect(backend.metadataTally(at: SegmentedUploadFixture.destination(on: backend))
            .perAspect[.modificationTime] == nil)
    }
}
