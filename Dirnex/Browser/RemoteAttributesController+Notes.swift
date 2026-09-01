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
            attributes, and no created or last-opened date, so those are not shown at all.
            """,
            comment: "Info panel note: what a non-local listing cannot report."
        )))
        notes.append(AttributeRow.note(editability.isReadOnly ? readOnlyNote() : undoNote()))
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

    /// Why nothing here can be changed — stated only when that is true of *this* row.
    ///
    /// Three reasons and they are not interchangeable, so the sentence names the one that applies:
    /// an archive member and an object are on a backend with no such verb at all, a row whose
    /// listing reported no mode has nothing to change, and an account that answered "no such
    /// command" has withdrawn the offer for the rest of the connection. A single "read-only" would
    /// leave a user on a perfectly capable SFTP account with no idea why.
    private func readOnlyNote() -> String {
        guard backend.editableMetadata(at: entry.path).isEmpty == false else {
            return String(
                localized: """
                Nothing on this panel can be changed. This item is not on a connection that offers a \
                way to change it.
                """,
                comment: "Info panel note: this backend has no verb for changing attributes."
            )
        }
        return String(
            localized: """
            Nothing on this panel can be changed, because this listing did not report a field the \
            server would let you set.
            """,
            comment: "Info panel note: the connection could write, but the listing reported nothing to write."
        )
    }

    /// What Save commits to, and what ⌘Z can and cannot do about it.
    ///
    /// This used to say the change could not be undone at all, which was true until 2026-09-01
    /// (PLAN.md §4 ▸ *Still open*). What replaces it is narrower than "you can undo this", because
    /// the mechanism is: ⌘Z sends the previous values back as a **second change**, so a server free
    /// to refuse the first one is free to refuse that too — and the sentence has to leave the user
    /// expecting a write rather than a rewind. PLAN.md §6's rule is unchanged either way: what an
    /// operation cannot promise is marked, never silently dropped.
    private func undoNote() -> String {
        String(
            localized: """
            A change made here is sent to the server straight away. Command-Z sends the previous \
            values back as another change, which the server can refuse in turn — and what the \
            panel shows after saving is what the server stored, which is not always what was \
            asked for.
            """,
            comment: "Info panel note: a remote attribute change is immediate, and its undo is a second write."
        )
    }

    /// Done alone while nothing is editable — there is nothing to discard, and a second button would
    /// imply otherwise. Cancel and Save once something is.
    func makeFooter() -> NSView {
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        guard !editability.isReadOnly else {
            let done = NSButton(
                title: String(localized: "Done", comment: "Button that closes a results sheet."),
                target: self,
                action: #selector(closeFromFooter(_:))
            )
            done.bezelStyle = .rounded
            done.keyEquivalent = "\r"
            return footerRow([spacer, done])
        }

        let cancel = NSButton(
            title: String(localized: "Cancel", comment: "Button that dismisses a dialog unchanged."),
            target: self,
            action: #selector(closeFromFooter(_:))
        )
        cancel.bezelStyle = .rounded
        cancel.keyEquivalent = "\u{1b}"

        let save = NSButton(
            title: String(localized: "Save", comment: "Button that commits an info panel's edits."),
            target: self,
            action: #selector(save(_:))
        )
        save.bezelStyle = .rounded
        save.keyEquivalent = "\r"
        // Nothing edited yet, so there is nothing to send — and an enabled Save over an unchanged
        // panel would spend a round trip to write a mode the item already has.
        save.isEnabled = false
        saveButton = save

        return footerRow([spacer, cancel, save])
    }

    private func footerRow(_ views: [NSView]) -> NSView {
        let footer = NSStackView(views: views)
        footer.orientation = .horizontal
        footer.spacing = 10
        footer.widthAnchor.constraint(
            equalToConstant: AttributesControllerLayout.contentWidth
        ).isActive = true
        return footer
    }

    @objc private func closeFromFooter(_ sender: Any?) { dismiss(sender) }
}
