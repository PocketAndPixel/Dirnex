import AppKit
import DirnexCore

/// Turning a marked set of rows into real files on this disk, so a gesture that only speaks in
/// paths can run over them (PLAN.md §M24 Slice 3).
///
/// **The gesture materializes; the engine never does.** That is M24's one structural rule
/// (PLAN.md §6). `ByteComparator` refuses to read through an evicted placeholder rather than
/// discovering one mid-sweep, and everything reached from here keeps that posture: `bsdtar`,
/// `ChecksumEngine`, LaunchServices and the share sheet all go on seeing files that are already
/// here, and this is the one place that makes them so.
///
/// **What each source costs is decided once, over the whole set.** `RemoteFetchPolicy` has answered
/// per *file* since M21 Slice 10 because one row under a cursor was the only shape that existed;
/// asking that question per file over a marked set would either interrupt once per file or — far
/// worse — weigh each one alone and start a transfer no single row ever justified. So
/// `MaterializationPlan` states the totals and one confirmation names them.
///
/// **What a cloud placeholder costs depends on who is about to read it**, which is why it is the
/// one source the caller chooses about (`includingPlaceholders`). A *hand-off* leaves it exactly
/// where it is: its bytes are the file provider's to fetch, when the receiving application reads
/// the path, and that is what Finder does with the same row — so they are neither ours to move nor
/// ours to confirm, and counting them would put a *"download this from the server"* dialog in front
/// of a file that is already on this disk. A *compare* or a *checksum* is the other side of it,
/// because `ByteComparator` and `ChecksumEngine` both refuse to read through one rather than
/// discovering it mid-sweep: there the gesture materializes it, in place, through the same
/// `CloudDownloadPrompt` ⏎ and F4 already use — and weighs it, since those bytes really are about
/// to move.
extension PanelViewController {
    // MARK: - What it will take

    /// What stands between `entries` and real paths, as this window sees it.
    ///
    /// The cache seam the plan documents is filled from **both** window caches, because "already
    /// here" has two meanings that a gesture must not be able to tell apart: an object downloaded
    /// for a preview, and a member extracted for one. Marking four rows, previewing one and then
    /// running Open With over all four must cost three transfers, not four.
    func materializationPlan(for entries: [FileEntry]) -> MaterializationPlan {
        MaterializationPlan.plan(for: entries) { [weak host] entry in
            guard let host else { return false }
            if let member = Self.archiveMember(for: entry) {
                return host.archivePreviewCache.cachedURL(for: member) != nil
            }
            return host.remoteFileCache.cachedURL(for: entry) != nil
        }
    }

    /// The on-disk file standing for `entry` right now, or `nil` when its bytes are not here yet.
    ///
    /// A local row answers with its own path, placeholder included — see the type comment.
    func materializedURL(for entry: FileEntry) -> URL? {
        if entry.path.backend == .local { return entry.path.localURL }
        if let member = Self.archiveMember(for: entry) {
            return host?.archivePreviewCache.cachedURL(for: member)
        }
        return host?.remoteFileCache.cachedURL(for: entry)
    }

    /// The map an engine reads this set back through — which file on this disk stands for each row
    /// that is not one (PLAN.md §M24 Slice 4).
    ///
    /// Built from ``materializedURL(for:)`` rather than from a job's report, and it has to be: a row
    /// the plan classified as already `cached` is never asked for, so it produces no
    /// `MaterializedFile` and is nonetheless exactly as readable as the ones that were. A map built
    /// from the report alone would report those as not downloaded.
    ///
    /// Local rows are left out entirely — ``DirnexCore/MaterializedPaths`` answers for them with
    /// their own path, placeholder included, which is what keeps an ordinary local run from needing
    /// a map at all.
    func materializedPaths(for entries: [FileEntry]) -> MaterializedPaths {
        var localPaths: [VFSPath: String] = [:]
        for entry in entries where entry.path.backend != .local {
            guard let url = materializedURL(for: entry) else { continue }
            localPaths[entry.path] = url.path
        }
        return MaterializedPaths(localPaths)
    }

    /// `entry` as an archive member, or `nil` when it does not live in one.
    static func archiveMember(for entry: FileEntry) -> ArchiveMember? {
        guard let archivePath = entry.path.backend.archivePath else { return nil }
        return ArchiveMember(archivePath: archivePath, innerPath: entry.path.path)
    }

