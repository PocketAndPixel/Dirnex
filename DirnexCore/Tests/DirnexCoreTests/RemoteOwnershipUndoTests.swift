import Foundation
import Testing

@testable import DirnexCore

/// Whether an owner or group landed, and how it is put back (PLAN.md §M38 Slice 1).
@Suite("Remote owner and group: read-back and undo")
struct RemoteOwnershipUndoTests {
    private let admin = RemotePrincipal(name: "admin", id: 80)

    private func entry(
        permissions: UInt16? = 0o644,
        owner: String? = "oleg",
        group: String? = "staff"
    ) -> FileEntry {
        RemoteOwnershipFixture.entry(permissions: permissions, owner: owner, group: group)
    }

    // MARK: - Reading it back

    @Test("a group that landed under its name or its number is complete")
    func readBackAccepted() {
        let change = RemoteAttributeChange(group: admin)
        for listed in ["admin", "80"] {
            let verdict = RemoteAttributeVerdict.weigh(
                change,
                refusals: [],
                landed: entry(group: listed)
            )
            #expect(verdict.isComplete, "listed as \(listed)")
        }
    }

    @Test("a clean answer over a group that did not move is reported")
    func readBackRefused() {
        let verdict = RemoteAttributeVerdict.weigh(
            RemoteAttributeChange(owner: RemotePrincipal(name: "root", id: 0), group: admin),
            refusals: [],
            landed: entry()
        )
        #expect(verdict.refused == [.owner, .group])
    }

    @Test("set-id bits lost to the change are the permissions' refusal")
    func lostBitsAreReported() {
        let verdict = RemoteAttributeVerdict.weigh(
            RemoteAttributeChange(permissions: POSIXPermissions(rawValue: 0o6755), group: admin),
            refusals: [],
            landed: entry(permissions: 0o755, group: "admin")
        )
        #expect(verdict.refused == [.permissions])
    }

    @Test("a refused chown names the group and not the mode re-sent beside it")
    func refusedChownLeavesTheModeAlone() {
        // A set-id item's mode goes out with every group change, so blaming every field the change
        // set would report a permissions loss on a mode nobody touched and that reads back exact.
        let verdict = RemoteAttributeVerdict.weigh(
            RemoteAttributeChange(permissions: POSIXPermissions(rawValue: 0o6755), group: admin),
            refusals: [.ownershipRefused("chown: you are not a member of group admin")],
            landed: entry(permissions: 0o6755)
        )
        #expect(verdict.refused == [.group])
        #expect(verdict.serverWords == "chown: you are not a member of group admin")
    }

    @Test("a refused chmod names the mode and not the group that landed")
    func refusedChmodLeavesTheOwnershipAlone() {
        let verdict = RemoteAttributeVerdict.weigh(
            RemoteAttributeChange(permissions: POSIXPermissions(rawValue: 0o600), group: admin),
            refusals: [.itemRefused("remote setstat \"/srv/report.txt\": Permission denied")],
            landed: entry(permissions: 0o644, group: "admin")
        )
        #expect(verdict.refused == [.permissions])
        // Only a `chown`'s words are quoted: this line is the transport's, and is about the path.
        #expect(verdict.serverWords == nil)
    }

    @Test("a re-sent mode refused beside a chown, reading back as asked, has lost nothing")
    func refusedRepairIsNoLoss() {
        // Seen live on an immutable file: the `chown` and the `chmod` behind it were both refused,
        // and the mode nobody had touched was reported as not stored.
        let verdict = RemoteAttributeVerdict.weigh(
            RemoteAttributeChange(permissions: POSIXPermissions(rawValue: 0o6755), group: admin),
            refusals: [
                .ownershipRefused("chown: /srv/report.txt: Operation not permitted"),
                .itemRefused("Couldn't setstat on \"/srv/report.txt\": Operation not permitted")
            ],
            landed: entry(permissions: 0o6755)
        )
        #expect(verdict.refused == [.group])
    }

