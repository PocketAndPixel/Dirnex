import Foundation

/// Many items' root-only changes, run as administrator after one password (PLAN.md §M40 Slice 4).
///
/// Each item's command is built from **its own** plan by ``EscalatedAttributeCommand``, which is the
/// single-item escalation's tested translation, quoting included: a batch adds no second way to turn
/// a change into shell. What it adds is how the commands are put together and how the result is
/// judged.
///
/// **Put together** so that one item's failure does not stop the others, which is the recursive
/// run's own rule for a per-item error. An item's steps stay joined by `&&`, because they are one
/// ordered plan (unlock, change, relock), and items are joined so that each runs whatever the one
/// before it did, with a failure remembered in `s` and returned as the exit status. A nonzero exit
/// is what makes `do shell script` hand back the tools' stderr, which it throws away on success.
///
/// **Chunked** because a body reaches `/bin/sh -c` through `execve`, whose `ARG_MAX` is 1 MiB with
/// the environment counted in. Probed 2026-11-18: a 1 040 000-byte body ran and a 1 048 000-byte one
/// failed. ``bodyLimit`` keeps each body to half of that, so no environment brings it near the limit,
/// and the app runs every body in one process, behind one password.
///
/// **Judged by reading the items back**, never by the shell's answer. `do shell script` keeps
/// stdout only on success and stderr only on failure (probed), so neither says which items landed,
/// and a password dialog cancelled before a later chunk leaves the earlier ones applied. So
/// ``outcome(journalLimit:reading:)`` reads every item again and journals what is on disk, as the
/// single-item path journals "what actually landed, not what was asked".
public struct EscalatedAttributeBatch: Sendable, Equatable {
    /// One item's change, with the command that makes it as root.
    public struct Item: Sendable, Equatable {
        public let path: VFSPath
        public let actsOnLink: Bool
        /// The item's attributes when the change was planned.
        public let current: FileAttributes
        /// What was asked.
        public let diff: AttributeDiff
        /// The item's list before the change, when the plan writes one.
        public let currentACL: AccessControlList?
        /// The ordered steps; the command is their translation.
        public let plan: AttributeChangePlan
        public let command: EscalatedAttributeCommand

        /// An item whose change writes no ACL, or writes `accessControlList` in place of
        /// `currentACL`.
        public init(
            path: VFSPath,
            actsOnLink: Bool,
            current: FileAttributes,
            diff: AttributeDiff,
            currentACL: AccessControlList? = nil,
            accessControlList: AccessControlList? = nil
        ) {
            self.path = path
            self.actsOnLink = actsOnLink
            self.current = current
            self.diff = diff
            self.currentACL = accessControlList == nil ? nil : currentACL ?? AccessControlList()
            plan = AttributeChangePlan(
                diff: diff,
                current: current,
                actsOnLink: actsOnLink,
                accessControlList: accessControlList
            )
            command = EscalatedAttributeCommand.build(for: plan, path: path.path, current: current)
        }

        /// The item a recursive job left for root, as that job would change it now.
        public init(_ change: AttributeItemChange) {
            self.init(
                path: change.path,
                actsOnLink: change.reading.isSymlink,
                current: change.reading.attributes,
                diff: change.diff,
                currentACL: change.existingACL,
                accessControlList: change.changesAccessControlList ? change.desiredACL : nil
            )
        }

        /// The list the plan writes, if any.
        public var desiredACL: AccessControlList? {
            for case let .setAccessControlList(list) in plan.steps { return list }
            return nil
        }
    }

    /// The items, in the order their commands run.
    public let items: [Item]

    public init(items: [Item]) {
        self.items = items
    }

    /// The items a recursive run left for root, each planned again against what is on disk now: the
    /// password dialog can come minutes after the run. An item that has gone, or that already
    /// matches, drops out.
    public init(
        retrying rootOnly: [AttributeApplyOutcome.RootOnlyItem],
        of job: AttributeApplyJob
    ) {
        items = rootOnly.compactMap { item in
            guard let change = try? job.change(at: item.path, kind: item.kind), !change.isEmpty
            else { return nil }
            return Item(change)
        }
    }

    /// Half of `ARG_MAX` (see the type's doc): each body passes `execve` with any environment.
    public static let bodyLimit = 512 * 1024

    /// Whether any item has a command to run. A batch can hold only changes no stock tool makes (the
    /// Created date), and then there is nothing to authenticate.
    public var hasCommands: Bool { items.contains { $0.command.hasCommands } }

    /// What the commands leave out, across every item, for the dialog to state.
    public var omissions: Set<EscalatedAttributeCommand.Omission> {
        items.reduce(into: []) { $0.formUnion($1.command.omissions) }
    }

    /// The shell bodies to run as root, in order, each at most `limit` bytes of UTF-8 unless a single
    /// item's command is longer by itself, which then runs alone and fails on its own.
    public func bodies(limit: Int = bodyLimit) -> [String] {
        var bodies: [String] = []
        var parts: [String] = []
        var size = Self.prefix.utf8.count + Self.suffix.utf8.count
        for item in items where item.command.hasCommands {
            let part = "\(item.command.scriptBody) || s=1; "
            let partSize = part.utf8.count
            if !parts.isEmpty, size + partSize > limit {
                bodies.append(Self.body(parts))
                parts = []
                size = Self.prefix.utf8.count + Self.suffix.utf8.count
            }
            parts.append(part)
            size += partSize
        }
        if !parts.isEmpty { bodies.append(Self.body(parts)) }
        return bodies
    }