    // MARK: - Doing it

    /// Bring `entries` down to real files and hand their URLs to `proceed`, in the order given.
    ///
    /// `proceed` does not run at all if the user declines, stops the transfer, or anything fails —
    /// and a **partial** set is a failure rather than a smaller success: a gesture hands over what
    /// the user marked, and a set with a hole in it is not that. (`MaterializeRunner` deliberately
    /// carries on past a failed row and names it, because the decision is the gesture's; this is
    /// this gesture making it.)
    ///
    /// `failureMessage` is the caller's own wording, evaluated only if something goes wrong — the
    /// same shape `fetchRemoteFile` uses, and for the same reason: "couldn't hand these to another
    /// app" is not "couldn't compare these".
    ///
    /// `includingPlaceholders` says whether an evicted cloud row is this gesture's to fetch — see
    /// the type comment. `false` is the hand-off answer and the default, because it is the one that
    /// costs the user nothing. It changes what is *fetched* and never what is *confirmed*: those
    /// bytes have a surface of their own already.
    ///
    /// `onAbandon` runs on every path that does **not** reach `proceed` — declined, stopped, or
    /// failed — and is for a caller that has put something on screen and has to take it back down.
    /// Most gestures need none of it: a hand-off that does not happen leaves nothing behind, and
    /// this funnel has already said why. The Synchronize sheet does, because it asks *while showing
    /// a comparison*, and a declined download must return it to the one it was showing rather than
    /// leave it saying "Comparing folders…" for the rest of the session (PLAN.md §M25 Slice 5d).
    ///
    /// One exit is deliberately not covered and cannot be: a **stopped placeholder download**.
    /// `CloudDownloadPrompt` reports a Stop to nobody — it simply never calls its continuation — so
    /// there is nothing here to observe. It is unreachable for a caller passing
    /// `includingPlaceholders: false`, where that stage has nothing to do.
    func materialize(
        _ entries: [FileEntry],
        for purpose: RemoteFetchPurpose,
        includingPlaceholders: Bool = false,
        failureMessage: @escaping () -> String,
        onAbandon: (@MainActor () -> Void)? = nil,
        then proceed: @escaping @MainActor ([URL]) -> Void
    ) {
        guard !entries.isEmpty else {
            onAbandon?()
            return
        }
        let whole = materializationPlan(for: entries)
        // **A placeholder is fetched but never weighed**, whichever gesture is fetching it, and the
        // asymmetry is deliberate: `CloudDownloadPrompt` already names the file and its size and
        // carries a Stop, so a confirmation in front of it would be a second thing reporting one
        // transfer — the shape a user reported against Quick View and this project has written down
        // since (docs/NOTES.md ▸ Design lessons). It would also have to lie about where the bytes
        // are coming from: a plan with no `requestCount` says "from the archive", which a file
        // provider's own file is not.
        let weighed = whole.excluding(.cloudPlaceholder)
        let work = includingPlaceholders ? whole : weighed
        guard !work.needsNothing else {
            // The ordinary marked set of local files: no dialog, no job, no branch anybody has to
            // remember. Synchronous, so a gesture over local rows behaves exactly as it did before
            // this funnel existed.
            deliver(
                entries,
                failureMessage: failureMessage,
                onAbandon: onAbandon,
                then: proceed
            )
            return
        }
        switch RemoteFetchPolicy.decision(
            for: weighed,
            purpose: purpose,
            previewLimit: AppPreferences.shared.quickViewFetchLimit
        ) {
        case .fetch:
            run(
                work,
                over: entries,
                failureMessage: failureMessage,
                onAbandon: onAbandon,
                then: proceed
            )
        case .confirm:
            confirm(weighed) { [weak self] accepted in
                guard accepted else {
                    onAbandon?()
                    return
                }
                self?.run(
                    work,
                    over: entries,
                    failureMessage: failureMessage,
                    onAbandon: onAbandon,
                    then: proceed
                )
            }
        case .decline:
            // Unreachable, and named rather than defaulted for the reason `RemoteFetchPrompt` names
            // it: only `.cursorPreview` declines, it is the one purpose with nobody standing at a
            // key to answer, and it never arrives as a set. A future automatic gesture routed here
            // fails at the compiler instead of silently inheriting a confirmation — and it answers
            // `onAbandon` on the way out, since nothing was fetched and nothing will proceed.
            onAbandon?()
        }
    }

