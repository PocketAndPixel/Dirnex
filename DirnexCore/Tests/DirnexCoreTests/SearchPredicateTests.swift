import Foundation
import Testing

@testable import DirnexCore

/// Which fields a place can answer, and the refusal that keeps a query from running without one of
/// them (PLAN.md §M22 Slice 1).
@Suite("Search fields")
struct SearchFieldsTests {
    @Test("the local index answers everything")
    func localIsIndexed() {
        #expect(SearchFields.answerable(by: .local) == .indexed)
    }

    /// The three connected backends and an archive together rather than one test each: they answer
    /// through one predicate, and asserting them separately would pass even if the set had been
    /// keyed on a list of cases a fourth backend later missed.
    @Test("a listing answers name, kind, size and date — never content or tags")
    func remoteIsListingOnly() {
        let listingOnly: [VFSBackendID] = [
            .sftp(SFTPLocation(host: "h", username: "u")),
            .ftp(FTPLocation(host: "h", username: "u")),
            .s3(S3Location(host: "h", bucket: "b", region: "r", accessKeyID: "k")),
            .archive(forArchiveAt: "/tmp/pkg.zip")
        ]
        for backend in listingOnly {
            let fields = SearchFields.answerable(by: backend)
            #expect(fields == .listed, "\(backend) should answer only what a listing carries")
            #expect(!fields.contains(.content))
            #expect(!fields.contains(.tags))
        }
    }

    @Test("a connected server walks, and the local disk does not")
    func routes() {
        #expect(SearchRoute.forBackend(.local) == .spotlight)
        #expect(SearchRoute.forBackend(.ftp(FTPLocation(host: "h", username: "u"))) == .walk)
        #expect(SearchRoute.forBackend(.archive(forArchiveAt: "/tmp/p.zip")) == .walk)
    }

    /// The one remote backend that is browsable and not searchable. It is a member of
    /// `isRemoteConnection`, so an ordering mistake in `forBackend` would silently make it walk —
    /// listing every bucket in the account, which is a much more expensive question than the one
    /// ⌥F7 asks.
    @Test("an S3 account pane is not searchable")
    func accountIsUnavailable() {
        let account = VFSBackendID.s3Account(S3Account(host: "h", region: "r", accessKeyID: "k"))
        #expect(account.isRemoteConnection)
        #expect(SearchRoute.forBackend(account) == .unavailable)
    }

    /// A virtual results container has no directory of its own; the app resolves such a pane's scope
    /// to a real one before asking. Pinned so the answer is a decision rather than a fall-through.
    @Test("the virtual containers have nothing to walk")
    func virtualsAreUnavailable() {
        for backend in [VFSBackendID.search, .trash, .icloud] {
            #expect(SearchRoute.forBackend(backend) == .unavailable, "\(backend)")
        }
    }
}

/// The compiled query. Every rule that differs from the Spotlight route has its own test, since a
/// divergence nobody wrote down is the one that reads as a bug.
@Suite("Search predicate")
struct SearchPredicateTests {
    private func entry(
        _ name: String,
        kind: FileEntry.Kind = .file,
        size: Int64 = 0,
        modified: Date = Date(timeIntervalSince1970: 1_700_000_000)
    ) -> FileEntry {
        FileEntry(
            path: .local("/tmp/\(name)"),
            name: name,
            kind: kind,
            byteSize: size,
            modificationDate: modified,
            creationDate: modified,
            isHidden: name.hasPrefix("."),
            permissions: 0o644,
            ownerID: 501,
            groupID: 20,
            flags: 0,
            inode: 1
        )
    }

    // MARK: - Refusing what it cannot answer

