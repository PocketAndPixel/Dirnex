import Foundation
import Testing

@testable import DirnexCore

/// `LineDiff` against git itself (PLAN.md §M31).
///
/// The corpus is this repository's own files, each edited the way files get edited: blocks deleted,
/// copied, moved and reindented, lines changed, whitespace added, line endings switched to CRLF, the
/// final newline dropped. Every edited file is compared with its original by
/// `git diff --no-index --diff-algorithm=minimal --numstat` and by `LineDiff`, under each of the
/// options git shares, and the counts have to agree.
///
/// The pairs are made here rather than taken from the repository's history because CI checks out a
/// single commit. The history was checked once instead (2026-10-22): 5 223 real pairs, 36.9 million
/// lines, no disagreement under any of the five options, and 221 under a deliberately wrong one.
@Suite("LineDiff against git")
struct LineDiffGitCorpusTests {
    /// The repository root, from this file's own path, which is right under `swift test` and
    /// `xcodebuild` alike (the reasoning is `MarkdownCorpusTests`').
    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    /// Each option `LineDiff` shares with git, as the flag git spells it.
    private static let modes: [(flags: [String], options: LineDiffOptions)] = [
        ([], LineDiffOptions(isMinimal: true)),
        (["--ignore-space-at-eol"], LineDiffOptions(whitespace: .ignoreTrailing, isMinimal: true)),
        (["-b"], LineDiffOptions(whitespace: .ignoreChanges, isMinimal: true)),
        (["-w"], LineDiffOptions(whitespace: .ignoreAll, isMinimal: true)),
        (["--ignore-cr-at-eol"], LineDiffOptions(ignoresLineEndings: true, isMinimal: true))
    ]

    /// Every seventh source file of the core, and three documents.
    static func corpus() throws -> [URL] {
        let sources = root.appending(path: "DirnexCore/Sources/DirnexCore/Services")
        let swiftFiles = try FileManager.default.contentsOfDirectory(atPath: sources.path)
            .filter { $0.hasSuffix(".swift") }
            .sorted()
            .enumerated()
            .filter { $0.offset % 7 == 0 }
            .map { sources.appending(path: $0.element) }
        let documents = ["PLAN.md", "README.md", "docs/LIVE-VERIFICATION.md"]
            .map { root.appending(path: $0) }
        return swiftFiles + documents
    }

