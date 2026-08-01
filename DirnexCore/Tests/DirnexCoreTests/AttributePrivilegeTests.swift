import Foundation
import Testing

@testable import DirnexCore

/// The probe matrix (2026-07-29) turned into assertions: for a file the user owns, almost everything
/// is unprivileged; root is needed only for `SF_*` flags, handing the file to another user, and a
/// `chgrp` to a group the user is not in.
@Suite("AttributePrivilege")
struct AttributePrivilegeTests {
    private let epoch = Date(timeIntervalSince1970: 1_000_000)
    private let me = UserContext(userID: 501, groupIDs: [501, 20, 12])

    private func attributes(
        flags: BSDFileFlags = [],
        owner: UInt32 = 501,
        group: UInt32 = 20
    ) -> FileAttributes {
        FileAttributes(
            permissions: POSIXPermissions(rawValue: 0o644),
            flags: flags,
            ownerID: owner,
            groupID: group,
            accessDate: epoch,
            modificationDate: epoch,
            creationDate: epoch
        )
    }

    private func reasons(from current: FileAttributes, to desired: FileAttributes) -> [
        AttributePrivilege.Reason
    ] {
        AttributePrivilege.reasons(
            for: AttributeDiff(from: current, to: desired), current: current, actor: me
        )
    }

    @Test("editing your own file's mode, UF flags and times needs no root")
    func ownFileUnprivileged() {
        var desired = attributes()
        desired.permissions = POSIXPermissions(rawValue: 0o600)
        desired.flags = [.hidden, .userImmutable]
        desired.accessDate = epoch.addingTimeInterval(60)
        desired.creationDate = epoch.addingTimeInterval(60)
        #expect(reasons(from: attributes(), to: desired).isEmpty)
    }

    @Test("changing an SF_* flag needs root, and names just those bits")
    func systemFlagsNeedRoot() {
        var desired = attributes()
        desired.flags = [.systemImmutable]
        #expect(reasons(from: attributes(), to: desired) == [.systemFlags(.systemImmutable)])

        // A UF change alongside it is not reported — only the super-user bits.
        var mixed = attributes()
        mixed.flags = [.hidden, .systemAppend]
        #expect(reasons(from: attributes(), to: mixed) == [.systemFlags(.systemAppend)])
    }

    /// Editing a *system*-immutable file needs root even when the flags themselves are untouched: the
    /// plan must clear SF_IMMUTABLE to apply the mode change, and only root can. A *user*-immutable
    /// file (Finder's Locked) is unprivileged, because the owner clears UF_IMMUTABLE themselves.
    @Test("an SF_IMMUTABLE file's implicit unlock needs root; a UF_IMMUTABLE one does not")
    func implicitUnlock() {
        var overSystem = attributes(flags: [.systemImmutable])
        overSystem.permissions = POSIXPermissions(rawValue: 0o600)
        #expect(reasons(from: attributes(flags: [.systemImmutable]), to: overSystem)
            == [.systemFlags(.systemImmutable)])

        var overUser = attributes(flags: [.userImmutable])
        overUser.permissions = POSIXPermissions(rawValue: 0o600)
        #expect(reasons(from: attributes(flags: [.userImmutable]), to: overUser).isEmpty)
    }

    @Test("handing the file to another user needs root")
    func changeOwnerNeedsRoot() {
        var desired = attributes()
        desired.ownerID = 502
        #expect(reasons(from: attributes(), to: desired) == [.changeOwner])
    }

    @Test("chgrp to a group you are in is free; to one you are not needs root")
    func groupMembership() {
        var toOwnGroup = attributes(group: 20)
        toOwnGroup.groupID = 12 // in me.groupIDs
        #expect(reasons(from: attributes(group: 20), to: toOwnGroup).isEmpty)

        var toForeign = attributes(group: 20)
        toForeign.groupID = 80 // not in me.groupIDs
        #expect(
            reasons(from: attributes(group: 20), to: toForeign) == [
                .changeToForeignGroup(groupID: 80)
            ]
        )
    }

    @Test("someone else's file is entirely root's, with no per-field reasons")
    func notOwner() {
        var desired = attributes(owner: 0)
        desired.permissions = POSIXPermissions(rawValue: 0o600) // trivial change an owner could do
        #expect(reasons(from: attributes(owner: 0), to: desired) == [.notOwner])
    }

    @Test("root needs nothing, and an empty diff needs nothing")
    func rootAndEmpty() {
        let root = UserContext(userID: 0, groupIDs: [])
        var desired = attributes(owner: 999)
        desired.flags = [.systemImmutable]
        desired.ownerID = 1
        #expect(AttributePrivilege.reasons(
            for: AttributeDiff(from: attributes(owner: 999), to: desired),
            current: attributes(owner: 999), actor: root
        ).isEmpty)

        #expect(reasons(from: attributes(), to: attributes()).isEmpty)
    }

    // MARK: - The ACL, which the diff does not carry

    /// An ACL change alone is a real change, even though ``AttributeDiff`` is empty — the ACL is an
    /// ordered list rather than a field, so it rides beside the diff. Without this the panel would
    /// ask "does an ACL-only edit need root?", get "no" for *someone else's* file, and hit the bare
    /// EPERM the whole design exists to avoid.
    @Test("an ACL change on someone else's file is root's, on an empty diff")
    func aclOnAnotherUsersFile() {
        let theirs = attributes(owner: 0)
        #expect(AttributePrivilege.reasons(
            for: AttributeDiff(), current: theirs, actor: me, changesAccessControlList: true
        ) == [.notOwner])
    }

    @Test("an ACL change on your own unlocked file needs no root")
    func aclOnOwnFile() {
        #expect(AttributePrivilege.reasons(
            for: AttributeDiff(), current: attributes(), actor: me, changesAccessControlList: true
        ).isEmpty)
    }

    /// `acl_set_file` is EPERM while an immutable bit is set (probed), so an ACL change inherits the
    /// implicit-unlock rule the mode already has: clearing `SF_IMMUTABLE` is root's, clearing
    /// `UF_IMMUTABLE` is not.
    @Test("an ACL change on an SF_IMMUTABLE file needs root; on a UF_IMMUTABLE one it does not")
    func aclUnderImmutableBits() {
        #expect(AttributePrivilege.reasons(
            for: AttributeDiff(),
            current: attributes(flags: [.systemImmutable]),
            actor: me,
            changesAccessControlList: true
        ) == [.systemFlags(.systemImmutable)])

        #expect(AttributePrivilege.reasons(
            for: AttributeDiff(),
            current: attributes(flags: [.userImmutable]),
            actor: me,
            changesAccessControlList: true
        ).isEmpty)
    }

    @Test("no ACL change and an empty diff still needs nothing")
    func aclFlagOffChangesNothing() {
        #expect(AttributePrivilege.reasons(
            for: AttributeDiff(), current: attributes(owner: 0), actor: me
        ).isEmpty)
    }

    @Test("multiple root-only changes are all reported")
    func combined() {
        var desired = attributes()
        desired.flags = [.systemImmutable]
        desired.ownerID = 502
        desired.groupID = 80
        let result = reasons(from: attributes(), to: desired)
        #expect(result.contains(.systemFlags(.systemImmutable)))
        #expect(result.contains(.changeOwner))
        #expect(result.contains(.changeToForeignGroup(groupID: 80)))
        #expect(AttributePrivilege.needsRoot(
            for: AttributeDiff(from: attributes(), to: desired), current: attributes(), actor: me
        ))
    }
}
