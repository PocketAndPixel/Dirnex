import Foundation

/// What a line comparison may overlook (PLAN.md §M31).
///
/// The whitespace and line-ending options are git's, on purpose: `git diff --no-index --minimal`
/// is the oracle `LineDiff` is tested against, and an option that meant something slightly different
/// here would have no oracle at all. Each case names the git flag it matches.
public struct LineDiffOptions: Sendable, Hashable {
    /// How whitespace inside a line counts.
    ///
    /// Whitespace is git's set: a space or a tab. A vertical tab, a form feed and a no-break space
    /// are content, as they are to git (probed 2026-10-22 with git 2.54). Every case but `compare`
    /// also overlooks the line terminator, which git treats as trailing whitespace: under any of its
    /// whitespace flags, CRLF against LF and a missing final newline count as no change.
    public enum Whitespace: Sendable, Hashable {
        /// Every space and tab counts.
        case compare
        /// Whitespace at the end of a line does not count (`--ignore-space-at-eol`).
        case ignoreTrailing
        /// A run of whitespace matches any other run, and whitespace at the end of a line does not
        /// count (`-b`). A run against none at all is still a change: `a b` and `ab` differ.
        case ignoreChanges
        /// No whitespace counts anywhere (`-w`): `a b` and `ab` match.
        case ignoreAll
    }

    public var whitespace: Whitespace
    /// Whether CRLF, LF, a lone CR and a missing final newline all match (`--ignore-cr-at-eol`).
    public var ignoresLineEndings: Bool
    /// Whether letters match regardless of case. git has no such flag; GNU diff's `-i` does.
    public var ignoresCase: Bool
    /// Whether to search for the fewest changed lines however long that takes, as `--minimal`
    /// does. Off, the search stops at a cost limit and settles for a near-minimal answer; on two
    /// dense 100 000-line files git's limit turned 12.7 s into 0.19 s for 1.1 % more changed lines.
    /// On is for tests, which compare against `--minimal`.
    public var isMinimal: Bool

    public init(
        whitespace: Whitespace = .compare,
        ignoresLineEndings: Bool = false,
        ignoresCase: Bool = false,
        isMinimal: Bool = false
    ) {
        self.whitespace = whitespace
        self.ignoresLineEndings = ignoresLineEndings
        self.ignoresCase = ignoresCase
        self.isMinimal = isMinimal
    }

    /// Whether the line terminator is part of what is compared.
    var comparesTerminators: Bool { whitespace == .compare && !ignoresLineEndings }

    /// The bytes that stand for `line` in a comparison: two lines match exactly when their keys do.
    ///
    /// **Bytes, never a `String`.** Swift compares and hashes strings by canonical equivalence, so
    /// *é* written precomposed (U+00E9) and decomposed (`e` U+0301) are equal strings and different
    /// files. git reports that line as changed, and so must this.
    func key(for line: TextLine) -> [UInt8] {
        var bytes = ignoresCase ? Array(line.content.lowercased().utf8) : Array(line.content.utf8)
        switch whitespace {
        case .compare:
            break
        case .ignoreTrailing:
            while let last = bytes.last, Self.isWhitespace(last) {
                bytes.removeLast()
            }
        case .ignoreChanges:
            bytes = Self.collapsingWhitespace(bytes)
        case .ignoreAll:
            bytes.removeAll(where: Self.isWhitespace)
        }
        if comparesTerminators {
            // A byte no line's content can hold after the split, so a terminator can never be
            // confused with text: `\n` ends a line rather than appearing in one.
            bytes.append(UInt8(ascii: "\n"))
            bytes.append(Self.terminatorTag(line.terminator))
        }
        return bytes
    }

    private static func isWhitespace(_ byte: UInt8) -> Bool {
        byte == UInt8(ascii: " ") || byte == UInt8(ascii: "\t")
    }

    /// Every run of whitespace as one space, and none at the end.
    private static func collapsingWhitespace(_ bytes: [UInt8]) -> [UInt8] {
        var collapsed: [UInt8] = []
        collapsed.reserveCapacity(bytes.count)
        var inRun = false
        for byte in bytes {
            if isWhitespace(byte) {
                inRun = true
                continue
            }
            if inRun {
                collapsed.append(UInt8(ascii: " "))
                inRun = false
            }
            collapsed.append(byte)
        }
        return collapsed
    }

    private static func terminatorTag(_ terminator: LineTerminator) -> UInt8 {
        switch terminator {
        case .lf: 0
        case .crlf: 1
        case .cr: 2
        case .none: 3
        }
    }
}
