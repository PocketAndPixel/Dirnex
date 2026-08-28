import Foundation

/// How an SFTP copy actually moves its bytes: whether a download is split, whether either direction
/// resumes, and where the metadata carry attaches to each.
///
/// Split from `SFTPBackend.swift` when it reached SwiftLint's `type_body_length` — by concept rather
/// than by shaving lines, which is the house rule. There, what the backend *is* and the verbs it
/// answers; here, the one verb with two directions and a choice to make in each.
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

    /// Upload `localPath` to `remote`, resuming from a remote partial when one is a proper prefix.
    /// Returns the bytes actually transferred (the whole file, or just the remainder on resume).
    func uploadFile(
        fromLocal localPath: String,
        remote destination: VFSPath,
        carrying carry: RemoteMetadataPlan,
        progress: (Int64) -> Void,
        isCancelled: () -> Bool
    ) throws -> Int64 {
        let sourceSize = localFileSize(localPath)
        // The remote size costs a round trip, so only look when resuming could pay off (a big file).
        let existingRemote = sourceSize > Self.resumeUploadThreshold ? remoteFileSize(destination) : 0
        let resume = existingRemote > 0 && existingRemote < sourceSize
        let outcome = try mapErrors(destination) {
            try transport.upload(
                localPath,
                to: destination.path,
                options: RemoteTransferOptions(resume: resume, carry: carry),
                progress: progress,
                isCancelled: isCancelled
            )
        }
        record(outcome, against: carry)
        let finalSize = outcome.bytes
        return resume ? max(0, finalSize - existingRemote) : finalSize
    }
}
