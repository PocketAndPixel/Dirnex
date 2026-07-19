import Foundation
import Testing

@testable import DirnexCore

@Suite("SpotlightQuery")
struct SpotlightQueryTests {
    @Test("an all-default query is empty and yields no predicate")
    func emptyQuery() {
        let query = SpotlightQuery()
        #expect(query.isEmpty)
        #expect(query.metadataPredicate() == nil)
        #expect(query.mdfindArguments(scopePath: "/tmp").isEmpty)
    }

    @Test("whitespace-only name/content still counts as empty")
    func whitespaceIsEmpty() {
        let query = SpotlightQuery(nameContains: "   ", contentContains: "\n\t")
        #expect(query.isEmpty)
        #expect(query.metadataPredicate() == nil)
    }

    @Test("a name term builds a case/diacritic-insensitive substring clause")
    func namePredicate() {
        let query = SpotlightQuery(nameContains: "report")
        #expect(!query.isEmpty)
        #expect(query.metadataPredicate() == #"kMDItemFSName == "*report*"cd"#)
    }

    @Test("a name term is trimmed before it is embedded")
    func nameTrimmed() {
        let query = SpotlightQuery(nameContains: "  budget  ")
        #expect(query.metadataPredicate() == #"kMDItemFSName == "*budget*"cd"#)
    }

    @Test("a content term builds a text-content substring clause")
    func contentPredicate() {
        let query = SpotlightQuery(contentContains: "quarterly")
        #expect(query.metadataPredicate() == #"kMDItemTextContent == "*quarterly*"cd"#)
    }

