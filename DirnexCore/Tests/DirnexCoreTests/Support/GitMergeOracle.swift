import Foundation
import Testing

@testable import DirnexCore

/// `git merge-file` as the oracle for `ThreeWayMerge` (PLAN.md §M34 Slice 1).
///
/// git is run with its configuration kept out, since a user's `merge.conflictStyle` or
/// `diff.algorithm` would change what it answers, and with the labels `O`, `B` and `T`, so a
/// merge Dirnex made can be written out in git's own marker format and compared byte for byte.
/// The markers exist only here: Dirnex never writes them (§M34).
struct GitMergeOracle {
    enum Style: String {
        /// The base between the two sides, and nothing moved out of a conflict.
        case diff3
        /// The same, with the lines both sides share at a conflict's edges moved out of it.
        case zdiff3
    }

    /// How git settles every conflict instead of marking it.
    enum Favor: String {
        /// Yours' lines.
        case ours
        /// Theirs' lines.
        case theirs
        /// Yours' lines, then theirs'.
        case union
    }

    let tree: TempTree

    init() throws {
        tree = try TempTree()
    }

    func cleanup() {
        tree.cleanup()
    }

    /// git's merge of `yours` and `theirs` against `base`, as the bytes it prints.
    /// With `favor`, every conflict is settled that way and nothing is marked.
    func merged(
        base: String,
        yours: String,
        theirs: String,
        style: Style,
        favor: Favor? = nil
    ) throws -> [UInt8] {
        let (status, output) = try git([
            "merge-file", "-p", "--\(style.rawValue)", "--diff-algorithm=minimal"
        ] + (favor.map { ["--\($0.rawValue)"] } ?? []) + [
            "-L", "O", "-L", "B", "-L", "T",
            tree.writeFile("yours", contents: yours),
            tree.writeFile("base", contents: base),
            tree.writeFile("theirs", contents: theirs)
        ])
        // The status is the number of conflicts, capped at 127; a failure is negative, so 255.
        try #require(status < 128, "git merge-file exited \(status)")
        return output
    }

    /// The blocks git's own minimal comparison finds from `base` to `side`, placed as
    /// `git merge-file` places them, with git's indent heuristic off.
    ///
    /// Read from a diff with one line of context, never `-U0`. With no context `git diff` first
    /// trims the two files' common tail in 1 KiB blocks (`trim_common_tail` in git's
    /// `xdiff-interface.c`), so a block that could slide lower stops where the trimmed file ends,
    /// while `merge-file` compares the whole files (docs/NOTES.md ▸ git).
    func changes(from base: String, to side: String) throws -> [LineDiff.Change] {
        let left = try tree.writeFile("diff-base", contents: base)
        let right = try tree.writeFile("diff-side", contents: side)
        let (status, output) = try git([
            "diff", "--no-index", "--no-renames", "--no-textconv", "--no-ext-diff",
            "--diff-algorithm=minimal", "--no-indent-heuristic", "-U1", "--", left, right
        ])
        try #require(status <= 1, "git diff exited \(status)")
        return try Self.blocks(inUnifiedDiff: output)
    }

    /// Every run of removed and added lines in a unified diff of one file, as line ranges.
    ///
    /// The bytes are split rather than a `String`: in one, `\r\n` is a single `Character`, so a
    /// line after a CRLF line would never start a line of its own.
    static func blocks(inUnifiedDiff output: [UInt8]) throws -> [LineDiff.Change] {
        var changes: [LineDiff.Change] = []
        var left = 0
        var right = 0
        var runStart: LineDiff.Change?
        var inHunk = false
        func endRun() {
            if let start = runStart {
                changes.append(LineDiff.Change(
                    left: start.left.lowerBound..<left,
                    right: start.right.lowerBound..<right
                ))
            }
            runStart = nil
        }
        for line in output.split(separator: UInt8(ascii: "\n")) {
            if line.starts(with: Array("@@ ".utf8)) {
                endRun()
                let header = try #require(String(bytes: line, encoding: .utf8))
                let fields = header.split(separator: " ")
                left = try #require(Self.start(fields[1].dropFirst()))
                right = try #require(Self.start(fields[2].dropFirst()))
                inHunk = true
                continue
            }
            guard inHunk, let marker = line.first else { continue }
            switch marker {
            case UInt8(ascii: " "):
                endRun()
                left += 1
                right += 1
            case UInt8(ascii: "-"), UInt8(ascii: "+"):
                if runStart == nil {
                    runStart = LineDiff.Change(left: left..<left, right: right..<right)
                }
                if marker == UInt8(ascii: "-") {
                    left += 1
                } else {
                    right += 1
                }
            default:
                // `\ No newline at end of file` belongs to the line before it.
                continue
            }
        }
        endRun()
        return changes
    }

    /// Where one side of a hunk header starts, as an index: the 1-based line named, or for a count
    /// of 0, which only an empty file has once there is context, the place after it.
    private static func start(_ field: Substring) -> Int? {
        let parts = field.split(separator: ",")
        guard let start = Int(parts[0]) else { return nil }
        return parts.count > 1 && parts[1] == "0" ? start : start - 1
    }

