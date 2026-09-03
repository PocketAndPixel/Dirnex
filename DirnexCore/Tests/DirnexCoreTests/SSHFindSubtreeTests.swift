import Foundation
import Testing

@testable import DirnexCore

/// The bytes a real `sshd` answered on 2026-08-16 — `find '/tmp/dxm22' -exec ls -ldn {} +` over a
/// fixture tree — captured verbatim rather than hand-written, so what these tests are pinned to is
/// what a server actually prints and not what this project believes it prints.
///
/// Everything awkward about the format is in here on purpose: the `@` BSD extended-attribute marker
/// on the mode, a symlink with its ` -> ` target, a size column and a **year-bearing** date
/// (`Jan  1  2024`) next to **year-less** ones (`Aug 16 02:51`), and `find`'s own depth-first row
/// order with `root.txt` — a top-level file — arriving last.
private enum SSHFindFixtures {
    static let root = "/tmp/dxm22"

    static let tree = """
    drwxr-xr-x@ 6 501  0   192 Aug 16 02:51 /tmp/dxm22
    drwxr-xr-x@ 4 501  0   128 Aug 16 02:51 /tmp/dxm22/docs
    -rw-r--r--@ 1 501  0  2048 Jan  1  2024 /tmp/dxm22/docs/report.pdf
    drwxr-xr-x@ 3 501  0    96 Aug 16 02:51 /tmp/dxm22/docs/sub
    -rw-r--r--@ 1 501  0     4 Aug 16 02:51 /tmp/dxm22/docs/sub/notes.txt
    drwxr-xr-x@ 2 501  0    64 Aug 16 02:51 /tmp/dxm22/empty
    drwxr-xr-x@ 4 501  0   128 Aug 16 02:51 /tmp/dxm22/photos
    lrwxr-xr-x@ 1 501  0     7 Aug 16 02:51 /tmp/dxm22/photos/link -> ../docs
    -rw-r--r--@ 1 501  0     4 Aug 16 02:51 /tmp/dxm22/photos/pic.png
    -rw-r--r--@ 1 501  0     5 Aug 16 02:51 /tmp/dxm22/root.txt
    """

    /// What an account confined to the `sftp` subsystem answers an exec request with — measured on
    /// **stdout**, with exit 1 and an empty stderr, which is what makes it dangerous: a reader that
    /// took stdout as its listing would be parsing an English sentence.
    static let sftpOnlyRefusal = "This service allows sftp connections only.\n"

    /// A login shell's rc writing to stdout. Nothing in this project's own `.bashrc` did, but it is
    /// sourced on every exec (measured), so the stream is not ours alone.
    static let shellNoise = "Welcome to example.com — 3 users logged in\n"
}

@Suite("SSHFindCommand")
struct SSHFindCommandTests {
    @Test("a path carrying shell metacharacters is one literal argument")
    func quotesMetacharacters() {
        // The live control for this is in the probe rather than here: a path built as
        // `…/tree'; touch CANARY; echo '` was sent to a real server and created no canary.
        #expect(SSHFindCommand.quote("/srv/it's $a `b` ;x") == #"'/srv/it'\''s $a `b` ;x'"#)
        #expect(SSHFindCommand.quote("/a b") == "'/a b'")
        #expect(SSHFindCommand.quote("/plain") == "'/plain'")
    }

    /// A newline in a name is not a formatting problem, it is a second command — the shape FTP has
    /// to refuse outright because it has nothing to escape with. Single quotes do have something.
    @Test("a newline in a path stays inside the quotes")
    func quotesNewlines() {
        #expect(SSHFindCommand.quote("/a\nrm -rf /") == "'/a\nrm -rf /'")
    }

    @Test("the root is normalized to what find will echo back")
    func normalizesRoot() {
        #expect(SSHFindCommand.normalizedRoot("/home/oleg/docs/") == "/home/oleg/docs")
        #expect(SSHFindCommand.normalizedRoot("/home/oleg/docs///") == "/home/oleg/docs")
        #expect(SSHFindCommand.normalizedRoot("/home/oleg/docs") == "/home/oleg/docs")
        // `/` has nothing else to be, and a bare "" can only mean it.
        #expect(SSHFindCommand.normalizedRoot("/") == "/")
        #expect(SSHFindCommand.normalizedRoot("") == "/")
    }

    /// The rule the probe found by watching a shell function print `SHADOWED` where `find` should
    /// have listed: an exec channel sources the user's rc, so every word the *shell* resolves has
    /// to go through `env`.
    @Test("every shell-resolved word goes through env, and the exec'd ls does not need to")
    func bypassesShellFunctions() {
        let command = SSHFindCommand.subtree(root: "/srv/data")

        #expect(command.contains("/usr/bin/env LC_ALL=C find "))
        #expect(command.contains("| /usr/bin/env head -n "))
        // `find` spawns this one itself, so no function can reach it — and wrapping it would put an
        // extra process between find and every batch of paths.
        #expect(command.contains("-exec ls -ldn {} +"))
        #expect(!command.contains("env ls"))
    }

