import Foundation

@testable import DirnexCore

/// A throwaway directory tree for hermetic filesystem tests.
///
/// Tests build exactly the shape they need and tear it down via `defer`, so they
/// don't depend on the `Tooling/generate-fixtures.swift` output or on any state
/// outside the temp dir.
struct TempTree {
    let root: URL
    private let fileManager = FileManager.default

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("dirnex-tests-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
    }

    /// Removes the tree, first taking off what the attribute tests leave on purpose and what stops a
    /// removal: an ACL denying delete, and the locked flag. Without that the `try?` hid the refusal,
    /// and each run left the ACL tests' `f.txt` behind in a folder of its own (2026-11-19).
    func cleanup() {
        if (try? fileManager.removeItem(at: root)) != nil { return }
        Self.unprotect(root.path)
        if let walker = fileManager.enumerator(atPath: root.path) {
            for case let relative as String in walker {
                Self.unprotect(root.appendingPathComponent(relative).path)
            }
        }
        try? fileManager.removeItem(at: root)
    }

    /// Clears the flags word and the extended ACL of the entry at `path`, a symlink itself rather
    /// than what it points to.
    private static func unprotect(_ path: String) {
        _ = lchflags(path, 0)
        guard let empty = acl_init(0) else { return }
        defer { acl_free(UnsafeMutableRawPointer(empty)) }
        _ = acl_set_link_np(path, ACL_TYPE_EXTENDED, empty)
    }

    /// Absolute path of a name relative to the tree root.
    func path(_ relative: String) -> String {
        root.appendingPathComponent(relative).path
    }

    /// `VFSPath` for a name relative to the tree root.
    func vfsPath(_ relative: String = "") -> VFSPath {
        relative.isEmpty ? .local(root.path) : .local(path(relative))
    }

    @discardableResult
    func makeDir(_ relative: String) throws -> String {
        let full = path(relative)
        try fileManager.createDirectory(atPath: full, withIntermediateDirectories: true)
        return full
    }

    @discardableResult
    func writeFile(_ relative: String, bytes: Int = 0, contents: String? = nil) throws -> String {
        let full = path(relative)
        let data: Data = if let contents {
            Data(contents.utf8)
        } else {
            Data(repeating: UInt8(ascii: "x"), count: bytes)
        }
        try data.write(to: URL(fileURLWithPath: full))
        return full
    }

    func symlink(_ relative: String, to target: String) throws {
        try fileManager.createSymbolicLink(atPath: path(relative), withDestinationPath: target)
    }

    /// Stamp an item's modification date, so tests can make one file demonstrably newer or
    /// older than another (the `newerOnly` conflict policy compares these).
    func setModificationDate(_ relative: String, to date: Date) throws {
        try fileManager.setAttributes([.modificationDate: date], ofItemAtPath: path(relative))
    }
}
