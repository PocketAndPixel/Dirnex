import Foundation
import Testing
import UniformTypeIdentifiers

@testable import DirnexCore

/// Which files Open With ▸ Always Open … With reaches (``DefaultApplicationScope/of(_:typeOf:)``):
/// one type, named by its extension when every row shares one, and only a type that is a document.
@Suite("Default application scope")
struct DefaultApplicationScopeTests {
    private static func entry(_ name: String, kind: FileEntry.Kind = .file) -> FileEntry {
        FileEntry(
            path: VFSPath(backend: .local, path: "/tmp/\(name)"),
            name: name,
            kind: kind,
            byteSize: 1,
            modificationDate: Date(timeIntervalSince1970: 0),
            creationDate: Date(timeIntervalSince1970: 0),
            isHidden: false,
            permissions: 0o644,
            inode: 0
        )
    }

    /// Types each row by its name, as a remote row is typed; `nil` where the table has no answer.
    private static func scope(
        _ entries: [FileEntry],
        types: [String: String]? = nil
    ) -> DefaultApplicationScope? {
        DefaultApplicationScope.of(entries) { entry in
            if let types { return types[entry.name] }
            return UTType(filenameExtension: entry.fileExtension)?.identifier
        }
    }

    // MARK: - One type

    @Test("one movie is named by its extension")
    func oneFile() {
        #expect(Self.scope([Self.entry("a.m4v")]) == DefaultApplicationScope(
            typeIdentifier: "com.apple.m4v-video",
            name: .fileExtension("m4v")
        ))
    }

    @Test("an extension in capitals is named in lowercase, as macOS keys it")
    func capitals() {
        let scope = Self.scope([Self.entry("A.M4V"), Self.entry("b.m4v")])
        #expect(scope?.name == .fileExtension("m4v"))
    }

    @Test("two extensions of one type are named by the type, since either would understate it")
    func twoExtensionsOneType() {
        let scope = Self.scope([Self.entry("a.jpg"), Self.entry("b.jpeg")])
        #expect(
            scope == DefaultApplicationScope(typeIdentifier: "public.jpeg", name: .typeDescription)
        )
    }

    @Test("an extension that is not one of the type's own is not used to name it")
    func foreignExtension() {
        let scope = Self.scope([Self.entry("notes.bak")], types: ["notes.bak": "public.plain-text"])
        #expect(scope == DefaultApplicationScope(
            typeIdentifier: "public.plain-text",
            name: .typeDescription
        ))
    }

    @Test("an extension nothing declares is still a type, so its default can be chosen")
    func dynamicType() throws {
        let type = try #require(UTType(filenameExtension: "dirnexprobe"))
        #expect(type.isDynamic)
        #expect(Self.scope([Self.entry("x.dirnexprobe")]) == DefaultApplicationScope(
            typeIdentifier: type.identifier,
            name: .fileExtension("dirnexprobe")
        ))
    }

    /// Typed by the table, as the file types a local package: `UTType(filenameExtension:)` alone answers
    /// a dynamic type for "rtfd", since it looks only among types that conform to `public.data`.
    @Test("a document package is a document")
    func documentPackage() {
        let rows = [Self.entry("Notes.rtfd", kind: .directory)]
        #expect(Self.scope(rows, types: ["Notes.rtfd": "com.apple.rtfd"]) == DefaultApplicationScope(
            typeIdentifier: "com.apple.rtfd",
            name: .fileExtension("rtfd")
        ))
    }

    // MARK: - Nothing to offer

    @Test("an empty selection has no scope")
    func empty() {
        #expect(Self.scope([]) == nil)
    }

    @Test("two types have no scope, since one change cannot cover both")
    func twoTypes() {
        #expect(Self.scope([Self.entry("a.m4v"), Self.entry("b.mp4")]) == nil)
    }

    @Test("a row with no type takes the scope away, wherever it sits")
    func untyped() {
        let rows = [Self.entry("a.m4v"), Self.entry("gone.m4v")]
        #expect(Self.scope(rows, types: ["a.m4v": "com.apple.m4v-video"]) == nil)
        #expect(Self.scope(rows.reversed(), types: ["a.m4v": "com.apple.m4v-video"]) == nil)
    }

    @Test("a folder, a volume and an application are not documents", arguments: [
        "public.folder", "public.directory", "public.volume",
        "com.apple.application-bundle", "com.apple.application"
    ])
    func notDocuments(identifier: String) {
        let rows = [Self.entry("x")]
        #expect(Self.scope(rows, types: ["x": identifier]) == nil)
    }

    @Test("a type no extension maps to would reach every unknown file, so it is not offered", arguments: [
        "public.data", "public.item", "public.content", "public.unix-executable", "public.symlink"
    ])
    func noExtension(identifier: String) {
        let rows = [Self.entry("README")]
        #expect(Self.scope(rows, types: ["README": identifier]) == nil)
    }

    @Test("a type macOS does not know has no scope")
    func unknownIdentifier() {
        #expect(Self.scope([Self.entry("x.y")], types: ["x.y": "not a type"]) == nil)
    }
}
