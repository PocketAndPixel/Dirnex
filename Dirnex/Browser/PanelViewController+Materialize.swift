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
/// **A cloud placeholder is left exactly where it is**, which is a decision rather than an omission.
/// Its bytes are the file provider's to fetch, when whoever we hand the path to reads it, and that
/// is what Finder does with the same row — so they are neither ours to move nor ours to confirm
/// (see ``DirnexCore/MaterializationPlan/excluding(_:)``). The gestures whose *engine* refuses to
/// read through one — ⌥F3 and a checksum run — materialize it themselves first, as they already do.
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
    func materialize(
        _ entries: [FileEntry],
        for purpose: RemoteFetchPurpose,
        failureMessage: @escaping () -> String,
        then proceed: @escaping @MainActor ([URL]) -> Void
    ) {
        guard !entries.isEmpty else { return }
        let plan = materializationPlan(for: entries).excluding(.cloudPlaceholder)
        guard !plan.needsNothing else {
            // The ordinary marked set of local files: no dialog, no job, no branch anybody has to
            // remember. Synchronous, so a gesture over local rows behaves exactly as it did before
            // this funnel existed.
            deliver(entries, failureMessage: failureMessage, then: proceed)
            return
        }
        switch RemoteFetchPolicy.decision(
            for: plan,
            purpose: purpose,
            previewLimit: AppPreferences.shared.quickViewFetchLimit
        ) {
        case .fetch:
            run(plan, over: entries, failureMessage: failureMessage, then: proceed)
        case .confirm:
            confirm(plan) { [weak self] in
                self?.run(plan, over: entries, failureMessage: failureMessage, then: proceed)
            }
        case .decline:
            // Unreachable, and named rather than defaulted for the reason `RemoteFetchPrompt` names
            // it: only `.cursorPreview` declines, it is the one purpose with nobody standing at a
            // key to answer, and it never arrives as a set. A future automatic gesture routed here
            // fails at the compiler instead of silently inheriting a confirmation.
            break
        }
    }

    /// Extract first, then download — so every question this gesture has to ask is asked before the
    /// slow part starts. An encrypted archive raises a passphrase prompt; a transfer raises nothing
    /// once it is running.
    private func run(
        _ plan: MaterializationPlan,
        over entries: [FileEntry],
        failureMessage: @escaping () -> String,
        then proceed: @escaping @MainActor ([URL]) -> Void
    ) {
        extractMembers(plan.archiveExtractions) { [weak self] in
            guard let self else { return }
            guard !plan.remoteFetches.isEmpty else {
                deliver(entries, failureMessage: failureMessage, then: proceed)
                return
            }
            host?.materializeRemoteFiles(plan.remoteFetches) { [weak self] report in
                guard let self else { return }
                // A stopped transfer is the user's own answer, already on screen in the queue bar:
                // nothing to report and nothing to proceed with.
                guard !report.wasCancelled else { return }
                // The runner carries on past a failed row and names it, leaving the decision here —
                // and the decision is made by what is *resolvable*, not by the failure count. A row
                // that failed while an earlier copy of it is still current costs the user nothing,
                // and refusing there would report a problem over a set that is all present. What
                // the failure is for is the **sentence**: the server's own reason beats "some of
                // these couldn't be prepared" whenever there is one.
                deliver(
                    entries,
                    failure: report.failures.first?.error,
                    failureMessage: failureMessage,
                    then: proceed
                )
            }
        } onFailure: { [weak self] error in
            guard let self else { return }
            presentOperationFailure(message: failureMessage(), detail: describe(error))
        }
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
    private func deliver(
        _ entries: [FileEntry],
        failure: (any Error)? = nil,
        failureMessage: @escaping () -> String,
        then proceed: @escaping @MainActor ([URL]) -> Void
    ) {
        let urls = entries.compactMap { materializedURL(for: $0) }
        guard urls.count == entries.count else {
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
    private func extractMembers(
        _ entries: [FileEntry],
        onSuccess: @escaping @MainActor () -> Void,
        onFailure: @escaping @MainActor (any Error) -> Void
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
        onFailure: @escaping @MainActor (any Error) -> Void
    ) {
        guard let archivePath = remaining.first, let cache = host?.archivePreviewCache else {
            onSuccess()
            return
        }
        let wanted = members[archivePath] ?? []
        withArchivePassphrase(forArchiveAt: archivePath) { passphrase in
            for member in wanted {
                _ = try await cache.extractedURL(for: member, passphrase: passphrase)
            }
        } onSuccess: { [weak self] in
            self?.extractNextArchive(
                Array(remaining.dropFirst()),
                members: members,
                onSuccess: onSuccess,
                onFailure: onFailure
            )
        } onFailure: { onFailure($0) }
    }

    // MARK: - Naming what it will cost

    /// Name the totals and let the user decide.
    ///
    /// The title carries the **count** and the body the **size**, and the second sentence about
    /// separate downloads appears only when the request rule is what refused — which is the whole
    /// reason that rule exists. Ten thousand objects of 500 bytes weigh 5 MB and take about 83
    /// minutes (docs/NOTES.md ▸ curl for S3), so a dialog that named only the size would look
    /// absurd on exactly the set it was raised to protect.
    private func confirm(_ plan: MaterializationPlan, then proceed: @escaping @MainActor () -> Void) {
        let alert = NSAlert()
        alert.messageText = materializationTitle(for: plan)
        alert.informativeText = materializationDetail(for: plan)
        alert.addButton(withTitle: String(
            localized: "Download",
            comment: "Button that starts downloading a remote file."
        ))
        alert.addButton(withTitle: String(localized: "Cancel", comment: "Dismiss button."))
        // `NSAlert` binds Escape by matching the byte string "Cancel", which a translated title is
        // not — so the response says which button ⎋ means (docs/NOTES.md ▸ Localization).
        alert.enableEscapeToCancel(safe: .alertSecondButtonReturn)
        // Captured strongly, exactly as `RemoteFetchPrompt.confirm` is and for the same measured
        // reason: `beginSheetModal` returns at once and the alert retains the *closure*, so a weak
        // capture would leave Download doing nothing at all (reported by a user 2026-08-19).
        let apply: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .alertFirstButtonReturn else { return }
            proceed()
        }
        if let window = view.window {
            alert.beginSheetModal(for: window, completionHandler: apply)
        } else {
            apply(alert.runModal())
        }
    }

    /// "Download 12 files from the server?" — or the archive wording when nothing is coming over a
    /// network, since a set of members costs an extraction and no round trip at all.
    ///
    /// A **mixed** set takes the server wording: that is where the time goes, and naming the
    /// cheaper half would be the reassuring lie rather than the useful one.
    private func materializationTitle(for plan: MaterializationPlan) -> String {
        let count = plan.pending.count
        let name = plan.pending.first?.entry.name ?? ""
        if plan.requestCount > 0 {
            return count == 1
                ? String(
                    localized: "Download “\(name)” from the server?",
                    comment: "Title of the confirmation before fetching a large remote file; %@ is the name."
                )
                : String(
                    localized: "Download \(count) files from the server?",
                    comment: """
                    Title of the confirmation before fetching a marked set from a server; %lld is \
                    the count.
                    """
                )
        }
        return count == 1
            ? String(
                localized: "Extract “\(name)” from the archive?",
                comment: """
                Title of the confirmation before extracting a large archive member; %@ is the name.
                """
            )
            : String(
                localized: "Extract \(count) files from the archive?",
                comment: """
                Title of the confirmation before extracting a marked set from an archive; %lld is \
                the count.
                """
            )
    }

    private func materializationDetail(for plan: MaterializationPlan) -> String {
        guard plan.totalsAreExact else {
            return String(
                localized: """
                Dirnex can’t tell in advance how much this will fetch, and it has to fetch all of \
                it before it can go on.
                """,
                comment: "Body of the set confirmation when the totals can only be a floor."
            )
        }
        let size = FileFormatting.byteString(plan.byteTotal)
        guard plan.requestCount > RemoteFetchPolicy.unaskedRequestLimit else {
            return String(
                localized: "They come to \(size) in total, and Dirnex has to fetch them all first.",
                comment: """
                Body of the set confirmation; %@ is a formatted size such as “84 MB”.
                """
            )
        }
        return String(
            localized: """
            They come to \(size) in total. Each one is a separate download, so this can take far \
            longer than that size suggests.
            """,
            comment: """
            Body of the set confirmation when the number of requests is what makes it worth \
            asking; %@ is a formatted size such as “5 MB”.
            """
        )
    }
}
