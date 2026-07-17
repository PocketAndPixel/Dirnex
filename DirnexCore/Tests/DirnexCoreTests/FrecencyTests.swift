import Foundation
import Testing

@testable import DirnexCore

@Suite("Frecency")
struct FrecencyTests {
    private func path(_ raw: String) -> VFSPath { .local(raw) }

    // A fixed clock so recency-dependent scores are deterministic.
    private let now = Date(timeIntervalSince1970: 1_000_000_000)
    private func ago(_ interval: TimeInterval) -> Date { now.addingTimeInterval(-interval) }

    @Test("a fresh index is empty and matches nothing")
    func startsEmpty() {
        let frecency = Frecency()
        #expect(frecency.entries.isEmpty)
        #expect(frecency.matches(for: "anything", now: now).isEmpty)
    }

    @Test("a first visit inserts an entry at rank 1")
    func firstVisitInserts() {
        var frecency = Frecency()
        frecency.visit(path("/Users/me/Downloads"), now: now)
        #expect(frecency.entries.count == 1)
        #expect(frecency.entries[0].path == path("/Users/me/Downloads"))
        #expect(frecency.entries[0].rank == 1)
        #expect(frecency.entries[0].lastAccess == now)
    }

    @Test("re-visiting a path bumps its rank rather than duplicating it")
    func revisitBumpsRank() {
        var frecency = Frecency()
        let dir = path("/a/b")
        frecency.visit(dir, now: ago(10))
        frecency.visit(dir, now: now)
        #expect(frecency.entries.count == 1)
        #expect(frecency.entries[0].rank == 2)
        // The latest visit's timestamp wins.
        #expect(frecency.entries[0].lastAccess == now)
    }

    @Test("the recency multiplier weights recent visits far above old ones")
    func recencyBuckets() {
        let frecency = Frecency()
        let base = FrecencyEntry(path: path("/x"), rank: 1, lastAccess: now)
        func score(_ elapsed: TimeInterval) -> Double {
            frecency.score(
                for: FrecencyEntry(path: path("/x"), rank: 1, lastAccess: ago(elapsed)),
                now: now
            )
        }
        #expect(score(60) == 4) // within the hour
        #expect(score(3600 + 60) == 2) // within the day
        #expect(score(86_400 + 60) == 0.5) // within the week
        #expect(score(604_800 + 60) == 0.25) // older
        // A future timestamp (clock skew) falls into the most-recent bucket, not below it.
        #expect(frecency.score(for: base, now: ago(60)) == 4)
    }

    @Test("a recent low-rank directory outranks an old high-rank one")
    func recencyBeatsRawFrequency() {
        var frecency = Frecency()
        // Visited many times, but a week+ ago (0.25×).
        let stale = path("/proj/library")
        for _ in 0..<8 { frecency.visit(stale, now: ago(604_800 + 100)) }
        // Visited just twice, but within the hour (4×).
        let fresh = path("/proj/lib")
        frecency.visit(fresh, now: ago(30))
        frecency.visit(fresh, now: ago(20))

        // Query "lib" fuzzily matches both folder names; frecency picks the fresh one:
        // 2 · 4 = 8 beats 8 · 0.25 = 2.
        #expect(frecency.matches(for: "lib", now: now).first?.path == fresh)
    }

    @Test("a slash-free fragment fuzzily matches the folder name (dl → Downloads)")
    func fuzzyFragmentMatchesLastComponent() {
        var frecency = Frecency()
        frecency.visit(path("/Users/me/Downloads"), now: now)
        frecency.visit(path("/Users/me/Documents"), now: now)
        #expect(frecency.matches(for: "dl", now: now).first?.path == path("/Users/me/Downloads"))
        #expect(frecency.matches(for: "dc", now: now).first?.path == path("/Users/me/Documents"))
    }

