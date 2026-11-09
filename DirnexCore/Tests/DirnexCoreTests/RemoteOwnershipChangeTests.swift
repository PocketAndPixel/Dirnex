import Foundation
import Testing

@testable import DirnexCore

/// What Get Info may offer, what a change sends, its read-back and its undo (PLAN.md §M38 Slice 1).
@Suite("Remote owner and group: changes")
struct RemoteOwnershipChangeTests {
    private let backendID = RemoteOwnershipFixture.backendID
    private static let macOS = RemoteOwnershipFixture.macOS
    private static let gnu = RemoteOwnershipFixture.gnu
    private static let busyboxRoot = RemoteOwnershipFixture.busyboxRoot

    private func identity(_ line: String = macOS) throws -> RemoteAccountIdentity {
        try RemoteOwnershipFixture.identity(line)
    }

    private func entry(
        permissions: UInt16? = 0o644,
        owner: String? = "oleg",
        group: String? = "staff"
    ) -> FileEntry {
        RemoteOwnershipFixture.entry(permissions: permissions, owner: owner, group: group)
    }

    private let admin = RemotePrincipal(name: "admin", id: 80)
    private let both = RemoteAttributeEditability(editable: [.permissions, .owner, .group])

    private func change(
        on item: FileEntry,
        mode: UInt16? = nil,
        owner: RemotePrincipal? = nil,
        group: RemotePrincipal? = nil,
        editable: RemoteAttributeEditability? = nil
    ) -> RemoteAttributeChange {
        RemoteAttributeChange.between(
            current: item,
            permissions: (mode ?? item.permissions).map { POSIXPermissions(rawValue: $0) },
            modificationTime: nil,
            shownModificationTime: nil,
            owner: owner,
            group: group,
            editable: editable ?? both
        )
    }

    // MARK: - What may be offered

    @Test("a non-root account may change the group of what it owns, and no owner")
    func ownerMayChangeGroup() throws {
        let editable = try RemoteAttributeEditability.decide(
            for: entry(),
            capabilities: .sftp,
            identity: identity()
        )
        #expect(editable.editable == [.permissions, .group])
    }

    @Test("nor anything about an item somebody else owns")
    func strangerGetsNothing() throws {
        let editable = try RemoteAttributeEditability.decide(
            for: entry(owner: "root"),
            capabilities: .sftp,
            identity: identity()
        )
        #expect(!editable.allows(.group))
        #expect(!editable.allows(.owner))
    }

    @Test("a listing that prints numbers still recognises the account")
    func numericListing() throws {
        let editable = try RemoteAttributeEditability.decide(
            for: entry(owner: "501", group: "20"),
            capabilities: .sftp,
            identity: identity()
        )
        #expect(editable.allows(.group))
    }

    @Test("one group, already the item's, leaves nothing to choose")
    func nothingToChoose() throws {
        let identity = try identity(Self.gnu)
        let same = RemoteAttributeEditability.decide(
            for: entry(owner: "www-data", group: "www-data"),
            capabilities: .sftp,
            identity: identity
        )
        #expect(!same.allows(.group))
        let other = RemoteAttributeEditability.decide(
            for: entry(owner: "www-data", group: "staff"),
            capabilities: .sftp,
            identity: identity
        )
        #expect(other.allows(.group))
    }

    @Test("root may change both")
    func rootMayChangeBoth() throws {
        let editable = try RemoteAttributeEditability.decide(
            for: entry(owner: "www-data"),
            capabilities: .sftp,
            identity: identity(Self.busyboxRoot)
        )
        #expect(editable.allows(.owner))
        #expect(editable.allows(.group))
    }

    @Test("with no identity, or a field the listing did not report, nothing is offered")
    func absentMeansNotOffered() throws {
        let unasked = RemoteAttributeEditability.decide(for: entry(), capabilities: .sftp)
        #expect(!unasked.allows(.owner))
        #expect(!unasked.allows(.group))

        let root = try identity(Self.busyboxRoot)
        let noColumns = RemoteAttributeEditability.decide(
            for: entry(owner: nil, group: nil),
            capabilities: .sftp,
            identity: root
        )
        #expect(!noColumns.allows(.owner))
        #expect(!noColumns.allows(.group))
    }

