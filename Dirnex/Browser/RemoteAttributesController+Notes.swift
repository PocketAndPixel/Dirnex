import AppKit
import DirnexCore

/// The panel's closing notes and its footer (PLAN.md §M24 Slice 7).
///
/// The notes are what make *absence* readable. A row that simply stops after "Where:" looks like a
/// panel that failed to load; the same row with a sentence saying the server reported no
/// permissions is a panel stating a fact about the server. Every one of them is derived from what
/// the entry actually carries rather than from a list of backend names, so a backend added later
/// is described correctly without anybody remembering to extend a switch.
extension RemoteAttributesController {
    func makeNotes() -> [NSView] {
        var notes: [NSView] = []
        if let absence = absenceNote() { notes.append(AttributeRow.note(absence)) }
        if entry.path.backend.isFTP, entry.hasModificationDate {
            notes.append(AttributeRow.note(String(
                localized: """
                FTP reports a modification time with no time zone, and with no year for a recent \
                file — on the server’s own clock. Treat it as approximate.
                """,
                comment: "Info panel note: an FTP LIST timestamp is not exact."
            )))
        }
        if entry.kind == .symlink {
            notes.append(AttributeRow.note(String(
                localized: """
                This is a symbolic link, so everything shown here describes the link itself — not \
                the item it points to.
                """,
                comment: "Info panel note explaining that a symlink's own attributes are shown."
            )))
        }
        notes.append(AttributeRow.note(String(
            localized: """
            A listing from a server or an archive carries no access-control list, no extended \
            attributes, and no created or last-opened date, so those are not shown at all. Nothing \
            on this panel can be changed.
            """,
            comment: "Info panel note: what a non-local listing cannot report, and that it is read-only."
        )))
        return [AttributeRow.separator()] + notes
    }

    /// Why the mode, owner and group rows are missing — stated only when they are.
    ///
    /// Three exhaustive strings rather than a joined list of field names: a sentence assembled from
    /// fragments cannot be reordered by a translator, and this one has to read naturally in fourteen
    /// languages. The two absences are asked separately because nothing makes them travel together
    /// by construction — they happen to today, and a backend reporting one without the other would
    /// otherwise get a sentence that is half wrong.
    private func absenceNote() -> String? {
        switch (entry.permissions == nil, entry.ownerName == nil) {
        case (true, true):
            return String(
                localized: """
                This listing reports no permissions, owner or group. An object store has none to \
                report, and an IIS-style FTP listing prints no such columns — so nothing is missing \
                from the item itself.
                """,
                comment: "Info panel note when a listing carries no mode, owner or group at all."
            )
        case (true, false):
            return String(
                localized: "This listing reports no permissions for the item.",
                comment: "Info panel note when a listing carries an owner but no mode."
            )
        case (false, true):
            return String(
                localized: "This listing reports no owner or group for the item.",
                comment: "Info panel note when a listing carries a mode but no owner."
            )
        case (false, false):
            return nil
        }
    }

    /// Done alone. There is deliberately no Cancel: nothing here is editable, so there is nothing to
    /// discard, and a second button would imply otherwise.
    func makeFooter() -> NSView {
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let done = NSButton(
            title: String(localized: "Done", comment: "Button that closes a results sheet."),
            target: self,
            action: #selector(closeFromFooter(_:))
        )
        done.bezelStyle = .rounded
        done.keyEquivalent = "\r"

        let footer = NSStackView(views: [spacer, done])
        footer.orientation = .horizontal
        footer.spacing = 10
        footer.widthAnchor.constraint(
            equalToConstant: AttributesControllerLayout.contentWidth
        ).isActive = true
        return footer
    }

    @objc private func closeFromFooter(_ sender: Any?) { dismiss(sender) }
}
