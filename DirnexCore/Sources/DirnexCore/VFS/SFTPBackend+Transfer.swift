import Foundation

/// How an SFTP copy actually moves its bytes: whether a download is split, whether either direction
/// resumes, whether the bytes need to move at all, and where the metadata carry attaches to each.
///
/// Split from `SFTPBackend.swift` when it reached SwiftLint's `type_body_length` — by concept rather
/// than by shaving lines, which is the house rule. There, what the backend *is* and the verbs it
/// answers; here, the one verb with three directions and a choice to make in each.
extension SFTPBackend {
    /// Uploads at or below this size skip resume detection: re-sending a small file is cheaper than
    /// the extra remote `stat` round trip that finding a resumable partial would cost. (Downloads
    /// need no threshold — they gate resume on the local partial's size, which is free to read.)
    static let resumeUploadThreshold: Int64 = 1 << 20 // 1 MiB

    /// Download to `localPath` — in several ranges at once when that is worth doing, in one stream
    /// when it is not.
    ///
    /// The fork has four conditions and each excludes a case the segmented path cannot serve. A
    /// **partial already on disk** takes the resuming route untouched, because segments are fetched
    /// into files of their own and have nothing to continue from; no **size hint** means no plan,
    /// since asking for one would cost a whole extra connection; a file under SFTP's threshold is
    /// not worth four key exchanges; and a connection that has already shown it **has no exec
    /// channel** is not asked again — which for an `sftp`-only account is the difference between one
    /// wasted attempt and one per file.
    ///
    /// **The retry after a refused run reports nothing**, and that is the one subtlety worth
    /// stating: whatever pieces landed have already been handed to `progress`. Reporting them again
    /// would count one file twice in a job total that only adds. The tail in ``copyFile`` still tops
    /// the count up to whatever the stream actually moved.
    func downloadFile(
        _ request: SFTPDownloadRequest,
        carrying carry: RemoteMetadataPlan,
        progress: (Int64) -> Void,
        isCancelled: () -> Bool
    ) throws -> Int64 {
        let existingLocal = localFileSize(request.localPath)
        if existingLocal == 0,
           let hint = request.expectedSize,
           SegmentedDownloadPlan.isWorthwhile(totalSize: hint, limits: .sftp),
           !segmentation.isRefused,
           let plan = SegmentedDownloadPlan(totalSize: hint, limits: .sftp) {
            if let moved = try downloadInSegments(
                request,
                plan: plan,
                progress: progress,
                isCancelled: isCancelled
            ) {
                // A segmented download is assembled from exec channels, which have no `-p` to carry
                // anything — so the whole carry falls to the local follow-up, which can do all of
                // it. That is why the download plan is built against the *local* destination's
                // capabilities rather than the wire's.
                finishLocally(carry, at: request.localPath, preserveWasHonoured: false)
                return moved
            }
            return try downloadWholeFile(
                request,
                resuming: nil,
                carrying: carry,
                progress: { _ in },
                isCancelled: isCancelled
            )
        }
        // Only when a local partial exists is a remote size worth fetching; `>` short-circuits so a
        // fresh download (the norm) never pays for the `stat`.
        let resumable = existingLocal > 0 && remoteFileSize(request.source) > existingLocal
        return try downloadWholeFile(
            request,
            resuming: resumable ? existingLocal : nil,
            carrying: carry,
            progress: progress,
            isCancelled: isCancelled
        )
    }

    /// Finish a download's carry on this machine, and record what it cost.
    ///
    /// `preserveWasHonoured` says whether `get -p` already carried the nine mode bits and the times;
    /// when it did, the only steps left are the ones it cannot express, and when it did not — a
    /// segmented download — everything the plan holds is applied here instead.
    func finishLocally(
        _ carry: RemoteMetadataPlan,
        at localPath: String,
        preserveWasHonoured: Bool
    ) {
        let steps = preserveWasHonoured
            ? carry.followUp
            : carry.steps.filter { $0 != .preserveDuringTransfer }
        var dropped = carry.dropped
        let refusals = LocalMetadataWriter.apply(steps, to: localPath)
        if !refusals.isEmpty { dropped.formUnion(carry.attemptedAspects) }
        if !preserveWasHonoured, carry.usesPreserveFlag {
            // Nothing carried the times unless the hint held one and the follow-up applied it.
            dropped.formUnion(carry.aspectsOnlyPreserveCarries)
        }
        metadata.record(dropped: dropped)
    }