    /// Extract, then ask the file provider, then download — so every question this gesture has to
    /// ask is asked before the slow part starts. An encrypted archive raises a passphrase prompt; a
    /// placeholder and a transfer both raise nothing once they are running.
    ///
    /// The three stages are sequential rather than concurrent, which is `CloudDownloadPrompt`'s own
    /// argument one layer out: one surface at a time is what a user can read, and stopping any of
    /// them abandons the whole gesture by construction, because `proceed` simply never runs.
    private func run(
        _ plan: MaterializationPlan,
        over entries: [FileEntry],
        failureMessage: @escaping () -> String,
        onAbandon: (@MainActor () -> Void)?,
        then proceed: @escaping @MainActor ([URL]) -> Void
    ) {
        extractMembers(plan.archiveExtractions) { [weak self] in
            guard let self else { return }
            downloadPlaceholders(plan.cloudMaterializations) { [weak self] in
                guard let self else { return }
                fetchRemotely(
                    plan,
                    over: entries,
                    failureMessage: failureMessage,
                    onAbandon: onAbandon,
                    then: proceed
                )
            }
        } onFailure: { [weak self] error, archivePath in
            guard let self else { return }
            // A refused code page is a question, not a failure, so it replaces the alert rather
            // than following it. `onAbandon` runs either way: the gesture's targets were named
            // from a listing nobody could read, so it is over in both endings and the user
            // presses the key again once the names are readable.
            if !offerNameEncoding(after: error, forArchiveAt: archivePath) {
                presentOperationFailure(message: failureMessage(), detail: describe(error))
            }
            onAbandon?()
        }
    }

    /// Ask the file provider for every evicted row, in place.
    ///
    /// The bytes land at the path the row already names, so there is nothing to record and nothing
    /// to put in a map — which is the whole reason ``DirnexCore/MaterializedPaths`` answers for a
    /// local path with its own. Empty for every gesture that left placeholders alone, where this
    /// costs one call and no `stat` at all.
    private func downloadPlaceholders(
        _ entries: [FileEntry],
        then proceed: @escaping @MainActor () -> Void
    ) {
        guard !entries.isEmpty else {
            proceed()
            return
        }
        CloudDownloadPrompt.materialize(
            entries.map(\.path),
            using: backend,
            over: alertHostWindow,
            then: proceed
        )
    }

    /// The last stage: whatever is still on a server, as one queued job.
    private func fetchRemotely(
        _ plan: MaterializationPlan,
        over entries: [FileEntry],
        failureMessage: @escaping () -> String,
        onAbandon: (@MainActor () -> Void)?,
        then proceed: @escaping @MainActor ([URL]) -> Void
    ) {
        guard !plan.remoteFetches.isEmpty else {
            deliver(
                entries,
                failureMessage: failureMessage,
                onAbandon: onAbandon,
                then: proceed
            )
            return
        }
        host?.materializeRemoteFiles(plan.remoteFetches) { [weak self] report in
            guard let self else { return }
            // A folder ⌥F5 staged is in the report and nowhere else: the cache does not adopt a
            // tree (`RemoteFileCache.adopt`), so this is the one place that knows where it landed.
            let staged = Self.stagedFolders(in: report)
            // A stopped transfer is the user's own answer, already on screen in the queue bar:
            // nothing to report and nothing to proceed with.
            guard !report.wasCancelled else {
                RemoteFileCache.sweepStagedTrees(staged.values)
                onAbandon?()
                return
            }
            // The runner carries on past a failed row and names it, leaving the decision here —
            // and the decision is made by what is *resolvable*, not by the failure count. A row
            // that failed while an earlier copy of it is still current costs the user nothing,
            // and refusing there would report a problem over a set that is all present. What
            // the failure is for is the **sentence**: the server's own reason beats "some of
            // these couldn't be prepared" whenever there is one.
            deliver(
                entries,
                staged: staged,
                failure: report.failures.first?.error,
                failureMessage: failureMessage,
                onAbandon: onAbandon,
                then: proceed
            )
        }
    }

