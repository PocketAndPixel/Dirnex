import Foundation
import Testing

@testable import DirnexCore

/// The elevated command is the security-critical seam of Slice 5 (PLAN.md §M14): its output ends up
/// on a shell running as **root**, so the two things pinned hardest here are that every path is
/// quoted (never interpolated raw) and that the two aspects stock CLI cannot reproduce — the Created
/// date and a non-reproducible ACL — are *named* rather than silently dropped. The CLI translation
/// itself is also proven live against the OS by a throwaway harness; these tests pin the string it
/// builds so a regression is loud.
@Suite("EscalatedAttributeCommand")
struct EscalatedAttributeCommandTests {
    private let epoch = Date(timeIntervalSince1970: 1_000_000)
    private let path = "/tmp/f.txt"

    private func attributes(
        mode: UInt16 = 0o644,
        flags: BSDFileFlags = [],
        owner: UInt32 = 501,
        group: UInt32 = 20,
        access: Date? = nil,
        modification: Date? = nil,
        creation: Date? = nil
    ) -> FileAttributes {
        FileAttributes(
            permissions: POSIXPermissions(rawValue: mode),
            flags: flags,
            ownerID: owner,
            groupID: group,
            accessDate: access ?? epoch,
            modificationDate: modification ?? epoch,
            creationDate: creation ?? epoch
        )
    }

    private func command(
        from current: FileAttributes,
        to desired: FileAttributes,
        actsOnLink: Bool = false,
        acl: AccessControlList? = nil
    ) -> EscalatedAttributeCommand {
        let plan = AttributeChangePlan(
            diff: AttributeDiff(from: current, to: desired),
            current: current,
            actsOnLink: actsOnLink,
            accessControlList: acl
        )
        return EscalatedAttributeCommand.build(for: plan, path: path, current: current)
    }

    private func aclEntry(
        kind: ACLSubjectKind = .group,
        guid: String = "ABCDEFAB-CDEF-ABCD-EFAB-CDEF0000000C",
        name: String = "everyone",
        numericID: UInt32? = 12,
        disposition: ACLDisposition = .allow,
        inheritance: ACLInheritance = [],
        rights: Set<ACLRight> = [.read, .write],
        unrecognizedRights: [String] = [],
        unrecognizedFlags: [String] = []
    ) -> ACLEntry {
        ACLEntry(
            subject: ACLSubject(kind: kind, guid: guid, name: name, numericID: numericID),
            disposition: disposition,
            inheritance: inheritance,
            rights: rights,
            unrecognizedRights: unrecognizedRights,
            unrecognizedFlags: unrecognizedFlags
        )
    }

    // MARK: - The POSIX core

    @Test("an empty plan is an empty command")
    func empty() {
        let result = command(from: attributes(), to: attributes())
        #expect(result.scriptBody.isEmpty)
        #expect(!result.hasCommands)
        #expect(result.omissions.isEmpty)
        #expect(result.terminalCommand == nil)
    }

    @Test("a plain mode change is one chmod against the quoted path")
    func plainMode() {
        let result = command(from: attributes(mode: 0o644), to: attributes(mode: 0o600))
        #expect(result.scriptBody == "/bin/chmod 600 '/tmp/f.txt'")
        #expect(result.omissions.isEmpty)
    }

    @Test("the setuid digit survives into the chmod argument")
    func setuidMode() {
        let result = command(from: attributes(mode: 0o755), to: attributes(mode: 0o4755))
        #expect(result.scriptBody == "/bin/chmod 4755 '/tmp/f.txt'")
    }

