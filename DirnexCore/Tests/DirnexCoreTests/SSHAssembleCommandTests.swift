import Foundation
import Testing

@testable import DirnexCore

/// The commands that put an upload's parts back together, and the reading of the one answer they
/// give back.
@Suite("SSHAssembleCommand")
struct SSHAssembleCommandTests {
    private func parts(_ names: [String]) -> [UploadSegment] {
        names.enumerated().map { index, name in
            UploadSegment(
                number: index + 1,
                localPath: "/tmp/\(index + 1)",
                remotePath: name,
                range: Int64(index * 10)..<Int64((index + 1) * 10)
            )
        }
    }

    @Test("the join names the parts in order and reports the size that landed")
    func joinIsOrderedAndReports() {
        let command = SSHAssembleCommand.join(parts(["/a/p.1", "/a/p.2"]), into: "/a/staging")
        #expect(command == "/usr/bin/env cat '/a/p.1' '/a/p.2' > '/a/staging'"
            + " && /usr/bin/env wc -c < '/a/staging'")
    }

    @Test("the join sorts by part number, whatever order the caller holds them in")
    func joinSortsByNumber() {
        var shuffled = parts(["/a/p.1", "/a/p.2", "/a/p.3"])
        shuffled.reverse()
        let command = SSHAssembleCommand.join(shuffled, into: "/a/s")
        // The order is the whole correctness argument: `cat` splices what it is given, so a run
        // that reversed the parts would produce a plausible file with its halves swapped.
        #expect(command.contains("cat '/a/p.1' '/a/p.2' '/a/p.3' >"))
    }

    @Test("the commit renames into place and only then sweeps the parts")
    func commitRenamesFirst() {
        let command = SSHAssembleCommand.commit(
            parts(["/a/p.1", "/a/p.2"]),
            from: "/a/staging",
            to: "/a/disk.img"
        )
        #expect(command == "/usr/bin/env mv '/a/staging' '/a/disk.img'"
            + " && /usr/bin/env rm -f '/a/p.1' '/a/p.2'")
    }

    @Test("the sweep removes the staging file as well as the parts")
    func discardTakesEverything() {
        let command = SSHAssembleCommand.discard(parts(["/a/p.1"]), staging: "/a/staging")
        #expect(command == "/usr/bin/env rm -f '/a/staging' '/a/p.1'")
    }

    @Test("a remote name reaches the shell quoted")
    func namesAreQuoted() {
        // Not formatting: a part's name is built from a destination the *server* may have named.
        //
        // The assertion is the **quoting**, not the absence of the dangerous words: inside single
        // quotes `; touch CANARY;` is ordinary text and a correct command still contains it, so
        // searching for it would fail on a right answer and pass on a wrong one that happened to
        // spell it differently (docs/NOTES.md ▸ Testing). What decides it is that every quote in the
        // name is closed and re-opened, which is what stops the operand ending early.
        let hostile = parts(["/a/'; touch CANARY; echo '.1"])
        let command = SSHAssembleCommand.join(hostile, into: "/a/s")
        #expect(command == "/usr/bin/env cat '/a/'\\''; touch CANARY; echo '\\''.1' > '/a/s'"
            + " && /usr/bin/env wc -c < '/a/s'")
    }

    @Test("every quoted operand reads back as the name it was built from")
    func quotingRoundTrips() {
        // The property behind the assertion above, over the names a real server can produce: a
        // POSIX shell splitting this command hands `cat` exactly these operands and no others.
        //
        // `words(of:)` is written out below rather than borrowed from the code under test — reusing
        // the quoter's own inverse would prove the two agree rather than that either is right
        // (docs/NOTES.md ▸ Testing).
        for name in ["/a/it's.1", "/a/$HOME.1", "/a/`b`.1", "/a/x y.1", "/a/*.1", "/a/;rm -rf.1"] {
            let command = SSHAssembleCommand.join(parts([name]), into: "/a/s")
            #expect(Self.words(of: command) == [
                "/usr/bin/env", "cat", name, ">", "/a/s",
                "&&", "/usr/bin/env", "wc", "-c", "<", "/a/s"
            ])
        }
    }

    /// A minimal POSIX word splitter: unquoted whitespace ends a word, a single quote opens a run in
    /// which everything is literal, and a backslash outside one escapes the next character. Enough
    /// of a shell to say what `cat` would be handed, and no more.
    private static func words(of command: String) -> [String] {
        var words: [String] = []
        var current = ""
        var started = false
        var quoted = false
        var escaped = false
        for character in command {
            if escaped {
                current.append(character)
                escaped = false
            } else if quoted {
                if character == "'" { quoted = false } else { current.append(character) }
            } else if character == "'" {
                quoted = true
                started = true
            } else if character == "\\" {
                escaped = true
                started = true
            } else if character.isWhitespace {
                if started || !current.isEmpty { words.append(current) }
                current = ""
                started = false
            } else {
                current.append(character)
            }
        }
        if started || !current.isEmpty { words.append(current) }
        return words
    }

    @Test("a byte count is read out of the answer, padding and all")
    func sizeIsRead() {
        #expect(SSHAssembleCommand.assembledSize(from: " 33554432\n") == 33_554_432)
        #expect(SSHAssembleCommand.assembledSize(from: "33554432") == 33_554_432)
        #expect(SSHAssembleCommand.assembledSize(from: "0\n") == 0)
    }

    @Test("the login shell's own noise ahead of the count does not confuse the reading")
    func rcNoiseIsSkipped() {
        // An exec channel runs the user's login shell, which sources their rc — measured writing to
        // stderr here, and nothing guarantees it does. The count is the last line because the rc
        // runs before the command.
        #expect(
            SSHAssembleCommand.assembledSize(from: "bash: ng: command not found\n1024\n") == 1024
        )
    }

    @Test("prose is not a byte count")
    func proseIsRefused() {
        // What an account confined to the sftp subsystem answers, on stdout, where the count goes.
        #expect(SSHAssembleCommand.assembledSize(
            from: "This service allows sftp connections only.\n"
        ) == nil)
        #expect(SSHAssembleCommand.assembledSize(from: "") == nil)
        #expect(SSHAssembleCommand.assembledSize(from: nil) == nil)
        #expect(SSHAssembleCommand.assembledSize(from: "12 files\n") == nil)
        #expect(SSHAssembleCommand.assembledSize(from: "-1\n") == nil)
        // A digit in another script is not one `Int64` would read the same way.
        #expect(SSHAssembleCommand.assembledSize(from: "١٢٣\n") == nil)
    }

    @Test("the probe is only answered by an account that echoed the token back")
    func probeNeedsItsToken() {
        let token = "dirnex-exec-abcd1234"
        #expect(SSHAssembleCommand.probe(token: token) == "/usr/bin/env echo 'dirnex-exec-abcd1234'")
        #expect(SSHAssembleCommand.answeredProbe("dirnex-exec-abcd1234\n", token: token))
        #expect(SSHAssembleCommand.answeredProbe("rc noise\ndirnex-exec-abcd1234\n", token: token))
        // The refusal that looks like an answer, which is why a sentinel and not a bare `true`.
        #expect(!SSHAssembleCommand.answeredProbe(
            "This service allows sftp connections only.\n",
            token: token
        ))
        #expect(!SSHAssembleCommand.answeredProbe(nil, token: token))
        #expect(!SSHAssembleCommand.answeredProbe("", token: token))
    }
}
