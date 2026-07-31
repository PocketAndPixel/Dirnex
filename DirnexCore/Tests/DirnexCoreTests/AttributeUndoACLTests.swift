import Foundation
import Testing

@testable import DirnexCore

/// Undo and redo of an **access-control-list** change, against real temp files with the OS reading
/// the result back — split from ``AttributeUndoTests`` by concept when that suite reached SwiftLint's
/// `type_body_length` (docs/NOTES.md §"Lint ceilings").
///
/// The step carries **whole lists** in both directions rather than a diff, because entry order is
/// meaning: "entry 2 changed" cannot describe an edit that also moved it, and the list the user had
/// is the only description that is always right. Two cases here exist because they are the ones a
/// field would get wrong — an empty list is a real state to restore ("there was no ACL"), and a file
/// still locked at undo time needs the same unlock/relock the forward change did, since
/// `acl_set_file` is EPERM while `UF_IMMUTABLE` is set.
@Suite("AttributeUndo — access control lists")
struct AttributeUndoACLTests {
    private let backend = LocalBackend()

    private func read(_ path: VFSPath) throws -> FileAttributes {
        try FileAttributeIO.read(at: path).attributes
    }

    private func meSubject() throws -> ACLSubject {
        let uid = getuid()
        return ACLSubject(
            kind: .user,
            guid: try #require(ACLIdentity.guid(forUserID: uid)),
            name: NSUserName(),
            numericID: uid
        )
    }

    @Test("undoing an ACL change puts the whole list back, in order")
    func undoRestoresACL() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        let path = VFSPath.local(try tree.writeFile("f.txt", contents: "hi"))
        let subject = try meSubject()

        let old = AccessControlList(entries: [
            ACLEntry(subject: subject, disposition: .allow, rights: [.read])
        ])
        let new = AccessControlList(entries: [
            ACLEntry(subject: subject, disposition: .deny, rights: [.delete]),
            ACLEntry(subject: subject, disposition: .allow, rights: [.read, .write])
        ])
        try AccessControlListIO.write(old, to: path)
        try AccessControlListIO.write(new, to: path)

