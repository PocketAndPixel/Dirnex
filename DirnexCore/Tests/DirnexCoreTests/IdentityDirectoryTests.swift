import Foundation
import Testing

@testable import DirnexCore

/// The roster rules are pinned against fixtures so they hold on any Mac; the enumeration itself is
/// checked against the accounts that must exist on every Mac, and against `dscl`, which is the OS's
/// own answer to the same question.
@Suite("IdentityDirectory")
struct IdentityDirectoryTests {
    // MARK: - The pure roster

    @Test("duplicate records collapse, keeping first-seen order")
    func deduplicates() {
        // The exact shape `getpwent` returns on this Mac: every record twice.
        let raw = [
            IdentityRecord(name: "root", numericID: 0),
            IdentityRecord(name: "root", numericID: 0),
            IdentityRecord(name: "oleg", numericID: 501),
            IdentityRecord(name: "oleg", numericID: 501)
        ]
        #expect(IdentityRoster.deduplicated(raw).map(\.name) == ["root", "oleg"])
    }

    @Test("two accounts sharing a name but not an id both survive")
    func deduplicatesOnTheWholeRecord() {
        let raw = [
            IdentityRecord(name: "staff", numericID: 20),
            IdentityRecord(name: "staff", numericID: 21)
        ]
        #expect(IdentityRoster.deduplicated(raw).count == 2)
    }

    @Test("service accounts are hidden by their leading underscore")
    func hidesServiceAccounts() {
        #expect(IdentityRecord(name: "_spotlight", numericID: 89).isServiceAccount)
        #expect(!IdentityRecord(name: "staff", numericID: 20).isServiceAccount)
    }

    /// The finding that decides the filter. A numeric "real accounts start at 500" rule is the
    /// tempting one and it is wrong: it would hide every group an ACL entry actually names.
    @Test("the low-numbered groups an ACL names survive the filter")
    func keepsWellKnownGroups() {
        let raw = [
            IdentityRecord(name: "wheel", numericID: 0),
            IdentityRecord(name: "everyone", numericID: 12),
            IdentityRecord(name: "staff", numericID: 20),
            IdentityRecord(name: "admin", numericID: 80),
            IdentityRecord(name: "_windowserver", numericID: 88)
        ]
        let visible = IdentityRoster.visible(raw)
        #expect(visible.map(\.name) == ["admin", "everyone", "staff", "wheel"])
    }

    @Test("visible records are sorted by name, case-insensitively")
    func sortsByName() {
        let raw = [
            IdentityRecord(name: "zulu", numericID: 3),
            IdentityRecord(name: "Alpha", numericID: 1),
            IdentityRecord(name: "mike", numericID: 2)
        ]
        #expect(IdentityRoster.visible(raw).map(\.name) == ["Alpha", "mike", "zulu"])
    }

    // MARK: - What a group picker may offer

    private var machineGroups: [IdentityRecord] {
        [
            IdentityRecord(name: "wheel", numericID: 0),
            IdentityRecord(name: "daemon", numericID: 1),
            IdentityRecord(name: "everyone", numericID: 12),
            IdentityRecord(name: "staff", numericID: 20),
            IdentityRecord(name: "admin", numericID: 80),
            IdentityRecord(name: "_windowserver", numericID: 88)
        ]
    }

    /// `chgrp` to a group the caller is not in is `EPERM` even on their own file, so the picker
    /// offers only what will actually apply rather than the machine's other ~150 groups.
    @Test("only the actor's own groups are offered")
    func offersOnlyOwnGroups() {
        let offered = IdentityRoster.selectableGroups(
            from: machineGroups, memberOf: [12, 20, 80], current: 20
        )
        #expect(offered.map(\.name) == ["admin", "everyone", "staff"])
    }

    /// A file's group is inherited from its parent, so sitting in a group the user is not in is
    /// ordinary — and a popup that cannot name its own current value would show the wrong one.
    @Test("the item's current group is offered even when the actor is not in it")
    func alwaysOffersTheCurrentGroup() {
        let offered = IdentityRoster.selectableGroups(
            from: machineGroups, memberOf: [20], current: 0
        )
        #expect(offered.map(\.name) == ["staff", "wheel"])
    }

    /// Same rule when the current group is a service account: it is what the item *is*, so it shows.
    @Test("a service account is offered when it is the current group")
    func offersTheCurrentServiceGroup() {
        let offered = IdentityRoster.selectableGroups(
            from: machineGroups, memberOf: [20], current: 88
        )
        #expect(offered.map(\.name) == ["_windowserver", "staff"])
    }

