import AppKit
import DirnexCore

/// Owner and group in a remote Get Info (PLAN.md §M38 Slice 2).
///
/// **Two shapes of control, because the two accounts have different questions to answer.** Root may
/// hand an item to anybody and nothing on an SSH connection lists a server's users, so it gets a
/// field that takes a name. Any other account may hand an item only to a group it belongs to, which
/// `id` has already listed, so it gets a popup and no way to ask for something every Save refuses.
///
/// Rows stay plain text, exactly as the listing spelled them, wherever nothing can be sent
/// (``RemoteAttributeEditability``). They are never resolved against this Mac: a server's `501` put
/// through `getpwuid` here would draw the local account of whoever is reading the panel over a file
/// belonging to a stranger (`FileEntry.ownerName`).
extension RemoteAttributesController: NSTextFieldDelegate {
    func makeOwnerRow() -> NSView {
        let label = String(
            localized: "Owner:",
            comment: "Info panel field label: the owning user, as the server named it."
        )
        guard editability.allows(.owner) else {
            return AttributeRow.make(label: label, value: entry.ownerName ?? "")
        }
        let field = makeNameField(entry.ownerName ?? "", accessibilityLabel: label)
        ownerField = field
        return AttributeRow.make(label: label, field: field)
    }

    func makeGroupRow() -> NSView {
        let label = String(
            localized: "Group:",
            comment: "Info panel field label: the owning group, as the server named it."
        )
        guard editability.allows(.group), let identity else {
            return AttributeRow.make(label: label, value: entry.groupName ?? "")
        }
        guard !identity.isSuperuser else {
            let field = makeNameField(entry.groupName ?? "", accessibilityLabel: label)
            groupField = field
            return AttributeRow.make(label: label, field: field)
        }
        return AttributeRow.make(label: label, control: makeGroupPopup(identity, label: label))
    }

    /// A name to type. `NSTextField(string:)` is single-line by construction.
    private func makeNameField(_ name: String, accessibilityLabel: String) -> NSTextField {
        let field = NSTextField(string: name)
        field.delegate = self
        field.lineBreakMode = .byTruncatingTail
        field.setAccessibilityLabel(accessibilityLabel)
        field.widthAnchor.constraint(equalToConstant: Self.controlWidth).isActive = true
        return field
    }

    /// The account's groups, with the item's own selected.
    ///
    /// Each name is offered once. A directory service can give two groups one name, and `chown` is
    /// handed the name, so a second row could only ever send the same thing as the first.
    private func makeGroupPopup(_ identity: RemoteAccountIdentity, label: String) -> NSView {
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        groupChoices = identity.groupChoices(listed: entry.groupName)
        for (index, group) in groupChoices.enumerated() where popup.item(withTitle: group.name) == nil {
            popup.addItem(withTitle: group.name)
            popup.lastItem?.tag = index
        }
        if let current = groupChoices.first(where: { $0.matches(entry.groupName) }) {
            popup.selectItem(withTitle: current.name)
        }
        popup.target = self
        popup.action = #selector(editChanged(_:))
        popup.setAccessibilityLabel(label)
        popup.widthAnchor.constraint(equalToConstant: Self.controlWidth).isActive = true
        groupPopup = popup
        return popup
    }

    /// Wide enough for a directory service's long names, and narrow enough to read as a name.
    private static let controlWidth: CGFloat = 240

    // MARK: - Reading the controls back

    var editedOwner: RemotePrincipal? { typedPrincipal(in: ownerField) }

    var editedGroup: RemotePrincipal? {
        guard let groupPopup else { return typedPrincipal(in: groupField) }
        let index = groupPopup.selectedTag()
        return groupChoices.indices.contains(index) ? groupChoices[index] : nil
    }

    /// What `field` holds, or `nil` for nothing: a cleared field asks for no change, since an empty
    /// name is not something `chown` can be told.
    private func typedPrincipal(in field: NSTextField?) -> RemotePrincipal? {
        let name = field?.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return name.isEmpty ? nil : RemotePrincipal(name: name)
    }

    func controlTextDidChange(_: Notification) {
        editChanged(nil)
    }

    // MARK: - Saying what happened

    /// Whether the panel owes an explanation for read-only owner and group rows.
    ///
    /// Only over SFTP: FTP, WebDAV and S3 have no commands to run at all, so read-only is simply
    /// what those rows are, where on SFTP it is something about this account.
    var ownershipNeedsItsReason: Bool {
        identity == nil && entry.path.backend.isSFTP
            && (entry.ownerName != nil || entry.groupName != nil)
    }

    /// True of an account that can only transfer files and of a server that could not be asked,
    /// since `accountIdentity(at:isCancelled:)` answers `nil` for both.
    static var noCommandNote: String {
        String(
            localized: """
            The owner and group can’t be changed here, because that takes a command on the server \
            and this account didn’t run one. An account limited to file transfer can’t run any.
            """,
            comment: "Info panel note: an SFTP account with no shell, so owner and group stay read-only."
        )
    }

    /// Which of the owner and group did not take, or `nil` when both did.
    static func ownershipDetail(_ refused: Set<RemoteAttributeField>) -> String? {
        switch (refused.contains(.owner), refused.contains(.group)) {
        case (true, true):
            String(
                localized: """
                Neither the owner nor the group was stored as asked. The panel now shows what the \
                item actually carries.
                """,
                comment: "Remote Get Info: neither the owner nor the group was stored."
            )
        case (true, false):
            String(
                localized: """
                The owner was not stored as asked. The panel now shows what the item actually carries.
                """,
                comment: "Remote Get Info: the owner was refused or came back different."
            )
        case (false, true):
            String(
                localized: """
                The group was not stored as asked. The panel now shows what the item actually carries.
                """,
                comment: "Remote Get Info: the group was refused or came back different."
            )
        case (false, false):
            nil
        }
    }
}