    @Test("name and content clauses AND together in order")
    func nameAndContent() {
        let query = SpotlightQuery(nameContains: "memo", contentContains: "urgent")
        #expect(
            query.metadataPredicate()
                == #"kMDItemFSName == "*memo*"cd && kMDItemTextContent == "*urgent*"cd"#
        )
    }

    @Test("a single kind becomes a parenthesized content-type-tree clause")
    func singleKind() {
        let query = SpotlightQuery(kinds: [.image])
        #expect(query.metadataPredicate() == #"(kMDItemContentTypeTree == "public.image"c)"#)
    }

    @Test("multiple kinds OR together in CaseIterable order regardless of set order")
    func multipleKindsAreOrdered() {
        let query = SpotlightQuery(kinds: [.archive, .folder, .image])
        // Declaration order is folder, image, …, archive — so folder comes first, archive last.
        #expect(
            query.metadataPredicate()
                == #"(kMDItemContentTypeTree == "public.folder"c || "#
                + #"kMDItemContentTypeTree == "public.image"c || "#
                + #"kMDItemContentTypeTree == "public.archive"c)"#
        )
    }

    @Test("a minimum size becomes a byte comparison")
    func minimumSize() {
        let query = SpotlightQuery(minSizeBytes: 1_048_576)
        #expect(query.metadataPredicate() == "kMDItemFSSize >= 1048576")
    }

    @Test("a modified-within window becomes a relative $time.now offset")
    func modifiedWithin() {
        let query = SpotlightQuery(modifiedWithin: .week)
        #expect(
            query.metadataPredicate()
                == "kMDItemFSContentChangeDate >= $time.now(-604800)"
        )
    }

    @Test("every clause ANDs together in the fixed name→content→kind→size→date order")
    func allClausesCombine() {
        let query = SpotlightQuery(
            nameContains: "photo",
            contentContains: "beach",
            kinds: [.image],
            minSizeBytes: 500,
            modifiedWithin: .today
        )
        #expect(
            query.metadataPredicate()
                == #"kMDItemFSName == "*photo*"cd"#
                + #" && kMDItemTextContent == "*beach*"cd"#
                + #" && (kMDItemContentTypeTree == "public.image"c)"#
                + " && kMDItemFSSize >= 500"
                + " && kMDItemFSContentChangeDate >= $time.now(-86400)"
        )
    }

    // MARK: - Tag chips

    /// Spotlight compares a multi-valued attribute member-wise, so this reads "carries Work among
    /// its tags". Case-insensitive (`c`) to match how macOS identifies a tag, but deliberately not
    /// diacritic-insensitive: `Café` and `Cafe` are two different tags to the system.
    @Test("a tag chip matches the multi-valued user-tags attribute by name")
    func singleTagClause() {
        let query = SpotlightQuery(tags: ["Work"])
        #expect(query.metadataPredicate() == #"kMDItemUserTags == "Work"c"#)
        #expect(!query.isEmpty)
    }

    /// Tags AND where kinds OR — a second kind chip broadens ("images *or* movies"), a second tag
    /// chip narrows. Someone adding "Urgent" to "Work" is asking for the overlap.
    @Test("tag chips AND together, sorted so a Set yields a deterministic predicate")
    func tagChipsAnd() {
        let query = SpotlightQuery(tags: ["Work", "Urgent"])
        #expect(
            query.metadataPredicate() == #"kMDItemUserTags == "Urgent"c && kMDItemUserTags == "Work"c"#
        )
        // Same set, built the other way round — the predicate must not depend on Set iteration order.
        #expect(
            SpotlightQuery(tags: ["Urgent", "Work"]).metadataPredicate() == query.metadataPredicate()
        )
    }

    @Test("tag chips join the other clauses at the end of the fixed order")
    func tagClausesComeLast() {
        let query = SpotlightQuery(nameContains: "photo", kinds: [.image], tags: ["Trip"])
        #expect(
            query.metadataPredicate()
                == #"kMDItemFSName == "*photo*"cd"#
                + #" && (kMDItemContentTypeTree == "public.image"c)"#
                + #" && kMDItemUserTags == "Trip"c"#
        )
    }

    @Test("blank and whitespace-only tags are dropped rather than matching everything")
    func blankTagsDropped() {
        #expect(SpotlightQuery(tags: ["", "   "]).isEmpty)
        #expect(SpotlightQuery(tags: ["", "   "]).metadataPredicate() == nil)
        #expect(
            SpotlightQuery(tags: [" Work "]).metadataPredicate() == #"kMDItemUserTags == "Work"c"#
        )
    }

    /// A tag name is user text and can hold the characters that end an mdfind string literal.
    @Test("a tag name's quotes are escaped like any other term")
    func tagNameEscaped() {
        #expect(
            SpotlightQuery(tags: [#"a"b"#]).metadataPredicate() == #"kMDItemUserTags == "a\"b"c"#
        )
    }

    @Test("a lone tag chip names the results panel")
    func tagSummary() {
        #expect(SpotlightQuery(tags: ["Work"]).summaryPlainName == "Work")
        #expect(SpotlightQuery(tags: ["Work", "Urgent"]).summaryPlainName == "Search results")
        // A name still outranks it — the more specific term wins.
        #expect(SpotlightQuery(nameContains: "photo", tags: ["Work"]).summaryPlainName == "photo")
    }

    /// Saved searches persisted before tags existed have no `tags` key, and the synthesized decoder
    /// throws on a missing one — which would not fail loudly, it would empty the user's Searches
    /// sidebar on upgrade.
    @Test("a query saved before tags existed still decodes")
    func decodesLegacyPayloadWithoutTags() throws {
        let legacy = #"{"nameContains":"photo","contentContains":"","kinds":["image"],"minSizeBytes":500}"#
        let decoded = try JSONDecoder().decode(SpotlightQuery.self, from: Data(legacy.utf8))
        #expect(decoded.tags.isEmpty)
        #expect(decoded.nameContains == "photo")
        #expect(decoded.kinds == [.image])
        #expect(decoded.minSizeBytes == 500)
        #expect(decoded.metadataPredicate() != nil)
    }

    @Test("a term's quotes and backslashes are escaped so they can't break the literal")
    func escapesQuotesAndBackslashes() {
        let query = SpotlightQuery(nameContains: #"a"b\c"#)
        #expect(query.metadataPredicate() == #"kMDItemFSName == "*a\"b\\c*"cd"#)
    }

    @Test("mdfind arguments prepend -onlyin for a scope and end with the predicate")
    func scopedArguments() {
        let query = SpotlightQuery(nameContains: "todo")
        let arguments = query.mdfindArguments(scopePath: "/Users/me/Docs")
        #expect(arguments == ["-onlyin", "/Users/me/Docs", #"kMDItemFSName == "*todo*"cd"#])
    }

    @Test("mdfind arguments omit -onlyin when the scope is nil or empty")
    func unscopedArguments() {
        let query = SpotlightQuery(nameContains: "todo")
        #expect(query.mdfindArguments(scopePath: nil) == [#"kMDItemFSName == "*todo*"cd"#])
        #expect(query.mdfindArguments(scopePath: "") == [#"kMDItemFSName == "*todo*"cd"#])
    }

    @Test("the summary prefers the name, then content, then a lone kind, then a fallback")
    func summaryPrecedence() {
        #expect(SpotlightQuery(nameContains: "  taxes ").summary == "“taxes”")
        #expect(SpotlightQuery(contentContains: "invoice").summary == "“invoice”")
        #expect(SpotlightQuery(kinds: [.movie]).summary == "Movies")
        #expect(SpotlightQuery(kinds: [.movie, .image]).summary == "Search results")
        #expect(SpotlightQuery(minSizeBytes: 10).summary == "Search results")
    }

    @Test("the plain-name summary drops the display quotes for an editable default")
    func summaryPlainName() {
        #expect(SpotlightQuery(nameContains: "  taxes ").summaryPlainName == "taxes")
        #expect(SpotlightQuery(contentContains: "invoice").summaryPlainName == "invoice")
        #expect(SpotlightQuery(kinds: [.movie]).summaryPlainName == "Movies")
        #expect(SpotlightQuery(minSizeBytes: 10).summaryPlainName == "Search results")
    }

    @Test("a fully-populated query round-trips through Codable so it can be saved")
    func codableRoundTrip() throws {
        let query = SpotlightQuery(
            nameContains: "report",
            contentContains: "quarterly",
            kinds: [.document, .archive],
            minSizeBytes: 2048,
            modifiedWithin: .month,
            tags: ["Work", "Urgent"]
        )
        let decoded = try JSONDecoder().decode(
            SpotlightQuery.self,
            from: try JSONEncoder().encode(query)
        )
        #expect(decoded == query)
        #expect(decoded.tags == ["Work", "Urgent"])
        #expect(decoded.metadataPredicate() == query.metadataPredicate())
    }
}