    /// One `sftp` `get`, the whole file, resuming from a local partial when the caller asks it to.
    ///
    /// `sftp` leaves the *whole* file on disk and reports its size, so the transferred delta is the
    /// caller's to derive — which is why `existingLocal` travels with the decision rather than being
    /// read again here, where the file has since grown.
    func downloadWholeFile(
        _ request: SFTPDownloadRequest,
        resuming existingLocal: Int64?,
        carrying carry: RemoteMetadataPlan,
        progress: (Int64) -> Void,
        isCancelled: () -> Bool
    ) throws -> Int64 {
        // Only the flag rides the wire here: the follow-up steps act on the *local* destination, so
        // sending them as batch lines would aim them at the server's copy of the file.
        let wire = RemoteMetadataPlan(
            steps: carry.usesPreserveFlag ? [.preserveDuringTransfer] : [],
            dropped: []
        )
        let outcome = try mapErrors(request.source) {
            try transport.download(
                request.remotePath,
                to: request.localPath,
                options: RemoteTransferOptions(resume: existingLocal != nil, carry: wire),
                progress: progress,
                isCancelled: isCancelled
            )
        }
        finishLocally(carry, at: request.localPath, preserveWasHonoured: outcome.refusals.isEmpty)
        // `sftp get` leaves the *whole* file on disk and reports its size, so a resumed transfer's
        // delta is the caller's to derive — which is why the pre-existing length travels with the
        // decision rather than being read again here, where the file has since grown.
        guard let existingLocal else { return outcome.bytes }
        return max(0, outcome.bytes - existingLocal)
    }

    /// Duplicate one file **inside this account**, with the server moving the bytes and nothing
    /// crossing this machine (PLAN.md §M25 Slice 3).
    ///
    /// Measured 2026-08-28 against a real `sshd`: 64 MiB in **0.09 s** for the whole session —
    /// connect, authentication and all — against **0.5 s** for the same file staged down and back up
    /// over *loopback*, where the relay is flattered by there being no network. Over a real link the
    /// comparison is not a ratio: one route sends the file twice and the other sends none of it.
    ///
    /// **What it cannot carry is the modification time**, and saying so is the point rather than a
    /// caveat. `cp` stamps the copy with *now* — measured, an mtime of 2018 came back as the moment
    /// of the copy — and `sftp`'s batch language has no verb that sets a time, so the plan built
    /// here counts it dropped and ``RemoteMetadataSupport`` accumulates it. The relay this replaces
    /// carried it exactly (`get -p`/`put -p`), so the trade is real and deliberate: it is bought
    /// with a report rather than with silence, which is what separates this milestone's answer from
    /// the failure it exists to prevent.
    ///
    /// The mode is carried in full. `cp` brings the low nine bits and drops the three special ones,
    /// so the corrective `chmod` rides the same batch — and unlike a transfer it is sent for an
    /// *ordinary* mode too, because an occupied destination is overwritten in place and keeps its
    /// own mode (both measured; ``SFTPBatchCommand/copy(_:to:)``).
    ///
    /// A refusal is read here rather than reported: only ``SFTPTransportError/copyExtensionUnavailable``
    /// is a fact about the account, so it latches and the copy becomes the `.unsupported` this
    /// method has always thrown — which is what sends the router back to ``RelayCopy`` with the old
    /// behaviour standing. Everything else (a missing source, an unwritable destination) is that
    /// operation's own failure and is mapped like any other.
    func copyWithinAccount(
        from source: VFSPath,
        to destination: VFSPath,
        hint: CopySourceHint,
        isCancelled: () -> Bool
    ) throws -> Int64 {
        guard !serverSideCopy.isRefused else { throw VFSError.unsupported(.remoteToRemoteCopy) }
        let carry = hint.metadata.map { metadata.planWithoutTransferFlag(for: $0) }
            ?? .carryingNothing
        // The destination names the failure: this is a write, and the source was listed a moment ago
        // by the caller that holds its entry. `cp` does distinguish the two on the wire
        // (`stat remote:` against `remote open(`) and the shared classifier does not, so one of them
        // has to be chosen rather than derived.
        let refusals = try mapErrors(destination) {
            do {
                return try transport.copyRemoteFile(
                    source.path,
                    to: destination.path,
                    carrying: carry,
                    isCancelled: isCancelled
                )
            } catch SFTPTransportError.copyExtensionUnavailable {
                serverSideCopy.recordUnsupported()
                throw VFSError.unsupported(.remoteToRemoteCopy)
            }
        }
        record(RemoteTransferOutcome(bytes: 0, refusals: refusals), against: carry)
        // Nothing moved through here, so there is no delta to have counted — and the queue's
        // denominator is the file's size, so a copy that reported nothing would leave the bar short
        // by exactly one file. The hint is what the caller's own listing already read; without one
        // the landed file is asked, which costs the round trip this route otherwise saves and is
        // paid only by a caller that had nothing to hand down.
        return hint.expectedSize ?? remoteFileSize(destination)
    }