    /// Where each staged folder landed, by the row it stands for.
    static func stagedFolders(in report: OperationReport) -> [VFSPath: URL] {
        var folders: [VFSPath: URL] = [:]
        for file in report.materialized ?? [] where file.isDirectory {
            folders[file.source] = URL(fileURLWithPath: file.localPath)
        }
        return folders
    }

    /// Resolve every row to the file standing for it and hand the lot over — or report that the set
    /// is short, which is the one report site this funnel has.
    ///
    /// **A hand-off hands over what the user marked**, so a short set is a failure rather than a
    /// smaller success: an application given three of the five files somebody selected has been told
    /// something untrue about what they asked for.
    ///
    /// `failure` is whatever went wrong on the way, and it is used for the *wording* only — the
    /// server's own reason where there is one, and the fallback below where the copies simply are
    /// not here (a cache dropped between landing and now, or a row nothing was ever asked to fetch).
    ///
    /// `staged` is the folders this fetch brought down whole, which only ⌥F5 asks for. They are
    /// read from here because the cache never holds one, and until 2026-10-24 that made every
    /// remote folder a missing row: the folder was staged, then reported as not prepared, then left
    /// in the temp root. A set that comes up short sweeps them, since no job will.
    private func deliver(
        _ entries: [FileEntry],
        staged: [VFSPath: URL] = [:],
        failure: (any Error)? = nil,
        failureMessage: @escaping () -> String,
        onAbandon: (@MainActor () -> Void)?,
        then proceed: @escaping @MainActor ([URL]) -> Void
    ) {
        let urls = entries.compactMap { materializedURL(for: $0) ?? staged[$0.path] }
        guard urls.count == entries.count else {
            RemoteFileCache.sweepStagedTrees(staged.values)
            presentOperationFailure(
                message: failureMessage(),
                detail: failure.map(describe) ?? String(
                    localized: """
                    Some of the selected items couldn’t be prepared. Try again — they may have \
                    changed on the server since the list was read.
                    """,
                    comment: """
                    Detail when a materialized set is short of files after the transfer reported \
                    success.
                    """
                )
            )
            onAbandon?()
            return
        }
        proceed(urls)
    }

    // MARK: - Archive members

    /// Extract every member in `entries`, one archive at a time, asking each encrypted archive for
    /// its passphrase once.
    ///
    /// Grouped by archive rather than run per member because the passphrase belongs to the archive:
    /// six members of one encrypted `.zip` is one prompt, and the retry that a typo needs already
    /// lives in `withArchivePassphrase` rather than being written out here.
    ///
    /// `onFailure` carries the **archive that refused** beside the error, which the caller cannot
    /// otherwise recover: a legacy archive's names refusal is answerable — by declaring its code
    /// page — and the chooser has to be told which file it is being asked about. With several
    /// archives in one gesture, only the loop below knows which of them got that far.
    private func extractMembers(
        _ entries: [FileEntry],
        onSuccess: @escaping @MainActor () -> Void,
        onFailure: @escaping @MainActor (any Error, String) -> Void
    ) {
        var order: [String] = []
        var byArchive: [String: [ArchiveMember]] = [:]
        for entry in entries {
            guard let member = Self.archiveMember(for: entry) else { continue }
            if byArchive[member.archivePath] == nil { order.append(member.archivePath) }
            byArchive[member.archivePath, default: []].append(member)
        }
        extractNextArchive(order, members: byArchive, onSuccess: onSuccess, onFailure: onFailure)
    }

    private func extractNextArchive(
        _ remaining: [String],
        members: [String: [ArchiveMember]],
        onSuccess: @escaping @MainActor () -> Void,
        onFailure: @escaping @MainActor (any Error, String) -> Void
    ) {
        guard let archivePath = remaining.first, let cache = host?.archivePreviewCache else {
            onSuccess()
            return
        }
        let wanted = members[archivePath] ?? []
        withArchivePassphrase(forArchiveAt: archivePath) { passphrase in
            for member in wanted {
                _ = try await cache.extractedURL(
                    for: member,
                    passphrase: passphrase,
                    nameEncoding: self.declaredNameEncoding(forArchiveAt: member.archivePath)
                )
            }
        } onSuccess: { [weak self] in
            self?.extractNextArchive(
                Array(remaining.dropFirst()),
                members: members,
                onSuccess: onSuccess,
                onFailure: onFailure
            )
        } onFailure: { onFailure($0, archivePath) }
    }
}
