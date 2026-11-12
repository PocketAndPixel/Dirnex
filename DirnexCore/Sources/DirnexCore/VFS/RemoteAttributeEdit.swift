import Foundation

/// One fact about a remote item that Get Info can change (PLAN.md §M25 Slice 5, §M38 Slice 1).
///
/// A remote listing carries no access-control list, no extended attributes, no BSD flags, no access
/// time and no birth time, so the four-tab local panel has nothing to offer here. And the fields
/// that *are* on the wire are not equally trustworthy once written, which is what
/// ``RemoteAttributeVerdict`` is for.
///
/// **Owner and group need more than a listing.** `sftp`'s `chown` and `chgrp` take a number, and a
/// listing prints names, so they go by name over the exec channel instead (``SSHOwnershipCommand``).
/// An account without one has neither control, and that is the old behaviour left standing where
/// a capability cannot be established.
public enum RemoteAttributeField: Sendable, Hashable, CaseIterable {
    /// The twelve mode bits, special ones included — `chmod` over the wire really does carry
    /// set-uid and the sticky bit, which the transfer flag silently drops.
    case permissions
    /// The modification time. FTP's `MFMT` writes one exactly, anchored to UTC (RFC 3659); `sftp`'s
    /// batch language has no verb that sets a time at all, so this is editable on one protocol and
    /// not the other.
    case modificationTime
    /// The owning user. Only root can change it, on every server measured.
    case owner
    /// The owning group. An account can give an item it owns to a group it belongs to.
    case group
}

/// Which of a remote row's fields this connection can actually change.
///
/// Two independent gates, and both have to hold. The **entry** must have reported the field, because
/// a control offering to set a mode the server never named would have to invent a starting value —
/// the same presence rule the read-only panel is built on (``RemoteAttributesController.fields``),
/// arriving on the write half. And the **connection** must still offer the verb, which is a fact
/// established by attempting one and reading the refusal rather than by asking a server in advance
/// (PLAN.md §M25: degrade per connection at run time).
///
/// Pure, so "which controls does this row deserve" is answerable — and testable — with no window, no
/// pane and no connection, which is the split ``AttributesRoute`` already needed for the same panel.
public struct RemoteAttributeEditability: Sendable, Equatable {
    /// The fields the user may change. Empty is an ordinary answer: an S3 object reports no mode,
    /// an archive member is on no connection, and an account that has refused `SITE CHMOD` has
    /// nothing left to offer.
    public let editable: Set<RemoteAttributeField>

    public init(editable: Set<RemoteAttributeField>) {
        self.editable = editable
    }

    /// Nothing can be changed — the read-only panel M24 Slice 7 shipped, unchanged.
    public static let readOnly = RemoteAttributeEditability(editable: [])

    public func allows(_ field: RemoteAttributeField) -> Bool { editable.contains(field) }

    /// Whether the panel has anything to save at all.
    public var isReadOnly: Bool { editable.isEmpty }

    /// What `entry` can be asked to change on a connection offering `capabilities`.
    ///
    /// - Parameter identity: who the account is, or `nil` when that could not be asked, in which
    ///   case owner and group are not offered.
    public static func decide(
        for entry: FileEntry,
        capabilities: RemoteMetadataCapabilities,
        identity: RemoteAccountIdentity? = nil
    ) -> RemoteAttributeEditability {
        var editable: Set<RemoteAttributeField> = []
        if entry.permissions != nil, capabilities.contains(.changeMode) {
            editable.insert(.permissions)
        }
        if entry.hasModificationDate, capabilities.contains(.setModificationTime) {
            editable.insert(.modificationTime)
        }
        if let identity { editable.formUnion(ownershipFields(of: entry, for: identity)) }
        return RemoteAttributeEditability(editable: editable)
    }

    /// What `identity` can change about who holds `entry`.
    ///
    /// A field the listing did not report is not offered, the presence rule the others follow. A
    /// group is offered only with somewhere to go: an account with one group, already the item's,
    /// has no choice to make.
    private static func ownershipFields(
        of entry: FileEntry,
        for identity: RemoteAccountIdentity
    ) -> Set<RemoteAttributeField> {
        var fields: Set<RemoteAttributeField> = []
        if identity.isSuperuser {
            if entry.ownerName != nil { fields.insert(.owner) }
            if entry.groupName != nil { fields.insert(.group) }
        } else if identity.user.matches(entry.ownerName),
                  entry.groupName != nil,
                  identity.groups.contains(where: { !$0.matches(entry.groupName) }) {
            fields.insert(.group)
        }
        return fields
    }
}

