import Darwin
import DirnexCore
import Foundation
import Testing

@testable import Dirnex

/// The space an SFTP server has left (``SFTPDiskFree``, PLAN.md §M38's SFTP follow-up), asked of the
/// live server through the real `sftp`. The throwaway server of `scripts/live_test_servers.sh` runs on
/// this Mac, so its answer can be checked against this Mac's own `statvfs` of the same login
/// directory, which is the call its `sftp-server` makes.
extension SFTPLiveIntegrationTests {
    @Test("the space left is the login directory's filesystem, as statvfs reads it on the server")
    func spaceLeft() async throws {
        let config = try #require(SFTPLiveEnvironment.current)
        let run = try await offCooperativePool { () -> SpaceRun in
            let transport = SFTPProcessTransport(
                location: config.location,
                authentication: .key(identityFile: config.identityFile)
            )
            let space = try SFTPBackend(location: config.location, transport: transport).space()
            return SpaceRun(space: space, home: try transport.resolveHomeDirectory())
        }
        let space = try #require(run.space, "the server reports its space")
        let total = try #require(space.totalBytes)
        #expect(space.availableBytes > 0 && space.availableBytes <= total)

        guard ["127.0.0.1", "localhost", "::1"].contains(config.location.host) else { return }
        var local = statvfs()
        #expect(statvfs(run.home, &local) == 0)
        // `sftp` prints KiB, so the total is the filesystem's rounded down to one.
        let kibibytes = UInt64(local.f_frsize) * UInt64(local.f_blocks) / 1024
        #expect(UInt64(total) == kibibytes * 1024)
        // The space left moves with everything else writing to this disk, a parallel test run
        // included, so it is held to within a gibibyte of this Mac's own reading.
        let available = Int64(UInt64(local.f_frsize) * UInt64(local.f_bavail))
        #expect(abs(space.availableBytes - available) < 1 << 30)
    }

    struct SpaceRun: Sendable {
        let space: ServerSpace?
        let home: String
    }
}
