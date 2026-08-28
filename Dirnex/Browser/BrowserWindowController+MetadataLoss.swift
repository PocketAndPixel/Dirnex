import AppKit
import DirnexCore

/// Saying what a finished copy could not carry (PLAN.md §M25 Slice 5b).
///
/// Slice 2 made the loss *knowable* — a plan that cannot carry a mode says so, and a step the server
/// refuses is counted rather than swallowed — and deliberately left choosing its surface here. This
/// is that choice: a **transient status line under the pane**, never a dialog.
///
/// **The routine case is what rules a dialog out, and it is not rare.** A duplicate inside one SFTP
/// account takes the server-side `cp` route, which carries no timestamp at all (measured in Slice 3:
/// `sftp`'s batch language has no verb that sets one), so *every* same-account duplicate drops the
/// modification time. An alert there would fire on an operation that worked exactly as designed, and
/// a user who dismisses the same alert twice stops reading the third. The status line is where this
/// app already says what a gesture did, and it interrupts nothing.
///
/// **What it must not do is go unsaid**, which is the other half: the whole milestone exists to stop
/// a copy reporting success it did not have. The line is the difference between "the speed is bought
/// with a report" and "the speed is bought with silence" — the sentence PLAN.md §M25 Slice 3 uses to
/// justify taking the fast path in the first place.
extension BrowserWindowController {
    /// Report on the pane the copy landed in, falling back to the focused one.
    ///
    /// Preferring the destination is what makes the sentence make sense — the affected files are the
    /// ones on screen there — and `isShowing` rather than a path comparison because a tree draws
    /// several directories at once, so a job's destination can be a row a pane merely *draws* rather
    /// than the pane's own path (the shape §M25's write-back fix already needed). The fallback
    /// matters more than it looks: a long transfer routinely finishes after the user has navigated
    /// away, and a report nobody is shown is the failure this exists to prevent.
    ///
    /// The destination comes from the report's own `outcomes` rather than from the operation,
    /// because `JobSnapshot` does not carry the operation and widening it for one caller would be a
    /// core change to answer a question the report can already answer: `landedAt` is where an item
    /// actually went, so its parent is the directory that actually received them.
    func presentMetadataLoss(_ loss: RemoteMetadataLoss, of report: OperationReport) {
        let pane = Self.landingDirectory(of: report).flatMap { destination in
            [leftPanel, rightPanel].first { $0.isShowing(destination) }
        } ?? focusedPanel
        pane.showTransientStatus(Self.metadataLossSentence(for: loss))
    }

    /// Where this job's items actually went, or `nil` when none of them landed anywhere.
    ///
    /// `static` so the derivation is assertable without a window — and worth extracting rather than
    /// inlining because it is the half that can be silently wrong: a report whose every outcome was
    /// skipped (the conflict policy declined them all) has landing paths of `nil` throughout, and a
    /// reader taking `outcomes.first` unconditionally would answer for an item that never moved.
    nonisolated static func landingDirectory(of report: OperationReport) -> VFSPath? {
        report.outcomes.lazy.compactMap { $0.landedAt?.parent }.first
    }

    /// What the line says.
    ///
    /// `nonisolated static` and window-free so every branch is assertable without presenting a pane
    /// — and the annotation is a claim rather than a convenience: this reads no window state at all — the split
    /// `AlertKeyCatcher` and `AttributesRoute` already needed, for the reason a test that hosts a
    /// live pane destabilizes its neighbours (docs/NOTES.md ▸ Testing).
    ///
    /// **Two families, not four aspects.** The core distinguishes `mode` from `specialModeBits` and
    /// `modificationTime` from `accessTime` because the *carry* has to — `-p` drops exactly the
    /// special bits, and only `-p` carries an access time — and none of that is a distinction a user
    /// can act on. What they can act on is "the permissions are not what they were" and "the dates
    /// are not what they were", so the sentence says that and nothing finer.
    ///
    /// Whole sentences per branch rather than a spliced list of field names, which is the house rule
    /// (docs/NOTES.md ▸ Localization): a sentence assembled from fragments cannot be reordered by a
    /// translator, and this one has to read naturally in fourteen languages.
    nonisolated static func metadataLossSentence(for loss: RemoteMetadataLoss) -> String {
        let permissions = loss.aspects.contains(.mode) || loss.aspects.contains(.specialModeBits)
        let dates = loss.aspects.contains(.modificationTime) || loss.aspects.contains(.accessTime)
        let count = loss.itemCount
        switch (permissions, dates) {
        case (true, true):
            return String(
                localized: "Copied — permissions and dates weren’t kept on \(count) items",
                comment: """
                Status line after a copy that could not carry either. %lld is how many items lost \
                something. Plural.
                """
            )
        case (true, false):
            return String(
                localized: "Copied — permissions weren’t kept on \(count) items",
                comment: """
                Status line after a copy whose destination would not take the permissions. %lld is \
                how many items lost them. Plural.
                """
            )
        case (false, true):
            return String(
                localized: "Copied — modification times weren’t kept on \(count) items",
                comment: """
                Status line after a copy that could not carry the dates — every same-account SFTP \
                duplicate does, since the server-side copy carries no timestamp. %lld is how many \
                items lost them. Plural.
                """
            )
        case (false, false):
            // Unreachable: `RemoteMetadataLoss` is never built with an empty aspect set (its own
            // doc says a loss with nothing in it is not a loss, and `RemoteMetadataTally.loss`
            // answers `nil` for one). Stated rather than forced, since a switch still has to compile
            // — and stated as something true, in case a later aspect lands in neither family.
            return String(
                localized: "Copied — some details weren’t kept on \(count) items",
                comment: """
                Status line after a copy that lost something the two named families don't cover. \
                %lld is how many items. Plural.
                """
            )
        }
    }
}