    @Test("the command asks for the quoted root and caps its own output")
    func buildsTheCommand() {
        #expect(SSHFindCommand.subtree(root: "/a b/", rowLimit: 25) ==
            "/usr/bin/env LC_ALL=C find '/a b' -exec ls -ldn {} + | /usr/bin/env head -n 25")
    }
}

@Suite("SSHFindListingParser")
struct SSHFindListingParserTests {
    @Test("a real server's rows become entries under the root")
    func parsesRealOutput() throws {
        let listing = try #require(
            SSHFindListingParser.parse(SSHFindFixtures.tree, under: SSHFindFixtures.root)
        )

        #expect(listing.rows.map(\.path) == [
            "/tmp/dxm22/docs",
            "/tmp/dxm22/docs/report.pdf",
            "/tmp/dxm22/docs/sub",
            "/tmp/dxm22/docs/sub/notes.txt",
            "/tmp/dxm22/empty",
            "/tmp/dxm22/photos",
            "/tmp/dxm22/photos/link",
            "/tmp/dxm22/photos/pic.png",
            "/tmp/dxm22/root.txt"
        ])
        #expect(listing.rows.map(\.kind) == [
            .directory, .file, .directory, .file, .directory, .directory, .symlink, .file, .file
        ])
        #expect(listing.rows.map(\.byteSize) == [128, 2048, 96, 4, 64, 128, 7, 4, 5])
        #expect(listing.rows.first(where: { $0.kind == .symlink })?.symlinkDestination == "../docs")
        // The root's own row is counted but never returned — see the next test for why it is
        // counted, and `SubtreeSearch` for why a folder is not a hit inside itself.
        #expect(listing.rowCount == 10)
    }

    /// The one case that separates "this folder is empty" from "this account has no shell", and the
    /// reason the root row is the sentinel rather than a marker of our own: `find` prints the
    /// operand it was given whatever else it finds.
    @Test("an empty folder parses to no rows rather than to nothing")
    func emptyFolderIsNotAFailure() throws {
        let onlyRoot = "drwxr-xr-x@ 2 501  0    64 Aug 16 02:51 /tmp/dxm22/empty"
        let listing = try #require(
            SSHFindListingParser.parse(onlyRoot, under: "/tmp/dxm22/empty")
        )

        #expect(listing.rows.isEmpty)
        #expect(listing.rowCount == 1)
    }

    @Test("the sftp-only refusal is not a listing")
    func refusesTheSFTPOnlyAnswer() {
        #expect(SSHFindListingParser.parse(
            SSHFindFixtures.sftpOnlyRefusal, under: SSHFindFixtures.root
        ) == nil)
    }

    @Test("shell noise with no rows behind it is not a listing")
    func refusesShellNoise() {
        #expect(SSHFindListingParser.parse(
            SSHFindFixtures.shellNoise, under: SSHFindFixtures.root
        ) == nil)
    }

    /// Noise that happens to be row-shaped is the case the anchor exists for — and it is also what
    /// would catch a GNU `ls` that quoted its names, since a quoted path stops matching the prefix.
    @Test("a row that is not under the root is dropped, and the root's own row still vouches")
    func anchorsEveryPathUnderTheRoot() throws {
        let mixed = """
        drwxr-xr-x@ 6 501  0   192 Aug 16 02:51 /tmp/dxm22
        -rw-r--r--@ 1 501  0     5 Aug 16 02:51 /etc/passwd
        -rw-r--r--@ 1 501  0     5 Aug 16 02:51 /tmp/dxm22-sibling/other.txt
        -rw-r--r--@ 1 501  0     5 Aug 16 02:51 /tmp/dxm22/root.txt
        """
        let listing = try #require(SSHFindListingParser.parse(mixed, under: SSHFindFixtures.root))

        // `/tmp/dxm22-sibling` shares the root's *string* prefix and is not under it — which is the
        // same trailing-delimiter trap S3's listing prefix has (docs/NOTES.md ▸ curl for S3).
        #expect(listing.rows.map(\.path) == ["/tmp/dxm22/root.txt"])
        #expect(listing.rowCount == 2)
    }

    @Test("a search rooted at / anchors on a single slash")
    func handlesTheFilesystemRoot() throws {
        let atRoot = """
        drwxr-xr-x@ 6 501  0   192 Aug 16 02:51 /
        -rw-r--r--@ 1 501  0     5 Aug 16 02:51 /root.txt
        """
        let listing = try #require(SSHFindListingParser.parse(atRoot, under: "/"))

        #expect(listing.rows.map(\.path) == ["/root.txt"])
    }
}

