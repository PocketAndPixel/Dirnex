import Foundation

/// Uploading one file over several `sftp` connections at once, and having the server put the parts
/// back together (PLAN.md §4 ▸ *Still open*, "No multipart upload over SFTP or FTP").
///
/// The upload twin of ``SFTPBackend/downloadInSegments(_:plan:progress:isCancelled:)``, and the
/// three ways it is *not* symmetrical are the whole design:
///
/// - **A part cannot be written where it belongs.** `sftp` has no verb that writes at an offset, so
///   the parts go under names of their own beside the destination and are joined by a server-side
///   `cat` over the exec channel (``SSHAssembleCommand``). The join costs a second pass over the
///   bytes on the server — 1.9 GiB/s, measured — and the destination's size again in scratch there
///   until it finishes.
/// - **The route has to be checked before anything is sent, not after.** A download that turns out
///   to be unavailable wastes a download; here the parts cross the network first, so an account
///   with no exec channel would waste the *whole upload* and only then fail. One sentinel echo, once
///   per connection, settles it (``SegmentedUploadSupport``).
/// - **What lands is not what was sent.** The destination is created by `cat`, not by a transfer
///   verb, so `put -p` has nothing to preserve: the mode is applied afterwards through the same
///   ``SFTPTransport/applyMetadata(_:to:)`` a remote Get Info uses, and the times have no route at
///   all over this protocol. That is the trade §M25 Slice 3 already shipped for the server-side
///   `cp`, and it is bought the same way — with a report rather than with silence.
///
/// Measured 2026-09-01 against a real `sshd` behind a 2 MB/s per-connection throttle, 32 MiB:
/// **one stream 16.85 s, four parts 4.32 s**, the joined file byte-identical to the source.
extension SFTPBackend {
    /// Upload `localPath` as `plan`'s parts, at once, and have the server join them into
    /// `destination`.
    ///
    /// Returns the bytes moved, or **`nil`** when the caller must send the file in one stream
    /// instead — which is every failure except a cancellation. A cancellation is the user's decision
    /// and is re-thrown: retrying what somebody just stopped is the one fallback never wanted.
    func uploadInSegments(
        _ request: SFTPUploadRequest,
        plan: SegmentedUploadPlan,
        progress: (Int64) -> Void,
        isCancelled: () -> Bool
    ) throws -> Int64? {
        let localPath = request.localPath
        let destination = request.destination
        let token = UUID().uuidString.prefix(8).lowercased()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("dirnex-sftp-parts-\(token)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            // No scratch space is this machine's problem, not the server's — and it is recoverable
            // by the one-stream route, which needs none.
            return nil
        }
        defer { try? FileManager.default.removeItem(at: directory) }

        let parts = plan.parts(
            stagingIn: directory,
            destination: destination.path,
            token: String(token)
        )
        let staging = Self.stagingPath(for: destination.path, token: String(token))

        do {
            try sendParts(
                parts,
                of: localPath,
                plan: plan,
                progress: progress,
                isCancelled: isCancelled
            )
            guard let landed = try joinOnServer(
                parts,
                staging: staging,
                destination: destination,
                expecting: plan.totalSize,
                isCancelled: isCancelled
            ) else {
                sweep(parts, staging: staging)
                return nil
            }
            applyCarry(request.carry, to: destination)
            return landed
        } catch is CancellationError {
            sweep(parts, staging: staging)
            throw CancellationError()
        } catch {
            // Nothing is under the real name yet — the join writes to a staging name and only a
            // verified size earns the rename — so a failure here costs the parts and nothing else.
            sweep(parts, staging: staging)
            return nil
        }
    }

    /// Whether this connection can be asked to join parts, asking once if nobody has yet.
    ///
    /// The probe is a plain `runCommand`, so a transport that has none (every test double, and any
    /// account confined to the `sftp` subsystem) answers `nil` and the whole route is declined —
    /// which is exactly the state a transport that never implemented this should be in.
    func canAssembleOnServer(isCancelled: () -> Bool) -> Bool {
        if segmentedUpload.hasAsked { return !segmentedUpload.isRefused }
        let token = "dirnex-exec-\(UUID().uuidString.prefix(8).lowercased())"
        let answer = try? transport.runCommand(
            SSHAssembleCommand.probe(token: token),
            isCancelled: isCancelled
        )
        // `try?` flattens the transport's own `String?`, so a throw and a `nil` arrive the same
        // way — which is right here and nowhere else: both mean "could not ask", and the route needs
        // an account that answered, not a reason it did not.
        let available = SSHAssembleCommand.answeredProbe(answer, token: token)
        segmentedUpload.record(execChannel: available)
        return available
    }

