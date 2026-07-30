import Foundation
import Testing

@testable import DirnexCore

@Suite("AttributeDiff")
struct AttributeDiffTests {
    private let epoch = Date(timeIntervalSince1970: 1_000_000)

    private func baseline() -> FileAttributes {
        FileAttributes(
            permissions: POSIXPermissions(rawValue: 0o644),
            flags: [],
            ownerID: 501,
            groupID: 20,
            accessDate: epoch,
            modificationDate: epoch,
            creationDate: epoch
        )
    }

    @Test("an unchanged copy diffs to empty")
    func emptyDiff() {
        let diff = AttributeDiff(from: baseline(), to: baseline())
        #expect(diff.isEmpty)
        #expect(!diff.changesOwnership && !diff.changesUtimes)
    }

    @Test("only the touched field appears, carrying the desired value")
    func onlyTouchedFields() {
        var edited = baseline()
        edited.permissions = POSIXPermissions(rawValue: 0o600)
        let diff = AttributeDiff(from: baseline(), to: edited)
        #expect(diff.permissions == POSIXPermissions(rawValue: 0o600))
        #expect(diff.flags == nil && diff.ownerID == nil && diff.groupID == nil)
        #expect(diff.accessDate == nil && diff.modificationDate == nil && diff.creationDate == nil)
        #expect(!diff.isEmpty)
    }

    @Test("ownership and utimes convenience flags reflect their pairs")
    func convenienceFlags() {
        var owner = baseline(); owner.ownerID = 502
        #expect(AttributeDiff(from: baseline(), to: owner).changesOwnership)

        var group = baseline(); group.groupID = 80
        #expect(AttributeDiff(from: baseline(), to: group).changesOwnership)

        var atime = baseline(); atime.accessDate = epoch.addingTimeInterval(60)
        let diff = AttributeDiff(from: baseline(), to: atime)
        #expect(diff.changesUtimes && diff.accessDate == epoch.addingTimeInterval(60))
        #expect(!diff.changesOwnership)

        var ctime = baseline(); ctime.creationDate = epoch.addingTimeInterval(60)
        #expect(!AttributeDiff(from: baseline(), to: ctime).changesUtimes) // birth time is not utimes
        #expect(AttributeDiff(from: baseline(), to: ctime).creationDate != nil)
    }
}
