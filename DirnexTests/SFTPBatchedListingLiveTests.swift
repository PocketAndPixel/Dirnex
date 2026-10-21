import DirnexCore
import Foundation
import Testing

@testable import Dirnex

/// A tree refresh's batched listing against a real `sshd`, through the shipped
/// `SFTPProcessTransport` — the one run that folds `sftp`'s standard error into its output and
/// reads the order back.
///
/// The core suites read transcripts shaped like the ones the probe captured; this is where the
/// shape is checked against the tool, so a newer `sftp` that echoes, buffers or words a refusal
/// differently fails here rather than in a pane. What it cannot see is the session count, which the
/// server's own log answers and parallel suites would blur — that was measured in the running app
/// (docs/HISTORY.md ▸ M30, 2026-10-19).
///
/// Gated on `SFTPLiveEnvironment` like its neighbours, so CI skips it.
@Suite("SFTP batched listing ▸ live", .enabled(if: SFTPLiveEnvironment.current != nil))
struct SFTPBatchedListingLiveTests {
    @Test("one session answers each folder as its own listing, with refusals in the middle")
    func answersEachFolderAsItsOwnListing() async throws {
        // Off the cooperative pool: every verb below blocks on a subprocess for a real network
        // round trip, which a test body may not do — see ``offCooperativePool``.
        try await offCooperativePool {
            let config = try #require(SFTPLiveEnvironment.current)
            let transport = SFTPProcessTransport(
                location: config.location,
                authentication: .key(identityFile: config.identityFile)
            )
            let backend = SFTPBackend(location: config.location, transport: transport)
            let base = VFSPath(backend: .sftp(config.location), path: config.remotePath)
            let root = base.appending("dirnex_batch_\(UUID().uuidString.prefix(8))")
            let listed = root.appending("listed")
            let denied = root.appending("denied")
            let empty = root.appending("empty")
            try backend.createDirectory(at: root)
            defer { try? backend.removeItem(at: root) }
            for folder in [listed, denied, empty] {
                try backend.createDirectory(at: folder)
            }
            let local = FileManager.default.temporaryDirectory
                .appendingPathComponent("dirnex_batch_\(UUID().uuidString).txt")
            try Data("rows".utf8).write(to: local)
            defer { try? FileManager.default.removeItem(at: local) }
            try backend.copyFile(
                at: .local(local.path), to: listed.appending("one.txt"),
                progress: { _ in }, isCancelled: { false }
            )
            // A folder the account may not read — the refusal `sftp` words as
            // `remote readdir("…/"): Permission denied`, the one that ends a plain `-b` batch.
            _ = try transport.applyMetadata(
                [.setMode(POSIXPermissions(rawValue: 0o000))], to: denied.path
            )
            defer {
                _ = try? transport.applyMetadata(
                    [.setMode(POSIXPermissions(rawValue: 0o755))], to: denied.path
                )
            }

            let folders = [root, listed, denied, root.appending("gone"), empty]
            let answers = try backend.listDirectories(at: folders, isCancelled: { false })

            #expect(answers.map { $0?.map(\.name).sorted() } == [
                ["denied", "empty", "listed"], ["one.txt"], nil, nil, []
            ])
            // Each answer is the single listing's, field for field.
            for (folder, answer) in zip(folders, answers) {
                #expect(answer == (try? backend.listDirectory(at: folder)))
            }
        }
    }
}