    // MARK: - What a change sends

    @Test("an owner or a group left alone is not sent")
    func untouchedIsDropped() {
        let same = change(
            on: entry(),
            owner: RemotePrincipal(name: "oleg", id: 501),
            group: RemotePrincipal(name: "staff", id: 20)
        )
        #expect(same.isEmpty)
        #expect(same.steps.isEmpty)
    }

    @Test("a field the connection cannot change never reaches the wire")
    func notEditableIsDropped() {
        let attempt = change(
            on: entry(),
            group: admin,
            editable: RemoteAttributeEditability(editable: [.permissions])
        )
        #expect(attempt.isEmpty)
    }

    @Test("the ownership goes before the mode")
    func ownershipGoesFirst() {
        let change = RemoteAttributeChange(
            permissions: POSIXPermissions(rawValue: 0o6755),
            group: admin
        )
        #expect(change.steps == [
            .setOwnership(owner: nil, group: "admin"),
            .setMode(POSIXPermissions(rawValue: 0o6755))
        ])
        #expect(change.fields == [.permissions, .group])
    }

    @Test("a group change on a set-id item sends the mode again, unasked")
    func keepsSetIDBits() {
        for mode: UInt16 in [0o6755, 0o4755, 0o2755] {
            let change = change(on: entry(permissions: mode), group: admin)
            #expect(change.group == admin)
            #expect(change.permissions?.rawValue == mode)
        }
    }

    @Test("an owner change does the same")
    func ownerChangeKeepsSetIDBits() {
        let change = change(
            on: entry(permissions: 0o4755),
            owner: RemotePrincipal(name: "root", id: 0)
        )
        #expect(change.permissions?.rawValue == 0o4755)
    }

    @Test("nothing to protect sends no mode")
    func noSetIDSendsNoMode() {
        #expect(change(on: entry(permissions: 0o755), group: admin).permissions == nil)
        // The sticky bit is not one a `chown` clears.
        #expect(change(on: entry(permissions: 0o1755), group: admin).permissions == nil)
        #expect(change(on: entry(permissions: nil), group: admin).permissions == nil)
    }

    @Test("no ownership change leaves a set-id item's mode unsent")
    func noOwnershipChangeSendsNoMode() {
        #expect(change(on: entry(permissions: 0o6755), group: nil).isEmpty)
    }

    @Test("the mode the user asked for wins over the one on the item")
    func askedModeIsKept() {
        let change = change(on: entry(permissions: 0o6755), mode: 0o755, group: admin)
        #expect(change.permissions?.rawValue == 0o755)
    }

    @Test("a mode the connection cannot write is not sent to protect the bits")
    func cannotProtectWithoutChmod() {
        let change = change(
            on: entry(permissions: 0o6755),
            group: admin,
            editable: RemoteAttributeEditability(editable: [.group])
        )
        #expect(change.group == admin)
        #expect(change.permissions == nil)
    }

    @Test("a journal written before these fields still decodes")
    func decodesOlderJournals() throws {
        let change = try JSONDecoder().decode(
            RemoteAttributeChange.self,
            from: Data(#"{"permissions":{"rawValue":420}}"#.utf8)
        )
        #expect(change.permissions?.rawValue == 0o644)
        #expect(change.owner == nil)
        #expect(change.group == nil)
    }

    @Test("a change survives the journal's round trip")
    func roundTrips() throws {
        let change = RemoteAttributeChange(
            permissions: POSIXPermissions(rawValue: 0o755),
            owner: RemotePrincipal(name: "root", id: 0),
            group: admin
        )
        let data = try JSONEncoder().encode(change)
        #expect(try JSONDecoder().decode(RemoteAttributeChange.self, from: data) == change)
    }
}
