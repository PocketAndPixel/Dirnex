import Foundation
import Testing

@testable import DirnexCore

/// The folder a path typed into Export's folder field or the copy dialog's destination names.
@Suite("TypedFolder")
struct TypedFolderTests {
    let base = VFSPath.local("/Users/someone/Docs")
    let remote = VFSPath(backend: VFSBackendID("sftp://user@host:22"), path: "/home/user")

    @Test("empty or blank text is the folder the field started from")
    func empty() {
        #expect(TypedFolder.resolve("", from: base) == base)
        #expect(TypedFolder.resolve("   ", from: base) == base)
        #expect(TypedFolder.resolve("", from: remote) == remote)
    }

    @Test("a path from a root is taken as it is, and one that is not is taken from the folder")
    func absoluteAndRelative() {
        #expect(TypedFolder.resolve("/tmp/x/", from: base) == .local("/tmp/x"))
        #expect(TypedFolder.resolve("out", from: base) == .local("/Users/someone/Docs/out"))
        #expect(TypedFolder.resolve("a//b/", from: base) == .local("/Users/someone/Docs/a/b"))
        #expect(
            TypedFolder.resolve("/", from: remote) == VFSPath(backend: remote.backend, path: "/")
        )
    }

    @Test("`~` is this Mac's home on this disk, and a plain name on a server")
    func tilde() {
        #expect(
            TypedFolder.resolve("~/Desktop", from: base) == .local(NSHomeDirectory() + "/Desktop")
        )
        #expect(TypedFolder.resolve("~", from: base) == .local(NSHomeDirectory()))
        #expect(TypedFolder.resolve("~/x", from: remote)
            == VFSPath(backend: remote.backend, path: "/home/user/~/x"))
    }

    /// The copy dialog refuses the source's own folder, and `dest/..` has to read as the folder it
    /// is for that refusal to see it.
    @Test("`.` and `..` are resolved by their spelling, and `..` stops at the root")
    func dots() {
        #expect(TypedFolder.resolve("..", from: base) == .local("/Users/someone"))
        #expect(TypedFolder.resolve("./a/../b", from: base) == .local("/Users/someone/Docs/b"))
        #expect(TypedFolder.resolve("/tmp/../../..", from: base) == .local("/"))
        #expect(TypedFolder.resolve("../x", from: remote)
            == VFSPath(backend: remote.backend, path: "/home/x"))
    }
}
