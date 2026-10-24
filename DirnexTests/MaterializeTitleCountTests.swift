import AppKit
import DirnexCore
import Foundation
import Testing

@testable import Dirnex

/// The fetch confirmation counts a marked folder as a folder (`PanelViewController+MaterializeConfirm`).
///
/// Seen live 2026-10-24: one file and one folder on the NAS, packed with ⌥F5, asked "Download 2
/// files from the server?". The title counted every pending row as a file. What it counts is
/// pinned here without any string, and the four titles that say it are read from the compiled
/// catalog in every language, so neither half depends on the language this Mac's test host runs in
/// (docs/NOTES.md ▸ Localization: the app test target inherits the developer's own pin).
@MainActor
@Suite("Fetch confirmation counts folders")
struct MaterializeTitleCountTests {
    private static let server = VFSBackendID("sftp://user@host")

    private static func entry(_ name: String, kind: FileEntry.Kind = .file) -> FileEntry {
        FileEntry(
            path: VFSPath(backend: server, path: "/srv/\(name)"),
            name: name,
            kind: kind,
            byteSize: 4096,
            modificationDate: Date(timeIntervalSince1970: 1_700_000_000),
            creationDate: Date(timeIntervalSince1970: 1_700_000_000),
            isHidden: false,
            permissions: 0o644,
            inode: 11
        )
    }

    private static func count(
        _ entries: [FileEntry],
        cached: Set<String> = []
    ) -> PanelViewController.MaterializationTitleCount {
        let plan = MaterializationPlan.plan(for: entries) { cached.contains($0.name) }
        return PanelViewController.titleCount(for: plan)
    }

    // MARK: - What the title counts

    @Test("one file and one folder are counted apart, the set seen live")
    func fileAndFolder() {
        let seen = Self.count([Self.entry("c.txt"), Self.entry("sub", kind: .directory)])
        #expect(seen == .filesAndFolders(files: 1, folders: 1))
    }

    @Test("a set of files is still counted as files, and of folders as folders")
    func singleKinds() {
        #expect(Self.count([Self.entry("a.txt"), Self.entry("b.txt")]) == .files(2))
        #expect(
            Self.count([Self.entry("x", kind: .directory), Self.entry("y", kind: .directory)])
                == .folders(2)
        )
    }

    @Test("one row is named, whether a file or a folder")
    func oneRowIsNamed() {
        #expect(Self.count([Self.entry("a.txt")]) == .named("a.txt"))
        #expect(Self.count([Self.entry("sub", kind: .directory)]) == .named("sub"))
    }

    @Test("a row already here is not counted, so the rest decide the title")
    func cachedRowIsNotCounted() {
        let rows = [Self.entry("a.txt"), Self.entry("b.txt"), Self.entry("sub", kind: .directory)]
        #expect(Self.count(rows, cached: ["a.txt"]) == .filesAndFolders(files: 1, folders: 1))
        #expect(Self.count(rows, cached: ["a.txt", "b.txt"]) == .named("sub"))
    }

    // MARK: - How each language says it

    nonisolated private static let titles = [
        "Download %lld folders from the server?",
        "Download %lld files and %lld folders from the server?",
        "Extract %lld folders from the archive?",
        "Extract %lld files and %lld folders from the archive?"
    ]

    /// `key` formatted with `counts` in every compiled language, through the stringsdict the app
    /// ships rather than the catalog it was built from.
    private static func rendered(_ key: String, _ counts: [Int]) -> [String: String] {
        let app = Bundle(for: PanelViewController.self)
        var out: [String: String] = [:]
        for lproj in app.paths(forResourcesOfType: "lproj", inDirectory: nil) {
            let language = (lproj as NSString).lastPathComponent
                .replacingOccurrences(of: ".lproj", with: "")
            guard language != "Base", let bundle = Bundle(path: lproj) else { continue }
            let format = bundle.localizedString(forKey: key, value: nil, table: "Localizable")
            guard format != key || language == "en" else { continue }
            out[language] = String(
                format: format,
                locale: Locale(identifier: language),
                arguments: counts.map { $0 as any CVarArg }
            )
        }
        return out
    }

    @Test(
        "every new title is in all 14 languages and leaves no placeholder behind",
        arguments: titles
    )
    func everyLanguage(key: String) {
        let counts = key.contains("and %lld") ? [3, 2] : [3]
        let all = Self.rendered(key, counts)
        #expect(all.count >= 14, "expected 14 languages for \(key), found \(all.keys.sorted())")
        for (language, text) in all {
            #expect(!text.contains("%"), "\(language) left a placeholder: \(text)")
            #expect(!text.contains("@"), "\(language) left a substitution: \(text)")
            #expect(text.contains("3"), "\(language) lost the first count: \(text)")
            if counts.count == 2 {
                #expect(text.contains("2"), "\(language) lost the second count: \(text)")
            }
        }
    }

    @Test("each count takes its own plural form")
    func pluralForms() {
        let both = "Download %lld files and %lld folders from the server?"
        #expect(Self.rendered(both, [1, 1])["en"] == "Download 1 file and 1 folder from the server?")
        #expect(
            Self.rendered(both, [1, 2])["en"] == "Download 1 file and 2 folders from the server?"
        )
        #expect(Self.rendered(both, [1, 1])["ru"] == "Загрузить 1 файл и 1 папку с сервера?")
        #expect(Self.rendered(both, [5, 2])["ru"] == "Загрузить 5 файлов и 2 папки с сервера?")
        #expect(Self.rendered(both, [2, 5])["pl"] == "Pobrać 2 pliki i 5 folderów z serwera?")
        let folders = "Extract %lld folders from the archive?"
        #expect(Self.rendered(folders, [1])["en"] == "Extract 1 folder from the archive?")
        #expect(Self.rendered(folders, [4])["de"] == "4 Ordner aus dem Archiv entpacken?")
        #expect(Self.rendered(folders, [2])["uk"] == "Видобути 2 папки з архіву?")
    }
}
