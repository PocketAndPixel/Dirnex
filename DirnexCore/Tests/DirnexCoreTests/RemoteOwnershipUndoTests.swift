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
            refusals: [.itemRefused("chown: nosuch: illegal group name")],
            landed: entry()
        ) == nil)
    }
}
