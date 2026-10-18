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

    func cleanup() {
        try? fileManager.removeItem(at: root)
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
