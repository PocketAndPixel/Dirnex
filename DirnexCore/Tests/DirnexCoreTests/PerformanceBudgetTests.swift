import Foundation
import Testing

@testable import DirnexCore

/// Performance budgets for the M1 hot paths, measured on a synthetic 100k "dirty"
/// directory (PLAN.md §M7 perf pass; §5 success-metric table). This is the
/// instruments audit made reproducible and CI-gated.
///
/// Budgets are **enforced only in release builds**. A debug `swift test` runs
/// unoptimized Swift 3–5× slower, so debug numbers would give false failures — the
/// suite still prints its measurements there, but the `#expect`s are compiled out.
/// CI runs this suite with `swift test -c release` (see `.github/workflows/ci.yml`).
///
/// What each budget protects:
/// - **filter keystroke < 16 ms** — type-to-filter must feel instant even on a huge
///   directory. Met with wide margin (~1–2 ms) because a keystroke re-filters the
///   already-sorted list instead of re-sorting it (`DirectoryModel.refilter`).
/// - **list build (sort)** — opening a directory sorts it with Finder-exact
///   `localizedStandardCompare`, whose collation is a hard ~350 ms floor at 100k that
///   no in-thread trick beats without diverging from Finder's order (probed: a custom
///   byte key disagrees with `localizedStandardCompare` on ~12% of Unicode pairs). The
///   gate here is a **regression ceiling** that catches an accidental O(n²) blow-up,
///   not the 150 ms interactive target — that target is met by sorting off the main
///   thread at the app layer, not by making the sort itself faster.
@Suite("PerformanceBudget", .serialized)
struct PerformanceBudgetTests {
    private static let count = 100_000

    /// A synthetic listing that stresses the sort/filter the way a real messy directory
    /// does: many entries, varied name lengths, a scatter of directories and dotfiles,
    /// numeric runs (so natural-order collation actually has work to do).
    private func dirtyListing(_ count: Int = count) -> DirectoryListing {
        var rng = SeededGenerator(seed: 0x1234_5678)
        let words = [
            "report",
            "image",
            "src",
            "node_modules",
            "IMG",
            "Document",
            "backup",
            "archive",
            "DATA",
            "temp",
            "cache",
            "Screenshot",
            "final"
        ]
        var entries: [FileEntry] = []
        entries.reserveCapacity(count)
        for i in 0..<count {
            let word = words[Int.random(in: 0..<words.count, using: &rng)]
            let name = "\(word)-\(i)-\(UInt16.random(in: 0...9999, using: &rng)).dat"
            entries.append(FileEntry(
                path: .local("/probe/\(name)"),
                name: name,
                kind: i % 20 == 0 ? .directory : .file,
                byteSize: Int64.random(in: 0...1_000_000_000, using: &rng),
                modificationDate: Date(
                    timeIntervalSince1970: Double.random(in: 0...1_800_000_000, using: &rng)
                ),
                creationDate: Date(timeIntervalSince1970: 1_000_000),
                isHidden: i % 50 == 0,
                permissions: 0o644,
                inode: UInt64(i)
            ))
        }
        return DirectoryListing(path: .local("/probe"), entries: entries)
    }

    /// Best-of-`iterations` wall-clock milliseconds after one warm-up run — the minimum
    /// rejects scheduling noise, which is what a budget cares about.
    private func bestMillis(iterations: Int = 5, _ body: () -> Void) -> Double {
        body()
        var best = Double.greatestFiniteMagnitude
        for _ in 0..<iterations {
            let start = DispatchTime.now().uptimeNanoseconds
            body()
            best = min(best, Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
        }
        return best
    }

    private func enforce(_ measured: Double, budget: Double, label: String) {
        print(
            "BUDGET \(label): \(String(format: "%.2f", measured)) ms (budget \(String(format: "%.0f", budget)) ms)"
        )
        #if !DEBUG
            #expect(measured < budget, "\(label) took \(measured) ms, over the \(budget) ms budget")
        #endif
    }

    @Test("type-to-filter keystroke on a 100k directory stays under 16 ms")
    func filterKeystrokeUnderBudget() {
        var model = DirectoryModel(listing: dirtyListing())
        // Warm the lazy lowercased cache, then measure a steady-state keystroke: "n"
        // matches the most names, so it is the worst single keystroke (largest result).
        model.filter = "x"
        let measured = bestMillis { model.filter = "n" }
        enforce(measured, budget: 16, label: "filter keystroke (steady state)")
    }

    @Test("the first filter keystroke (lazy cache build) stays under 16 ms")
    func firstFilterKeystrokeUnderBudget() {
        // The one keystroke that also pays the lazy lowercased-cache build. Build a fresh
        // (cache-cold) model *outside* the timed region each iteration and time only the
        // `filter =` set, so the ~350 ms sort never contaminates the measurement.
        let listing = dirtyListing()
        var best = Double.greatestFiniteMagnitude
        for _ in 0..<5 {
            var model = DirectoryModel(listing: listing)
            let start = DispatchTime.now().uptimeNanoseconds
            model.filter = "no"
            best = min(best, Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
            _ = model.count
        }
        enforce(best, budget: 16, label: "filter keystroke (cold cache)")
    }

    @Test("building a 100k directory model does not regress into quadratic territory")
    func listBuildRegressionCeiling() {
        let listing = dirtyListing()
        let measured = bestMillis { _ = DirectoryModel(listing: listing) }
        // NOT the 150 ms interactive target (that is met off-main at the app layer): a
        // generous ceiling that still trips on an accidental O(n²) or per-entry-bridging
        // regression. Exact-collation sort of 100k is ~350 ms release; CI runners are
        // slower, hence the headroom.
        enforce(measured, budget: 1500, label: "100k model build (sort)")
    }
}

/// A deterministic PRNG so the synthetic corpus — and therefore the timings — are
/// reproducible run to run. A plain SplitMix64; quality is irrelevant here, determinism
/// is the point.
private struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var mixed = state
        mixed = (mixed ^ (mixed >> 30)) &* 0xBF58_476D_1CE4_E5B9
        mixed = (mixed ^ (mixed >> 27)) &* 0x94D0_49BB_1331_11EB
        return mixed ^ (mixed >> 31)
    }
}
