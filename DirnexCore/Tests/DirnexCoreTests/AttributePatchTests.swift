import Foundation
import Testing

@testable import DirnexCore

@Suite("AttributePatch")
struct AttributePatchTests {
    private let epoch = Date(timeIntervalSince1970: 1_000_000)

    private func item(
        mode: UInt16 = 0o644,
        flags: BSDFileFlags = [],
        group: UInt32 = 20,
        access: Date? = nil,
        modification: Date? = nil,
        creation: Date? = nil
    ) -> FileAttributes {
        FileAttributes(
            permissions: POSIXPermissions(rawValue: mode),
            flags: flags,
            ownerID: 501,
            groupID: group,
            accessDate: access ?? epoch,
            modificationDate: modification ?? epoch,
            creationDate: creation ?? epoch
        )
    }

    // MARK: - Empty

    @Test("an empty patch is a no-op against any item")
    func emptyPatch() {
        let patch = AttributePatch()
        #expect(patch.isEmpty)
        #expect(patch.diff(against: item()).isEmpty)
        #expect(patch.diff(against: item(mode: 0o777, flags: [.hidden], group: 80)).isEmpty)
    }

    // MARK: - Mode: the mixed-stays-mixed property

    @Test("forcing one bit leaves an untouched, differing bit at each item's own value")
    func mixedBitStaysMixed() {
        // The user turns owner-read ON and touches nothing else. Two items disagree on group-write,
        // which is NOT in the mask — each item's result must keep its own group-write bit.
        var patch = AttributePatch()
        patch.permissionMask[.owner, .read] = true
        patch.permissionValues[.owner, .read] = true

        // Item A: owner-read already off, group-write off (0o400 has neither... use 0o044).
        let itemA = item(mode: 0o044) // r-- for group/other, nothing for owner
        let diffA = patch.diff(against: itemA)
        // owner-read forced on; group-write stays off.
        #expect(diffA.permissions == POSIXPermissions(rawValue: 0o444))

        // Item B: owner-read off, group-write ON (0o064).
        let itemB = item(mode: 0o064)
        let diffB = patch.diff(against: itemB)
        // owner-read forced on; group-write stays ON.
        #expect(diffB.permissions == POSIXPermissions(rawValue: 0o464))

        // Only the mode field is touched by either.
        #expect(diffA.flags == nil && diffA.groupID == nil)
        #expect(diffB.flags == nil && diffB.groupID == nil)
    }

    @Test("forcing a bit to the value the item already has diffs to empty")
    func forcingUnchangedBitIsNoOp() {
        var patch = AttributePatch()
        patch.permissionMask[.owner, .read] = true
        patch.permissionValues[.owner, .read] = true
        // 0o644 already has owner-read on, so forcing it on changes nothing.
        #expect(patch.diff(against: item(mode: 0o644)).permissions == nil)
        #expect(patch.diff(against: item(mode: 0o644)).isEmpty)
    }

    @Test("a special bit is forced through the mask like any other")
    func specialBit() {
        var patch = AttributePatch()
        patch.permissionMask.setUserID = true
        patch.permissionValues.setUserID = true
        let diff = patch.diff(against: item(mode: 0o755))
        #expect(diff.permissions == POSIXPermissions(rawValue: 0o4755))
        // A file that already has it set is unchanged.
        #expect(patch.diff(against: item(mode: 0o4755)).permissions == nil)
    }

    @Test("clearing a bit forces it off while leaving neighbours alone")
    func clearingABit() {
        var patch = AttributePatch()
        patch.permissionMask[.other, .write] = true
        patch.permissionValues[.other, .write] = false
        // 0o666 → other-write off → 0o664, the rest untouched.
        #expect(
            patch.diff(against: item(mode: 0o666)).permissions == POSIXPermissions(rawValue: 0o664)
        )
    }

    // MARK: - Flags

    @Test("flags are forced on/off while every other bit, SF_* included, is preserved")
    func flagsSetAndClear() {
        var patch = AttributePatch()
        patch.flagsToSet = [.hidden]
        patch.flagsToClear = [.userImmutable]

        // Item carries a system flag Dirnex never offers plus the immutable bit we are clearing.
        let current = item(flags: [.userImmutable, .archived])
        let diff = patch.diff(against: current)
        // hidden added, userImmutable removed, archived (SF_ARCHIVED) untouched.
        #expect(diff.flags == [.hidden, .archived])
    }

    @Test("a flag already in the wanted state does not appear in the diff")
    func flagsNoOp() {
        var patch = AttributePatch()
        patch.flagsToSet = [.hidden]
        #expect(patch.diff(against: item(flags: [.hidden])).flags == nil)
    }

    // MARK: - Group and dates

    @Test("group is applied only where it differs, and nil leaves it alone")
    func group() {
        var patch = AttributePatch()
        patch.groupID = 80
        #expect(patch.diff(against: item(group: 20)).groupID == 80)
        #expect(patch.diff(against: item(group: 80)).groupID == nil) // already 80

        var untouched = AttributePatch()
        untouched.flagsToSet = [.hidden] // make it non-empty without touching group
        #expect(untouched.diff(against: item(group: 20)).groupID == nil)
    }

    @Test("each of the three dates is applied only where it differs")
    func dates() {
        let later = epoch.addingTimeInterval(3600)
        var patch = AttributePatch()
        patch.modificationDate = later
        let diff = patch.diff(against: item(modification: epoch))
        #expect(diff.modificationDate == later)
        #expect(diff.accessDate == nil && diff.creationDate == nil)
        // An item already at that mtime is unchanged.
        #expect(patch.diff(against: item(modification: later)).modificationDate == nil)
    }

    // MARK: - isEmpty

    @Test("isEmpty tracks whether anything is forced")
    func isEmptyTracking() {
        #expect(AttributePatch().isEmpty)

        var mode = AttributePatch(); mode.permissionMask[.owner, .read] = true
        #expect(!mode.isEmpty)

        var flag = AttributePatch(); flag.flagsToSet = [.hidden]
        #expect(!flag.isEmpty)

        var grp = AttributePatch(); grp.groupID = 80
        #expect(!grp.isEmpty)

        var date = AttributePatch(); date.creationDate = epoch
        #expect(!date.isEmpty)
    }
}

