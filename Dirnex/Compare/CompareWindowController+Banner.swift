import AppKit
import DirnexCore

/// A side no copy may go to, and why, which the banner names (PLAN.md §M33).
struct ReadOnlySide: Equatable {
    enum Reason: Equatable {
        /// The file, written back unedited, would not be the same bytes.
        case notExact
        /// The file is a copy of one Dirnex has no way to write: a member of an archive inside
        /// another archive, or a file on a backend that takes no uploads.
        case nowhereToSave
    }

    let side: ComparisonPaneText.Side
    let reason: Reason
}

/// The line under the toolbar that says what differs where the rows cannot show it (PLAN.md §M31
/// Slice 3): an encoding, a byte-order mark, and whatever the options overlooked.
///
/// When no line differs, this is the window's whole answer, and it opens with that fact, so two
/// files ⌥F3 called different never show as two columns with nothing marked and nothing said. It
/// ends by naming a side no copy can go to (PLAN.md §M33), whose arrow is otherwise just grayed.
extension CompareWindowController {
    static func bannerText(
        for comparison: TextComparison,
        readOnly: [ReadOnlySide] = []
    ) -> String? {
        var sentences: [String] = []
        if comparison.diff.isIdentical {
            sentences.append(String(
                localized: "No line differs.",
                comment: "Compare window: the first sentence when every line matches."
            ))
        }
        for difference in comparison.unshownDifferences {
            sentences.append(sentence(for: difference))
        }
        if !comparison.unshownDifferences.contains(.lineEndings),
           comparison.rows.contains(where: { $0.kind != .same && $0.lineEndingsDiffer }) {
            sentences.append(String(
                localized: "Lines marked ↵ end differently.",
                comment: "Compare window: some changed lines also differ in their line ending, marked ↵ in the gutter."
            ))
        }
        for readOnlySide in readOnly {
            sentences.append(readOnlySentence(for: readOnlySide))
        }
        return sentences.isEmpty ? nil : sentences.joined(separator: " ")
    }

    /// Why no copy can go to a side: its file, written back unedited, would not be the same bytes
    /// (`ComparedDocument.isSavable`), or there is nowhere to write it.
    private static func readOnlySentence(for readOnly: ReadOnlySide) -> String {
        switch (readOnly.side, readOnly.reason) {
        case (.left, .notExact):
            String(
                localized: "The left file is read-only here: Dirnex can’t write it back exactly as it was read.",
                comment: "Compare window: changes can't be copied into the left file, and why."
            )
        case (.right, .notExact):
            String(
                localized: "The right file is read-only here: Dirnex can’t write it back exactly as it was read.",
                comment: "Compare window: changes can't be copied into the right file, and why."
            )
        case (.left, .nowhereToSave):
            String(
                localized: "The left file is read-only here: Dirnex can’t save it back where it came from.",
                comment: """
                Compare window: changes can't be copied into the left file, because it is a copy of \
                a file Dirnex cannot write, such as a member of an archive inside another archive.
                """
            )
        case (.right, .nowhereToSave):
            String(
                localized: "The right file is read-only here: Dirnex can’t save it back where it came from.",
                comment: """
                Compare window: changes can't be copied into the right file, because it is a copy \
                of a file Dirnex cannot write, such as a member of an archive inside another archive.
                """
            )
        }
    }

    private static func sentence(for difference: TextComparison.UnshownDifference) -> String {
        switch difference {
        case let .encoding(left, right):
            let leftName = String.localizedName(of: left)
            let rightName = String.localizedName(of: right)
            return String(
                localized: "The left file is \(leftName) and the right file is \(rightName).",
                comment: "Compare window: the two files' text encodings, such as “Unicode (UTF-8)”."
            )
        case let .byteOrderMark(left, _):
            return left
                ? String(
                    localized: "Only the left file starts with a byte-order mark.",
                    comment: "Compare window: a difference in the files' first bytes that no line shows."
                )
                : String(
                    localized: "Only the right file starts with a byte-order mark.",
                    comment: "Compare window: a difference in the files' first bytes that no line shows."
                )
        case .lineEndings:
            return String(
                localized: "Some lines shown as the same end differently.",
                comment: "Compare window: line endings are ignored, and some matching lines differ in them."
            )
        case .whitespace:
            return String(
                localized: "Some lines shown as the same differ in whitespace.",
                comment: "Compare window: whitespace is ignored, and some matching lines differ in it."
            )
        case .letterCase:
            return String(
                localized: "Some lines shown as the same differ in case.",
                comment: "Compare window: case is ignored, and some matching lines differ in it."
            )
        }
    }
}
