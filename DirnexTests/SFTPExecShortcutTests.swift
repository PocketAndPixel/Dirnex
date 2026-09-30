import DirnexCore
import Foundation
import Testing

@testable import Dirnex

/// The app's half of M22 Slice 4: the SSH **exec** channel a subtree search borrows.
///
/// Everything about *what* to run and *how to read the answer* is pure and tested in `DirnexCore`
/// (`SSHFindCommand`, `SSHFindListingParser`, `SFTPBackend+Subtree`). What only this side can show
/// is the whole chain against a real spawned `ssh` — that a server which cannot be reached costs
/// the search nothing worse than the walk it was always able to fall back on.
///
/// It runs against a **closed loopback port**, so `connect(2)` is refused at once: no DNS, no
/// network, no server to arrange, and nothing to skip when there is no live account configured.
/// (The live end of this, against a real `sshd`, is `SFTPLiveIntegrationTests`.)
@Suite("SFTP exec shortcut")
struct SFTPExecShortcutTests {
    private let unreachable = SFTPLocation(host: "127.0.0.1", port: 47_351, username: "nobody")

    private func transport() -> SFTPProcessTransport {
        SFTPProcessTransport(
            location: unreachable,
            authentication: .key(identityFile: "/nonexistent/key"),
            connectTimeout: 2
        )
    }

    /// The claim the whole fallback rests on: an unreachable server must leave the search *able to
    /// walk*, which means `subtreeListing` answers "no shortcut" rather than throwing. Throwing
    /// would abort a search that a walk could still have answered — and on a server that is truly
    /// down the walk raises the real error, with the real reason, one layer up.
    @Test("a server that cannot be reached reports no shortcut instead of failing the search")
    func unreachableDegradesToTheWalk() throws {
        let backend = SFTPBackend(location: unreachable, transport: transport())

        let listing = try backend.subtreeListing(
            at: VFSPath(backend: .sftp(unreachable), path: "/home/nobody"),
            isCancelled: { false }
        )
        #expect(listing == nil)
    }

    /// Cancellation is the one answer that must travel out rather than degrading to "no shortcut":
    /// it is the user's own instruction, and `SubtreeSearch` turns it back into the stop they asked
    /// for. Degrading it here would silently start the walk they had just stopped.
    @Test("a stop is reported as a stop, not as a missing shortcut")
    func cancellationTravels() throws {
        let backend = SFTPBackend(location: unreachable, transport: transport())

        #expect(throws: CancellationError.self) {
            _ = try backend.subtreeListing(
                at: VFSPath(backend: .sftp(unreachable), path: "/home/nobody"),
                isCancelled: { true }
            )
        }
    }
}
