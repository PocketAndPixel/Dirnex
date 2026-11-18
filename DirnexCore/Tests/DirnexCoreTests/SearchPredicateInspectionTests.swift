import Foundation
import Testing

@testable import DirnexCore

/// The two clauses a walk answers by reading the file, where Spotlight does not index the folder
/// (PLAN.md §M40 Slice 3): Finder tags and text.
///
/// Driven by a recording inspector, since what matters here is *when* a file is read as much as what
/// the answer is: never past a clause the listing already ruled out, and never for a folder's text.
@Suite("Search predicate: tags and content")
struct SearchPredicateInspectionTests {
    private func entry(_ name: String, kind: FileEntry.Kind = .file) -> FileEntry {
        FileEntry(
            path: .local("/scratch/\(name)"),
            name: name,
            kind: kind,
            byteSize: 10,
            modificationDate: Date(timeIntervalSince1970: 1_700_000_000),
            creationDate: Date(timeIntervalSince1970: 1_700_000_000),
            isHidden: false,
            permissions: 0o644,
            inode: 1
        )
    }

    // MARK: - Refusing without a reader

    /// The proof `SearchPredicate` carries: a place that answers content, with nothing to read it,
    /// must refuse rather than run a name search under a content search's label.
    @Test("a place answering tags and content refuses them with nothing to read the file")
    func noInspectorRefuses() {
        let error = #expect(throws: SearchQueryUnanswerable.self) {
            try SearchPredicate(
                FileQuery(contentContains: "invoice", tags: ["Work"]),
                answering: .indexed
            )
        }
        #expect(error?.fields == [.content, .tags])
    }

    @Test("an inspector that reads only tags still refuses content")
    func partialInspectorRefuses() {
        let tagsOnly = RecordingInspector(fields: .tags)
        let error = #expect(throws: SearchQueryUnanswerable.self) {
            try SearchPredicate(
                FileQuery(contentContains: "invoice", tags: ["Work"]),
                answering: .indexed,
                inspector: tagsOnly
            )
        }
        #expect(error?.fields == .content)
    }

    /// The other direction: an inspector does not widen a place. A server answers the listing's
    /// fields, whatever reader is handed in.
    @Test("an inspector does not make a server answer content")
    func inspectorDoesNotWidenAPlace() {
        #expect(throws: SearchQueryUnanswerable.self) {
            try SearchPredicate(
                FileQuery(contentContains: "invoice"),
                answering: .listed,
                inspector: RecordingInspector()
            )
        }
    }

    @Test("a walk on this Mac reads files, and one on a server or in an archive does not")
    func walkingPredicates() throws {
        let query = FileQuery(contentContains: "invoice", tags: ["Work"])
        #expect(try SearchPredicate.walking(query, in: .local).readsFiles)
        for backend in [
            VFSBackendID.ftp(FTPLocation(host: "h", username: "u")),
            .archive(forArchiveAt: "/a.zip")
        ] {
            #expect(throws: SearchQueryUnanswerable.self) {
                try SearchPredicate.walking(query, in: backend)
            }
        }
        // A name search reads nothing, so it keeps the listing's rhythm.
        #expect(try !SearchPredicate.walking(FileQuery(nameContains: "x"), in: .local).readsFiles)
    }

    // MARK: - Tags

    @Test("every asked tag must be carried, in any case, and no diacritic is ignored")
    func tags() throws {
        let inspector = RecordingInspector(tags: [
            "/scratch/both.txt": ["Work", "Red"],
            "/scratch/one.txt": ["work"],
            "/scratch/cafe.txt": ["Cafe"],
            "/scratch/folder": ["Work", "Red"]
        ])
        let predicate = try SearchPredicate(
            FileQuery(tags: ["WORK", "red"]),
            answering: .indexed,
            inspector: inspector
        )
        #expect(predicate.matches(entry("both.txt")))
        #expect(!predicate.matches(entry("one.txt")))
        #expect(!predicate.matches(entry("none.txt")))
        // A folder carries tags as a file does.
        #expect(predicate.matches(entry("folder", kind: .directory)))

        let accented = try SearchPredicate(
            FileQuery(tags: ["Café"]),
            answering: .indexed,
            inspector: inspector
        )
        #expect(!accented.matches(entry("cafe.txt")))
    }

    // MARK: - Content

    @Test("text is asked of files only")
    func contentIsAboutFiles() throws {
        let inspector = RecordingInspector(text: [
            "/scratch/notes.txt": "the invoice",
            "/scratch/folder": "the invoice",
            "/scratch/link": "the invoice"
        ])
        let predicate = try SearchPredicate(
            FileQuery(contentContains: "invoice"),
            answering: .indexed,
            inspector: inspector
        )
        #expect(predicate.matches(entry("notes.txt")))
        #expect(!predicate.matches(entry("folder", kind: .directory)))
        #expect(!predicate.matches(entry("link", kind: .symlink)))
        #expect(inspector.textReads == ["/scratch/notes.txt"])
    }

    /// Each clause costs more than the one before: a name is free, a tag is one attribute, the text
    /// is the whole file.
    @Test("a file the listing rules out is never read, and its tags are read before its text")
    func cheapClausesFirst() throws {
        let inspector = RecordingInspector(
            tags: ["/scratch/report.txt": ["Work"]],
            text: ["/scratch/report.txt": "invoice", "/scratch/notes.txt": "invoice"]
        )
        let predicate = try SearchPredicate(
            FileQuery(nameContains: "report", contentContains: "invoice", tags: ["Work"]),
            answering: .indexed,
            inspector: inspector
        )
        #expect(!predicate.matches(entry("notes.txt")))
        #expect(inspector.tagReads.isEmpty)
        #expect(inspector.textReads.isEmpty)

        #expect(predicate.matches(entry("report.txt")))
        #expect(inspector.tagReads == ["/scratch/report.txt"])
        #expect(inspector.textReads == ["/scratch/report.txt"])

        let untagged = RecordingInspector(text: ["/scratch/report.txt": "invoice"])
        let needsTag = try SearchPredicate(
            FileQuery(contentContains: "invoice", tags: ["Work"]),
            answering: .indexed,
            inspector: untagged
        )
        #expect(!needsTag.matches(entry("report.txt")))
        #expect(untagged.textReads.isEmpty)
    }
}

/// Answers tags and text from tables, and records every read.
final class RecordingInspector: SearchInspector, @unchecked Sendable {
    let fields: SearchFields
    private let tags: [String: [String]]
    private let text: [String: String]
    private let lock = NSLock()
    private var tagReadPaths: [String] = []
    private var textReadPaths: [String] = []

    init(
        fields: SearchFields = [.tags, .content],
        tags: [String: [String]] = [:],
        text: [String: String] = [:]
    ) {
        self.fields = fields
        self.tags = tags
        self.text = text
    }

    var tagReads: [String] {
        lock.lock()
        defer { lock.unlock() }
        return tagReadPaths
    }

    var textReads: [String] {
        lock.lock()
        defer { lock.unlock() }
        return textReadPaths
    }

    func tagNames(of entry: FileEntry) -> [String] {
        lock.lock()
        tagReadPaths.append(entry.path.path)
        lock.unlock()
        return tags[entry.path.path] ?? []
    }

    func text(of entry: FileEntry, contains needle: String, isCancelled: () -> Bool) -> Bool {
        lock.lock()
        textReadPaths.append(entry.path.path)
        lock.unlock()
        return text[entry.path.path]?.localizedCaseInsensitiveContains(needle) ?? false
    }
}
