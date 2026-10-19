import Foundation
import Testing

@testable import DirnexCore

/// Reading one `sftp` session's transcript back into one listing per folder.
///
/// Every transcript here has the shape a real `sshd` printed on 2026-10-19 (OpenSSH 10.3, standard
/// error folded into standard output, as the transport runs it), with only the base path shortened:
/// the `sftp> ` echo of each line, the `.`/`..` rows of a listed folder, and the two refusals with
/// their trailing `\r` — `remote readdir("…/")` for a folder it may not read and `Can't ls:` for one
/// that is not there.
@Suite("SFTP batched listing ▸ the transcript")
struct SFTPBatchListingTests {
    private let folders = ["/srv/probe/a", "/srv/probe/denied", "/srv/probe/gone", "/srv/probe/c"]

    private func rows(_ folder: String, _ names: [String]) -> [String] {
        [
            "drwxr-xr-x    ? oleg     wheel         128 Oct 19 17:02 \(folder)/.",
            "drwxr-xr-x    ? oleg     wheel         192 Oct 19 17:02 \(folder)/.."
        ]
            + names.map { "-rw-r--r--    ? oleg     wheel           3 Oct 19 17:02 \(folder)/\($0)" }
    }

    private func echo(_ folder: String) -> String { "sftp> -ls -la \"\(folder)\"" }

    private let end = ["sftp> pwd", "Remote working directory: /Users/oleg"]

    /// The measured run: a listed folder, a refused one and a missing one in the middle, and a
    /// listed one last.
    private var measured: [String] {
        [echo(folders[0])] + rows(folders[0], ["one.txt", "two.txt"])
            + [
                echo(folders[1]),
                "remote readdir(\"\(folders[1])/\"): Permission denied\r",
                echo(folders[2]),
                "Can't ls: \"\(folders[2])\" not found\r",
                echo(folders[3])
            ]
            + rows(folders[3], ["three.txt"]) + end
    }

    private func names(_ answer: String?) -> [String]? {
        answer.map { SFTPListingParser.parse($0).map(\.name) }
    }

