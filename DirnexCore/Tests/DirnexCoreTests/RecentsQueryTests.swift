import Foundation
import Testing

@testable import DirnexCore

@Suite("Recents query")
struct RecentsQueryTests {
    @Test("the default window is 30 days")
    func defaultWindow() {
        #expect(RecentsQuery.defaultWindowSeconds == 2_592_000)
        #expect(RecentsQuery().usedWithinSeconds == 2_592_000)
    }

    @Test("the predicate filters by last-used within the window and excludes app bundles")
    func predicate() {
        // Last-*used*, not last-modified: that is what keeps Recents to opened documents rather than
        // a wall of `~/Library` churn, and the reason this isn't just a `SpotlightQuery`.
        #expect(
            RecentsQuery().metadataPredicate()
                == "(kMDItemLastUsedDate >= $time.now(-2592000))"
                + " && (kMDItemContentTypeTree != \"com.apple.application-bundle\")"
        )
    }

    @Test("the window is expressed as a relative offset, so a custom window flows through")
    func customWindow() {
        #expect(
            RecentsQuery(usedWithinSeconds: 604_800).metadataPredicate()
                == "(kMDItemLastUsedDate >= $time.now(-604800))"
                + " && (kMDItemContentTypeTree != \"com.apple.application-bundle\")"
        )
    }

    @Test("the argument vector is the predicate alone — everywhere, never scoped")
    func arguments() {
        let arguments = RecentsQuery().mdfindArguments()
        // No `-onlyin`: Recents searches every indexed volume, like Finder's, so a scope flag would
        // be the bug.
        #expect(arguments == [RecentsQuery().metadataPredicate()])
        #expect(!arguments.contains("-onlyin"))
    }

    @Test("results present newest-modified first, files not grouped behind folders")
    func resultSort() {
        // A recency proxy: `mdfind` can't sort and a statted entry has no last-used date, so
        // modification-descending is the orderable signal. `directoriesFirst` off so the ordering is
        // purely recency, not folders-then-files.
        #expect(RecentsQuery.resultSort.key == .modified)
        #expect(RecentsQuery.resultSort.ascending == false)
        #expect(RecentsQuery.resultSort.directoriesFirst == false)
    }
}
