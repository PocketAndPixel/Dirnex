import AppKit
import DirnexCore

/// The users and groups an ACL entry can name, as a popup menu (PLAN.md §M14 Slice 4).
///
/// **The one place a name becomes an identity.** macOS spells ACL subjects by GUID, so every entry
/// the editor writes has to go through `mbr_uid_to_uuid` — and PLAN.md put that in one place on
/// purpose, because a second site that builds a subject is a second site that can build a wrong one.
///
/// Two rules come from the Slice 4 probe (docs/NOTES.md) and neither is guessable from the API:
///
/// - **Service accounts are filtered by the leading underscore, never by a numeric floor.** The
///   tempting "real accounts start at 500" rule hides `wheel` (0), `everyone` (12), `staff` (20) and
///   `admin` (80) — precisely the groups an ACL entry names.
/// - **`mbr_uid_to_uuid` cannot validate an account**: it *synthesizes* a GUID for an id nobody owns,
///   so a non-`nil` GUID proves nothing. The roster only ever offers accounts `getpwent`/`getgrent`
///   actually enumerated, which is what keeps an entry from naming nobody.
@MainActor
enum ACLSubjectPicker {
    /// Fill a popup with every user and group worth offering, in two labelled sections, and select
    /// the one `subject` names.
    ///
    /// An entry's current subject is added to the top when the roster does not contain it — an
    /// unresolved GUID or a service account is a perfectly ordinary thing for a *stored* entry to
    /// name, and a popup that cannot display the value it holds would show the wrong account as
    /// selected. Same rule, and the same reason, as the group picker's "current group is always
    /// included" (``IdentityRoster/selectableGroups(from:memberOf:current:)``).
    static func populate(_ popup: NSPopUpButton, selecting subject: ACLSubject?) {
        popup.removeAllItems()
        guard let menu = popup.menu else { return }

        if let subject, !isInRoster(subject) {
            menu.addItem(item(for: subject, title: subjectTitle(subject)))
            menu.addItem(.separator())
        }

        addSection(
            to: menu,
            title: String(
                localized: "Users",
                comment: "Section heading in the ACL subject picker, above the user accounts."
            ),
            records: IdentityRoster.visible(IdentityDirectory.users()),
            kind: .user
        )
        addSection(
            to: menu,
            title: String(
                localized: "Groups",
                comment: "Section heading in the ACL subject picker, above the groups."
            ),
            records: IdentityRoster.visible(IdentityDirectory.groups()),
            kind: .group
        )

        if let subject { select(subject, in: popup) }
    }

    /// The subject a popup's selection stands for, or `nil` when nothing is selected.
    static func selectedSubject(in popup: NSPopUpButton) -> ACLSubject? {
        popup.selectedItem?.representedObject as? ACLSubject
    }

    /// How a subject reads in the menu: `oleg (501)` for an account, and the bare GUID for one that
    /// answers to nobody — which is what `ls -le` shows for the same entry.
    static func subjectTitle(_ subject: ACLSubject) -> String {
        guard let numericID = subject.numericID, !subject.name.isEmpty else {
            return subject.displayName
        }
        return AttributesSnapshot.describe(subject.name, id: numericID)
    }

    // MARK: - Construction

    private static func addSection(
        to menu: NSMenu,
        title: String,
        records: [IdentityRecord],
        kind: ACLSubjectKind
    ) {
        let heading = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        heading.isEnabled = false
        menu.addItem(heading)
        for record in records {
            // A record with no GUID cannot be written into an ACL at all, so it is not offered.
            guard let subject = ACLIdentity.subject(for: record, kind: kind) else { continue }
            let entry = item(for: subject, title: subjectTitle(subject))
            entry.indentationLevel = 1
            menu.addItem(entry)
        }
    }

    /// The subject rides on the item as its `representedObject` — captured at build time, the way
    /// every other menu in this app carries what it acts on (docs/NOTES.md), so nothing has to be
    /// re-derived from a title or an index at click time.
    private static func item(for subject: ACLSubject, title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.representedObject = subject
        return item
    }

    private static func select(_ subject: ACLSubject, in popup: NSPopUpButton) {
        let match = popup.menu?.items.first {
            guard let candidate = $0.representedObject as? ACLSubject else { return false }
            return candidate.guid == subject.guid
        }
        if let match { popup.select(match) }
    }

    private static func isInRoster(_ subject: ACLSubject) -> Bool {
        guard subject.isResolved else { return false }
        let records = subject.kind == .user
            ? IdentityRoster.visible(IdentityDirectory.users())
            : IdentityRoster.visible(IdentityDirectory.groups())
        return records.contains { $0.numericID == subject.numericID && $0.name == subject.name }
    }
}
