import Testing

@testable import DirnexCore

/// What F7 and ⇧F4 make of the text in their name field: a name, or a path of names whose folders
/// are made on the way (2026-11-18).
@Suite("NestedName")
struct NestedNameTests {
    private static let directory = VFSPath.local("/Users/tester/Work")

    private static func parsed(_ typed: String, as leaf: NestedName.Leaf = .folder) -> NestedName? {
        try? NestedName(parsing: typed, as: leaf)
    }

    private static func problem(_ typed: String, as leaf: NestedName.Leaf) -> NestedName.Problem? {
        do {
            _ = try NestedName(parsing: typed, as: leaf)
            return nil
        } catch {
            return error
        }
    }

    // MARK: - What it names

    @Test("a plain name is one component, made where it always was")
    func plainName() throws {
        let name = try #require(Self.parsed("untitled folder"))
        #expect(name.components == ["untitled folder"])
        #expect(!name.isNested)
        #expect(name.target(in: Self.directory) == .local("/Users/tester/Work/untitled folder"))
        #expect(name.folders(in: Self.directory).isEmpty)
        #expect(name.outermost(in: Self.directory) == name.target(in: Self.directory))
    }

    @Test("a path names its folders outermost first, and the item last")
    func nestedName() throws {
        let name = try #require(Self.parsed("folder A/sub folder A"))
        #expect(name.components == ["folder A", "sub folder A"])
        #expect(name.isNested)
        #expect(name.name == "sub folder A")
        #expect(
            name.target(in: Self.directory) == .local("/Users/tester/Work/folder A/sub folder A")
        )
        #expect(name.folders(in: Self.directory) == [.local("/Users/tester/Work/folder A")])
        // The row the cursor lands on is the one the pane's own listing shows.
        #expect(name.outermost(in: Self.directory) == .local("/Users/tester/Work/folder A"))
    }

    @Test("a file's path names the folders on the way and then the file")
    func nestedFile() throws {
        let name = try #require(Self.parsed("Folder A/B/test.txt", as: .file))
        #expect(name.name == "test.txt")
        #expect(name.folders(in: Self.directory) == [
            .local("/Users/tester/Work/Folder A"),
            .local("/Users/tester/Work/Folder A/B")
        ])
    }

    /// At a backend root `appending` must not double the slash, which is where a server pane starts.
    @Test("a path below a backend root joins without a doubled slash")
    func belowARoot() throws {
        let root = VFSPath(backend: VFSBackendID("sftp://user@host"), path: "/")
        let name = try #require(Self.parsed("a/b"))
        #expect(name.target(in: root).path == "/a/b")
        #expect(name.folders(in: root).map(\.path) == ["/a"])
    }

    @Test("repeated slashes collapse, and a folder's trailing slash changes nothing")
    func slashesCollapse() {
        #expect(Self.parsed("a//b")?.components == ["a", "b"])
        #expect(Self.parsed("a/b/")?.components == ["a", "b"])
        #expect(Self.parsed("a///")?.components == ["a"])
        #expect(Self.parsed("a//b", as: .file)?.components == ["a", "b"])
    }

    /// The field's ends are trimmed by the dialog; what is between the slashes is the user's, as it
    /// is in Finder and in `mkdir -p`.
    @Test("spaces beside a slash stay part of the name")
    func spacesAreKept() {
        #expect(Self.parsed("a /  b")?.components == ["a ", "  b"])
        #expect(Self.parsed("a/ /b")?.components == ["a", " ", "b"])
    }

    @Test("the path is shown back with single slashes")
    func displayPath() {
        #expect(Self.parsed("a//b/")?.displayPath == "a/b")
        #expect(Self.parsed("plain")?.displayPath == "plain")
    }

    // MARK: - What it refuses

    @Test("nothing typed is empty, which the dialogs read as a cancel")
    func emptyIsEmpty() {
        #expect(Self.problem("", as: .folder) == .empty)
        #expect(Self.problem("", as: .file) == .empty)
    }

    @Test("a leading slash is refused for both, a lone slash included")
    func leadingSlash() {
        for typed in ["/", "/a", "/a/b", "//a"] {
            #expect(Self.problem(typed, as: .folder) == .startsAtRoot, "\(typed)")
            #expect(Self.problem(typed, as: .file) == .startsAtRoot, "\(typed)")
        }
    }

    @Test("a dot or two dots on the way is refused, naming which")
    func dotsAreReserved() {
        #expect(Self.problem("..", as: .folder) == .reserved(".."))
        #expect(Self.problem(".", as: .folder) == .reserved("."))
        #expect(Self.problem("a/../b", as: .folder) == .reserved(".."))
        #expect(Self.problem("./a", as: .file) == .reserved("."))
        #expect(Self.problem("a/..", as: .file) == .reserved(".."))
        // Dots inside a name are a name, as they are on disk.
        #expect(Self.parsed("...")?.components == ["..."])
        #expect(Self.parsed(".hidden/..x")?.components == [".hidden", "..x"])
    }

    /// A folder's trailing slash is harmless; a file's leaves it without a name.
    @Test("a trailing slash is refused for a file only")
    func trailingSlashOnAFile() {
        #expect(Self.problem("a/", as: .file) == .endsInSlash)
        #expect(Self.problem("a/b/", as: .file) == .endsInSlash)
        #expect(Self.problem("a/", as: .folder) == nil)
    }
}
