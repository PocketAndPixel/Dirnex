import Foundation

/// Several folders listed in **one** `sftp` session, and the reading of what that session printed
/// back into one listing per folder — the pure half of ``SFTPTransport/listDirectories(_:isCancelled:)``.
///
/// Every rule here was measured on 2026-10-19 against a real `sshd` (OpenSSH 10.3), with a listed
/// folder, an empty one, a refused one and a missing one in the same batch:
///
/// - **`sftp` echoes each line it runs as `sftp> <line>`**, under `-b -` and over piped stdin alike
///   (the password route), so the echo is the frame: what lies between one folder's echo and the
///   next is that folder's answer.
/// - **A refusal leaves the rest of the batch running only because each line is sent allowed to
///   fail** (``SFTPBatchCommand/allowedToFail(_:)``). Without the prefix, `-b` stops at the first
///   folder it cannot list and exits 1, and every folder after it is lost.
/// - **The refusal goes to standard error**, so the transport folds it into standard output.
///   `sftp` line-buffers stdout, and in one stream the refusal lands between its own folder's echo
///   and the next one, which held behind a 3000-row listing. In two streams nothing says whose
///   refusal it was.
/// - **The exit status says nothing about any one folder.** It was 0 with the refused folder in the
///   middle and 0 with it last, so a batch is read from its transcript alone.
public enum SFTPBatchListing {
    /// The batch for `remotePaths`: one allowed-to-fail `ls -la` per folder that can be framed
    /// (``canFrame(_:)``), then ``endMarker``.
    public static func script(for remotePaths: [String]) -> String {
        SFTPBatchCommand.batch(remotePaths.filter(canFrame).map(command(for:)) + [endMarker])
    }

    /// One answer per path, in order: the folder's rows as its own `ls -la` would have printed
    /// them, `""` for a folder listed empty, and `nil` for one that could not be listed or whose
    /// answer cannot be told apart from its neighbours'.
    ///
    /// **A folder's answer is trusted only when `sftp` went on to the next line of the batch.** Its
    /// block runs from its own echo to the next echo the batch sent, and if that next echo is not in
    /// the transcript the session ended inside the block, so the folder answers `nil` rather than
    /// whatever part of it arrived. ``endMarker`` is what gives the last folder a next line too.
    /// The same rule covers an echo that does not read back as sent: that folder answers `nil`, and
    /// so does the one before it, since nothing marks where the earlier block stops.
    public static func answers(in transcript: String, for remotePaths: [String]) -> [String?] {
        // Scalars rather than characters, because Swift reads `\r\n` as one character: a refusal
        // ends in one, and split by character it would swallow the echo after it.
        let scalars = transcript.unicodeScalars
        let lines = scalars
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.startIndex..<$0.endIndex }
        func line(_ index: Int, reads text: String) -> Bool {
            scalars[lines[index]].elementsEqual(text.unicodeScalars)
        }

        // Where each folder's echo was found, searched in the order the lines were sent. A folder
        // left out of the batch was never echoed and stays `nil`.
        var echoes: [Int?] = []
        var cursor = 0
        for remotePath in remotePaths {
            let echo = canFrame(remotePath) ? echoLine(command(for: remotePath)) : nil
            let found = echo.flatMap { echo in
                (cursor..<lines.count).first { line($0, reads: echo) }
            }
            echoes.append(found)
            if let found { cursor = found + 1 }
        }
        // Searched from the end: a name can forge `sftp> pwd` (below), but nothing a name prints
        // comes after the real one.
        let end = (cursor..<lines.count).last { line($0, reads: echoLine(endMarker)) }

        // Each sent folder's block ends where the next sent line's echo begins.
        let sent = echoes.indices.filter { canFrame(remotePaths[$0]) }
        var answers = [String?](repeating: nil, count: remotePaths.count)
        for (position, index) in sent.enumerated() {
            let next = position + 1 < sent.count ? echoes[sent[position + 1]] : end
            guard let start = echoes[index], let next else { continue }
            let block = start + 1 < next
                ? String(scalars[lines[start + 1].lowerBound..<lines[next - 1].upperBound])
                : ""
            answers[index] = answer(from: block)
        }
        return answers
    }

    /// Whether `remotePath` can ride the batch and be told apart in what comes back.
    ///
    /// A **newline** splits the line that carries it, so `sftp` runs half a command and reports
    /// `Unterminated quoted argument`. A single listing of that path fails the same way (exit 1),
    /// so leaving it out answers `nil`, which is what listing it alone would have answered. And
    /// the echo must hold a **slash**, because that is what no row can forge. `sftp` prints a name
    /// raw, newline included, so the text after a newline in a name can read like anything at
    /// all, except a path, since a name cannot hold a `/`. Every path an SFTP connection lists here
    /// is absolute, so this costs nothing in practice.
    static func canFrame(_ remotePath: String) -> Bool {
        remotePath.contains("/") && !remotePath.unicodeScalars.contains("\n")
    }

    /// The line that lists one folder, allowed to fail so a refusal does not end the batch.
    static func command(for remotePath: String) -> String {
        SFTPBatchCommand.allowedToFail(SFTPBatchCommand.list(remotePath))
    }

    /// The line `sftp` prints for each line of the batch it runs.
    static func echoLine(_ command: String) -> String { "sftp> " + command }

    /// The batch's last line, there only so the last folder has a next echo to end at. `pwd` costs
    /// no round trip: `sftp` prints the directory it resolved when it connected.
    static let endMarker = SFTPBatchCommand.printWorkingDirectory

    /// What one folder's block says. Rows are a listing. No row at all is a folder listed empty when
    /// `sftp` said nothing, since a server may send no `.`/`..` rows (OpenSSH's always does), and a
    /// refusal when it said anything else: the rows are printed only after the whole folder has
    /// been read, so a block with no rows and some text is `sftp` explaining why it had none.
    private static func answer(from block: String) -> String? {
        if !SFTPListingParser.parse(block).isEmpty { return block }
        return block.allSatisfy(\.isWhitespace) ? "" : nil
    }
}