    /// Cut and send one batch at a time, deleting each batch's slices before the next is cut.
    ///
    /// That is what bounds the scratch: peak local space is ``SegmentedUploadPlan/stagingPeak``
    /// however large the file is, which is the same accounting ``SegmentAssembly`` makes coming the
    /// other way.
    private func sendParts(
        _ parts: [UploadSegment],
        of localPath: String,
        plan: SegmentedUploadPlan,
        progress: (Int64) -> Void,
        isCancelled: () -> Bool
    ) throws {
        let byNumber = Dictionary(uniqueKeysWithValues: parts.map { ($0.number, $0) })
        for batch in plan.batches {
            if isCancelled() { throw CancellationError() }
            let sending = batch.compactMap { byNumber[$0] }
            for part in sending {
                _ = try S3PartSlice.write(
                    from: localPath,
                    range: part.range,
                    to: part.localPath
                )
            }
            defer {
                for part in sending {
                    try? FileManager.default.removeItem(atPath: part.localPath)
                }
            }
            _ = try transport.uploadParts(sending, progress: progress, isCancelled: isCancelled)
        }
    }

    /// Have the server join the parts, and check the size it reports against the file that was sent.
    ///
    /// `nil` means "this route did not work" — the caller sweeps and falls back. Three things arrive
    /// that way and all three are the same answer to the caller: an account that answers prose
    /// instead of a count (which also latches, since it is a fact about the connection), a join that
    /// wrote fewer bytes than were sent, and a rename that did not take.
    private func joinOnServer(
        _ parts: [UploadSegment],
        staging: String,
        destination: VFSPath,
        expecting total: Int64,
        isCancelled: () -> Bool
    ) throws -> Int64? {
        if isCancelled() { throw CancellationError() }
        let joined = try transport.runCommand(
            SSHAssembleCommand.join(parts, into: staging),
            isCancelled: isCancelled
        )
        guard let landed = SSHAssembleCommand.assembledSize(from: joined) else {
            // The one failure that says something about the *account* rather than about this file:
            // an exec request answered with anything but a number is the refusal arriving late.
            segmentedUpload.record(execChannel: false)
            return nil
        }
        // A short join is the quiet failure this whole route has to defend against — `cat` cannot
        // tell a truncated part from a small one, so nothing on the server would complain. Checked
        // *before* the rename, which is why the destination never exists in a wrong state.
        guard landed == total else { return nil }
        if isCancelled() { throw CancellationError() }
        _ = try transport.runCommand(
            SSHAssembleCommand.commit(parts, from: staging, to: destination.path),
            isCancelled: isCancelled
        )
        return landed
    }

    /// Apply what the join could not carry, and record what nothing could.
    ///
    /// The plan is built **without** the transfer flag, because there is no transfer verb here — the
    /// file is created by `cat`. So the mode goes as its own batch and the times are counted lost,
    /// exactly as they are for a server-side `cp`.
    private func applyCarry(_ carry: RemoteMetadataPlan, to destination: VFSPath) {
        let refusals = (try? transport.applyMetadata(carry.followUp, to: destination.path)) ?? []
        record(RemoteTransferOutcome(bytes: 0, refusals: refusals), against: carry)
    }

    /// Remove whatever this run left on the server. Best effort by construction: the caller is about
    /// to send the file again in one stream, and a leftover part is a hidden file with this run's
    /// token in its name.
    private func sweep(_ parts: [UploadSegment], staging: String) {
        _ = try? transport.runCommand(
            SSHAssembleCommand.discard(parts, staging: staging),
            isCancelled: { false }
        )
    }

    /// Where the parts are joined before the rename — beside the destination, hidden, and carrying
    /// this run's token so two uploads of one file cannot collide.
    static func stagingPath(for destination: String, token: String) -> String {
        guard let slash = destination.lastIndex(of: "/") else {
            return ".dirnex-upload-\(token)-\(destination).joined"
        }
        let directory = String(destination[...slash])
        let leaf = String(destination[destination.index(after: slash)...])
        return "\(directory).dirnex-upload-\(token)-\(leaf).joined"
    }
}
