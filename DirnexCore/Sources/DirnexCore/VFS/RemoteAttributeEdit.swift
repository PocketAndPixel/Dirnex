import Foundation

/// One fact about a remote item that Get Info can change (PLAN.md §M25 Slice 5).
///
/// Two, and the shortness of the list is the finding rather than a first pass. A remote listing
/// carries no access-control list, no extended attributes, no BSD flags, no access time and no birth
/// time, so the four-tab local panel has nothing to offer here — and the two fields that *are* on
/// the wire are not equally trustworthy once written, which is what ``RemoteAttributeVerdict`` is
/// for.
///
/// **Owner and group are deliberately absent, and it took a probe to say so.** `sftp` has `chown`
/// and `chgrp` and both work — but they take a **numeric id**, and `sftp`'s own `ls -la` prints
/// *names* (`oleg staff`), so a panel built on a listing has nothing to send. Worse, a remote
/// `chgrp` clears set-uid **and** set-gid as a side effect, exactly as the local `chown(2)` does
/// (measured 2026-08-28: `106755` became `100755` on a successful `chgrp`, exit 0, nothing printed)
/// — so offering it would need both an id the panel does not have and the ordering rule
/// ``AttributeChangePlan`` already encodes locally. Refusing to offer it is the honest end of that,
/// and it is what the milestone means by leaving the old behaviour standing where a capability
/// cannot be established.
public enum RemoteAttributeField: Sendable, Hashable, CaseIterable {
    /// The twelve mode bits, special ones included — `chmod` over the wire really does carry
    /// set-uid and the sticky bit, which the transfer flag silently drops.
    case permissions
    /// The modification time. FTP's `MFMT` writes one exactly, anchored to UTC (RFC 3659); `sftp`'s
    /// batch language has no verb that sets a time at all, so this is editable on one protocol and
    /// not the other.
    case modificationTime
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
    public static func decide(
        for entry: FileEntry,
        capabilities: RemoteMetadataCapabilities
    ) -> RemoteAttributeEditability {
        var editable: Set<RemoteAttributeField> = []
        if entry.permissions != nil, capabilities.contains(.changeMode) {
            editable.insert(.permissions)
        }
        if entry.hasModificationDate, capabilities.contains(.setModificationTime) {
            editable.insert(.modificationTime)
        }
        return RemoteAttributeEditability(editable: editable)
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

    public init(permissions: POSIXPermissions? = nil, modificationTime: Date? = nil) {
        self.permissions = permissions
        self.modificationTime = modificationTime
    }

    /// Nothing to do — what an untouched panel commits, and what must never reach a server.
    public static let none = RemoteAttributeChange()

    public var isEmpty: Bool { permissions == nil && modificationTime == nil }

    /// The fields this change sets.
    public var fields: Set<RemoteAttributeField> {
        var fields: Set<RemoteAttributeField> = []
        if permissions != nil { fields.insert(.permissions) }
        if modificationTime != nil { fields.insert(.modificationTime) }
        return fields
    }

    /// The wire steps that carry it, in the vocabulary the transports already speak.
    ///
    /// The same ``RemoteMetadataStep`` a *copy* rides on, not a second spelling of it: one
    /// `SITE CHMOD` builder, one `chmod` batch line, one classifier for what a refusal means. A
    /// panel with its own steps would be a second definition of what a remote metadata write is,
    /// which this project has paid for before.
    public var steps: [RemoteMetadataStep] {
        var steps: [RemoteMetadataStep] = []
        if let permissions { steps.append(.setMode(permissions)) }
        if let modificationTime { steps.append(.setModificationTime(modificationTime)) }
        return steps
    }

    /// The change from `current` to `edited`, with every untouched field dropped.
    ///
    /// `editable` is applied here rather than trusted from the caller, so a field the connection
    /// cannot change can never reach the wire even if a control for it were somehow left enabled.
    public static func between(
        current: FileEntry,
        permissions: POSIXPermissions?,
        modificationTime: Date?,
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
           !current.hasModificationDate || modificationTime != current.modificationDate {
            time = modificationTime
        }
        return RemoteAttributeChange(permissions: mode, modificationTime: time)
    }
}