    /// Upload `localPath` to `remote` — in several parts at once when that is worth doing and this
    /// account can join them, in one stream when it is not. Returns the bytes actually transferred
    /// (the whole file, or just the remainder on resume).
    ///
    /// The fork has four conditions and each excludes a case the segmented path cannot serve, in the
    /// order that keeps the cheap questions in front of the dear ones. A **partial already on the
    /// server** takes the resuming route untouched, because parts are sent under names of their own
    /// and have nothing to continue from — and it costs nothing to ask, since the remote size was
    /// already being read for exactly that decision. A file under
    /// ``SegmentedUploadLimits/threshold`` is not worth four key exchanges, a slice on this disk and
    /// a second copy on the server's. A connection that has already shown it **cannot join parts** is
    /// not asked again. And only then is the account itself asked, once, whether it has an exec
    /// channel at all — which has to happen *before* a byte is sent, or an `sftp`-only account would
    /// carry the whole file across the network and then fail (``SegmentedUploadSupport``).
    ///
    /// **The retry after a refused run reports nothing**, exactly as the download's does: whatever
    /// parts landed have already been handed to `progress`, and reporting them again would count one
    /// file twice in a job total that only adds. The tail in ``copyFile`` still tops the count up to
    /// whatever the stream actually moved.
    func uploadFile(
        fromLocal localPath: String,
        remote destination: VFSPath,
        source sourceMetadata: RemoteSourceMetadata,
        progress: (Int64) -> Void,
        isCancelled: () -> Bool
    ) throws -> Int64 {
        let sourceSize = localFileSize(localPath)
        // The remote size costs a round trip, so only look when resuming could pay off (a big file).
        let existingRemote = sourceSize > Self.resumeUploadThreshold ? remoteFileSize(destination) : 0
        let resume = existingRemote > 0 && existingRemote < sourceSize

        if !resume,
           SegmentedUploadPlan.isWorthwhile(totalSize: sourceSize, limits: segmentedUploadLimits),
           !segmentedUpload.isRefused,
           let plan = SegmentedUploadPlan(totalSize: sourceSize, limits: segmentedUploadLimits),
           canAssembleOnServer(isCancelled: isCancelled) {
            let split = SFTPUploadRequest(
                localPath: localPath,
                destination: destination,
                carry: segmentedUploadPlan(for: sourceMetadata)
            )
            if let moved = try uploadInSegments(
                split,
                plan: plan,
                progress: progress,
                isCancelled: isCancelled
            ) {
                return moved
            }
            return try uploadWholeFile(
                SFTPUploadRequest(
                    localPath: localPath,
                    destination: destination,
                    carry: uploadPlan(for: sourceMetadata)
                ),
                resuming: nil,
                progress: { _ in },
                isCancelled: isCancelled
            )
        }

        return try uploadWholeFile(
            SFTPUploadRequest(
                localPath: localPath,
                destination: destination,
                carry: uploadPlan(for: sourceMetadata)
            ),
            resuming: resume ? existingRemote : nil,
            progress: progress,
            isCancelled: isCancelled
        )
    }

    /// One `sftp` `put`, the whole file, resuming from a remote partial when the caller asks it to.
    ///
    /// `sftp` leaves the *whole* file on the server and reports its size, so the transferred delta
    /// is the caller's to derive — which is why the pre-existing length travels with the decision
    /// rather than being read again here.
    private func uploadWholeFile(
        _ request: SFTPUploadRequest,
        resuming existingRemote: Int64?,
        progress: (Int64) -> Void,
        isCancelled: () -> Bool
    ) throws -> Int64 {
        let outcome = try mapErrors(request.destination) {
            try transport.upload(
                request.localPath,
                to: request.destination.path,
                options: RemoteTransferOptions(
                    resume: existingRemote != nil,
                    carry: request.carry
                ),
                progress: progress,
                isCancelled: isCancelled
            )
        }
        record(outcome, against: request.carry)
        guard let existingRemote else { return outcome.bytes }
        return max(0, outcome.bytes - existingRemote)
    }
}

/// What one SFTP upload is about: which local file, where it lands, and what it is carrying.
///
/// The mirror of ``SFTPDownloadRequest`` and bundled for the same reason — every step needs the same
/// three and none of them varies between steps, so spelling them out pushes each signature past the
/// parameter-count ceiling the moment a progress hook is added.
struct SFTPUploadRequest {
    let localPath: String
    let destination: VFSPath
    /// What this route may carry, which differs between the two: a single stream rides `put -p`,
    /// where a split one is assembled by `cat` and has no transfer verb to ride at all.
    let carry: RemoteMetadataPlan
}
