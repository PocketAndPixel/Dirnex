import Foundation
import Testing

@testable import DirnexCore

/// Reading a symlink's **target** over the SSH exec channel, and refusing to copy a link whose
/// target could not be read (PLAN.md §M25 Slice 4).
///
/// Every fixture row below is a real server's bytes, captured from a throwaway `sshd` on
/// 2026-08-28 with only the directory prefix shortened — including the four adversarial links,
/// which is the half that matters: a target containing ` -> `, a *name* containing ` -> `, a target
/// containing a newline, and a path that is not a link at all. Hand-typing them would have proved
/// the parser agrees with my idea of the format rather than with `ls`.
@Suite("SFTP symlink targets")
struct SFTPLinkTargetTests {
    /// Verbatim `ls -ldn` output for eight operands, one of which does not exist.
    ///
    /// Note what is *not* here: `/srv/nope` printed no row at all (its error went to stderr), which
    /// is why "no row" has to mean "no answer for this path" rather than an empty target.
    private static let rows = """
    lrwxr-xr-x@ 1 501  0   1 Aug 28 13:09 /srv/a -> b -> c
    lrwxr-xr-x@ 1 501  0  10 Aug 28 13:06 /srv/abs -> /etc/hosts
    lrwxr-xr-x@ 1 501  0  12 Aug 28 13:06 /srv/arrowtarget -> has -> arrow
    lrwxr-xr-x@ 1 501  0  10 Aug 28 13:06 /srv/dangling -> ../nowhere
    lrwxr-xr-x@ 1 501  0  14 Aug 28 13:06 /srv/newlinetarget -> weird
    name.txt
    -rw-r--r--@ 1 501  0   6 Aug 28 13:06 /srv/plain.txt
    lrwxr-xr-x@ 1 501  0   9 Aug 28 13:06 /srv/rel -> plain.txt
    """

    private static let paths = [
        "/srv/a -> b", "/srv/abs", "/srv/arrowtarget", "/srv/dangling",
        "/srv/newlinetarget", "/srv/plain.txt", "/srv/rel", "/srv/nope"
    ]

    // MARK: - The parser

    @Test("an ordinary link's target is read")
    func readsAnOrdinaryTarget() throws {
        let targets = try #require(SSHLinkTargetParser.parse(Self.rows, forPaths: Self.paths))
        #expect(targets["/srv/rel"] == "plain.txt")
        #expect(targets["/srv/abs"] == "/etc/hosts")
    }

    @Test("a dangling link keeps its target — a link is copied as written, never resolved")
    func readsADanglingTarget() throws {
        let targets = try #require(SSHLinkTargetParser.parse(Self.rows, forPaths: Self.paths))
        #expect(targets["/srv/dangling"] == "../nowhere")
    }

    @Test("a target containing ` -> ` survives, because the size column says where it starts")
    func readsATargetContainingAnArrow() throws {
        let targets = try #require(SSHLinkTargetParser.parse(Self.rows, forPaths: Self.paths))
        #expect(targets["/srv/arrowtarget"] == "has -> arrow")
    }

    /// The case that inverts the shipped rule. The row is `…/a -> b -> c` for a link *named*
    /// `a -> b` pointing at `c`, so the first ` -> ` is inside the name: a first-arrow split answers
    /// `b -> c`, and the size column (1) can only be `c`.
    @Test("a link whose NAME contains ` -> ` is read by size, not by the first arrow")
    func readsALinkWhoseNameContainsAnArrow() throws {
        let targets = try #require(SSHLinkTargetParser.parse(Self.rows, forPaths: Self.paths))
        #expect(targets["/srv/a -> b"] == "c")
    }

    /// A newline in a target breaks any line-oriented read — `weird\nname.txt` arrives as `weird` —
    /// and the size column (14 against 5) is the only thing that can tell. Dropped rather than
    /// handed over: a *wrong* target would be recreated as a real link somewhere nobody wrote.
    @Test("a target cut short by an embedded newline is dropped, not truncated")
    func dropsAnUnverifiableTarget() throws {
        let targets = try #require(SSHLinkTargetParser.parse(Self.rows, forPaths: Self.paths))
        #expect(targets["/srv/newlinetarget"] == nil)
    }

    @Test("a path that is not a link, and one with no row at all, simply have no target")
    func hasNoTargetForANonLinkOrAMissingPath() throws {
        let targets = try #require(SSHLinkTargetParser.parse(Self.rows, forPaths: Self.paths))
        #expect(targets["/srv/plain.txt"] == nil)
        #expect(targets["/srv/nope"] == nil)
        // Rows did come back, so the channel is fine and nothing about the account is in question.
        #expect(targets.count == 5)
    }

