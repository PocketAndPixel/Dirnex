import Foundation
import Testing

@testable import DirnexCore

/// The job a single-item sheet's "Apply to enclosed items" describes (PLAN.md §M14 Slice 4).
///
/// An edit travels as ``AttributePatch/init(from:to:)`` already says. What this suite pins is the
/// Save with nothing edited: it pushes the item's own mode down the tree, and *only* then — an edit
/// beside it must not drag the mode along, or ticking Hidden would rewrite every mode inside.
@Suite("AttributeApplyJob from an edit")
struct AttributeApplyJobTests {
    private func attributes(
        mode: UInt16 = 0o700,
        flags: BSDFileFlags = [],
        groupID: UInt32 = 20
    ) -> FileAttributes {
        FileAttributes(
            permissions: POSIXPermissions(rawValue: mode),
            flags: flags,
            ownerID: 501,
            groupID: groupID,
            accessDate: Date(timeIntervalSince1970: 500_000),
            modificationDate: Date(timeIntervalSince1970: 1_000_000),
            creationDate: Date(timeIntervalSince1970: 100_000)
        )
    }

    @Test("An untouched Save carries the item's own mode, whole, and nothing else")
    func untouchedCarriesCurrentMode() {
        let folder = attributes(mode: 0o700)
        let job = AttributeApplyJob(from: folder, to: folder, target: .filesOnly)

        #expect(!job.isEmpty, "the box alone is a request, so Save has something to do")
        #expect(job.patch.permissionMask.rawValue == 0o7777)
        #expect(job.patch.permissionValues.rawValue == 0o700)
        #expect(job.patch.flagsToSet.isEmpty && job.patch.flagsToClear.isEmpty)
        #expect(job.patch.groupID == nil)
        #expect(job.patch.accessDate == nil && job.patch.modificationDate == nil)
        #expect(job.patch.creationDate == nil)
        #expect(job.accessControlList == nil)
        #expect(job.target == .filesOnly)

        // A child gets the folder's mode and keeps everything that is its own.
        let child = job.patch.apply(to: attributes(mode: 0o644, flags: .hidden, groupID: 80))
        #expect(child.permissions.rawValue == 0o700)
        #expect(child.flags == .hidden)
        #expect(child.groupID == 80)
        // And the folder itself, which already has it, diffs to nothing.
        #expect(job.patch.diff(against: folder).isEmpty)
    }

    @Test("A flag edit travels alone, without dragging the unchanged mode along")
    func editDoesNotForceMode() {
        let job = AttributeApplyJob(
            from: attributes(mode: 0o700), to: attributes(mode: 0o700, flags: .hidden)
        )

        #expect(job.patch == AttributePatch(
            from: attributes(mode: 0o700), to: attributes(mode: 0o700, flags: .hidden)
        ))
        #expect(job.patch.permissionMask.rawValue == 0)
        #expect(job.patch.apply(to: attributes(mode: 0o644)).permissions.rawValue == 0o644)
    }

    @Test("An ACL edit travels alone, without dragging the unchanged mode along")
    func aclEditDoesNotForceMode() {
        let subject = ACLSubject(
            kind: .user, guid: "FFFFEEEE-DDDD-CCCC-BBBB-AAAA000001F5", name: "", numericID: nil
        )
        let list = AccessControlList(entries: [
            ACLEntry(subject: subject, disposition: .deny, rights: [.delete])
        ])
        let job = AttributeApplyJob(
            from: attributes(), to: attributes(), accessControlList: list
        )

        #expect(job.patch.isEmpty)
        #expect(job.accessControlList == list)
    }

    @Test("A changed mode carries as it always did")
    func changedModeCarries() {
        let job = AttributeApplyJob(from: attributes(mode: 0o700), to: attributes(mode: 0o755))

        #expect(job.patch.permissionMask.rawValue == 0o7777)
        #expect(job.patch.permissionValues.rawValue == 0o755)
    }

    // MARK: - Against a real tree

    @Test("An untouched Save gives everything inside the folder's mode and leaves the folder alone")
    func untouchedRunMatchesTree() throws {
        let fixture = try AttributeApplyFixture()
        defer { fixture.cleanup() }
        #expect(chmod(fixture.tree.path(""), 0o700) == 0)
        let folder = try FileAttributeIO.read(at: fixture.tree.vfsPath("")).attributes

        let report = try fixture.run(AttributeApplyJob(from: folder, to: folder))

        #expect(report.failures.isEmpty, "\(report.failures)")
        #expect(try fixture.outcome(report).changedCount == 5, "everything inside, not the root")
        #expect(try fixture.mode() == 0o700)
        for item in ["a.txt", "sub", "sub/b.txt", "sub/deep", "sub/deep/c.txt"] {
            #expect(try fixture.mode(item) == 0o700, "\(item)")
        }
    }
}
