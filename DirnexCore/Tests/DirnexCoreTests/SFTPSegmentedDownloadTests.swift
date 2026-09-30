import Foundation
import Testing

@testable import DirnexCore

/// Asking for several ranges of one remote file at once over SSH — the *command* half
/// (docs/HISTORY.md ▸ After M19).
///
/// The third route, and the one that is not the protocol it serves: the system `curl` speaks no
/// `sftp` and `sftp(1)` has no range verb, so a segment is an SSH **exec** channel. Everything here
/// is about the one shell command that goes down it, which is also the one place a remote path
/// reaches a stranger's shell.
@Suite("SFTP segmented download: the command")
struct SFTPSegmentedDownloadTests {
    private static let mebibyte: Int64 = 1024 * 1024

    // MARK: - The remote command

    /// `tail -c +N` counts from **one** where a range's lower bound counts from zero. One character,
    /// and it is the difference between a correct assembly and every piece starting a byte early.
    @Test("the range becomes a one-based tail and an exact head")
    func rangeBecomesTailAndHead() {
        let command = SSHSegmentCommand.read("/pub/clip.mov", range: 0..<1024)
        #expect(command == "/usr/bin/env tail -c +1 '/pub/clip.mov'"
            + " | /usr/bin/env head -c 1024")
        let later = SSHSegmentCommand.read("/pub/clip.mov", range: 8_388_608..<12_582_912)
        #expect(later.contains("tail -c +8388609"))
        #expect(later.contains("head -c 4194304"))
    }

    /// Both words are resolved by the *shell*, and an exec channel runs the user's login shell with
    /// their rc sourced — where a function can shadow either. Probed: a `dd() { echo SHADOWED; }`
    /// did exactly that, while `/usr/bin/env dd` returned the real bytes.
    @Test("both halves go through env, so a shell function cannot shadow them")
    func bothHalvesGoThroughEnv() {
        let command = SSHSegmentCommand.read("/a/b.bin", range: 0..<10)
        #expect(command.components(separatedBy: "/usr/bin/env ").count == 3)
        #expect(!command.contains("| tail"))
        #expect(!command.contains("| head -c 10 |"))
    }

    /// Not formatting: a remote path can arrive from a listing the *server* produced, so a name a
    /// stranger chose reaches a shell here.
    @Test("a hostile path is single-quoted, and the quote itself is escaped")
    func hostilePathsAreQuoted() {
        let command = SSHSegmentCommand.read("/pub/tree'; touch CANARY; echo '", range: 0..<4)
        #expect(command.contains("'/pub/tree'\\''; touch CANARY; echo '\\'''"))
        #expect(!command.contains("; touch CANARY; echo ' | "))
    }

    @Test("a name full of shell metacharacters survives whole")
    func metacharactersSurvive() {
        let command = SSHSegmentCommand.read("/pub/it's $a `b` ;x.txt", range: 0..<4)
        #expect(command.contains("'/pub/it'\\''s $a `b` ;x.txt'"))
    }

    /// The two commands that send a path over an exec channel share one quoting rule, because a
    /// second spelling of it is how one of them comes to have a weaker one.
    @Test("the subtree search and a segment quote identically")
    func quotingIsShared() {
        let hostile = "/pub/x'; rm -rf /; echo '"
        #expect(SSHSegmentCommand.read(hostile, range: 0..<1)
            .contains(SSHShellQuote.quote(hostile)))
        #expect(SSHFindCommand.subtree(root: hostile).contains(SSHShellQuote.quote(hostile)))
    }

    // MARK: - The plan

    /// SFTP's ceiling is four and its threshold twice S3's — a segment is a key exchange and an
    /// authentication, not a TLS handshake, and four leaves room under OpenSSH's `MaxStartups`.
    @Test("SFTP splits into at most four segments, above a higher threshold")
    func sftpLimitsAreItsOwn() throws {
        #expect(!SegmentedDownloadPlan.isWorthwhile(totalSize: 16 * Self.mebibyte, limits: .sftp))
        #expect(SegmentedDownloadPlan.isWorthwhile(totalSize: 16 * Self.mebibyte + 1, limits: .sftp))
        let plan = try #require(
            SegmentedDownloadPlan(totalSize: 100 * Self.mebibyte, limits: .sftp)
        )
        #expect(plan.segmentCount == 4)
    }

    @Test("no segment is ever under SFTP's floor, at any size")
    func segmentsClearTheFloor() throws {
        for megabytes in [17, 24, 33, 64, 100, 512, 4096] {
            let plan = try #require(
                SegmentedDownloadPlan(totalSize: Int64(megabytes) * Self.mebibyte, limits: .sftp)
            )
            #expect(plan.segmentSize >= SegmentedDownloadLimits.sftp.minimumSegmentSize)
            #expect(plan.segmentCount <= SegmentedDownloadLimits.sftp.maximumSegments)
        }
    }
}