    @Test("a row for a path nobody asked about is ignored")
    func ignoresAnUnrequestedRow() throws {
        let targets = try #require(
            SSHLinkTargetParser.parse(Self.rows, forPaths: ["/srv/rel"])
        )
        #expect(targets == ["/srv/rel": "plain.txt"])
    }

    /// The sentinel. An `sftp`-only account answers an exec request with this sentence on *stdout*
    /// (measured), and `runCommand` returns no exit status to tell it apart — so a reader that took
    /// stdout for a target would recreate the link pointing at an English sentence.
    @Test("prose from an sftp-only account is not an answer")
    func rejectsProse() {
        #expect(SSHLinkTargetParser.parse(
            "This service allows sftp connections only.\n", forPaths: Self.paths
        ) == nil)
    }

    @Test("empty output is not an answer either")
    func rejectsEmptyOutput() {
        #expect(SSHLinkTargetParser.parse("", forPaths: Self.paths) == nil)
    }

    // MARK: - The command

    @Test("the command names every path, quoted, and asks ls not to follow or resolve names")
    func buildsTheCommand() throws {
        let command = try #require(SSHReadLinkCommand.targets(of: ["/srv/a b", "/srv/it's"]))
        #expect(command == "/usr/bin/env LC_ALL=C ls -ldn -- '/srv/a b' '/srv/it'\\''s'")
    }

    @Test("no paths is no command, so a directory with no links opens no channel")
    func buildsNoCommandForNoPaths() {
        #expect(SSHReadLinkCommand.targets(of: []) == nil)
    }

    @Test("paths past the argv cap are split into further batches, in order")
    func batchesPaths() {
        let batches = SSHReadLinkCommand.batches(of: ["a", "b", "c", "d", "e"], limit: 2)
        #expect(batches == [["a", "b"], ["c", "d"], ["e"]])
    }

    // MARK: - The backend

    private let location = SFTPLocation(host: "example.com", port: 22, username: "oleg")

    private func path(_ remote: String) -> VFSPath {
        VFSPath(backend: .sftp(location), path: remote)
    }

    private func link(_ remote: String, target: String? = nil) -> FileEntry {
        FileEntry(
            path: path(remote),
            name: (remote as NSString).lastPathComponent,
            kind: .symlink,
            byteSize: 9,
            modificationDate: Date(timeIntervalSince1970: 0),
            creationDate: Date(timeIntervalSince1970: 0),
            isHidden: false,
            permissions: 0o755,
            inode: 0,
            symlinkDestination: target
        )
    }

    @Test("the backend fills in the targets the listing could not carry")
    func resolvesTargets() {
        let transport = FakeSFTPTransport()
        transport.commandOutput = Self.rows
        let resolved = SFTPBackend(location: location, transport: transport)
            .resolvingSymlinkTargets(in: [link("/srv/rel"), link("/srv/abs")])
        #expect(resolved.map(\.symlinkDestination) == ["plain.txt", "/etc/hosts"])
        #expect(transport.commands.count == 1) // one channel for both, not one each
    }

    @Test("a directory with no unresolved links opens no channel at all")
    func asksNothingWithoutLinks() {
        let transport = FakeSFTPTransport()
        transport.commandOutput = Self.rows
        let entries = [link("/srv/rel", target: "plain.txt")]
        let resolved = SFTPBackend(location: location, transport: transport)
            .resolvingSymlinkTargets(in: entries)
        #expect(resolved.map(\.symlinkDestination) == ["plain.txt"])
        #expect(transport.commands.isEmpty)
    }

    @Test("an account with no exec channel leaves every target unknown")
    func leavesTargetsUnknownWithoutAnExecChannel() {
        let transport = FakeSFTPTransport() // `commandOutput` nil: the protocol's own default
        let resolved = SFTPBackend(location: location, transport: transport)
            .resolvingSymlinkTargets(in: [link("/srv/rel")])
        #expect(resolved.map(\.symlinkDestination) == [nil])
    }

    /// The latch, and its narrowness. "No recognisable row" is about the *account*; a batch that
    /// answered, in which one path happened not to be a link, is about that path — latching on the
    /// second is how one ordinary file would cost every later link its only way of being copied.
    @Test("an account that cannot answer is asked once, and a real answer never latches")
    func latchesOnlyOnNoAnswerAtAll() {
        let mute = FakeSFTPTransport()
        mute.commandOutput = "This service allows sftp connections only.\n"
        let refused = SFTPBackend(location: location, transport: mute)
        _ = refused.resolvingSymlinkTargets(in: [link("/srv/rel")])
        _ = refused.resolvingSymlinkTargets(in: [link("/srv/abs")])
        #expect(mute.commands.count == 1)
        #expect(refused.links.isRefused)

        let answering = FakeSFTPTransport()
        answering.commandOutput = Self.rows
        let live = SFTPBackend(location: location, transport: answering)
        _ = live.resolvingSymlinkTargets(in: [link("/srv/plain.txt")]) // answered, no target
        _ = live.resolvingSymlinkTargets(in: [link("/srv/rel")])
        #expect(answering.commands.count == 2)
        #expect(!live.links.isRefused)
    }
}