    /// A gid that resolves to no group at all still has to be displayable — the panel already
    /// renders a bare number in that case, and the popup must agree with it.
    @Test("a current gid with no group behind it becomes a numeric row")
    func offersAnUnknownCurrentGroupAsANumber() {
        let offered = IdentityRoster.selectableGroups(
            from: machineGroups, memberOf: [20], current: 4242
        )
        #expect(offered.map(\.name) == ["4242", "staff"])
    }

    @Test("service accounts the actor belongs to are still hidden when they are not current")
    func hidesServiceGroupsTheActorIsIn() {
        let offered = IdentityRoster.selectableGroups(
            from: machineGroups, memberOf: [20, 88], current: 20
        )
        #expect(offered.map(\.name) == ["staff"])
    }

    /// The live pairing the panel actually runs: whatever the machine reports, the running user's
    /// own group is offered and every offered group is one they are really in.
    @Test("the live roster offers the running user's own group")
    func liveRosterIncludesTheCurrentGroup() {
        let actor = UserContext.current()
        let offered = IdentityRoster.selectableGroups(
            from: IdentityDirectory.groups(), memberOf: actor.groupIDs, current: getgid()
        )
        #expect(offered.contains { $0.numericID == getgid() })
        #expect(offered.allSatisfy { actor.groupIDs.contains($0.numericID) })
    }

    // MARK: - The live enumeration

    @Test("the enumeration returns no duplicates, whatever Open Directory hands back")
    func enumeratesWithoutDuplicates() {
        let users = IdentityDirectory.users()
        #expect(Set(users).count == users.count)
        let groups = IdentityDirectory.groups()
        #expect(Set(groups).count == groups.count)
    }

    /// `dscl . list` is the OS answering the same question a different way. It is what caught the
    /// doubling in the first place: 322 raw `getgrent` records against 161 real groups.
    @Test("the de-duplicated count matches what dscl reports")
    func agreesWithDirectoryServices() throws {
        func dsclCount(_ node: String) throws -> Int {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/dscl")
            process.arguments = [".", "list", node]
            let pipe = Pipe()
            process.standardOutput = pipe
            try process.run()
            let output = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return (String(bytes: output, encoding: .utf8) ?? "")
                .split(whereSeparator: \.isNewline).count
        }
        #expect(IdentityDirectory.users().count == (try dsclCount("/Users")))
        #expect(IdentityDirectory.groups().count == (try dsclCount("/Groups")))
    }

    @Test("the accounts every Mac has are found, and an absent one is nil")
    func resolvesNames() {
        #expect(IdentityDirectory.userName(for: 0) == "root")
        #expect(IdentityDirectory.groupName(for: 0) == "wheel")
        #expect(IdentityDirectory.userID(for: "root") == 0)
        #expect(IdentityDirectory.groupID(for: "staff") == 20)
        #expect(IdentityDirectory.userName(for: 31337) == nil)
        #expect(IdentityDirectory.userID(for: "no.such.account") == nil)
    }

    @Test("the running user resolves both ways")
    func resolvesTheCurrentUser() throws {
        let name = try #require(IdentityDirectory.userName(for: getuid()))
        #expect(IdentityDirectory.userID(for: name) == getuid())
    }

    // MARK: - Subject construction

    @Test("a chosen account becomes a complete ACL subject")
    func buildsSubjects() throws {
        let group = IdentityRecord(name: "staff", numericID: 20)
        let subject = try #require(ACLIdentity.subject(for: group, kind: .group))
        #expect(subject.kind == .group)
        #expect(subject.name == "staff")
        #expect(subject.numericID == 20)
        // The well-known group GUID form, confirmed against the OS's own answer.
        #expect(subject.guid == "ABCDEFAB-CDEF-ABCD-EFAB-CDEF00000014")
    }

    /// A GUID coming back is **not** an existence check — `mbr_uid_to_uuid` synthesizes one from the
    /// numeric id for an account that does not exist. Pinned so nobody later uses it as a validator.
    @Test("an id with no account still yields a GUID, so it cannot validate a picker's input")
    func guidIsNotAnExistenceCheck() throws {
        let ghost = IdentityRecord(name: "ghost", numericID: 31337)
        #expect(ACLIdentity.subject(for: ghost, kind: .user) != nil)
        #expect(IdentityDirectory.userName(for: 31337) == nil)
    }
}
