import AppKit
import DirnexCore

/// What the merge window says about whitespace (PLAN.md §M37 Slice 5): a conflict whose difference
/// whitespace explains is named in the banner, with the take that keeps both edits where it is
/// offered. The banner also says how many conflicts are still open, so both are drawn here.
extension MergeWindowController {
    /// What whitespace explains in the current conflict, if anything.
    var currentWhitespace: ConflictWhitespace? {
        guard let merge, let currentConflict, merge.whitespace.indices.contains(currentConflict) else { return nil }
        return merge.whitespace[currentConflict]
    }

    /// The line under the toolbar: what whitespace explains in the current conflict, then where the
    /// merge stands.
    func refreshBanner() {
        let text = [
            Self.whitespaceText(currentWhitespace),
            shown.flatMap { Self.bannerText(conflicts: $0.conflictCount, open: $0.openConflictCount) }
        ].compactMap(\.self).joined(separator: " ")
        guard text != banner.stringValue || banner.isHidden != text.isEmpty else { return }
        banner.stringValue = text
        banner.isHidden = text.isEmpty
        window?.contentView?.layoutSubtreeIfNeeded()
    }

    /// What whitespace explains in a conflict, for the banner: which side changed only whitespace,
    /// and whether the take that keeps both edits is offered. `nil` where whitespace explains nothing.
    static func whitespaceText(_ whitespace: ConflictWhitespace?) -> String? {
        guard let whitespace else { return nil }
        let offered = whitespace.combined != nil
        switch whitespace.kind {
        case .yoursOnlyWhitespace where offered:
            return String(
                localized: """
                Yours changed only whitespace in this conflict. Take Theirs with Your Whitespace keeps \
                both edits.
                """,
                comment: """
                Merge window: the current conflict, where your version changed only indentation, \
                spacing or line endings. Take Theirs with Your Whitespace is the button's name.
                """
            )
        case .yoursOnlyWhitespace:
            return String(
                localized: "Yours changed only whitespace in this conflict, on lines theirs changed too.",
                comment: """
                Merge window: the current conflict, where your version changed only indentation, \
                spacing or line endings, on lines the other version also changed, so the two cannot be \
                combined.
                """
            )
        case .theirsOnlyWhitespace where offered:
            return String(
                localized: """
                Theirs changed only whitespace in this conflict. Take Yours with Their Whitespace keeps \
                both edits.
                """,
                comment: """
                Merge window: the current conflict, where the other version changed only indentation, \
                spacing or line endings. Take Yours with Their Whitespace is the button's name.
                """
            )
        case .theirsOnlyWhitespace:
            return String(
                localized: "Theirs changed only whitespace in this conflict, on lines yours changed too.",
                comment: """
                Merge window: the current conflict, where the other version changed only indentation, \
                spacing or line endings, on lines your version also changed, so the two cannot be \
                combined.
                """
            )
        case .sidesDifferOnlyInWhitespace:
            return String(
                localized: "The two sides differ only in whitespace in this conflict.",
                comment: """
                Merge window: the current conflict, where your version and the other one differ only \
                in indentation, spacing or line endings.
                """
            )
        }
    }
}
