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
