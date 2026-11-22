import AppKit

/// The sentences under the Find Files fields: what an account search costs (PLAN.md §M38 Slice 5),
/// and that a folder Spotlight does not index is searched file by file (PLAN.md §M40 Slice 3).
///
/// Split from `SearchController` by concept when the second one took its type body past SwiftLint's
/// ceiling: both are about the search rather than questions in it, and both are drawn alike.
extension SearchController {
    /// The cost sentence, wrapped to the footer's width.
    func makeCostNote(_ text: String) -> NSView {
        let note = NSTextField(wrappingLabelWithString: text)
        styleNote(note)
        return note
    }

    /// The row for ``showUnindexedNote()``, hidden until it is called.
    func configureUnindexedNote() -> NSView {
        styleNote(unindexedNote)
        // Shown already when the pane learned before the view loaded.
        unindexedNote.isHidden = unindexedNote.stringValue.isEmpty
        return unindexedNote
    }

    /// Say that "This Folder" is searched file by file, and that Content then reads plain text only.
    /// The stack leaves a hidden row out of its layout, so the dialog grows to take the sentence.
    func showUnindexedNote() {
        unindexedNote.stringValue = String(
            localized: """
            Spotlight doesn’t index “\(currentFolderName)”, so Dirnex searches it file by file. \
            Content is found in plain-text files only, not inside PDFs or Word documents.
            """,
            comment: """
            Find Files: note under the fields when the folder is not in the Spotlight index; %@ is \
            the folder's name.
            """
        )
        unindexedNote.isHidden = false
    }

    /// Whether the dialog is saying so, for a test.
    var isShowingUnindexedNote: Bool {
        !unindexedNote.isHidden
    }

    /// Secondary text, since a note is about the search rather than a question in it.
    private func styleNote(_ note: NSTextField) {
        note.textColor = .secondaryLabelColor
        note.preferredMaxLayoutWidth = 512
        note.widthAnchor.constraint(equalToConstant: 512).isActive = true
    }
}
