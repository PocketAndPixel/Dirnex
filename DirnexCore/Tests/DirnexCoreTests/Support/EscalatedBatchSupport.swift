import Foundation
import Testing

@testable import DirnexCore

/// The vocabulary the two batch-escalation suites share (PLAN.md §M40 Slice 4): a plain item, an
/// item planned from a real file, and the shell `do shell script` would run a body in.
enum EscalatedBatchSupport {
    static let epoch = Date(timeIntervalSince1970: 1_000_000)

    static func attributes(mode: UInt16 = 0o644, flags: BSDFileFlags = []) -> FileAttributes {
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

    /// An item at `path` whose change is a mode from `old` to `new`.
    static func item(_ path: String, from old: UInt16 = 0o644, to new: UInt16) -> EscalatedAttributeBatch.Item {
        var diff = AttributeDiff()
        diff.permissions = POSIXPermissions(rawValue: new)
        return EscalatedAttributeBatch.Item(
            path: VFSPath.local(path),
            actsOnLink: false,
            current: attributes(mode: old),
            diff: diff
        )
    }

    /// Run one body the way `do shell script` does, unprivileged.
    static func runShell(_ body: String) throws -> (status: Int32, stderr: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", body]
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = Pipe()
        try process.run()
        let data = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(bytes: data, encoding: .utf8) ?? "")
    }

    /// A real item on disk with its own current attributes, changed to `mode`.
    static func diskItem(
        _ fixture: AttributeApplyFixture,
        _ relative: String,
        mode: UInt16
    ) throws -> EscalatedAttributeBatch.Item {
        let path = fixture.tree.vfsPath(relative)
        let reading = try FileAttributeIO.read(at: path)
        var diff = AttributeDiff()
        diff.permissions = POSIXPermissions(rawValue: mode)
        return EscalatedAttributeBatch.Item(
            path: path,
            actsOnLink: reading.isSymlink,
            current: reading.attributes,
            diff: diff
        )
    }
}
