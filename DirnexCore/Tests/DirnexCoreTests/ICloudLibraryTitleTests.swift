import Foundation
import Testing

@testable import DirnexCore

/// `ICloudLocation.libraryTitle(of:)` — the app's name an iCloud app library's `Documents` folder is
/// shown under, for everything that names a folder in a sentence or on a tab rather than in the path
/// bar. Its own suite because `ICloudLocationTests` is about the trail, and sits near SwiftLint's
/// `type_body_length`.
@Suite("ICloudLocation — an app library's name")
struct ICloudLibraryTitleTests {
    private static let pagesDocuments = "Library/Mobile Documents/com~apple~Pages/Documents"

    @Test("an app library's Documents folder is named for its app")
    func libraryFolderWearsTheAppName() throws {
        let temp = try TempTree()
        defer { temp.cleanup() }
        try ICloudFixture.makeContainer(
            temp,
            bundleID: "com.apple.Pages",
            name: "Pages",
            public: true,
            contents: ["a.pages"]
        )

        let title = ICloudLocation.libraryTitle(
            of: temp.vfsPath(Self.pagesDocuments),
            home: temp.root.path,
            languageCode: nil
        )
        #expect(title == "Pages")
    }

    /// The claim that makes this worth a function rather than a second lookup: whichever source
    /// answers — the cached metadata, a translation of it, the system's name when the cache is
    /// refused, or the bundle id when the cache has forgotten the app — the name is the crumb's.
    @Test("the name agrees with the path bar's crumb whichever source answers it")
    func agreesWithTheTrail() throws {
        let temp = try TempTree()
        defer { temp.cleanup() }
        try ICloudFixture.makeContainer(
            temp,
            bundleID: "com.apple.Pages",
            name: "Pages",
            public: true,
            contents: ["a.pages"],
            localizedNames: ["de": "Seiten"]
        )
        // No metadata at all, so only the system's name or the bundle id can answer.
        let sketch = "Library/Mobile Documents/com~acme~Sketch/Documents"
        try temp.makeDir(sketch)

        let cases = [
            Source("cached", Self.pagesDocuments, fallback: { _ in "Documents" }, expected: "Pages"),
            Source("translated", Self.pagesDocuments, language: "de", expected: "Seiten"),
            Source("the system's", sketch, fallback: { _ in "Sketch" }, expected: "Sketch"),
            Source("the bundle id", sketch, expected: "com.acme.Sketch")
        ]
        for source in cases {
            let path = temp.vfsPath(source.relative)
            let title = ICloudLocation.libraryTitle(
                of: path,
                home: temp.root.path,
                languageCode: source.language,
                fallbackName: source.fallback
            )
            let crumb = ICloudLocation.trail(
                for: path,
                home: temp.root.path,
                languageCode: source.language,
                fallbackName: source.fallback
            )?.first?.title
            #expect(title == source.expected, "\(source.name)")
            #expect(title == crumb, "\(source.name)")
        }
    }

    /// One place a library's name can come from, and what it should read.
    private struct Source {
        let name: String
        let relative: String
        let language: String?
        let fallback: (VFSPath) -> String?
        let expected: String

        init(
            _ name: String,
            _ relative: String,
            language: String? = nil,
            fallback: @escaping (VFSPath) -> String? = { _ in nil },
            expected: String
        ) {
            self.name = name
            self.relative = relative
            self.language = language
            self.fallback = fallback
            self.expected = expected
        }
    }

    /// The narrowness controls. Each of these keeps its own name, and most are a shape a looser test
    /// would take for a library: a folder inside one (two of them called `Documents`), the container
    /// above it, and — the one ``ICloudDrive/isMergedRoot(_:home:)`` does take — a loose folder that
    /// happens to be called `Documents`.
    @Test("no other folder is renamed, a loose one called Documents included")
    func onlyTheLibraryFolderIsRenamed() throws {
        let temp = try TempTree()
        defer { temp.cleanup() }
        try ICloudFixture.makeContainer(
            temp,
            bundleID: "com.apple.Pages",
            name: "Pages",
            public: true,
            contents: ["a.pages"]
        )
        let paths = [
            temp.vfsPath(Self.pagesDocuments + "/Drafts"),
            temp.vfsPath(Self.pagesDocuments + "/Documents"),
            temp.vfsPath("Library/Mobile Documents/com~apple~Pages"),
            temp.vfsPath("Library/Mobile Documents/com~apple~CloudDocs"),
            temp.vfsPath("Library/Mobile Documents/com~apple~CloudDocs/Documents"),
            temp.vfsPath("Library/Mobile Documents"),
            temp.vfsPath("Documents"),
            .local("/Users/test/Documents"),
            ICloudLocation.mergedPath
        ]
        for path in paths {
            let title = ICloudLocation.libraryTitle(
                of: path,
                home: temp.root.path,
                languageCode: nil,
                fallbackName: { _ in "Wrong" }
            )
            #expect(title == nil, "\(path.path)")
        }
    }
}
