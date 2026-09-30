import AppKit
import DirnexCore

/// **Download Now**, **Remove Download** and **Show in Finder** (docs/NOTES.md ▸ Google Drive (and
/// every other `CloudStorage` provider), "Download Now and Remove Download on any provider").
///
/// Finder's menu over a cloud file is mostly the provider's own — Copy Dropbox link, View on Box.com,
/// Version History — and Dirnex can offer none of that: those actions are declared in each provider's
/// File Provider extension, gated on metadata only `fileproviderd` can read, and run through a private
/// API. What *is* public is the pair every provider shares, which is what Download Now and Remove
/// Download are; and Show in Finder puts the provider's own menu one right-click away for the rest.
///
/// The pane owns the AppKit half only. Which rows qualify, what each action does with a folder and
/// what a refusal means are `DirnexCore.CloudLocalCopy`; this supplies the facts the pane already
/// holds, runs the two system calls off the main thread, and reports.
extension PanelViewController {
    /// How many refusals an alert names before it counts the rest.
    private static let listedRefusalLimit = 6

    // MARK: - What the selection is

    /// The selection as the cloud commands see it: every target on this disk that is a cloud item.
    ///
    /// `recursiveTargets`, so a folder marked together with something inside it is walked once.
    func cloudLocalCopyTargets() -> [CloudLocalCopyTarget] {
        let standingInCloud = isStandingInCloudDirectory
        return recursiveTargets().compactMap { entry in
            CloudLocalCopyTarget(
                entry: entry,
                isKnownCloudItem: standingInCloud || syncSnapshot?.status(for: entry.path) != nil
            )
        }
    }

    var canDownloadNow: Bool {
        CloudLocalCopyAction.download.applies(toAnyOf: cloudLocalCopyTargets())
    }

    var canRemoveDownload: Bool {
        CloudLocalCopyAction.removeDownload.applies(toAnyOf: cloudLocalCopyTargets())
    }

    /// Whether the right-click menu carries the cloud pair at all — a different question from the two
    /// above, answered for any cloud item whether or not either action applies to it.
    var offersCloudLocalCopy: Bool {
        !cloudLocalCopyTargets().isEmpty
    }

    /// Whether anything selected is a file or folder on this disk for Finder to show.
    var canShowInFinder: Bool {
        !handoffTargets().isEmpty
    }

    func validateCloudLocalCopyItem(_ menuItem: NSMenuItem) -> Bool? {
        switch menuItem.action {
        case #selector(downloadNow(_:)): canDownloadNow
        case #selector(removeDownload(_:)): canRemoveDownload
        case #selector(showInFinder(_:)): canShowInFinder
        default: nil
        }
    }

    // MARK: - Where the pane is standing

    /// Whether the directory this pane stands in was read, off the main thread, as a cloud directory.
    ///
    /// The one fact the path rule cannot supply: iCloud's Desktop and Documents folders are cloud
    /// directories that live outside `~/Library`. Never read here — a menu validator must not wait on
    /// `fileproviderd`, which inside a provider domain is a round trip and while a domain is wedged is
    /// unbounded (docs/NOTES.md).
    var isStandingInCloudDirectory: Bool {
        guard let reading = tabs[activeTabIndex].cloudDirectoryReading, reading.path == panel.path else {
            return false
        }
        return reading.isCloud == true
    }

    /// Read whether the pane's directory is a cloud directory, unless it already has been.
    ///
    /// Called from `updateSyncStatus`, which runs on every navigation, tab switch and live refresh —
    /// ahead of its badge-visibility gate, so switching the badges off does not quietly switch Remove
    /// Download off in `~/Documents` with them.
    func noteCloudDirectory() {
        let tab = tabs[activeTabIndex]
        let path = panel.path
        guard path.backend == .local, tab.cloudDirectoryReading?.path != path else { return }
        tab.cloudDirectoryReading = (path: path, isCloud: nil)
        Task {
            let isCloud = await BlockingWork.run { CloudSyncStorage.isCloudDirectory(path) }
            guard tab.cloudDirectoryReading?.path == path else { return }
            tab.cloudDirectoryReading = (path: path, isCloud: isCloud)
        }
    }

    // MARK: - Commands

    /// File ▸ Download Now — ask the provider for every placeholder in the selection, folders walked.
    @objc func downloadNow(_ sender: Any?) {
        runCloudLocalCopy(.download)
    }

    /// File ▸ Remove Download — let the provider drop the selection's local bytes.
    @objc func removeDownload(_ sender: Any?) {
        runCloudLocalCopy(.removeDownload)
    }