    /// The reachable escalation case: an owner's own file carrying `SF_IMMUTABLE`. The command must
    /// clear the system-immutable bit, apply, and restore it — the CLI shape of the unlock/relock
    /// ``AttributeChangePlan`` encodes, which no unprivileged owner could run.
    @Test("a system-immutable file's mode change is unlock, chmod, relock")
    func systemImmutableUnlockDance() {
        let result = command(
            from: attributes(mode: 0o644, flags: .systemImmutable),
            to: attributes(mode: 0o600, flags: .systemImmutable)
        )
        #expect(result.scriptBody == [
            "/usr/bin/chflags noschg '/tmp/f.txt'",
            "/bin/chmod 600 '/tmp/f.txt'",
            "/usr/bin/chflags schg '/tmp/f.txt'"
        ].joined(separator: " && "))
    }

    /// `chflags` is additive, so a flags change is emitted as the minimal delta — flipping Hidden on a
    /// file that is also Locked must not re-assert `uchg`, or a later reader cannot tell what changed.
    @Test("a flags change is the minimal keyword delta, leaving untouched bits alone")
    func minimalFlagsDelta() {
        let result = command(
            from: attributes(flags: .userImmutable),
            to: attributes(flags: [.userImmutable, .hidden])
        )
        #expect(result.scriptBody == "/usr/bin/chflags hidden '/tmp/f.txt'")
    }

    @Test("clearing a flag emits its no-keyword")
    func clearingFlag() {
        let result = command(from: attributes(flags: .hidden), to: attributes(flags: []))
        #expect(result.scriptBody == "/usr/bin/chflags nohidden '/tmp/f.txt'")
    }

    @Test("a group-only change is a numeric chgrp")
    func groupOnly() {
        let result = command(from: attributes(group: 20), to: attributes(group: 80))
        #expect(result.scriptBody == "/usr/bin/chgrp 80 '/tmp/f.txt'")
    }

    /// A plain `chgrp` is a `chown` and clears the set-uid/gid bits, so the plan re-writes the mode
    /// after it — the command has to carry that repair `chmod` too, in that order.
    @Test("a group change on a setuid file re-writes the mode after the chgrp")
    func groupPreservesSetuid() {
        let result = command(
            from: attributes(mode: 0o6755, group: 20),
            to: attributes(mode: 0o6755, group: 80)
        )
        #expect(
            result.scriptBody == "/usr/bin/chgrp 80 '/tmp/f.txt' && /bin/chmod 6755 '/tmp/f.txt'"
        )
    }

    @Test("an owner change is a numeric chown uid:gid")
    func ownerAndGroup() {
        let result = command(
            from: attributes(owner: 501, group: 20),
            to: attributes(owner: 0, group: 0)
        )
        #expect(result.scriptBody == "/usr/sbin/chown 0:0 '/tmp/f.txt'")
    }

    // MARK: - Times

    @Test("only the changed time is touched, so the untouched one keeps its sub-second value")
    func onlyModificationTime() {
        let result = command(
            from: attributes(),
            to: attributes(modification: epoch.addingTimeInterval(100))
        )
        #expect(result.scriptBody.contains("/usr/bin/touch -m -t "))
        #expect(!result.scriptBody.contains("-a -t"))
        #expect(result.scriptBody.contains("'/tmp/f.txt'"))
    }

    @Test("changing both times is two touches, since touch -t sets one value")
    func bothTimes() {
        let result = command(
            from: attributes(),
            to: attributes(
                access: epoch.addingTimeInterval(50),
                modification: epoch.addingTimeInterval(100)
            )
        )
        #expect(result.scriptBody.contains("/usr/bin/touch -a -t "))
        #expect(result.scriptBody.contains("/usr/bin/touch -m -t "))
    }

    // MARK: - The two omissions

    @Test("the Created date is omitted and named, never reproduced")
    func creationDateOmitted() {
        let result = command(
            from: attributes(creation: epoch),
            to: attributes(creation: epoch.addingTimeInterval(100))
        )
        #expect(result.scriptBody.isEmpty)
        #expect(!result.hasCommands)
        #expect(result.omissions == [.creationDate])
        #expect(result.terminalCommand == nil)
    }

    @Test("a Created-date change alongside a mode change omits only the date")
    func creationDateOmittedButModeKept() {
        let result = command(
            from: attributes(mode: 0o644, creation: epoch),
            to: attributes(mode: 0o600, creation: epoch.addingTimeInterval(100))
        )
        #expect(result.scriptBody == "/bin/chmod 600 '/tmp/f.txt'")
        #expect(result.omissions == [.creationDate])
    }
}

// The ACL, symlink, injection and ordering cases, split off so neither half of the suite trips
// SwiftLint's `type_body_length` — the same by-concept split the app controllers use. The helpers
// are `private` on the struct above and reachable here because this extension is in the same file.
extension EscalatedAttributeCommandTests {
    // MARK: - ACL