        let attributes = try read(path)
        let record = try #require(UndoRecord.attributeChange(
            at: path, actsOnLink: false, from: attributes, to: attributes,
            accessControlList: (old: old, new: new)
        ))
        #expect(record.steps.count == 1) // no attribute change, so only the ACL step
        #expect(UndoJournal.revert(record, using: backend).succeeded)

        let readBack = try AccessControlListIO.read(at: path)
        #expect(readBack.entries.count == 1)
        #expect(readBack.entries[0].disposition == .allow)
        #expect(readBack.entries[0].rights == [.read])
    }

    /// Redo, and the "there was no ACL" direction: an empty list is a real state to restore, not a
    /// missing value, so undoing the *creation* of an ACL removes it entirely.
    @Test("undoing the creation of an ACL removes it, and redo puts it back")
    func undoRemovesACLAndRedoRestoresIt() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        let path = VFSPath.local(try tree.writeFile("f.txt", contents: "hi"))

        let new = AccessControlList(entries: [
            ACLEntry(subject: try meSubject(), disposition: .deny, rights: [.delete])
        ])
        try AccessControlListIO.write(new, to: path)
        #expect(try !AccessControlListIO.read(at: path).isEmpty)

        let attributes = try read(path)
        let record = try #require(UndoRecord.attributeChange(
            at: path, actsOnLink: false, from: attributes, to: attributes,
            accessControlList: (old: AccessControlList(), new: new)
        ))
        #expect(UndoJournal.revert(record, using: backend).succeeded)
        #expect(try AccessControlListIO.read(at: path).isEmpty)

        #expect(UndoJournal.revert(record.inverted, using: backend).succeeded)
        #expect(try AccessControlListIO.read(at: path).entries.count == 1)
    }

    /// The locked-file exit criterion, on the ACL path: `acl_set_file` is EPERM while `UF_IMMUTABLE`
    /// is set (probed), so undoing an ACL change on a file that is *still* locked has to unlock,
    /// write and relock — the plan built at revert time, against what is on disk now.
    @Test("undoing an ACL change on a still-locked file restores it in one gesture")
    func undoRestoresACLOnLockedFile() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        let path = VFSPath.local(try tree.writeFile("f.txt", contents: "hi"))
        let subject = try meSubject()

        let old = AccessControlList(entries: [
            ACLEntry(subject: subject, disposition: .allow, rights: [.read])
        ])
        let new = AccessControlList(entries: [
            ACLEntry(subject: subject, disposition: .deny, rights: [.delete])
        ])
        try AccessControlListIO.write(new, to: path)
        chflags(path.path, UInt32(UF_IMMUTABLE))
        defer { chflags(path.path, 0) }

        let attributes = try read(path)
        #expect(attributes.flags.contains(.userImmutable))
        let record = try #require(UndoRecord.attributeChange(
            at: path, actsOnLink: false, from: attributes, to: attributes,
            accessControlList: (old: old, new: new)
        ))
        #expect(UndoJournal.revert(record, using: backend).succeeded)

        let readBack = try AccessControlListIO.read(at: path)
        #expect(readBack.entries[0].disposition == .allow)
        #expect(try read(path).flags.contains(.userImmutable)) // still locked afterwards
    }

    @Test("a commit that changed both the mode and the ACL is one record with two steps")
    func modeAndACLAreOneRecord() throws {
        let path = VFSPath.local("/tmp/f.txt")
        let attributes = FileAttributes(
            permissions: POSIXPermissions(rawValue: 0o644),
            flags: BSDFileFlags(),
            ownerID: 501, groupID: 20,
            accessDate: Date(timeIntervalSince1970: 1),
            modificationDate: Date(timeIntervalSince1970: 2),
            creationDate: Date(timeIntervalSince1970: 3)
        )
        var changed = attributes
        changed.permissions = POSIXPermissions(rawValue: 0o600)
        let list = AccessControlList(entries: [
            ACLEntry(
                subject: ACLSubject(kind: .group, guid: "G", name: "staff", numericID: 20),
                disposition: .deny,
                rights: [.delete]
            )
        ])

        let record = try #require(UndoRecord.attributeChange(
            at: path, actsOnLink: false, from: attributes, to: changed,
            accessControlList: (old: AccessControlList(), new: list)
        ))
        #expect(record.steps.count == 2)
        // One Cmd+Z reverses the whole panel commit, both halves.
        #expect(record.label == .changeAttributes)
    }

    @Test("an unchanged ACL contributes no step")
    func unchangedACLIsNoStep() throws {
        let path = VFSPath.local("/tmp/f.txt")
        let attributes = FileAttributes(
            permissions: POSIXPermissions(rawValue: 0o644),
            flags: BSDFileFlags(), ownerID: 501, groupID: 20,
            accessDate: Date(timeIntervalSince1970: 1),
            modificationDate: Date(timeIntervalSince1970: 2),
            creationDate: Date(timeIntervalSince1970: 3)
        )
        let list = AccessControlList(entries: [
            ACLEntry(
                subject: ACLSubject(kind: .group, guid: "G", name: "staff", numericID: 20),
                disposition: .allow,
                rights: [.read]
            )
        ])
        #expect(UndoRecord.attributeChange(
            at: path, actsOnLink: false, from: attributes, to: attributes,
            accessControlList: (old: list, new: list)
        ) == nil)
    }

    @Test("the ACL step survives the journal's JSON round-trip")
    func aclStepSurvivesJSONRoundTrip() throws {
        let path = VFSPath.local("/tmp/f.txt")
        let list = AccessControlList(entries: [
            ACLEntry(
                subject: ACLSubject(kind: .user, guid: "GUID", name: "oleg", numericID: 501),
                disposition: .deny,
                inheritance: [.fileInherit, .inherited],
                rights: [.read, .delete],
                unrecognizedRights: ["future_right"],
                unrecognizedFlags: ["future_flag"]
            ),
            // An unresolved subject has to survive too — it is the one entry the panel cannot rebuild.
            ACLEntry(
                subject: ACLSubject(kind: .user, guid: "F-1", name: "", numericID: nil),
                disposition: .allow,
                rights: [.read]
            )
        ])
        let record = UndoRecord(
            label: .changeAttributes,
            steps: [.restoreAccessControlList(
                path: path, actsOnLink: true, apply: AccessControlList(), reverse: list
            )]
        )
        let data = try JSONEncoder().encode(record)
        #expect(try JSONDecoder().decode(UndoRecord.self, from: data) == record)
    }
}