    /// The line for the dialog's "run it yourself" field, or `nil` when there is nothing to run or
    /// the batch does not fit one body, since `sudo` passes it through `execve` too.
    public func terminalCommand(limit: Int = bodyLimit) -> String? {
        let bodies = bodies(limit: limit)
        guard bodies.count == 1, let body = bodies.first else { return nil }
        return "sudo /bin/sh -c \(ShellQuoting.quoted(body, for: .other))"
    }

    private static let prefix = "s=0; "
    private static let suffix = "exit $s"

    private static func body(_ parts: [String]) -> String {
        prefix + parts.joined() + suffix
    }
}

// MARK: - What landed

public extension EscalatedAttributeBatch {
    /// One item as read back after the run.
    struct Observed: Sendable, Equatable {
        public let attributes: FileAttributes
        /// Its list, read only when the item's plan writes one.
        public let accessControlList: AccessControlList?

        public init(attributes: FileAttributes, accessControlList: AccessControlList? = nil) {
            self.attributes = attributes
            self.accessControlList = accessControlList
        }
    }

    /// What the run did, judged from the items as they are now.
    struct Outcome: Sendable, Equatable {
        /// Undo material for every item that changed, holding what is on disk rather than what was
        /// asked. **Empty when ``isUndoable`` is `false`.**
        public let changed: [UndoRecord.AttributeBatchEntry]
        /// How many items changed at all.
        public let changedCount: Int
        /// The items where something asked, and not left out as an omission, is not on disk: the
        /// shell failed there, or never reached it.
        public let unchanged: [VFSPath]
        /// Whether the changed items fit the journal's limit, the recursive run's all-or-nothing rule.
        public let isUndoable: Bool
    }

    /// Read every item back with `read` and say what landed. An item `read` cannot answer for counts
    /// as unchanged and journals nothing, since nothing about it is known.
    func outcome(
        journalLimit: Int = AttributeApplyJob.defaultJournalLimit,
        reading read: (Item) -> Observed?
    ) -> Outcome {
        var changed: [UndoRecord.AttributeBatchEntry] = []
        var unchanged: [VFSPath] = []
        for item in items {
            guard let observed = read(item) else {
                unchanged.append(item.path)
                continue
            }
            if let entry = Self.landed(item, observed) { changed.append(entry) }
            if !Self.matchesRequest(item, observed) { unchanged.append(item.path) }
        }
        let isUndoable = changed.count <= journalLimit
        return Outcome(
            changed: isUndoable ? changed : [],
            changedCount: changed.count,
            unchanged: unchanged,
            isUndoable: isUndoable
        )
    }

    /// ``outcome(journalLimit:reading:)`` against the items on this Mac.
    func outcomeOnDisk(journalLimit: Int = AttributeApplyJob.defaultJournalLimit) -> Outcome {
        outcome(journalLimit: journalLimit) { item in
            guard let reading = try? FileAttributeIO.read(at: item.path) else { return nil }
            let list = item.desiredACL == nil
                ? nil
                : try? AccessControlListIO.read(at: item.path, actsOnLink: item.actsOnLink)
            return Observed(attributes: reading.attributes, accessControlList: list)
        }
    }

    /// The journal entry for what is on disk: the item as planned, with every field the plan writes
    /// taken from what was read back. Only those fields, so a change nobody here made to some other
    /// field is never put back by ⌘Z. `nil` when nothing the plan writes has moved.
    private static func landed(_ item: Item, _ observed: Observed) -> UndoRecord.AttributeBatchEntry? {
        var new = item.current
        let after = observed.attributes
        for step in item.plan.steps {
            switch step {
            case let .setOwnership(userID, groupID):
                if userID != nil { new.ownerID = after.ownerID }
                if groupID != nil { new.groupID = after.groupID }
            case .setPermissions:
                new.permissions = after.permissions
            case .setTimes:
                new.accessDate = after.accessDate
                new.modificationDate = after.modificationDate
            case .setCreationDate:
                new.creationDate = after.creationDate
            case .setFlags:
                new.flags = after.flags
            case .setAccessControlList:
                break
            }
        }
        let lists: (old: AccessControlList, new: AccessControlList)? =
            if let before = item.currentACL, let now = observed.accessControlList, now != before {
                (old: before, new: now)
            } else {
                nil
            }
        guard !AttributeDiff(from: item.current, to: new).isEmpty || lists != nil else { return nil }
        return UndoRecord.AttributeBatchEntry(
            path: item.path,
            actsOnLink: item.actsOnLink,
            old: item.current,
            new: new,
            accessControlLists: lists
        )
    }

    /// Whether everything asked that the command makes is on disk. Times are compared to the second,
    /// which is what `touch -t` writes.
    private static func matchesRequest(_ item: Item, _ observed: Observed) -> Bool {
        let diff = item.diff
        let after = observed.attributes
        let omissions = item.command.omissions
        func sameSecond(_ lhs: Date, _ rhs: Date) -> Bool {
            lhs.timeIntervalSince1970.rounded(.down) == rhs.timeIntervalSince1970.rounded(.down)
        }
        if let value = diff.permissions, value != after.permissions { return false }
        if let value = diff.flags, value != after.flags { return false }
        if let value = diff.ownerID, value != after.ownerID { return false }
        if let value = diff.groupID, value != after.groupID { return false }
        if let value = diff.accessDate, !sameSecond(value, after.accessDate) { return false }
        if let value = diff.modificationDate, !sameSecond(value, after.modificationDate) {
            return false
        }
        if let value = diff.creationDate, !omissions.contains(.creationDate),
           !sameSecond(value, after.creationDate) {
            return false
        }
        if let desired = item.desiredACL, !omissions.contains(.accessControlList),
           observed.accessControlList != desired {
            return false
        }
        return true
    }
}
