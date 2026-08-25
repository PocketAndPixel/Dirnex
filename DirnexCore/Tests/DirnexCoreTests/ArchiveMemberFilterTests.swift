import Testing

@testable import DirnexCore

/// The rule ``ArchiveMemberFilter`` applies, tested as a pure function over strings.
///
/// Its job is to agree with `bsdtar`'s member matching, since the two extraction routes serve the
/// same gestures and a user cannot see which one ran — so the cases here are the ones where the two
/// could plausibly disagree (a directory member, a trailing slash, a partial component) rather than
/// a sample of names.
@Suite("ArchiveMemberFilter")
struct ArchiveMemberFilterTests {
    @Test("no filter takes every entry, whatever it is called")
    func everythingTakesEverything() {
        let filter = ArchiveMemberFilter.everything
        for name in ["a.txt", "docs/", "docs/api/x.md", "../evil", "", "/absolute"] {
            #expect(filter.includes(entryNamed: name), "should have taken \(name)")
        }
    }

    @Test("naming zero members selects nothing — not the same as naming none")
    func emptyListSelectsNothing() {
        let filter = ArchiveMemberFilter.members([])
        #expect(!filter.includes(entryNamed: "a.txt"))
    }

    @Test("a file member matches itself and nothing else")
    func fileMemberMatchesItself() {
        let filter = ArchiveMemberFilter.members(["/docs/api/x.md"])
        #expect(filter.includes(entryNamed: "docs/api/x.md"))
        #expect(!filter.includes(entryNamed: "docs/api/y.md"))
        #expect(!filter.includes(entryNamed: "docs/api"))
        #expect(!filter.includes(entryNamed: "other/docs/api/x.md"))
    }

    /// The claim F5 on a folder inside an archive rests on: `bsdtar` extracts a directory member
    /// recursively, so a filter that matched only the directory entry itself would copy out an
    /// empty folder and report success.
    @Test("a directory member takes everything beneath it")
    func directoryMemberTakesItsSubtree() {
        let filter = ArchiveMemberFilter.members(["/docs"])
        #expect(filter.includes(entryNamed: "docs"))
        #expect(filter.includes(entryNamed: "docs/"))
        #expect(filter.includes(entryNamed: "docs/x.md"))
        #expect(filter.includes(entryNamed: "docs/api/"))
        #expect(filter.includes(entryNamed: "docs/api/deep.md"))
    }

    /// Matching on whole components rather than on a string prefix. `docs` must not take `docs2`,
    /// which is what a bare `hasPrefix` would do — the same distinction an S3 listing prefix needs.
    @Test("a member matches whole path components, never a partial name")
    func matchesOnComponentBoundaries() {
        let filter = ArchiveMemberFilter.members(["docs"])
        #expect(!filter.includes(entryNamed: "docs2/x.md"))
        #expect(!filter.includes(entryNamed: "docs-old"))
        #expect(!filter.includes(entryNamed: "documents/x.md"))
    }

    /// A directory entry carries a trailing slash in both zip and tar and the request for it does
    /// not, so the two spellings have to meet somewhere. Both directions, since either side can
    /// carry one.
    @Test("trailing and leading slashes are the same name on both sides")
    func slashesAreNormalizedOnBothSides() {
        #expect(ArchiveMemberFilter.members(["/notes/"]).includes(entryNamed: "notes/"))
        #expect(ArchiveMemberFilter.members(["notes"]).includes(entryNamed: "notes/"))
        #expect(ArchiveMemberFilter.members(["/notes/"]).includes(entryNamed: "notes"))
        #expect(ArchiveMemberFilter.members(["/notes/"]).includes(entryNamed: "notes/hello.txt"))
    }

    @Test("several members are taken together")
    func severalMembers() {
        let filter = ArchiveMemberFilter.members(["/a.txt", "/docs"])
        #expect(filter.includes(entryNamed: "a.txt"))
        #expect(filter.includes(entryNamed: "docs/x.md"))
        #expect(!filter.includes(entryNamed: "b.txt"))
    }

    /// Glob metacharacters are the `bsdtar` route's problem and not this one's: it escapes them
    /// because `bsdtar` matches shell patterns, while this compares strings. A name that would need
    /// escaping there is simply its own name here — worth pinning, since the two routes' member
    /// spellings sit a few lines apart and one is escaped.
    @Test("a name holding glob metacharacters matches literally, unescaped")
    func globMetacharactersAreLiteral() {
        let filter = ArchiveMemberFilter.members(["/weird[1].txt"])
        #expect(filter.includes(entryNamed: "weird[1].txt"))
        #expect(!filter.includes(entryNamed: "weird1.txt"))

        #expect(!ArchiveMemberFilter.members(["/*.txt"]).includes(entryNamed: "a.txt"))
    }
}