    @Test("the batch lists each folder allowed to fail, then marks its end")
    func scriptListsEachFolder() {
        #expect(SFTPBatchListing.script(for: ["/srv/a", "/srv/b c"]) == """
        -ls -la "/srv/a"
        -ls -la "/srv/b c"
        pwd
        """)
    }

    @Test("each folder's block comes back as its own listing, and a refusal as nil")
    func readsTheMeasuredTranscript() {
        let answers = SFTPBatchListing.answers(
            in: measured.joined(separator: "\n"), for: folders
        )
        #expect(answers.map(names) == [
            [".", "..", "one.txt", "two.txt"], nil, nil, [".", "..", "three.txt"]
        ])
    }

    /// What the single listing prints for the same folder, echo and all — the two must parse to the
    /// same rows, or a tree refresh and a pane would disagree about one folder.
    @Test("a folder's block parses to what its own listing does")
    func blockMatchesTheSingleListing() throws {
        let single = ([#"sftp> ls -la "/srv/probe/a""#] + rows(folders[0], ["one.txt", "two.txt"]))
            .joined(separator: "\n")
        let answers = SFTPBatchListing.answers(
            in: measured.joined(separator: "\n"), for: folders
        )
        #expect(SFTPListingParser.parse(try #require(answers[0])) == SFTPListingParser.parse(single))
    }

    /// The password route runs `sftp` without `-b`, which prints `Connected to …` first; `ssh`'s own
    /// first-contact warning lands there too. Neither is inside any folder's block.
    @Test("what the session prints before its first echo belongs to no folder")
    func preambleBelongsToNoFolder() {
        let transcript = [
            "Warning: Permanently added '[127.0.0.1]:2222' (ED25519) to the list of known hosts.\r",
            "Connected to 127.0.0.1."
        ] + measured
        let answers = SFTPBatchListing.answers(
            in: transcript.joined(separator: "\n"), for: folders
        )
        #expect(answers.map { $0 != nil } == [true, false, false, true])
    }

    /// OpenSSH always sends `.` and `..`, so an empty folder there has rows. A server that sends
    /// neither lists an empty folder as nothing at all, and that silence is an answer: reading it as
    /// a refusal would keep a folder's old rows after it really was emptied.
    @Test("a folder listed with no rows at all is empty, and a refusal beside it is still nil")
    func silentFolderIsEmpty() {
        let transcript = [
            echo(folders[0]),
            echo(folders[1]),
            "remote readdir(\"\(folders[1])/\"): Permission denied\r"
        ] + end
        let answers = SFTPBatchListing.answers(
            in: transcript.joined(separator: "\n"), for: Array(folders.prefix(2))
        )
        #expect(answers == ["", nil])
    }

    /// The rule that keeps a dropped connection from emptying a folder: a block counts only once
    /// `sftp` has gone on to the next line, so a session that ends inside one never answers for it.
    @Test("a session that ends inside a folder answers nil for it and keeps the ones before")
    func truncatedSessionAnswersNil() {
        let cut = Array(measured.prefix(while: { $0 != echo(folders[3]) }))
            + [echo(folders[3])] + Array(rows(folders[3], ["three.txt"]).prefix(1))
        let answers = SFTPBatchListing.answers(in: cut.joined(separator: "\n"), for: folders)
        #expect(answers.map(names) == [[".", "..", "one.txt", "two.txt"], nil, nil, nil])

        // And silence after the last echo is not an empty folder, for the same reason.
        let silent = [echo(folders[0])] + rows(folders[0], ["one.txt"]) + [echo(folders[3])]
        #expect(SFTPBatchListing.answers(
            in: silent.joined(separator: "\n"), for: [folders[0], folders[3]]
        ).map(names) == [[".", "..", "one.txt"], nil])
    }

    @Test("a session that never got in answers nil for every folder")
    func refusedSessionAnswersNothing() {
        let transcript = "oleg@127.0.0.1: Permission denied (publickey).\r\nConnection closed\r\n"
        #expect(SFTPBatchListing.answers(in: transcript, for: folders) == [nil, nil, nil, nil])
    }

    /// `sftp` prints a name raw, newline included, so the text after a newline in a name can read
    /// like anything — `sftp> pwd`, or a refusal. Measured: a file named `new\nline.txt` lists as
    /// two lines. It cannot read like a folder's echo, which holds a slash.
    @Test("a name holding a newline cannot move a block's edge")
    func forgedLinesMoveNothing() {
        let transcript = [echo(folders[0])]
            + rows(folders[0], ["x\nPermission denied", "y.txt"])
            + [echo(folders[3])]
            + rows(folders[3], ["m\nsftp> pwd", "z.txt"]) + end
        let answers = SFTPBatchListing.answers(
            in: transcript.joined(separator: "\n"), for: [folders[0], folders[3]]
        )
        #expect(names(answers[0])?.contains("y.txt") == true)
        // The forged end marker comes before the real one, which is the one that counts.
        #expect(names(answers[1])?.contains("z.txt") == true)
    }

    /// An echo that does not read back as sent leaves nothing to say where the block before it
    /// stops, so both answer nil — and no folder is ever handed another's rows.
    @Test("an echo that does not match costs its folder and the one before, never another's rows")
    func unmatchedEchoIsNotMisattributed() {
        let transcript = [echo(folders[0])] + rows(folders[0], ["one.txt"])
            + [#"sftp> -ls -la "/srv/probe/\320\237""#] + rows("/srv/probe/П", ["inner.txt"])
            + [echo(folders[3])] + rows(folders[3], ["three.txt"]) + end
        let answers = SFTPBatchListing.answers(
            in: transcript.joined(separator: "\n"),
            for: [folders[0], "/srv/probe/П", folders[3]]
        )
        #expect(answers.map(names) == [nil, nil, [".", "..", "three.txt"]])
    }

    /// A newline would split the folder's own line in two; its single listing fails the same way
    /// (`Unterminated quoted argument`, exit 1), so it is left out and answers nil, and the folders
    /// either side of it are still framed.
    @Test("a path holding a newline is left out of the batch and answers nil")
    func newlinePathIsLeftOut() {
        let odd = "/srv/probe/two\nlines"
        #expect(SFTPBatchListing.script(for: [folders[0], odd, "relative"]) == """
        -ls -la "/srv/probe/a"
        pwd
        """)
        let transcript = [echo(folders[0])] + rows(folders[0], ["one.txt"])
            + [echo(folders[3])] + rows(folders[3], ["three.txt"]) + end
        let answers = SFTPBatchListing.answers(
            in: transcript.joined(separator: "\n"), for: [folders[0], odd, folders[3]]
        )
        #expect(answers.map { $0 != nil } == [true, false, true])
    }
}
