import AppKit
import DirnexCore

/// The one question `PanelViewController+Materialize` asks before a marked set is fetched: what it
/// will cost, named as a count in the title and a size in the body (PLAN.md §M24 Slice 3).
///
/// Split from that file when it reached SwiftLint's `file_length`. The boundary is the one the file
/// already drew with a `MARK`: everything there is about *getting* the bytes, everything here about
/// *saying* what getting them will take.
extension PanelViewController {
    /// Name the totals and let the user decide.
    ///
    /// The title carries the **count** and the body the **size**, and the second sentence about
    /// separate downloads appears only when the request rule is what refused — which is the whole
    /// reason that rule exists. Ten thousand objects of 500 bytes weigh 5 MB and take about 83
    /// minutes (docs/NOTES.md ▸ curl for S3), so a dialog that named only the size would look
    /// absurd on exactly the set it was raised to protect.
    /// Answers `true` when the user agreed and `false` on every other ending, so a caller with
    /// something on screen can take it back down — see `materialize`'s `onAbandon`.
    func confirm(
        _ plan: MaterializationPlan,
        then decided: @escaping @MainActor (Bool) -> Void
    ) {
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
            decided(response == .alertFirstButtonReturn)
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
