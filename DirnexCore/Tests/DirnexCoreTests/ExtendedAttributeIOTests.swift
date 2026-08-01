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
            try ExtendedAttributeIO.set("com.dirnex.a", to: Data("one".utf8), at: path)
            try ExtendedAttributeIO.set("com.dirnex.b", to: Data("two".utf8), at: path)

            let all = try ExtendedAttributeIO.all(at: path)
            let mine = all.filter { $0.name.hasPrefix("com.dirnex.") }
                .sorted { $0.name < $1.name }
            #expect(mine.map(\.name) == ["com.dirnex.a", "com.dirnex.b"])
            #expect(mine.map { String(bytes: $0.data, encoding: .utf8) } == ["one", "two"])
        }
    }

    @Test("removing an attribute the file never had succeeds")
    func removeIsIdempotent() throws {
        try withTree { tree in
            let path = VFSPath.local(try tree.writeFile("f.txt", contents: "hi"))
            // The `xattr -d` vs `xattr -dr` lesson as a test: over an ordinary multi-selection most
            // files never carried the attribute, and a throwing remove would surface as a failure
            // alert for a command that did exactly what was asked.
            try ExtendedAttributeIO.remove("com.apple.quarantine", at: path)
            #expect(try ExtendedAttributeIO.value(of: "com.apple.quarantine", at: path) == nil)
        }
    }

    @Test("removing an attribute the file does have takes it away")
    func removes() throws {
        try withTree { tree in
            let path = VFSPath.local(try tree.writeFile("f.txt", contents: "hi"))
            try ExtendedAttributeIO.set("com.dirnex.probe", to: Data("x".utf8), at: path)
            try ExtendedAttributeIO.remove("com.dirnex.probe", at: path)
            #expect(try !ExtendedAttributeIO.names(at: path).contains("com.dirnex.probe"))
        }
    }

    @Test("reading an absent attribute is nil, not a throw")
    func absentValueIsNil() throws {
        try withTree { tree in
            let path = VFSPath.local(try tree.writeFile("f.txt", contents: "hi"))
            #expect(try ExtendedAttributeIO.value(of: "com.dirnex.absent", at: path) == nil)
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
                "com.dirnex.target", to: Data("t".utf8), at: .local(target)
            )
            try ExtendedAttributeIO.set(
                "com.dirnex.link", to: Data("l".utf8), at: .local(tree.path("link"))
            )

            let linkNames = try ExtendedAttributeIO.names(at: .local(tree.path("link")))
            #expect(linkNames.contains("com.dirnex.link"))
            #expect(!linkNames.contains("com.dirnex.target"))

            let targetNames = try ExtendedAttributeIO.names(at: .local(target))
            #expect(targetNames.contains("com.dirnex.target"))
            #expect(!targetNames.contains("com.dirnex.link"))
        }
    }

    @Test("what Dirnex writes is what the stock xattr tool reads back")
    func agreesWithTheStockTool() throws {
        try withTree { tree in
            let file = try tree.writeFile("f.txt", contents: "hi")
            try ExtendedAttributeIO.set(
                "com.dirnex.probe", to: Data("hello".utf8), at: .local(file)
            )

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
            process.arguments = ["-p", "com.dirnex.probe", file]
            let pipe = Pipe()
            process.standardOutput = pipe
            try process.run()
            let output = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()

            #expect(String(bytes: output, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) == "hello")
        }
    }

    @Test("a directory carries attributes too")
    func worksOnDirectories() throws {
        try withTree { tree in
            let dir = VFSPath.local(try tree.makeDir("folder"))
            try ExtendedAttributeIO.set("com.dirnex.probe", to: Data("d".utf8), at: dir)
            #expect(try ExtendedAttributeIO.value(of: "com.dirnex.probe", at: dir)
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
