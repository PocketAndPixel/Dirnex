import Foundation

/// How a long comparison finds out it should stop (PLAN.md §M37 Slice 3).
///
/// Each stage takes a `check` closure generic in what it throws. The call that can be stopped passes
/// one that throws `CancellationError`; every other caller passes `{}`, whose error type is `Never`,
/// so a comparison nobody can stop stays non-throwing.
enum ComparisonStop {
    /// How many lines a loop walks between two checks: at about a microsecond a line, a Stop lands
    /// within a few tens of milliseconds.
    static let linesBetweenChecks = 1 << 14
    /// How many steps of a search between two checks.
    static let searchStepsBetweenChecks = 1 << 6
}
