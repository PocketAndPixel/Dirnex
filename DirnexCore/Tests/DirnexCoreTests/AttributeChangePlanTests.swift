import Foundation
import Testing

@testable import DirnexCore

/// The ordering these pin is invisible in any dialog screenshot, which is exactly why it is tested
/// directly (PLAN.md §M14 Slice 3): unlock → apply → relock around an immutable file, and `chown`
/// before `chmod` so a set-uid bit survives.
@Suite("AttributeChangePlan")
struct AttributeChangePlanTests {
    private let epoch = Date(timeIntervalSince1970: 1_000_000)

    private func attributes(
        mode: UInt16 = 0o644,
        flags: BSDFileFlags = [],
        owner: UInt32 = 501,
        group: UInt32 = 20
    ) -> FileAttributes {
        FileAttributes(
            permissions: POSIXPermissions(rawValue: mode),
            flags: flags,
            ownerID: owner,
            groupID: group,
            accessDate: epoch,
            modificationDate: epoch,
            creationDate: epoch
        )
    }

    private func plan(from current: FileAttributes, to desired: FileAttributes) -> AttributeChangePlan {
        AttributeChangePlan(
            diff: AttributeDiff(from: current, to: desired),
            current: current,
            actsOnLink: false
        )
    }

    @Test("an empty diff plans nothing")
    func empty() {
        let result = plan(from: attributes(), to: attributes())
        #expect(result.isEmpty && result.steps.isEmpty)
    }

    @Test("a plain mode change on an unlocked file is one chmod")
    func plainMode() {
        let result = plan(from: attributes(mode: 0o644), to: attributes(mode: 0o600))
        #expect(result.steps == [.setPermissions(POSIXPermissions(rawValue: 0o600))])
    }

    @Test("toggling Locked is a single chflags, no unlock dance")
    func toggleLocked() {
        let on = plan(from: attributes(flags: []), to: attributes(flags: .userImmutable))
        #expect(on.steps == [.setFlags(.userImmutable)])

        let off = plan(from: attributes(flags: .userImmutable), to: attributes(flags: []))
        #expect(off.steps == [.setFlags([])])
    }

    /// The headline case: changing the mode of a *locked* file must unlock, apply, then relock — in
    /// one gesture, so the user never sees the EPERM that reads like "you need root".
    @Test("a locked file's mode change unlocks, applies, then relocks")
    func lockedModeChange() {
        let result = plan(
            from: attributes(mode: 0o644, flags: .userImmutable),
            to: attributes(mode: 0o600, flags: .userImmutable)
        )
        #expect(result.steps == [
            .setFlags([]),
            .setPermissions(POSIXPermissions(rawValue: 0o600)),
            .setFlags(.userImmutable)
        ])
    }

    @Test("unlocking while changing the mode does not relock, and writes flags only once")
    func unlockAndEdit() {
        let result = plan(
            from: attributes(mode: 0o644, flags: .userImmutable),
            to: attributes(mode: 0o600, flags: [])
        )
        #expect(result.steps == [
            .setFlags([]),
            .setPermissions(POSIXPermissions(rawValue: 0o600))
        ])
    }

    /// A locked file keeps its *other* flags across the unlock — only the immutable bit is cleared.
    @Test("unlock preserves non-immutable flags")
    func unlockPreservesOtherFlags() {
        let result = plan(
            from: attributes(mode: 0o644, flags: [.userImmutable, .hidden]),
            to: attributes(mode: 0o600, flags: [.userImmutable, .hidden])
        )
        #expect(result.steps == [
            .setFlags(.hidden),
            .setPermissions(POSIXPermissions(rawValue: 0o600)),
            .setFlags([.userImmutable, .hidden])
        ])
    }

    /// `chown(2)` clears set-uid/gid for an unprivileged caller, so ownership must precede the chmod.
    @Test("chown lands before chmod")
    func chownBeforeChmod() {
        let result = plan(
            from: attributes(mode: 0o644, owner: 501),
            to: attributes(mode: 0o4755, owner: 502)
        )
        #expect(result.steps == [
            .setOwnership(userID: 502, groupID: nil),
            .setPermissions(POSIXPermissions(rawValue: 0o4755))
        ])
    }

    @Test("utimes carries both times even when only one changed")
    func utimesCarriesBoth() {
        var desired = attributes()
        desired.modificationDate = epoch.addingTimeInterval(3600)
        let result = plan(from: attributes(), to: desired)
        #expect(
            result.steps == [.setTimes(access: epoch, modification: epoch.addingTimeInterval(3600))]
        )
    }

    @Test("creation date is its own step, separate from utimes")
    func creationDateStep() {
        var desired = attributes()
        desired.creationDate = epoch.addingTimeInterval(3600)
        desired.accessDate = epoch.addingTimeInterval(60)
        let result = plan(from: attributes(), to: desired)
        #expect(result.steps == [
            .setTimes(access: epoch.addingTimeInterval(60), modification: epoch),
            .setCreationDate(epoch.addingTimeInterval(3600))
        ])
    }

    @Test("actsOnLink is carried through for the applier")
    func actsOnLink() {
        let current = attributes(mode: 0o644)
        var desired = current; desired.permissions = POSIXPermissions(rawValue: 0o600)
        let result = AttributeChangePlan(
            diff: AttributeDiff(from: current, to: desired), current: current, actsOnLink: true
        )
        #expect(result.actsOnLink)
    }
}
