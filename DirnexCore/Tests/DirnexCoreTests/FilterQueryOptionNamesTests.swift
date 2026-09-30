import Testing

@testable import DirnexCore

/// What the bar's two toggles are stored as, so they can be remembered across surfaces and launches
/// (2026-09-18). The app owns *where* they are written (`QuickViewFindOptionsStore`); this is the
/// encoding, and the two claims worth pinning are that it round-trips and that it degrades rather
/// than trapping when it meets a name from somewhere else.
@Suite("Filter query option names")
struct FilterQueryOptionNamesTests {
    @Test("every option round-trips, alone and together")
    func roundTrips() {
        let sets: [FilterQuery.Options] = [
            [],
            .caseSensitive,
            .wholeWord,
            [.caseSensitive, .wholeWord]
        ]
        for options in sets {
            #expect(FilterQuery.Options(storedNames: options.storedNames) == options)
        }
    }

    /// The names are API from the moment one is written to a preferences domain, so they are pinned
    /// as literals: renaming one silently stops reading what every existing install has stored.
    @Test("the stored names are the ones already on disk")
    func namesAreStable() {
        #expect(FilterQuery.Options.caseSensitive.storedNames == ["caseSensitive"])
        #expect(FilterQuery.Options.wholeWord.storedNames == ["wholeWord"])
        #expect(
            FilterQuery.Options([.wholeWord, .caseSensitive]).storedNames
                == ["caseSensitive", "wholeWord"],
            "`named` order, so what is written does not depend on how the set was built"
        )
    }

    /// The completeness guard: an option added to the type without a name would be unstorable — it
    /// would read back off on the next launch, which is the quiet direction.
    @Test("every option has a name")
    func namesCoverEveryOption() {
        let named = FilterQuery.Options.named.reduce(into: FilterQuery.Options()) {
            $0.insert($1.option)
        }
        #expect(named == FilterQuery.Options.all)
        // Relationships rather than a count: a number here expires the day an option is added, in a
        // pass that has done nothing wrong — which is what happened when pattern search arrived.
        #expect(
            Set(FilterQuery.Options.named.map(\.name)).count == FilterQuery.Options.named.count,
            "no two options share a name"
        )
        #expect(
            Set(FilterQuery.Options.named.map(\.option.rawValue)).count
                == FilterQuery.Options.named.count,
            "no option is named twice"
        )
    }

    @Test("a name this build does not know is dropped, and the rest still read")
    func unknownNamesAreDropped() {
        #expect(FilterQuery.Options(storedNames: ["regexFromANewerBuild"]) == [])
        #expect(
            FilterQuery.Options(storedNames: ["caseSensitive", "regexFromANewerBuild"])
                == .caseSensitive
        )
        #expect(FilterQuery.Options(storedNames: []) == [])
        // Not a case fold: a domain holding the wrong spelling reads as nothing rather than as
        // something near it.
        #expect(FilterQuery.Options(storedNames: ["CaseSensitive"]) == [])
    }

    /// The narrowness control for the whole encoding: what is stored has to *mean* what the query
    /// reads, or the two could round-trip perfectly and still search the wrong way.
    @Test("a decoded option set is the one the query then reads by")
    func decodedOptionsReachTheQuery() {
        let decoded = FilterQuery.Options(storedNames: ["caseSensitive"])
        #expect(FilterQuery("Beta", options: decoded).matches("beta") == false)
        #expect(FilterQuery("Beta", options: decoded).matches("Beta"))
        #expect(FilterQuery("Beta", options: FilterQuery.Options(storedNames: [])).matches("beta"))
    }
}