    @Test("every edited file counts the same changed lines as git's minimal diff, under each option")
    func agreesWithGit() throws {
        let corpus = try Self.corpus()
        try #require(corpus.count > 30, "the corpus was not found under \(Self.root.path)")
        let tree = try TempTree()
        defer { tree.cleanup() }
        var rng = SeededGenerator(seed: 0x0031_0004)
        var compared = 0
        var whitespaceMattered = 0

        for url in corpus {
            let original = try String(contentsOf: url, encoding: .utf8)
            let edited = Self.edit(original, using: &rng)
            let left = try tree.writeFile("left", contents: original)
            let right = try tree.writeFile("right", contents: edited)
            var gitCounts: [[String]: (added: Int, deleted: Int)] = [:]
            for mode in Self.modes {
                let git = try Self.gitCounts(left, right, flags: mode.flags)
                gitCounts[mode.flags] = git
                let ours = LineDiff.compare(original, edited, options: mode.options)
                #expect(
                    ours.insertedLineCount == git.added && ours.removedLineCount == git.deleted,
                    """
                    \(url.lastPathComponent) \(mode.flags): git +\(git.added) -\(git.deleted), \
                    LineDiff +\(ours.insertedLineCount) -\(ours.removedLineCount)
                    """
                )
                compared += 1
            }
            if gitCounts[[]]?.added != gitCounts[["-w"]]?.added {
                whitespaceMattered += 1
            }
        }
        // Without these, a corpus that shrank, or edits that stopped touching whitespace, would
        // pass on agreement about nothing.
        #expect(compared >= 150)
        #expect(whitespaceMattered >= 10)
    }

    /// Lines added and deleted, as `git diff --numstat` counts them. git's own configuration is
    /// kept out, since a user's `diff.algorithm` or a system `core.whitespace` would change them.
    private static func gitCounts(
        _ left: String,
        _ right: String,
        flags: [String]
    ) throws -> (added: Int, deleted: Int) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = [
            "diff", "--no-index", "--no-renames", "--no-textconv", "--no-ext-diff",
            "--diff-algorithm=minimal", "--numstat"
        ] + flags + ["--", left, right]
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_CONFIG_NOSYSTEM"] = "1"
        environment["GIT_CONFIG_GLOBAL"] = "/dev/null"
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = try #require(String(bytes: data, encoding: .utf8))
        // `--no-index` exits 1 when the files differ, 0 when they don't; anything else is a failure.
        try #require(process.terminationStatus <= 1, "git exited \(process.terminationStatus)")
        let fields = output.split(separator: "\t")
        guard fields.count >= 2 else { return (0, 0) }
        return try (#require(Int(fields[0])), #require(Int(fields[1])))
    }

    /// `text` with between three and ten edits, of the kinds people make.
    static func edit(_ text: String, using rng: inout SeededGenerator) -> String {
        var lines = text.components(separatedBy: "\n")
        if lines.last?.isEmpty == true {
            lines.removeLast()
        }
        for _ in 0..<Int.random(in: 3...10, using: &rng) where lines.count > 2 {
            let start = Int.random(in: 0..<lines.count, using: &rng)
            let end = min(lines.count, start + Int.random(in: 1...15, using: &rng))
            switch Int.random(in: 0..<9, using: &rng) {
            case 0: // delete a block
                lines.removeSubrange(start..<end)
            case 1: // copy a block somewhere else
                lines.insert(
                    contentsOf: lines[start..<end],
                    at: Int.random(in: 0...lines.count, using: &rng)
                )
            case 2: // move a block
                let block = lines[start..<end]
                lines.removeSubrange(start..<end)
                lines.insert(contentsOf: block, at: Int.random(in: 0...lines.count, using: &rng))
            case 3: // change a line
                lines[start] = appending(" // edited", to: lines[start])
            case 4: // reindent a block
                let indent = Bool.random(using: &rng) ? "    " : "\t"
                for index in start..<end {
                    lines[index] = indent + lines[index]
                }
            case 5: // trailing whitespace
                for index in start..<end {
                    lines[index] = appending(
                        Bool.random(using: &rng) ? " " : " \t",
                        to: lines[index]
                    )
                }
            case 6: // more space between words
                lines[start] = lines[start].replacingOccurrences(of: " ", with: "  ")
            case 7: // no space at all
                lines[start] = lines[start].replacingOccurrences(of: " ", with: "")
            default: // CRLF, never on the last line, whose line break may be dropped below
                for index in start..<min(end, lines.count - 1) where !lines[index].hasSuffix("\r") {
                    lines[index] += "\r"
                }
            }
        }
        let dropsFinalNewline = Int.random(in: 0..<5, using: &rng) == 0
        if dropsFinalNewline, lines.last?.hasSuffix("\r") == true {
            // A moved block can end the file with a CRLF line. Without its LF that CR would be a
            // lone one, which git and `TextLines` are documented to split differently.
            lines[lines.count - 1].removeLast()
        }
        return lines.joined(separator: "\n") + (dropsFinalNewline ? "" : "\n")
    }

    /// `suffix` added to the end of a line's text, ahead of the CR a CRLF line carries. After it,
    /// the CR would be a lone one in mid-line, which git and `TextLines` split differently.
    private static func appending(_ suffix: String, to line: String) -> String {
        guard line.hasSuffix("\r") else { return line + suffix }
        return line.dropLast() + suffix + "\r"
    }
}
