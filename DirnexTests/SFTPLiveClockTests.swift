import DirnexCore
import Foundation
import Testing

@testable import Dirnex

/// The SFTP search walk's clock, against a real server — its own suite because
/// `SFTPLiveIntegrationTests` sits at SwiftLint's `type_body_length`, and gated on the same file.
@Suite("SFTP live clock", .enabled(if: SFTPLiveEnvironment.current != nil))
struct SFTPLiveClockTests {
    private func makeBackend() throws -> (SFTPBackend, SFTPLiveEnvironment.Config) {
        let config = try #require(SFTPLiveEnvironment.current)
        let transport = SFTPProcessTransport(
            location: config.location,
            authentication: .key(identityFile: config.identityFile)
        )
        return (SFTPBackend(location: config.location, transport: transport), config)
    }

    /// The walk's times, end to end: a file stamped with a known time, found by the shortcut, lands
    /// on the minute the pane's own listing gives it — which is the stamp's minute.
    ///
    /// **It needs a server whose clock is not this Mac's**, or the bug it pins passes too. The walk
    /// used to print the server's local time and read it as this Mac's, which agrees whenever the two
    /// zones do; measured 2026-10-19, a server in New York put a file written at 16:41 Kyiv time at
    /// 09:41. `scripts/live_test_servers.sh` starts its `sshd` in another zone for that reason, and
    /// the test asks the server first, so a server in this Mac's zone is reported as a run that
    /// proved nothing rather than passing as if it had.
    ///
    /// The pane's listing is the right yardstick because a recent `sftp` client formats the
    /// protocol's own epoch time on this Mac; the stamp is minute-aligned plus 37 seconds, and both
    /// listings print to the minute.
    @Test("the shortcut's times match the pane's, on a server in another zone")
    func shortcutTimesMatchThePane() async throws {
        try await offCooperativePool {
            let (backend, config) = try makeBackend()
            let transport = SFTPProcessTransport(
                location: config.location,
                authentication: .key(identityFile: config.identityFile)
            )
            // The last line shaped like `+1400`: the login shell's rc may print first.
            let printed = try transport.runCommand("/usr/bin/env date +%z", isCancelled: { false })
            let offset = try #require(printed?.split(whereSeparator: \.isNewline).last { line in
                line.count == 5 && (line.first == "+" || line.first == "-")
            })
            let sign = offset.first == "-" ? -1 : 1
            let digits = offset.dropFirst().compactMap(\.wholeNumberValue)
            let serverOffset = sign * (
                (digits[0] * 10 + digits[1]) * 3600 + (digits[2] * 10 + digits[3]) * 60
            )
            #expect(
                serverOffset != TimeZone.current.secondsFromGMT(),
                "The server keeps this Mac's clock (\(offset)), so this run cannot tell UTC from it."
            )

            let base = VFSPath(backend: .sftp(config.location), path: config.remotePath)
            let root = base.appending("dirnex_clock_\(UUID().uuidString.prefix(8))")
            try backend.createDirectory(at: root)
            defer { try? backend.removeItem(at: root) }

            let minute = ((Date().timeIntervalSince1970 - 7 * 86_400) / 60).rounded(.down) * 60
            let stamp = Date(timeIntervalSince1970: minute + 37)
            let local = FileManager.default.temporaryDirectory
                .appendingPathComponent("dirnex_clock_\(UUID().uuidString.prefix(8)).txt")
            try Data("clock".utf8).write(to: local)
            defer { try? FileManager.default.removeItem(at: local) }
            try FileManager.default.setAttributes(
                [.modificationDate: stamp],
                ofItemAtPath: local.path
            )
            let remote = root.appending("timed.txt")
            try backend.copyFile(
                at: .local(local.path),
                to: remote,
                hint: CopySourceHint(metadata: RemoteSourceMetadata(
                    permissions: 0o644,
                    modificationTime: stamp
                )),
                progress: { _ in },
                isCancelled: { false }
            )

            let shortcut = try #require(try backend.subtreeListing(at: root, isCancelled: { false }))
            let found = try #require(shortcut.entries.first { $0.name == "timed.txt" })
            let listed = try #require(try backend.listDirectory(at: root).first {
                $0.name == "timed.txt"
            })
            #expect(found.modificationDate == listed.modificationDate)
            #expect(found.modificationDate.timeIntervalSince1970 == minute)
        }
    }
}