    @Test("a content search cannot be compiled for a listing")
    func contentIsRefused() {
        let query = FileQuery(nameContains: "report", contentContains: "invoice")
        let error = #expect(throws: SearchQueryUnanswerable.self) {
            try SearchPredicate(query, answering: .listed)
        }
        #expect(error?.fields == .content)
    }

    /// Both missing fields come back, not the first one — the sentence the user reads names what
    /// they typed, and naming half of it sends them to delete the wrong term.
    @Test("every unanswerable field is reported, not just the first")
    func allMissingFieldsReported() {
        let query = FileQuery(contentContains: "invoice", tags: ["Work"])
        let error = #expect(throws: SearchQueryUnanswerable.self) {
            try SearchPredicate(query, answering: .listed)
        }
        #expect(error?.fields == [.content, .tags])
    }

    /// The narrowness control for the refusal: everything a listing *does* carry compiles. Without
    /// this, "refuse content" could silently have become "refuse everything".
    @Test("name, kind, size and date compile against a listing")
    func listingFieldsCompile() throws {
        let query = FileQuery(
            nameContains: "a",
            kinds: [.image],
            minSizeBytes: 1024,
            modifiedWithin: .week
        )
        _ = try SearchPredicate(query, answering: .listed)
    }

    @Test("an empty term is not an asked-about field")
    func whitespaceIsNotAQuestion() throws {
        // A blank content field left untouched in the dialog must not make the query unrunnable.
        _ = try SearchPredicate(
            FileQuery(nameContains: "x", contentContains: "   "),
            answering: .listed
        )
    }

    // MARK: - Name

    @Test("the name match is case- and diacritic-insensitive, like the metadata predicate's `cd`")
    func nameFolding() throws {
        let predicate = try SearchPredicate(FileQuery(nameContains: "cafe"), answering: .listed)
        #expect(predicate.matches(entry("Café Notes.txt")))
        #expect(predicate.matches(entry("CAFE.txt")))
        #expect(!predicate.matches(entry("tea.txt")))
    }

    // MARK: - Kind

    @Test("kind is decided from the extension, and conformance rather than equality")
    func kindFromExtension() throws {
        let predicate = try SearchPredicate(FileQuery(kinds: [.image]), answering: .listed)
        #expect(predicate.matches(entry("a.png")))
        #expect(predicate.matches(entry("b.HEIC")))
        #expect(!predicate.matches(entry("c.txt")))
        // No extension at all is not an image — and must not crash the walk either.
        #expect(!predicate.matches(entry("README")))
    }

    /// The rule that keeps a directory from being typed by its own name. `holiday.photos` is a
    /// folder, and deriving a UTI from that extension is exactly how it would come back as one.
    @Test("a directory never matches a file kind, whatever it is called")
    func directoryIsNotTypedByName() throws {
        let images = try SearchPredicate(FileQuery(kinds: [.image]), answering: .listed)
        #expect(!images.matches(entry("holiday.png", kind: .directory)))

        let folders = try SearchPredicate(FileQuery(kinds: [.folder]), answering: .listed)
        #expect(folders.matches(entry("holiday.png", kind: .directory)))
        #expect(!folders.matches(entry("holiday.png")))
    }

    // MARK: - Size and date, the two questions about files

    @Test("a directory never satisfies a size filter")
    func sizeIsAboutFiles() throws {
        let predicate = try SearchPredicate(
            FileQuery(minSizeBytes: 1024),
            answering: .listed
        )
        #expect(predicate.matches(entry("big.bin", size: 4096)))
        #expect(!predicate.matches(entry("small.bin", size: 16)))
        // A remote listing reports no size for a folder, so a match here would be vacuous.
        #expect(!predicate.matches(entry("folder", kind: .directory, size: 4096)))
    }

    /// An S3 "folder" is a common prefix with no `LastModified` at all, which arrives as
    /// `FileEntry.unknownDate`. It must not match a date question because nothing contradicted it.
    @Test("a row with no date never satisfies a date filter")
    func unknownDateNeverMatches() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let predicate = try SearchPredicate(
            FileQuery(modifiedWithin: .week),
            answering: .listed,
            now: now
        )
        #expect(predicate.matches(entry("fresh.txt", modified: now.addingTimeInterval(-3600))))
        #expect(!predicate.matches(entry("old.txt", modified: now.addingTimeInterval(-999_999))))
        #expect(
            !predicate.matches(
                entry("prefix", kind: .directory, modified: FileEntry.unknownDate)
            )
        )
    }

    /// The window is resolved once, at construction. A remote walk runs for minutes, and a cutoff
    /// re-derived per entry would let the same file match at the start of a search and miss at the
    /// end — a result set that disagrees with itself.
    @Test("the date window is fixed at compile time, not re-read per entry")
    func windowIsFixed() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let predicate = try SearchPredicate(
            FileQuery(modifiedWithin: .today),
            answering: .listed,
            now: now
        )
        // Exactly on the boundary matches; a second older does not — which is only a stable claim
        // because the cutoff cannot move underneath it.
        let cutoff = now.addingTimeInterval(-Double(SearchAge.today.seconds))
        #expect(predicate.matches(entry("edge", modified: cutoff)))
        #expect(!predicate.matches(entry("past", modified: cutoff.addingTimeInterval(-1))))
    }

    // MARK: - Clauses AND

    @Test("clauses narrow, exactly as the metadata predicate's do")
    func clausesAnd() throws {
        let predicate = try SearchPredicate(
            FileQuery(nameContains: "holiday", kinds: [.image], minSizeBytes: 1000),
            answering: .listed
        )
        #expect(predicate.matches(entry("holiday-01.jpg", size: 2000)))
        #expect(!predicate.matches(entry("holiday-01.jpg", size: 10)))
        #expect(!predicate.matches(entry("work-01.jpg", size: 2000)))
        #expect(!predicate.matches(entry("holiday-notes.txt", size: 2000)))
    }
}
