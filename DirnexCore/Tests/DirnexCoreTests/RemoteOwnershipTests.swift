import Foundation
import Testing

@testable import DirnexCore

/// Real `id` output, captured 2026-11-09 from a Mac, GNU coreutils and busybox.
enum RemoteOwnershipFixture {
    static let macOS = """
    uid=501(oleg) gid=20(staff) groups=20(staff),12(everyone),61(localaccounts),80(admin)
    """
    static let gnu = "uid=33(www-data) gid=33(www-data) groups=33(www-data)"
    static let busyboxRoot = """
    uid=0(root) gid=0(root) groups=0(root),1(bin),2(daemon),3(sys),4(adm),6(disk),10(wheel)
    """
    static let unnamed = "uid=1234 gid=5678 groups=5678"
    static let backendID = VFSBackendID.sftp(SFTPLocation(host: "srv", username: "oleg"))

    static func identity(_ line: String = macOS) throws -> RemoteAccountIdentity {
        try #require(RemoteAccountIdentity.parse(line))
    }

    static func entry(
        permissions: UInt16? = 0o644,
        owner: String? = "oleg",
        group: String? = "staff"
    ) -> FileEntry {
        FileEntry(
            path: VFSPath(backend: backendID, path: "/srv/report.txt"),
            name: "report.txt",
            kind: .file,
            byteSize: 12,
            modificationDate: Date(timeIntervalSince1970: 1_700_000_000),
            creationDate: FileEntry.unknownDate,
            isHidden: false,
            permissions: permissions,
            ownerName: owner,
            groupName: group,
            inode: 1
        )
    }
}

/// Reading who an account is, and the command that changes an owner or group (PLAN.md §M38 Slice 1).
@Suite("Remote owner and group: reading and commands")
struct RemoteOwnershipTests {
    private func identity(_ line: String = RemoteOwnershipFixture.macOS) throws -> RemoteAccountIdentity {
        try RemoteOwnershipFixture.identity(line)
    }

    private static let gnu = RemoteOwnershipFixture.gnu
    private static let busyboxRoot = RemoteOwnershipFixture.busyboxRoot
    private static let unnamed = RemoteOwnershipFixture.unnamed

    // MARK: - Reading `id`

    @Test("a Mac's id line gives the user and every group, primary first")
    func readsMacOutput() throws {
        let identity = try identity()
        #expect(identity.user == RemotePrincipal(name: "oleg", id: 501))
        #expect(identity.groups.map(\.name) == ["staff", "everyone", "localaccounts", "admin"])
        #expect(identity.groups.first?.id == 20)
        #expect(!identity.isSuperuser)
    }

    @Test("GNU's and busybox's lines read the same way")
    func readsLinuxOutput() throws {
        #expect(try identity(Self.gnu).user == RemotePrincipal(name: "www-data", id: 33))
        #expect(try identity(Self.gnu).groups.map(\.name) == ["www-data"])
        let root = try identity(Self.busyboxRoot)
        #expect(root.isSuperuser)
        #expect(root.groups.count == 7)
        #expect(root.groups.last == RemotePrincipal(name: "wheel", id: 10))
    }

    @Test("an id with no name is carried as its number")
    func readsUnnamedIDs() throws {
        let identity = try identity(Self.unnamed)
        #expect(identity.user == RemotePrincipal(name: "1234", id: 1234))
        #expect(identity.groups == [RemotePrincipal(name: "5678", id: 5678)])
    }

    @Test("what an rc file printed before the command is passed over")
    func passesOverRCNoise() throws {
        let identity = try identity("Welcome back!\nuid=7 is my lucky number\n\(Self.gnu)\n")
        #expect(identity.user.name == "www-data")
    }

    @Test(
        "prose from an account with no shell is not an identity",
        arguments: [
            "This service allows sftp connections only.\n",
            "Permission denied, please try again.\n",
            "",
            "uid=abc gid=20\n",
            "uid=501(oleg)\n"
        ]
    )
    func refusesProse(_ output: String) {
        #expect(RemoteAccountIdentity.parse(output) == nil)
    }