    @Test("an explicit resolved ACL is cleared and rebuilt in order with chmod +a#")
    func explicitACL() {
        let list = AccessControlList(entries: [
            aclEntry(name: "everyone", rights: [.read, .write]),
            aclEntry(kind: .user, name: "oleg", numericID: 501, disposition: .deny, rights: [.write])
        ])
        let result = command(from: attributes(), to: attributes(), acl: list)
        #expect(result.scriptBody == [
            "/bin/chmod -N '/tmp/f.txt'",
            "/bin/chmod +a# 0 'group:everyone allow read,write' '/tmp/f.txt'",
            "/bin/chmod +a# 1 'user:oleg deny write' '/tmp/f.txt'"
        ].joined(separator: " && "))
        #expect(result.omissions.isEmpty)
    }

    @Test("an empty ACL removes the list with chmod -N")
    func emptyACL() {
        let result = command(from: attributes(), to: attributes(), acl: AccessControlList())
        #expect(result.scriptBody == "/bin/chmod -N '/tmp/f.txt'")
        #expect(result.omissions.isEmpty)
    }

    @Test("an inherited entry makes the whole ACL an omission, not a wrong reproduction")
    func inheritedACLOmitted() {
        let list = AccessControlList(entries: [aclEntry(inheritance: .inherited, rights: [.read])])
        let result = command(from: attributes(), to: attributes(), acl: list)
        #expect(result.scriptBody.isEmpty)
        #expect(result.omissions == [.accessControlList])
    }

    @Test("an unresolved GUID subject makes the whole ACL an omission (chmod rejects a bare GUID)")
    func unresolvedSubjectOmitted() {
        let list = AccessControlList(entries: [aclEntry(name: "", numericID: nil, rights: [.read])])
        let result = command(from: attributes(), to: attributes(), acl: list)
        #expect(result.omissions == [.accessControlList])
    }

    @Test(
        "a right this build only keeps verbatim makes the ACL an omission rather than a lossy write"
    )
    func unrecognizedRightOmitted() {
        let list = AccessControlList(
            entries: [aclEntry(rights: [.read], unrecognizedRights: ["future_right"])]
        )
        let result = command(from: attributes(), to: attributes(), acl: list)
        #expect(result.omissions == [.accessControlList])
    }

    @Test("a directory ACL's inheritance controls are carried in the chmod spec")
    func directoryInheritanceInSpec() {
        let list = AccessControlList(entries: [
            aclEntry(inheritance: [.fileInherit, .directoryInherit], rights: [.read])
        ])
        let result = command(from: attributes(), to: attributes(), acl: list)
        #expect(result.scriptBody.contains(
            "+a# 0 'group:everyone allow read,file_inherit,directory_inherit'"
        ))
    }

    // MARK: - Symlinks

    @Test("acting on a symlink gives every tool the -h flag")
    func symlinkFlag() {
        let list = AccessControlList(entries: [aclEntry(rights: [.read])])
        let result = command(
            from: attributes(mode: 0o755, group: 20),
            to: attributes(mode: 0o700, group: 80),
            actsOnLink: true,
            acl: list
        )
        #expect(result.scriptBody.contains("/bin/chmod -h 700 "))
        #expect(result.scriptBody.contains("/usr/bin/chgrp -h 80 "))
        #expect(result.scriptBody.contains("/bin/chmod -h -N "))
        #expect(result.scriptBody.contains("/bin/chmod -h +a# 0 "))
    }

    // MARK: - Injection

    /// The whole point of the type: a file name is attacker-controlled and the command runs as root,
    /// so the path may appear *only* as its `ShellQuoting` form — never interpolated raw.
    @Test("a hostile file name is quoted, never interpolated raw")
    func hostileNameQuoted() {
        let hostile = "/tmp/it's a \"x\" $(touch pwned)\n; rm -rf /"
        let plan = AttributeChangePlan(
            diff: AttributeDiff(from: attributes(mode: 0o644), to: attributes(mode: 0o600)),
            current: attributes(mode: 0o644),
            actsOnLink: false
        )
        let result = EscalatedAttributeCommand.build(
            for: plan,
            path: hostile,
            current: attributes(mode: 0o644)
        )
        // The path appears *only* as its single-quoted form — the substitution is present but inert,
        // wrapped in single quotes where `$`, `(` and the newline are all literal. Equality against
        // `ShellQuoting.quoted` is the whole proof: there is no unquoted copy of the name anywhere.
        #expect(result.scriptBody == "/bin/chmod 600 \(ShellQuoting.quoted(hostile, for: .other))")
    }

    @Test("a hostile ACL subject name is quoted inside the +a# spec")
    func hostileSubjectQuoted() {
        let list = AccessControlList(
            entries: [aclEntry(kind: .user, name: "ev'il", numericID: 999, rights: [.read])]
        )
        let result = command(from: attributes(), to: attributes(), acl: list)
        let spec = "user:ev'il allow read"
        #expect(result.scriptBody.contains("+a# 0 \(ShellQuoting.quoted(spec, for: .other)) "))
    }

    // MARK: - The two escalation surfaces share one body

    @Test("the terminal command wraps the same body in sudo /bin/sh -c")
    func terminalWrapsBody() {
        let result = command(from: attributes(mode: 0o644), to: attributes(mode: 0o600))
        let quotedBody = ShellQuoting.quoted(result.scriptBody, for: .other)
        #expect(result.terminalCommand == "sudo /bin/sh -c \(quotedBody)")
    }

    // MARK: - Ordering

    /// The full shape in one plan: unlock a locked file, change its group, its mode, its time, its
    /// ACL, then relock — in exactly that order, which is `AttributeChangePlan`'s and must survive the
    /// translation.
    @Test("a full plan keeps the plan's step order")
    func fullOrder() {
        let list = AccessControlList(entries: [aclEntry(rights: [.read])])
        let result = command(
            from: attributes(mode: 0o644, flags: .userImmutable, group: 20),
            to: attributes(
                mode: 0o600,
                flags: .userImmutable,
                group: 80,
                modification: epoch.addingTimeInterval(100)
            ),
            acl: list
        )
        let body = result.scriptBody
        let order = [
            "chflags nouchg",
            "/usr/bin/chgrp 80",
            "/bin/chmod 600",
            "/usr/bin/touch -m",
            "/bin/chmod -N",
            "/bin/chmod +a# 0",
            "chflags uchg"
        ]
        var searchFrom = body.startIndex
        for token in order {
            guard let range = body.range(of: token, range: searchFrom..<body.endIndex) else {
                Issue.record("token \(token) missing or out of order in: \(body)")
                return
            }
            searchFrom = range.upperBound
        }
    }
}