    @Test("matching is against the last component only, not deeper path segments")
    func matchesLastComponentNotAncestors() {
        var frecency = Frecency()
        // "downloads" appears as an ancestor, but the folder itself is "reports".
        frecency.visit(path("/Users/me/downloads/reports"), now: now)
        // "dl" matches nothing in "reports", so no match despite the ancestor.
        #expect(frecency.matches(for: "dl", now: now).isEmpty)
        #expect(
            frecency.matches(for: "rp", now: now).first?.path == path("/Users/me/downloads/reports")
        )
    }

    @Test("matching is case-insensitive and an empty query matches nothing")
    func caseInsensitiveAndEmpty() {
        var frecency = Frecency()
        frecency.visit(path("/A/Photos"), now: now)
        #expect(frecency.matches(for: "PHT", now: now).first?.path == path("/A/Photos"))
        #expect(frecency.matches(for: "", now: now).isEmpty)
        #expect(frecency.matches(for: "   ", now: now).isEmpty)
    }

    @Test("matches returns every hit, best first")
    func matchesReturnsRanked() {
        var frecency = Frecency()
        let often = path("/a/src")
        let rare = path("/b/source")
        frecency.visit(rare, now: now)
        for _ in 0..<3 { frecency.visit(often, now: now) }
        let hits = frecency.matches(for: "src", now: now).map(\.path)
        #expect(hits == [often, rare])
    }

    @Test("aging scales ranks down and drops entries that fall below one")
    func agingBoundsTheIndex() {
        // A tiny budget so a couple of visits trip aging deterministically.
        var frecency = Frecency(maxAge: 3)
        frecency.visit(path("/a"), now: now) // rank 1, total 1
        frecency.visit(path("/b"), now: now) // rank 1, total 2
        frecency.visit(path("/a"), now: now) // /a → 2, total 3 (not over yet)
        frecency.visit(path("/c"), now: now) // total 4 > 3 → age

        // factor = 0.9 · 3 / 4 = 0.675. Ranks: /a 2·.675=1.35 (kept), /b .675 (<1, dropped),
        // /c .675 (<1, dropped).
        let byPath = Dictionary(uniqueKeysWithValues: frecency.entries.map { ($0.path, $0.rank) })
        #expect(byPath[path("/a")] != nil)
        #expect(byPath[path("/b")] == nil)
        #expect(byPath[path("/c")] == nil)
        #expect(abs((byPath[path("/a")] ?? 0) - 1.35) < 0.0001)
    }

    @Test("the de-duplicating initializer collapses duplicate paths, keeping the first")
    func initDeduplicates() {
        let frecency = Frecency(entries: [
            FrecencyEntry(path: path("/a"), rank: 5, lastAccess: now),
            FrecencyEntry(path: path("/a"), rank: 1, lastAccess: ago(100)),
            FrecencyEntry(path: path("/b"), rank: 2, lastAccess: now)
        ])
        #expect(frecency.entries.count == 2)
        #expect(frecency.entries[0].rank == 5) // the first occurrence survived
    }

    @Test("the index round-trips through JSON, preserving ranks, timestamps, and budget")
    func jsonRoundTrip() throws {
        var frecency = Frecency(maxAge: 500)
        frecency.visit(path("/a/b"), now: ago(42))
        frecency.visit(path("/a/b"), now: now)
        frecency.visit(path("/c"), now: ago(1000))

        let data = try JSONEncoder().encode(frecency)
        let decoded = try JSONDecoder().decode(Frecency.self, from: data)
        #expect(decoded == frecency)
        #expect(decoded.maxAge == 500)
        #expect(decoded.matches(for: "b", now: now).first?.path == path("/a/b"))
    }

    @Test("a store written before maxAge existed decodes with the default budget")
    func decodesLegacyWithoutMaxAge() throws {
        let json = """
        { "entries": [ { "path": { "backend": "local", "path": "/a" }, "rank": 1, \
        "lastAccess": 0 } ] }
        """
        let decoded = try JSONDecoder().decode(Frecency.self, from: Data(json.utf8))
        #expect(decoded.entries.count == 1)
        #expect(decoded.maxAge == 10_000)
    }
}
