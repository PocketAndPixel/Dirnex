import Foundation
import Testing

@testable import DirnexCore

/// The syscall half, against **real** temp files, with the stock `xattr` tool as the independent
/// judge wherever the claim is about what the OS sees.
@Suite("ExtendedAttributeIO")
struct ExtendedAttributeIOTests {
    private func withTree(_ body: (TempTree) throws -> Void) throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        try body(tree)
    }

    @Test("a written attribute reads back byte-for-byte")
    func roundTrips() throws {
        try withTree { tree in
            let path = VFSPath.local(try tree.writeFile("f.txt", contents: "hi"))
            let value = Data("0281;6a5c94dc;Chrome;4EB3AC05".utf8)
            try ExtendedAttributeIO.set("com.apple.quarantine", to: value, at: path)

            #expect(try ExtendedAttributeIO.names(at: path).contains("com.apple.quarantine"))
            #expect(try ExtendedAttributeIO.value(of: "com.apple.quarantine", at: path) == value)
        }
    }

    @Test("`all` pairs every name with its value")
    func listsAll() throws {
        try withTree { tree in
            let path = VFSPath.local(try tree.writeFile("f.txt", contents: "hi"))
            try ExtendedAttributeIO.set("app.dirnex.a", to: Data("one".utf8), at: path)
            try ExtendedAttributeIO.set("app.dirnex.b", to: Data("two".utf8), at: path)

            let all = try ExtendedAttributeIO.all(at: path)
            let mine = all.filter { $0.name.hasPrefix("app.dirnex.") }
                .sorted { $0.name < $1.name }
            #expect(mine.map(\.name) == ["app.dirnex.a", "app.dirnex.b"])
            #expect(mine.map { String(bytes: $0.data, encoding: .utf8) } == ["one", "two"])
        }
    }

    @Test("reading an absent attribute is nil, not a throw")
    func absentValueIsNil() throws {
        try withTree { tree in
            let path = VFSPath.local(try tree.writeFile("f.txt", contents: "hi"))
            #expect(try ExtendedAttributeIO.value(of: "app.dirnex.absent", at: path) == nil)
        }
    }

    /// The reason every call passes `XATTR_NOFOLLOW`. Probed live: following a symlink returned the
    /// *target's* attributes, so a panel that followed would list — and delete — the wrong file's.
    @Test("a symlink's own attributes are read, never its target's")
    func actsOnTheLink() throws {
        try withTree { tree in
            let target = try tree.writeFile("target.txt", contents: "hi")
            try tree.symlink("link", to: target)
            try ExtendedAttributeIO.set(
                "app.dirnex.target", to: Data("t".utf8), at: .local(target)
            )
            try ExtendedAttributeIO.set(
                "app.dirnex.link", to: Data("l".utf8), at: .local(tree.path("link"))
            )

            let linkNames = try ExtendedAttributeIO.names(at: .local(tree.path("link")))
            #expect(linkNames.contains("app.dirnex.link"))
            #expect(!linkNames.contains("app.dirnex.target"))

            let targetNames = try ExtendedAttributeIO.names(at: .local(target))
            #expect(targetNames.contains("app.dirnex.target"))
            #expect(!targetNames.contains("app.dirnex.link"))
        }
    }

    @Test("what the stock xattr tool writes is what Dirnex reads back")
    func agreesWithTheStockTool() throws {
        try withTree { tree in
            let file = try tree.writeFile("f.txt", contents: "hi")

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
            process.arguments = ["-w", "app.dirnex.probe", "hello", file]
            try process.run()
            process.waitUntilExit()
            #expect(process.terminationStatus == 0)

            #expect(try ExtendedAttributeIO.value(of: "app.dirnex.probe", at: .local(file))
                == Data("hello".utf8))
        }
    }

    @Test("a directory carries attributes too")
    func worksOnDirectories() throws {
        try withTree { tree in
            let dir = VFSPath.local(try tree.makeDir("folder"))
            try ExtendedAttributeIO.set("app.dirnex.probe", to: Data("d".utf8), at: dir)
            #expect(try ExtendedAttributeIO.value(of: "app.dirnex.probe", at: dir)
                == Data("d".utf8))
        }
    }

    @Test("a non-local path never reaches a syscall")
    func refusesVirtualPaths() throws {
        #expect(throws: VFSError.self) {
            _ = try ExtendedAttributeIO.names(at: VFSPath(backend: .trash, path: "/x"))
        }
    }

    @Test("the kernel's NUL-separated name buffer splits into names")
    func splitsNames() {
        let buffer = "com.apple.quarantine\0com.apple.provenance\0".utf8.map { CChar(bitPattern: $0) }
        #expect(ExtendedAttributeIO.splitNames(buffer)
            == ["com.apple.quarantine", "com.apple.provenance"])
        #expect(ExtendedAttributeIO.splitNames([CChar]()) == [])
    }
}