/// What the user asked a remote item to become — a field left `nil` is one they did not touch.
///
/// A patch rather than a whole `FileAttributes`, because only the fields that changed should reach
/// the wire: an unchanged mode re-sent is a round trip that can be refused, and on a server that
/// clears set-uid on a neighbouring write it is a round trip that can do *harm*.
///
/// `Codable` because it is also what the undo journal carries in both directions
/// (``UndoStep/restoreRemoteAttributes(path:apply:reverse:)``): the values a ⌘Z would send back are
/// the same patch, and the journal survives relaunch. The patch shape is what makes that safe —
/// a step puts back only the fields the edit actually moved, so nothing else on the item is written.
public struct RemoteAttributeChange: Sendable, Equatable, Codable {
    /// The mode to store, or `nil` to leave it alone.
    public let permissions: POSIXPermissions?
    /// The modification time to store, or `nil` to leave it alone.
    public let modificationTime: Date?
    /// The owner to give it, or `nil` to leave it alone.
    public let owner: RemotePrincipal?
    /// The group to give it, or `nil` to leave it alone.
    public let group: RemotePrincipal?

    public init(
        permissions: POSIXPermissions? = nil,
        modificationTime: Date? = nil,
        owner: RemotePrincipal? = nil,
        group: RemotePrincipal? = nil
    ) {
        self.permissions = permissions
        self.modificationTime = modificationTime
        self.owner = owner
        self.group = group
    }

    public var isEmpty: Bool {
        permissions == nil && modificationTime == nil && owner == nil && group == nil
    }

    /// The fields this change sets.
    public var fields: Set<RemoteAttributeField> {
        var fields: Set<RemoteAttributeField> = []
        if permissions != nil { fields.insert(.permissions) }
        if modificationTime != nil { fields.insert(.modificationTime) }
        if owner != nil { fields.insert(.owner) }
        if group != nil { fields.insert(.group) }
        return fields
    }

    /// The wire steps that carry it, in the vocabulary the transports already speak.
    ///
    /// The same ``RemoteMetadataStep`` a *copy* rides on, not a second spelling of it: one
    /// `SITE CHMOD` builder, one `chmod` batch line, one classifier for what a refusal means. A
    /// panel with its own steps would be a second definition of what a remote metadata write is,
    /// which this project has paid for before.
    ///
    /// **Ownership goes first**, for the rule ``AttributeChangePlan`` states locally.
    public var steps: [RemoteMetadataStep] {
        var steps: [RemoteMetadataStep] = []
        if owner != nil || group != nil {
            steps.append(.setOwnership(owner: owner?.name, group: group?.name))
        }
        if let permissions { steps.append(.setMode(permissions)) }
        if let modificationTime { steps.append(.setModificationTime(modificationTime)) }
        return steps
    }

    /// The change from `current` to what the controls hold, with every untouched field dropped.
    ///
    /// `editable` is applied here rather than trusted from the caller, so a field the connection
    /// cannot change can never reach the wire even if a control for it were somehow left enabled.
    ///
    /// - Parameters:
    ///   - modificationTime: what the date control holds now, or `nil` when there is none.
    ///   - shownModificationTime: what the date control was **given**, read back from it right after
    ///     assigning. Untouched means equal to *this*, not to the entry: an `MLSD` stamp can carry a
    ///     fraction of a second, and a control that resolves time more coarsely would otherwise send
    ///     a date nobody edited along with every mode change (docs/NOTES.md ▸ ACLs and file
    ///     attributes).
    ///   - owner: what the owner control holds now, or `nil` when there is none.
    ///   - group: what the group control holds now, or `nil` when there is none.
    public static func between(
        current: FileEntry,
        permissions: POSIXPermissions?,
        modificationTime: Date?,
        shownModificationTime: Date?,
        owner: RemotePrincipal? = nil,
        group: RemotePrincipal? = nil,
        editable: RemoteAttributeEditability
    ) -> RemoteAttributeChange {
        var mode: POSIXPermissions?
        if editable.allows(.permissions),
           let permissions,
           let now = current.permissions,
           permissions.rawValue != now {
            mode = permissions
        }
        var time: Date?
        if editable.allows(.modificationTime),
           let modificationTime,
           modificationTime != shownModificationTime {
            time = modificationTime
        }
        let newOwner = moved(owner, from: current.ownerName, editable: editable.allows(.owner))
        let newGroup = moved(group, from: current.groupName, editable: editable.allows(.group))
        // **Any group change clears set-uid and set-gid**, the same group included, measured on
        // macOS, GNU and busybox: `chown :admin` turned `6755` into `755`, exit 0, nothing printed.
        // Sending the mode after it is the only repair, and the read-back then says if it held.
        if mode == nil, newOwner != nil || newGroup != nil, editable.allows(.permissions),
           let now = current.permissions, POSIXPermissions(rawValue: now).carriesSetID {
            mode = POSIXPermissions(rawValue: now)
        }
        return RemoteAttributeChange(
            permissions: mode,
            modificationTime: time,
            owner: newOwner,
            group: newGroup
        )
    }

    /// `asked`, when it can be sent and is not what the item already has.
    private static func moved(
        _ asked: RemotePrincipal?,
        from listed: String?,
        editable: Bool
    ) -> RemotePrincipal? {
        guard editable, let asked, !asked.matches(listed) else { return nil }
        return asked
    }
}
