import Foundation
import Testing

@testable import DirnexCore

/// The ACL half of the ordered plan, split from ``AttributeChangePlanTests`` by concept when that
/// suite reached SwiftLint's `type_body_length` (docs/NOTES.md §"Lint ceilings").
///
/// What these pin is one probe result (2026-07-31): **`acl_set_file` fails with `EPERM` on a
/// `UF_IMMUTABLE` file exactly as `chmod` does** — `chmod: Failed to set ACL on file: Operation not
/// permitted`, and clearing the ACL fails the same way. So an ACL change is a *step inside the
/// unlock/relock window*, not a separate write, and getting that wrong surfaces as the EPERM that is
/// indistinguishable from the one genuinely needing root. Invisible in any dialog screenshot, which
/// is why it is tested here rather than trusted.
@Suite("AttributeChangePlan — access control lists")
struct AttributeChangePlanACLTests {
    private let epoch = Date(timeIntervalSince1970: 1_000_000)

    private func attributes(mode: UInt16 = 0o644, flags: BSDFileFlags = []) -> FileAttributes {
        FileAttributes(
            permissions: POSIXPermissions(rawValue: mode),
            flags: flags,
            ownerID: 501,
            groupID: 20,
            accessDate: epoch,
            modificationDate: epoch,
            creationDate: epoch
        )
    }

    private func sampleList() -> AccessControlList {
        AccessControlList(entries: [
            ACLEntry(
                subject: ACLSubject(kind: .group, guid: "G", name: "staff", numericID: 20),
                disposition: .deny,
                rights: [.delete]
            )
        ])
    }

    @Test("an ACL-only change on an unlocked file is one step")
    func aclOnly() {
        let current = attributes()
        let result = AttributeChangePlan(
            diff: AttributeDiff(),
            current: current,
            actsOnLink: false,
            accessControlList: sampleList()
        )
        #expect(result.steps == [.setAccessControlList(sampleList())])
    }

    /// The headline ACL case, and the reason the ACL is a plan *step* rather than a separate write:
    /// probed 2026-07-31, `acl_set_file` fails with `EPERM` on a `UF_IMMUTABLE` file exactly as
    /// `chmod` does. Writing the ACL outside the unlock window would surface that EPERM, which is
    /// indistinguishable from the one that genuinely needs root.
    @Test("a locked file's ACL change unlocks, writes the ACL, then relocks")
    func lockedACLChange() {
        let current = attributes(flags: .userImmutable)
        let result = AttributeChangePlan(
            diff: AttributeDiff(),
            current: current,
            actsOnLink: false,
            accessControlList: sampleList()
        )
        #expect(result.steps == [
            .setFlags([]),
            .setAccessControlList(sampleList()),
            .setFlags(.userImmutable)
        ])
    }

    /// Removing the ACL entirely is an empty list, not an absent one — the "deleted the last entry"
    /// case, which must still be sequenced inside the unlock window.
    @Test("clearing the ACL on a locked file is still unlocked and relocked")
    func lockedACLRemoval() {
        let current = attributes(flags: .userImmutable)
        let result = AttributeChangePlan(
            diff: AttributeDiff(),
            current: current,
            actsOnLink: false,
            accessControlList: AccessControlList()
        )
        #expect(result.steps == [
            .setFlags([]),
            .setAccessControlList(AccessControlList()),
            .setFlags(.userImmutable)
        ])
    }

    /// Both halves of one Save, on a locked file: the ACL lands after the mode and before the relock.
    @Test("a mode and ACL change in one gesture keeps both inside the unlock window")
    func modeAndACLTogether() {
        let current = attributes(mode: 0o644, flags: .userImmutable)
        var desired = current
        desired.permissions = POSIXPermissions(rawValue: 0o600)
        let result = AttributeChangePlan(
            diff: AttributeDiff(from: current, to: desired),
            current: current,
            actsOnLink: false,
            accessControlList: sampleList()
        )
        #expect(result.steps == [
            .setFlags([]),
            .setPermissions(POSIXPermissions(rawValue: 0o600)),
            .setAccessControlList(sampleList()),
            .setFlags(.userImmutable)
        ])
    }

    /// A `nil` list means "not touching the ACL" and must not plan a write — the diff contract
    /// applied to the one field that is not in the diff.
    @Test("no ACL argument plans no ACL step")
    func absentACLPlansNothing() {
        let current = attributes(mode: 0o644)
        var desired = current; desired.permissions = POSIXPermissions(rawValue: 0o600)
        let result = AttributeChangePlan(
            diff: AttributeDiff(from: current, to: desired), current: current, actsOnLink: false
        )
        let plansAnACL = result.steps.contains {
            if case .setAccessControlList = $0 { true } else { false }
        }
        #expect(!plansAnACL)
    }
}