@Suite("SFTPBackend subtree shortcut")
struct SFTPSubtreeListingTests {
    private let location = SFTPLocation(host: "example.com", port: 22, username: "oleg")

    private func backend(_ transport: FakeSFTPTransport) -> SFTPBackend {
        SFTPBackend(location: location, transport: transport)
    }

    private func path(_ remote: String) -> VFSPath {
        VFSPath(backend: .sftp(location), path: remote)
    }

    private func transport(answering output: String) -> FakeSFTPTransport {
        let transport = FakeSFTPTransport()
        transport.commandOutput = output
        return transport
    }

    @Test("the whole subtree is asked for in one command, rooted at the folder")
    func sendsOneFindCommand() throws {
        let fake = transport(answering: SSHFindFixtures.tree)
        _ = try backend(fake).subtreeListing(at: path(SSHFindFixtures.root), isCancelled: { false })

        #expect(fake.commands == [SSHFindCommand.subtree(root: SSHFindFixtures.root)])
    }

    /// The claim the whole slice rests on, as a number a test can hold: one round trip covers every
    /// depth, where the walk would have opened a connection per directory.
    @Test("one command answers four directories' worth of rows")
    func answersEveryDepthAtOnce() throws {
        let fake = transport(answering: SSHFindFixtures.tree)
        let listing = try #require(
            try backend(fake).subtreeListing(at: path(SSHFindFixtures.root), isCancelled: { false })
        )

        #expect(fake.commands.count == 1)
        #expect(listing.entries.count == 9)
        #expect(listing.isComplete)
        #expect(listing.entries.allSatisfy { $0.path.backend == .sftp(location) })
        #expect(listing.entries.first { $0.name == "notes.txt" }?.path.path
            == "/tmp/dxm22/docs/sub/notes.txt")
    }

    /// `find` walks depth-first, so its own order puts a whole deep branch ahead of a sibling file
    /// at the top — `root.txt` is printed last in the fixture. Truncating *that* at the result cap
    /// is the "deep sliver of one branch" this milestone rejected for the walk.
    @Test("rows come back shallowest-first, not in find's traversal order")
    func ordersByDepth() throws {
        let fake = transport(answering: SSHFindFixtures.tree)
        let listing = try #require(
            try backend(fake).subtreeListing(at: path(SSHFindFixtures.root), isCancelled: { false })
        )

        #expect(listing.entries.map(\.name) == [
            "docs", "empty", "photos", "root.txt", // depth 1
            "report.pdf", "sub", "link", "pic.png", // depth 2
            "notes.txt" // depth 3
        ])
    }

    @Test("a transport with no exec channel reports no shortcut, so the caller walks")
    func noExecChannelMeansWalk() throws {
        let fake = FakeSFTPTransport() // commandOutput nil — the protocol's own default answer
        #expect(try backend(fake).subtreeListing(
            at: path(SSHFindFixtures.root), isCancelled: { false }
        ) == nil)
    }

    /// A refusal is not an error to report: the walk is standing right behind it and will raise a
    /// real failure if there is one.
    @Test("a transport failure reports no shortcut rather than failing the search")
    func transportFailureMeansWalk() throws {
        let fake = FakeSFTPTransport()
        fake.commandError = SFTPTransportError.failure("Couldn’t launch ssh.")
        #expect(try backend(fake).subtreeListing(
            at: path(SSHFindFixtures.root), isCancelled: { false }
        ) == nil)
    }

    @Test("the sftp-only refusal reports no shortcut rather than a listing of one sentence")
    func sftpOnlyAccountMeansWalk() throws {
        let fake = transport(answering: SSHFindFixtures.sftpOnlyRefusal)
        #expect(try backend(fake).subtreeListing(
            at: path(SSHFindFixtures.root), isCancelled: { false }
        ) == nil)
    }

    /// Asked before the command, so a stop costs nothing rather than one more handshake.
    @Test("a stop before the command throws rather than spending one")
    func cancelsBeforeAsking() throws {
        let fake = transport(answering: SSHFindFixtures.tree)

        #expect(throws: CancellationError.self) {
            _ = try backend(fake).subtreeListing(
                at: path(SSHFindFixtures.root), isCancelled: { true }
            )
        }
        #expect(fake.commands.isEmpty)
    }

    /// Cancellation is the one thing that must travel out rather than degrading to `nil`: it is the
    /// caller's own instruction, and `SubtreeSearch` turns it back into the stop that was asked for.
    @Test("a stop during the command is reported, not swallowed as a missing shortcut")
    func cancellationTravels() throws {
        let fake = FakeSFTPTransport()
        fake.commandError = CancellationError()

        #expect(throws: CancellationError.self) {
            _ = try backend(fake).subtreeListing(
                at: path(SSHFindFixtures.root), isCancelled: { false }
            )
        }
    }

    /// The row cap is applied by the *server's* `head`, so a capped run looks exactly like a
    /// complete one — the rows are all real and nothing failed. Counting them against the cap we
    /// asked for is the only evidence there is, and claiming a slice is the whole subtree is the
    /// quiet direction: it is a statement about the folder made from part of it.
    ///
    /// The fixture prints 10 rows including the root's, so a cap of 10 is what the server would
    /// have stopped at.
    @Test("a run that filled the row cap says it is incomplete")
    func reportsTruncation() throws {
        var sut = backend(transport(answering: SSHFindFixtures.tree))
        sut.subtreeRowLimit = 10

        let listing = try #require(
            try sut.subtreeListing(at: path(SSHFindFixtures.root), isCancelled: { false })
        )
        #expect(!listing.isComplete)
        // The hits are still real and still handed over — a search says "there may be more", it
        // does not throw away what it found.
        #expect(listing.entries.count == 9)
    }

    /// The narrowness control: one row short of the cap is a tree that genuinely ended, and must
    /// not be reported as cut off — otherwise every search on a well-behaved server would advise
    /// narrowing the scope.
    @Test("a run that stopped short of the cap is complete")
    func reportsCompletion() throws {
        var sut = backend(transport(answering: SSHFindFixtures.tree))
        sut.subtreeRowLimit = 11

        let listing = try #require(
            try sut.subtreeListing(at: path(SSHFindFixtures.root), isCancelled: { false })
        )
        #expect(listing.isComplete)
    }

    @Test("the cap the backend counts against is the cap it asked the server for")
    func asksForItsOwnCap() throws {
        let fake = transport(answering: SSHFindFixtures.tree)
        var sut = backend(fake)
        sut.subtreeRowLimit = 10
        _ = try sut.subtreeListing(at: path(SSHFindFixtures.root), isCancelled: { false })

        #expect(fake.commands == [SSHFindCommand.subtree(root: SSHFindFixtures.root, rowLimit: 10)])
        #expect(SSHFindCommand.defaultRowLimit == 50_000)
    }
}

