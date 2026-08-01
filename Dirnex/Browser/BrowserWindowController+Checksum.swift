import AppKit
import DirnexCore

/// Where a finished checksum job's answer reaches the user (PLAN.md §M14 Slice 2).
///
/// It lands on the *window*, not the pane, for the same reason a copy's failure summary does: the
/// job outlives the gesture that started it. The user can change tabs, switch panes or start
/// another operation while a 50 GB SHA-256 runs, and the report must still arrive — and arrive
/// once, over whatever is on screen then.
///
/// The two modes get deliberately different surfaces. A **verification** is the answer the user
/// asked for, so it gets a sheet they have to look at. A **creation** produced a file they can see
/// in the pane, so it gets a status line — unless something was skipped, which is the one case a
/// created manifest can quietly lie by omission and therefore the one case that interrupts.
extension BrowserWindowController {
    /// Present whatever a finished job's report carries. Called from `finalizeCompletedJobs` for
    /// every terminal job; a non-checksum job has `nil` here and falls straight through.
    func presentChecksumOutcome(of report: OperationReport, kind: FileOperation.Kind) {
        guard case let .checksum(job) = kind, let outcome = report.checksum else { return }
        switch outcome {
        case let .verified(verdict):
            presentReport(verdict, manifestName: job.manifest.lastComponent)
        case let .created(summary):
            presentCreation(summary)
        case let .failed(error):
            presentChecksumFailure(error, manifest: job.manifest)
        }
    }

    // MARK: - Verify

    private func presentReport(_ report: ChecksumVerificationReport, manifestName: String) {
        let controller = ChecksumReportController(report: report, manifestName: manifestName)
        focusedPanel.presentAsSheet(controller)
    }

    // MARK: - Create

    /// A written manifest reports itself in the status line — the file is right there in the pane,
    /// and a modal saying "done" over a result the user can already see is noise.
    ///
    /// Unless files were skipped. A manifest that omits a file verifies perfectly ever after while
    /// saying nothing about the file it never looked at, which is exactly the false comfort a
    /// checksum exists to remove — so that case gets an alert naming what was left out.
    private func presentCreation(_ summary: ChecksumCreationSummary) {
        focusedPanel.refreshCurrentDirectory(selecting: summary.manifest)
        guard !summary.isComplete else {
            focusedPanel.showTransientStatus(
                String(
                    localized: """
                    Wrote “\(summary.manifest.lastComponent)” — \(summary.writtenCount) checksums
                    """,
                    comment: """
                    Status after writing a checksum file; %1$@ is its name, %2$lld the count. Plural.
                    """
                )
            )
            return
        }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(
            localized: "\(summary.skipped.count) files weren’t included",
            comment: "Create-checksum warning title; %lld files could not be hashed. Plural."
        )
        let notDownloaded = summary.skipped.count { $0.status == .notDownloaded }
        alert.informativeText = notDownloaded > 0
            ? String(
                localized: """
                “\(summary.manifest.lastComponent)” lists \(summary.writtenCount) files. The rest \
                are stored in the cloud and aren’t downloaded, so Dirnex didn’t read them.
                """,
                comment: """
                Create-checksum warning body when cloud placeholders were skipped; %1$@ is the \
                checksum file's name and %2$lld the number written. Plural.
                """
            )
            : String(
                localized: """
                “\(summary.manifest.lastComponent)” lists \(summary.writtenCount) files. The rest \
                couldn’t be read.
                """,
                comment: """
                Create-checksum warning body; %1$@ is the checksum file's name and %2$lld the \
                number written. Plural.
                """
            )
        alert.addButton(withTitle: String(localized: "OK", comment: "Dismiss button."))
        alert.enableEscapeToCancel()
        present(alert)
    }

    // MARK: - Failure

    /// The job could not start — an unreadable manifest, or one mixing digest widths. The sentence
    /// comes from the catalog rather than the core's English (`LocalizedCatalog.sentence(for:)`):
    /// it reaches the screen through a return value, where a literal would render English under a
    /// translated title at the moment something failed.
    private func presentChecksumFailure(_ error: ChecksumError, manifest: VFSPath) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(
            localized: "Couldn’t verify “\(manifest.lastComponent)”",
            comment: "Checksum failure title; %@ is the checksum file's name."
        )
        alert.informativeText = LocalizedCatalog.sentence(for: error)
        alert.addButton(withTitle: String(localized: "OK", comment: "Dismiss button."))
        alert.enableEscapeToCancel()
        present(alert)
    }

    private func present(_ alert: NSAlert) {
        if let window { alert.beginSheetModal(for: window) } else { alert.runModal() }
    }
}