    /// Run git with its output going to a file in the tree rather than a pipe. Many oracles run at
    /// once, and launching thousands of processes with pipes from several threads failed with
    /// `EBADF` in a throwaway run of this suite's harness.
    private func git(_ arguments: [String]) throws -> (status: Int32, output: [UInt8]) {
        let outputPath = tree.path("git-output")
        try Data().write(to: URL(fileURLWithPath: outputPath))
        let output = try FileHandle(forWritingTo: URL(fileURLWithPath: outputPath))
        defer { try? output.close() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_CONFIG_NOSYSTEM"] = "1"
        environment["GIT_CONFIG_GLOBAL"] = "/dev/null"
        process.environment = environment
        let errors = try FileHandle(forWritingTo: URL(fileURLWithPath: "/dev/null"))
        defer { try? errors.close() }
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        process.waitUntilExit()
        let data = try Data(contentsOf: URL(fileURLWithPath: outputPath))
        return (process.terminationStatus, Array(data))
    }

    /// `merge` written out as `git merge-file -p` writes it in `style`'s format: each region from
    /// the side the merge takes it from, and each conflict between markers with the base in the
    /// middle. A conflict's sections each end in a line break, and its markers end in CRLF when
    /// the lines around them do, as xdiff's `fill_conflict_hunk` and `is_cr_needed` have it.
    ///
    /// `keptByGit` names the base ranges of conflicts whose two sides are the same lines, which
    /// `ThreeWayMerge` merges and git's `--zdiff3` keeps: their lines come first, then markers
    /// with nothing on either side, as git writes them once the trimming has taken every line.
    static func rendered(
        _ merge: ThreeWayMerge,
        base: [TextLine],
        yours: [TextLine],
        theirs: [TextLine],
        keptByGit: Set<Range<Int>> = []
    ) -> [UInt8] {
        var output: [UInt8] = []
        for region in merge.regions {
            switch region.kind {
            case .same where keptByGit.contains(region.base):
                append(yours[region.yours], to: &output)
                let emptied = ThreeWayMerge.Region(
                    kind: .conflict,
                    base: region.base,
                    yours: region.yours.upperBound..<region.yours.upperBound,
                    theirs: region.theirs.upperBound..<region.theirs.upperBound
                )
                appendConflict(emptied, base: base, yours: yours, theirs: theirs, to: &output)
            case .unchanged, .yours, .same:
                append(yours[region.yours], to: &output)
            case .theirs:
                append(theirs[region.theirs], to: &output)
            case .conflict:
                appendConflict(region, base: base, yours: yours, theirs: theirs, to: &output)
            }
        }
        return output
    }

    /// The base ranges of `merge`'s conflicts whose two sides are the same lines. `merge` is
    /// untrimmed, `--diff3`'s, where git still shows them as conflicts.
    static func identicalConflicts(
        in merge: ThreeWayMerge,
        yours: [TextLine],
        theirs: [TextLine]
    ) -> Set<Range<Int>> {
        Set(merge.regions.filter { region in
            region.kind == .conflict && bytes(yours[region.yours]) == bytes(theirs[region.theirs])
        }.map(\.base))
    }

    private static func bytes(_ lines: ArraySlice<TextLine>) -> [UInt8] {
        var output: [UInt8] = []
        append(lines, to: &output)
        return output
    }

    private static func appendConflict(
        _ region: ThreeWayMerge.Region,
        base: [TextLine],
        yours: [TextLine],
        theirs: [TextLine],
        to output: inout [UInt8]
    ) {
        let carriageReturn = needsCarriageReturn(region, base: base, yours: yours, theirs: theirs)
        func marker(_ text: String) {
            output += Array((text + (carriageReturn ? "\r\n" : "\n")).utf8)
        }
        marker("<<<<<<< O")
        append(yours[region.yours], endingLine: carriageReturn, to: &output)
        marker("||||||| B")
        append(base[region.base], endingLine: carriageReturn, to: &output)
        marker("=======")
        append(theirs[region.theirs], endingLine: carriageReturn, to: &output)
        marker(">>>>>>> T")
    }

    /// The lines' bytes. With `endingLine`, a last line that has no line break gets one, CRLF when
    /// the flag says so; nil leaves it as it is.
    private static func append(
        _ lines: ArraySlice<TextLine>,
        endingLine carriageReturn: Bool? = nil,
        to output: inout [UInt8]
    ) {
        for line in lines {
            output += Array(line.content.utf8) + Array(line.terminator.text.utf8)
        }
        if let carriageReturn, let last = lines.last, last.terminator == .none {
            output += Array((carriageReturn ? "\r\n" : "\n").utf8)
        }
    }

    /// Whether a conflict's markers end in CRLF, as `is_cr_needed` decides: the line before the
    /// conflict on each side is asked in turn, then the base's first line, and the first one that
    /// ends in LF settles it. A file with nothing to judge by passes the question on, and the last
    /// answer is the one that counts, so a base with nothing to judge by means LF.
    private static func needsCarriageReturn(
        _ region: ThreeWayMerge.Region,
        base: [TextLine],
        yours: [TextLine],
        theirs: [TextLine]
    ) -> Bool {
        let checks = [
            (yours, max(region.yours.lowerBound - 1, 0)),
            (theirs, max(region.theirs.lowerBound - 1, 0)),
            (base, 0)
        ]
        var answer: Bool?
        for (lines, index) in checks {
            answer = endsInCRLF(lines, at: index)
            if answer == false {
                return false
            }
        }
        return answer == true
    }

    /// xdiff's `is_eol_crlf`: whether line `index` ends in CRLF, judged by the line before it when
    /// it is the last and has no line break, and `nil` when there is nothing to judge by.
    private static func endsInCRLF(_ lines: [TextLine], at index: Int) -> Bool? {
        guard !lines.isEmpty else { return nil }
        if lines[index].terminator != .none {
            return lines[index].terminator == .crlf
        }
        guard index > 0 else { return nil }
        return lines[index - 1].terminator == .crlf
    }
}