    @Test("a mode beside a chown that did not land is still reported")
    func refusedModeBesideAChownIsReported() {
        // The narrowness half: the read-back decides, so a mode that really did not arrive is named.
        let verdict = RemoteAttributeVerdict.weigh(
            RemoteAttributeChange(permissions: POSIXPermissions(rawValue: 0o600), group: admin),
            refusals: [
                .ownershipRefused("chown: /srv/report.txt: Operation not permitted"),
                .itemRefused("Couldn't setstat on \"/srv/report.txt\": Operation not permitted")
            ],
            landed: entry(permissions: 0o644)
        )
        #expect(verdict.refused == [.group, .permissions])
    }

    @Test("a chown that printed nothing leaves nothing to quote")
    func emptyRefusalHasNoWords() {
        let verdict = RemoteAttributeVerdict.weigh(
            RemoteAttributeChange(group: admin),
            refusals: [.ownershipRefused("")],
            landed: entry()
        )
        #expect(verdict.refused == [.group])
        #expect(verdict.serverWords == nil)
    }

    // MARK: - What to offer

    @Test("an item in the account's own group offers the account's groups as they are")
    func ownGroupOffersTheList() throws {
        let identity = try RemoteOwnershipFixture.identity()
        #expect(identity.groupChoices(listed: "admin") == identity.groups)
    }

    @Test("an item's group outside the account's still leads the list")
    func strangerGroupLeadsTheList() throws {
        let identity = try RemoteOwnershipFixture.identity()
        let choices = identity.groupChoices(listed: "wheel")
        #expect(choices.first == RemotePrincipal(name: "wheel"))
        #expect(Array(choices.dropFirst()) == identity.groups)
    }

    @Test("a listing's number is the group it stands for, and adds nothing")
    func numberMatchesItsGroup() throws {
        let identity = try RemoteOwnershipFixture.identity()
        #expect(identity.groupChoices(listed: "80") == identity.groups)
    }

    @Test("a listing with no group offers the account's")
    func noListedGroup() throws {
        let identity = try RemoteOwnershipFixture.identity()
        #expect(identity.groupChoices(listed: nil) == identity.groups)
    }

    // MARK: - Undo

    private func undo(
        from previous: FileEntry,
        asked: RemoteAttributeChange,
        refusals: [RemoteMetadataRefusal] = [],
        landed: FileEntry
    ) -> (apply: RemoteAttributeChange, reverse: RemoteAttributeChange)? {
        let verdict = RemoteAttributeVerdict.weigh(asked, refusals: refusals, landed: landed)
        guard let record = UndoRecord.remoteAttributeChange(
            from: previous,
            asked: asked,
            verdict: verdict
        ), case let .restoreRemoteAttributes(_, apply, reverse)? = record.steps.first else {
            return nil
        }
        return (apply, reverse)
    }

    @Test("a group that moved is put back as the listing named it")
    func undoPutsGroupBack() throws {
        let steps = try #require(undo(
            from: entry(),
            asked: RemoteAttributeChange(group: admin),
            landed: entry(group: "admin")
        ))
        #expect(steps.apply.group == RemotePrincipal(name: "staff"))
        #expect(steps.apply.permissions == nil)
        #expect(steps.reverse.group == admin)
    }

    @Test("undoing a group change on a set-id item restores the bits as well")
    func undoKeepsSetIDBits() throws {
        // Save re-sent an unchanged 6755, so no mode moved, and yet putting the group back clears
        // both bits. Without this the undo would succeed and lose them.
        let change = RemoteAttributeChange(
            permissions: POSIXPermissions(rawValue: 0o6755),
            group: admin
        )
        let steps = try #require(undo(
            from: entry(permissions: 0o6755),
            asked: change,
            landed: entry(permissions: 0o6755, group: "admin")
        ))
        #expect(steps.apply.group == RemotePrincipal(name: "staff"))
        #expect(steps.apply.permissions?.rawValue == 0o6755)
        #expect(steps.reverse.permissions?.rawValue == 0o6755)
    }

    @Test("a group the server refused is nothing to put back")
    func undoSkipsRefusedGroup() {
        #expect(undo(
            from: entry(),
            asked: RemoteAttributeChange(group: admin),
            refusals: [.ownershipRefused("chown: nosuch: illegal group name")],
            landed: entry()
        ) == nil)
    }
}
