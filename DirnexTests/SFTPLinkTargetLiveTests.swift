import DirnexCore
import Foundation
import Testing

@testable import Dirnex

/// Reading a symlink's target over the SSH exec channel, against a **real server** (PLAN.md §M25
/// Slice 4).
///
/// It has to be live for the reason the whole milestone does: what is under test is what a server
/// prints and what `ls` does with an awkward name, and both failure directions are invisible from
/// inside. A link copied with the *wrong* target is a real link pointing somewhere nobody wrote, and
/// a link copied with an empty one used to terminate the process — neither looks like a failure to
/// the code that caused it.
///
/// Gated on the same config file the other SFTP suites use (`/tmp/dirnex_sftp_live_test.json`), so
/// CI skips it.
///
/// **Read the run's issue count, not the per-test ticks** — every body runs inside
/// ``offCooperativePool``, which puts a failed `#expect` under `Test «unknown»` while the test it
/// came from still prints a tick.
@Suite("SFTP symlink targets ▸ live", .enabled(if: SFTPLiveEnvironment.current != nil))
struct SFTPLinkTargetLiveTests {
    private func makeBackend() throws -> (SFTPBackend, SFTPLiveEnvironment.Config) {
        let config = try #require(SFTPLiveEnvironment.current)
        let transport = SFTPProcessTransport(
            location: config.location,
            authentication: .key(identityFile: config.identityFile)
        )
        return (SFTPBackend(location: config.location, transport: transport), config)
    }

    /// A remote directory holding links this suite made, removed on the way out.
    private func withRemoteLinks(
        _ links: [(name: String, target: String)],
        _ body: (SFTPBackend, VFSPath) throws -> Void
    ) throws {
        let (backend, config) = try makeBackend()
        let directory = VFSPath(
            backend: .sftp(config.location),
            path: config.remotePath + "/dirnex-links-\(UUID().uuidString)"
        )
        try backend.createDirectory(at: directory)
        defer { try? backend.removeItem(at: directory) }

        for link in links {
            try backend.createSymbolicLink(
                at: directory.appending(link.name),
                withDestination: link.target
            )
        }
        try body(backend, directory)
    }

    @Test("the server's own links come back with the targets it was given")
    func readsRealTargets() async throws {
        try await offCooperativePool {
            try withRemoteLinks([
                ("rel", "plain.txt"),
                ("abs", "/etc/hosts"),
                ("dangling", "../nowhere")
            ]) { backend, directory in
                let listed = try backend.listDirectory(at: directory)
                // The state this slice exists to change: `sftp`'s own listing knows they are links
                // and cannot say what they point at.
                #expect(listed.allSatisfy { $0.kind == .symlink })
                #expect(listed.allSatisfy { $0.symlinkDestination == nil })

                let resolved = backend.resolvingSymlinkTargets(in: listed)
                let targets = Dictionary(
                    uniqueKeysWithValues: resolved.map { ($0.name, $0.symlinkDestination) }
                )
                #expect(targets["rel"] == "plain.txt")
                #expect(targets["abs"] == "/etc/hosts")
                // A dangling link keeps its text: a copy duplicates the link, never resolves it.
                #expect(targets["dangling"] == "../nowhere")
            }
        }
    }

    /// Both arrows, against a real server rather than a fixture, because they are settled by two
    /// different rules and each fails silently on its own.
    ///
    /// A ` -> ` inside the **target** is framed by the exec row's size column (`…/arrowtarget -> has
    /// -> arrow`, size 12). A ` -> ` inside the **name** is settled one layer earlier, by
    /// `SFTPListingParser` not splitting at all: `sftp`'s `ls -la` prints no target ever, so the
    /// arrow belongs to the name, and the split this parser used to do listed the link under the
    /// shorter name `a` — a wrong *file name*, which a copy then writes to disk.
    @Test("a real ls disambiguates an arrow in the target and an arrow in the name")
    func readsAwkwardNames() async throws {
        try await offCooperativePool {
            try withRemoteLinks([
                ("arrowtarget", "has -> arrow"),
                ("a -> b", "c")
            ]) { backend, directory in
                let resolved = backend.resolvingSymlinkTargets(
                    in: try backend.listDirectory(at: directory)
                )
                let targets = Dictionary(
                    uniqueKeysWithValues: resolved.map { ($0.name, $0.symlinkDestination) }
                )
                #expect(targets["arrowtarget"] == "has -> arrow")
                #expect(targets["a -> b"] == "c")
            }
        }
    }

    /// The whole point, end to end through `CopyEngine`: a link on the server is downloaded as a
    /// link on this disk, pointing where the server's does.
    @Test("downloading a folder of links recreates them, pointing where the server's do")
    func downloadsLinksFaithfully() async throws {
        try await offCooperativePool {
            let config = try #require(SFTPLiveEnvironment.current)
            try withRemoteLinks([("rel", "plain.txt"), ("abs", "/etc/hosts")]) { _, remote in
                let local = FileManager.default.temporaryDirectory
                    .appendingPathComponent("dirnex-links-\(UUID().uuidString)")
                try FileManager.default.createDirectory(
                    at: local, withIntermediateDirectories: true
                )
                defer { try? FileManager.default.removeItem(at: local) }

                // The real router, so the download takes the path the app takes — the remote read
                // and the local write are two different backends and the engine holds only one.
                let composite = CompositeBackend(local: LocalBackend())
                let connected = composite.connectSFTP(
                    location: config.location,
                    authentication: .key(identityFile: config.identityFile)
                )
                let report = CopyEngine.run(
                    FileOperation(
                        kind: .copy,
                        sources: [try connected.stat(at: remote)],
                        destinationDirectory: .local(local.path)
                    ),
                    using: composite
                )
                #expect(report.failures.isEmpty)

                let landed = local.appendingPathComponent(remote.lastComponent)
                #expect(
                    try FileManager.default.destinationOfSymbolicLink(
                        atPath: landed.appendingPathComponent("rel").path
                    ) == "plain.txt"
                )
                #expect(
                    try FileManager.default.destinationOfSymbolicLink(
                        atPath: landed.appendingPathComponent("abs").path
                    ) == "/etc/hosts"
                )
            }
        }
    }
}