@Suite("SFTPProcessArguments exec")
struct SFTPProcessArgumentsExecTests {
    private let location = SFTPLocation(host: "example.com", port: 2222, username: "oleg")

    /// `ssh` spells the port `-p` and `sftp` spells it `-P`. Swapping them is a *usage* error that
    /// exits 1 having printed help — which times like a very fast success and reads like one, and
    /// which cost this milestone's own benchmark a wrong answer before it was noticed.
    @Test("the port is ssh's spelling, not sftp's")
    func usesSSHPortFlag() {
        let arguments = SFTPProcessArguments.exec(
            location: location,
            dial: .asTyped(location.host),
            authentication: .key(identityFile: "/k"),
            connectTimeout: 15,
            command: "true"
        )

        #expect(arguments.contains("-p"))
        #expect(!arguments.contains("-P"))
        #expect(arguments[arguments.firstIndex(of: "-p")! + 1] == "2222")
    }

    /// There is no batch file to read — the command *is* an argument — so `-b -` would leave `ssh`
    /// looking for a file called `-`.
    @Test("there is no batch flag, and the command is the last argument")
    func putsTheCommandLast() {
        let arguments = SFTPProcessArguments.exec(
            location: location,
            dial: .asTyped(location.host),
            authentication: .key(identityFile: "/k"),
            connectTimeout: 15,
            command: "find / -name x"
        )

        #expect(!arguments.contains("-b"))
        #expect(arguments.last == "find / -name x")
        #expect(arguments[arguments.count - 2] == "oleg@example.com")
    }

    /// The exec channel must not become a second security posture: it is the same connection to the
    /// same host, so it gets the same host-key policy and the same offered authentication methods.
    @Test("the security-relevant flags match the browsing channel's exactly")
    func sharesTheBrowsingPosture() {
        for authentication in [SFTPAuthentication.key(identityFile: "/k"), .password] {
            let batch = SFTPProcessArguments.batch(
                location: location, dial: .asTyped(location.host), authentication: authentication,
                connectTimeout: 15
            )
            let exec = SFTPProcessArguments.exec(
                location: location, dial: .asTyped(location.host), authentication: authentication,
                connectTimeout: 15,
                command: "true"
            )
            for flag in [
                "StrictHostKeyChecking=accept-new", "ConnectTimeout=15",
                "PreferredAuthentications=password", "PubkeyAuthentication=no",
                "NumberOfPasswordPrompts=1", "BatchMode=yes"
            ] where batch.contains(flag) {
                #expect(exec.contains(flag), "exec dropped \(flag)")
            }
        }
    }
}
