import DirnexCore
import Foundation
import Testing

@testable import Dirnex

/// That a file whose name is not ASCII survives a round trip through the real `sftp` — and that the
/// row the listing produces still addresses it.
///
/// Its own file rather than another test in ``SFTPLiveIntegrationTests`` because it is its own
/// subject: that suite proves the *verbs* work, and this proves the **names** do. (It also sits at
/// SwiftLint's `file_length`, and the house rule is to split by concept rather than shave lines.)
///
/// Gated on the same config file, so CI — which has no server — skips it silently.
@Suite("SFTP non-ASCII names live", .enabled(if: SFTPLiveEnvironment.current != nil))
struct SFTPNonASCIINameLiveTests {
    private func makeBackend() throws -> (SFTPBackend, SFTPLiveEnvironment.Config) {
        let config = try #require(SFTPLiveEnvironment.current)
        let transport = SFTPProcessTransport(
            location: config.location,
            authentication: .key(identityFile: config.identityFile)
        )
        return (SFTPBackend(location: config.location, transport: transport), config)
    }

    /// A non-ASCII name survives the upload **and the read back**, which is the half that broke.
    ///
    /// Reported 2026-09-08 as files being renamed by the copy: a `DSC_0697-Панорама.jpg` sent to a
    /// server listed back as `DSC_0697-\320\237\320\260\320\275\320\276\321\200\320\260\320\274\320\260.jpg`.
    /// Nothing was renamed — `put` carries the real bytes of the name, and it is `sftp`'s own
    /// `ls -la` that escapes every byte its locale calls unprintable, which for a
    /// LaunchServices-launched app (no `LANG`, no `LC_CTYPE`, no `LC_ALL`) is every byte above
    /// ASCII. See ``ChildProcessLocale``.
    ///
    /// **The download is addressed through the path the listing produced, never through the literal
    /// above**, and that is what makes this a test of the bug rather than of nothing: what failed
    /// was the disagreement between the name the listing hands back and the file on the server, so a
    /// probe that re-types the name it wrote is on neither side of it. Re-typed, this passes against
    /// the broken build (docs/NOTES.md ▸ curl for S3, where the same probe had to be rewritten for
    /// the same reason).
    @Test("a non-ASCII name lists back verbatim, and the row it produces still addresses the file")
    func nonASCIINameRoundTrips() async throws {
        // Off the cooperative pool: every verb below blocks on a subprocess for a real network
        // round trip, which a test body may not do — see ``offCooperativePool``.
        try await offCooperativePool {
            let (backend, config) = try makeBackend()
            let base = VFSPath(backend: .sftp(config.location), path: config.remotePath)
            let dir = base.appending("dirnex_utf8_test_\(UUID().uuidString)")
            try backend.createDirectory(at: dir)
            defer { try? backend.removeItem(at: dir) }

            let fileManager = FileManager.default
            let scratch = fileManager.temporaryDirectory
                .appendingPathComponent("dirnex_sftp_\(UUID().uuidString)")
            try fileManager.createDirectory(at: scratch, withIntermediateDirectories: true)
            defer { try? fileManager.removeItem(at: scratch) }

            // The reporter's own name, Cyrillic in the middle of ASCII — the shape that makes an
            // escaped listing look like a *rename* rather than like mojibake.
            let name = "DSC_0697-Панорама.jpg"
            let localSource = scratch.appendingPathComponent(name)
            let payload = Data("panorama \(UUID().uuidString)".utf8)
            try payload.write(to: localSource)
            try backend.copyFile(
                at: .local(localSource.path),
                to: dir.appending(name),
                progress: { _ in },
                isCancelled: { false }
            )

            // The listing draws the name the user gave the file, with nothing escaped.
            let listed = try backend.listDirectory(at: dir)
            let names = listed.map(\.name)
            #expect(names == [name])
            let entry = try #require(listed.first)
            #expect(!entry.name.contains("\\"))

            // And the row addresses the file: this is where the escaped name failed, because every
            // verb re-quotes it and the server is asked for a name that is not there.
            let localDest = scratch.appendingPathComponent("back.bin")
            try backend.copyFile(
                at: entry.path,
                to: .local(localDest.path),
                progress: { _ in },
                isCancelled: { false }
            )
            #expect(try Data(contentsOf: localDest) == payload)
            #expect(try backend.stat(at: entry.path).byteSize == Int64(payload.count))
        }
    }
}