    @Test("a directory service's names can hold spaces and parentheses")
    func readsAwkwardNames() throws {
        let identity = try identity(
            "uid=1001(jo) gid=513(domain users) groups=513(domain users),1100(web (prod)),1200(ops)"
        )
        #expect(identity.groups.map(\.name) == ["domain users", "web (prod)", "ops"])
    }

    @Test("what can follow or be left out does not get in the way")
    func readsOptionalParts() throws {
        let selinux = try identity(
            "uid=1000(deploy) gid=1000(deploy) groups=1000(deploy),10(wheel) context=unconfined_u:s0"
        )
        #expect(selinux.groups.map(\.name) == ["deploy", "wheel"])

        let setID = try identity(
            "uid=1000(a) gid=1000(a) euid=0(root) egid=0(root) groups=1000(a),4(adm)"
        )
        #expect(setID.groups.map(\.name) == ["a", "adm"])

        let noGroups = try identity("uid=1000(a) gid=1000(a)")
        #expect(noGroups.groups.map(\.name) == ["a"])
    }

    @Test("the primary group comes first, once, wherever the list put it")
    func primaryGroupComesFirst() throws {
        let identity = try identity("uid=1(a) gid=2(b) groups=3(c),2(b),3(c)")
        #expect(identity.groups.map(\.name) == ["b", "c"])
    }

    // MARK: - The command

    @Test("a group alone is one chown, with the dashes before the operand")
    func changesGroupAlone() {
        #expect(
            SSHOwnershipCommand.change(owner: nil, group: "admin", of: "/srv/a.txt")
                == "/usr/bin/env chown -h -- ':admin' '/srv/a.txt' 2>&1 "
                + "&& /usr/bin/env echo dirnex-chown-ok"
        )
    }

    @Test("an owner and a group go together, and an owner alone stands alone")
    func changesOwner() throws {
        let both = try #require(SSHOwnershipCommand.change(owner: "oleg", group: "admin", of: "/a"))
        #expect(both.contains("-- 'oleg:admin' '/a'"))
        let owner = try #require(SSHOwnershipCommand.change(owner: "oleg", group: nil, of: "/a"))
        #expect(owner.contains("-- 'oleg' '/a'"))
    }

    @Test("a name from a stranger's listing cannot reach the shell")
    func quotesWhatItSends() throws {
        let command = try #require(SSHOwnershipCommand.change(
            owner: nil,
            group: "a'; touch CANARY; echo '",
            of: "/srv/it's $a.txt"
        ))
        #expect(command.contains(#"':a'\''; touch CANARY; echo '\'''"#))
        #expect(command.contains(#"'/srv/it'\''s $a.txt'"#))
    }

    @Test("nothing to change, or a name that would split in two, sends nothing")
    func refusesToBuild() {
        #expect(SSHOwnershipCommand.change(owner: nil, group: nil, of: "/a") == nil)
        #expect(SSHOwnershipCommand.change(owner: "a:b", group: nil, of: "/a") == nil)
        #expect(SSHOwnershipCommand.change(owner: nil, group: "a:b", of: "/a") == nil)
    }

    @Test("only the token says it ran, wherever an rc file wrote first")
    func readsSuccess() {
        #expect(SSHOwnershipCommand.refusal(in: "dirnex-chown-ok\n") == nil)
        #expect(SSHOwnershipCommand.refusal(in: "motd line\ndirnex-chown-ok\n") == nil)
    }

    @Test(
        "a refusal keeps the server's own sentence",
        arguments: [
            ("chown: nosuch: illegal group name\n", "chown: nosuch: illegal group name"),
            ("chown: invalid group: ':nosuch'\n", "chown: invalid group: ':nosuch'"),
            ("chown: unknown group nosuch\n", "chown: unknown group nosuch"),
            (
                "This service allows sftp connections only.\n",
                "This service allows sftp connections only."
            )
        ]
    )
    func readsRefusals(_ output: String, _ words: String) {
        #expect(SSHOwnershipCommand.refusal(in: output) == .itemRefused(words))
    }

    @Test("a command that could not be asked is a refusal too")
    func noAnswerIsARefusal() {
        #expect(SSHOwnershipCommand.refusal(in: nil) == .itemRefused(""))
    }
}
