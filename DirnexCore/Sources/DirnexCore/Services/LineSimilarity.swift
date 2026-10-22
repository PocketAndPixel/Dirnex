import Foundation

/// How alike two lines are, from 0 to 1, for deciding which lines of a changed block belong on the
/// same row of the compare window (PLAN.md §M31 Slice 2).
///
/// The measure is the Dice coefficient over pairs of adjacent characters: twice the pairs the two
/// lines share, over the pairs they have between them. `foo(a)` and `foo(b)` share three of five
/// pairs each and score 0.6; a comment and a call share almost none. Indentation is left out, so a
/// line that only moved in or out still matches itself, and case is folded when the comparison
/// folds it.
struct LineFingerprint {
    /// Lines at least this alike go on one row, with the differences inside them marked.
    static let pairingThreshold = 0.5

    /// Every pair of adjacent scalars, packed and sorted, so two fingerprints compare by a merge.
    private let pairs: [UInt64]
    /// The trimmed text, for lines too short to have a pair.
    private let trimmed: String

    init(_ content: Substring, ignoresCase: Bool) {
        let text = ignoresCase ? content.lowercased() : String(content)
        let trimmed = text.trimmingCharacters(in: CharacterSet(charactersIn: " \t"))
        var pairs: [UInt64] = []
        var previous: UInt32?
        for scalar in trimmed.unicodeScalars {
            if let previous {
                pairs.append(UInt64(previous) << 32 | UInt64(scalar.value))
            }
            previous = scalar.value
        }
        self.pairs = pairs.sorted()
        self.trimmed = trimmed
    }

    func similarity(to other: LineFingerprint) -> Double {
        if trimmed == other.trimmed {
            return 1
        }
        guard !pairs.isEmpty, !other.pairs.isEmpty else { return 0 }
        var shared = 0
        var mine = 0
        var theirs = 0
        while mine < pairs.count, theirs < other.pairs.count {
            if pairs[mine] == other.pairs[theirs] {
                shared += 1
                mine += 1
                theirs += 1
            } else if pairs[mine] < other.pairs[theirs] {
                mine += 1
            } else {
                theirs += 1
            }
        }
        return Double(2 * shared) / Double(pairs.count + other.pairs.count)
    }
}