/// Turning a **single-item edit** into a patch that can travel down a tree (PLAN.md §M14 Slice 4).
///
/// The asymmetry is the whole content: a mode is a shape and carries whole, flags are independent
/// switches and carry bit by bit. Getting the second one wrong is quiet and destructive — it would
/// strip a `UF_HIDDEN` from every file inside a folder whose Locked box was merely ticked.
@Suite("AttributePatch from an edit")
struct AttributePatchFromEditTests {
    private func attributes(
        mode: UInt16 = 0o644,
        flags: BSDFileFlags = [],
        groupID: UInt32 = 20,
        modified: Date = Date(timeIntervalSince1970: 1_000_000)
    ) -> FileAttributes {
        FileAttributes(
            permissions: POSIXPermissions(rawValue: mode),
            flags: flags,
            ownerID: 501,
            groupID: groupID,
            accessDate: Date(timeIntervalSince1970: 500_000),
            modificationDate: modified,
            creationDate: Date(timeIntervalSince1970: 100_000)
        )
    }

    @Test("An untouched edit forces nothing")
    func noChangeIsEmpty() {
        let same = attributes()
        #expect(AttributePatch(from: same, to: same).isEmpty)
    }

    @Test("A changed mode carries whole, so every one of the twelve bits is forced")
    func modeCarriesWhole() {
        let patch = AttributePatch(from: attributes(mode: 0o644), to: attributes(mode: 0o750))

        #expect(patch.permissionMask.rawValue == 0o7777)
        #expect(patch.permissionValues.rawValue == 0o750)
        // And applying it to an item with a completely different mode gives that shape, not a merge.
        #expect(patch.apply(to: attributes(mode: 0o600)).permissions.rawValue == 0o750)
    }

    /// The one that matters. Ticking Locked on a folder must not clear the `UF_HIDDEN` a file inside
    /// it carries — the folder never had that bit, so a whole-word copy would silently strip it.
    @Test("Flags carry bit by bit, so an untouched bit survives on an item that has it")
    func flagsCarryBitByBit() {
        let patch = AttributePatch(
            from: attributes(flags: []), to: attributes(flags: .userImmutable)
        )

        #expect(patch.flagsToSet == .userImmutable)
        #expect(patch.flagsToClear.isEmpty)
        let child = patch.apply(to: attributes(flags: .hidden))
        #expect(child.flags.contains(.hidden), "a bit the edit never touched must survive")
        #expect(child.flags.contains(.userImmutable))
    }

    @Test("Clearing a flag forces it off wherever it is set")
    func clearedFlagIsForcedOff() {
        let patch = AttributePatch(
            from: attributes(flags: [.hidden, .userImmutable]),
            to: attributes(flags: .userImmutable)
        )

        #expect(patch.flagsToClear == .hidden)
        #expect(patch.flagsToSet.isEmpty)
        #expect(!patch.apply(to: attributes(flags: .hidden)).flags.contains(.hidden))
    }

    @Test("Group and dates carry only when they changed")
    func singleValuesCarryWhenChanged() {
        let unchanged = AttributePatch(from: attributes(), to: attributes())
        #expect(unchanged.groupID == nil)
        #expect(unchanged.modificationDate == nil)

        let stamp = Date(timeIntervalSince1970: 2_000_000)
        let changed = AttributePatch(
            from: attributes(), to: attributes(groupID: 80, modified: stamp)
        )
        #expect(changed.groupID == 80)
        #expect(changed.modificationDate == stamp)
        #expect(changed.accessDate == nil, "a date left alone is never forced")
    }

    /// Owner is absent by construction: `chown` to another user is `EPERM` even on your own file, so
    /// it is never offered — in bulk, singly or recursively.
    @Test("Owner never travels, even when the two values differ")
    func ownerNeverTravels() {
        var other = attributes()
        other.ownerID = 31337
        let patch = AttributePatch(from: attributes(), to: other)

        #expect(patch.isEmpty)
        #expect(patch.apply(to: attributes()).ownerID == 501)
    }
}