    /// File ▸ Show in Finder — the selection, selected in a Finder window.
    @objc func showInFinder(_ sender: Any?) {
        let urls = handoffTargets()
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    /// Run `action` over the selection off the main thread, then refresh and report.
    ///
    /// Reachable from the palette too, which dispatches without asking a validator — so a selection
    /// the action has nothing to do for says so on the status line rather than doing nothing.
    ///
    /// No confirmation for either. Removing a download loses nothing (the provider refuses anything it
    /// has not uploaded — measured), and Finder asks for neither.
    private func runCloudLocalCopy(_ action: CloudLocalCopyAction) {
        let targets = cloudLocalCopyTargets()
        guard action.applies(toAnyOf: targets) else {
            showTransientStatus(
                Self.idleCloudLocalCopyStatus(for: action, hasCloudItems: !targets.isEmpty)
            )
            return
        }
        let backend = backend
        Task {
            let report = await BlockingWork.run {
                CloudLocalCopyRunner.run(
                    action,
                    on: targets,
                    using: backend,
                    perform: PanelViewController.performCloudLocalCopy
                )
            }
            // An eviction is done by the time the call returns, and a requested download is picked up
            // by the sync scan's own follow-ups — both want the rows re-read now rather than whenever
            // the directory watcher next fires.
            refreshCurrentDirectory()
            reportCloudLocalCopy(report)
        }
    }

    /// The two public calls. Blocking, and each a round trip to `fileproviderd`.
    nonisolated private static func performCloudLocalCopy(
        _ action: CloudLocalCopyAction,
        on path: VFSPath
    ) throws {
        switch action {
        case .download: try FileManager.default.startDownloadingUbiquitousItem(at: path.localURL)
        case .removeDownload: try FileManager.default.evictUbiquitousItem(at: path.localURL)
        }
    }

    private func reportCloudLocalCopy(_ report: CloudLocalCopyReport) {
        if let status = Self.cloudLocalCopyStatus(for: report) {
            showTransientStatus(status)
        }
        guard !report.failures.isEmpty else { return }
        presentOperationFailure(
            message: Self.cloudLocalCopyFailureTitle(for: report),
            detail: Self.cloudLocalCopyFailureDetail(for: report)
        )
    }

    // MARK: - Wording

    /// What the status line says after a run, or `nil` when the refusal alert says it all.
    ///
    /// A count and never a name: the status line truncates its tail in silence, and an interpolated
    /// name is unbounded (docs/NOTES.md ▸ Localization).
    static func cloudLocalCopyStatus(for report: CloudLocalCopyReport) -> String? {
        guard report.accepted > 0 else {
            guard report.failures.isEmpty else { return nil }
            return idleCloudLocalCopyStatus(
                for: report.action,
                hasCloudItems: report.notCloudItems == 0
            )
        }
        switch report.action {
        case .download:
            return String(
                localized: "Downloading \(report.accepted) items",
                comment: "Status line after Download Now; %lld is how many files the provider was asked for."
            )
        case .removeDownload:
            return String(
                localized: "Removed \(report.accepted) downloads",
                comment: "Status line after Remove Download; %lld is how many items no longer use space here."
            )
        }
    }

    /// What the status line says when there was nothing to do.
    static func idleCloudLocalCopyStatus(for action: CloudLocalCopyAction, hasCloudItems: Bool) -> String {
        guard hasCloudItems else { return nothingInTheCloud }
        switch action {
        case .download:
            return String(
                localized: "Everything selected is already downloaded",
                comment: "Status line when Download Now finds nothing to download."
            )
        case .removeDownload:
            return String(
                localized: "Nothing selected is downloaded",
                comment: "Status line when Remove Download finds nothing on this Mac to remove."
            )
        }
    }

    private static var nothingInTheCloud: String {
        String(
            localized: "Nothing selected is stored in the cloud",
            comment: "Status line when Download Now or Remove Download finds no cloud item in the selection."
        )
    }

    static func cloudLocalCopyFailureTitle(for report: CloudLocalCopyReport) -> String {
        let failures = report.failures
        if failures.count == 1, let only = failures.first {
            let name = only.path.lastComponent
            switch report.action {
            case .download:
                return String(
                    localized: "Couldn’t download “\(name)”",
                    comment: "Cloud download failure title; %@ is the file name."
                )
            case .removeDownload:
                return String(
                    localized: "Couldn’t remove the download of “\(name)”",
                    comment: "Remove Download failure title; %@ is the item name."
                )
            }
        }
        switch report.action {
        case .download:
            return String(
                localized: "Couldn’t download \(failures.count) items",
                comment: "Download Now failure title; %lld is how many items the provider refused."
            )
        case .removeDownload:
            return String(
                localized: "Couldn’t remove \(failures.count) downloads",
                comment: "Remove Download failure title; %lld is how many items the provider refused."
            )
        }
    }

    /// The reason for one refusal, or a list naming each for several.
    static func cloudLocalCopyFailureDetail(for report: CloudLocalCopyReport) -> String {
        let failures = report.failures
        if failures.count == 1, let only = failures.first {
            return sentence(for: only.refusal)
        }
        var lines = failures.prefix(listedRefusalLimit).map { failure in
            let name = failure.path.lastComponent
            let reason = sentence(for: failure.refusal)
            return String(
                localized: "“\(name)”: \(reason)",
                comment: "Multi-selection failure detail; %1$@ is an item name, %2$@ the reason."
            )
        }
        let rest = failures.count - lines.count
        if rest > 0 {
            lines.append(String(
                localized: "…and \(rest) more",
                comment: "Last line of a cloud refusal list that was cut short; %lld is how many are not listed."
            ))
        }
        return lines.joined(separator: "\n")
    }

    static func sentence(for refusal: CloudLocalCopyRefusal) -> String {
        switch refusal {
        case .inUse:
            String(
                localized: "It’s open in an app. Close it there and try again.",
                comment: "Why a cloud provider refused Remove Download: the file is open in an app."
            )
        case .notYetUploaded:
            String(
                localized: "It hasn’t finished uploading, or it’s set to stay on this Mac.",
                comment: "Why a cloud provider refused Remove Download: not uploaded yet, or pinned to this Mac."
            )
        case .excludedFromSync:
            String(
                localized: "It’s excluded from syncing, so this Mac holds the only copy.",
                comment: "Why a cloud provider refused Remove Download: the item is excluded from sync."
            )
        case .folderUnreadable:
            String(
                localized: "Its contents couldn’t be listed.",
                comment: "Why Download Now skipped a folder: the folder could not be read."
            )
        case .notACloudItem:
            // Counted by the runner rather than reported, so it never reaches a list; spelled out
            // only so the switch is total.
            nothingInTheCloud
        case let .other(message):
            message
        }
    }
}
