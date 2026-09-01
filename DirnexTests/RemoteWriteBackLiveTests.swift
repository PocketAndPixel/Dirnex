import DirnexCore
import Foundation
import Testing

@testable import Dirnex

/// A save-back batch against a **real server** (PLAN.md §4 ▸ *Still open*, taken 2026-09-01).
///
/// The core suite pins the runner's rules against a fake that answers whatever it is told. What
/// only a live run can show is that the whole batch is a real conversation with a real `sshd` — one
/// ordered pass through the actual transport, with this Mac's own bytes as the judge — and that the
/// two endings that matter are reachable: an item the account cannot write does not abandon the
/// batch, and a Stop leaves what it had not reached alone.
///
/// Gated on `/tmp/dirnex_sftp_live_test.json`, so CI (which has no server) skips it.
///
/// **Read the run's issue count, not the per-test ticks.** Every body runs inside
/// ``offCooperativePool``, which executes it outside any task, so a failed `#expect` is filed under
/// `Test «unknown»` while the test it came from still prints a tick (docs/NOTES.md ▸ Testing).
@Suite("Save-back batch ▸ live", .enabled(if: SFTPLiveEnvironment.current != nil))
struct RemoteWriteBackLiveTests {
    private func makeBackend() throws -> (SFTPBackend, SFTPLiveEnvironment.Config) {
        let config = try #require(SFTPLiveEnvironment.current)
        let transport = SFTPProcessTransport(
            location: config.location,
            authentication: .key(identityFile: config.identityFile)
        )
        return (SFTPBackend(location: config.location, transport: transport), config)
    }

    /// A destination on the server with known contents, and a local "edited" copy for it.
    ///
    /// Written locally because the server *is* this Mac — the fixture is the only part a loopback
    /// harness gets for free, and every claim below is read back through the real transport or off
    /// the real file.
    private func pair(
        _ config: SFTPLiveEnvironment.Config,
        _ name: String,
        edited: String
    ) throws -> (item: RemoteWriteBackItem, onDisk: String) {
        let onDisk = config.remotePath + "/" + name
        try Data("original".utf8).write(to: URL(fileURLWithPath: onDisk))
        let local = NSTemporaryDirectory() + "dirnex-wb-\(UUID().uuidString)"
        try Data(edited.utf8).write(to: URL(fileURLWithPath: local))
        let destination = VFSPath(backend: .sftp(config.location), path: onDisk)
        return (
            RemoteWriteBackItem(
                localPath: local,
                destination: destination,
                byteSize: Int64(edited.utf8.count),
                name: name
            ),
            onDisk
        )
    }

    private func operation(
        _ items: [RemoteWriteBackItem],
        _ config: SFTPLiveEnvironment.Config
    ) -> FileOperation {
        FileOperation(
            kind: .writeBack(WriteBackJob(items: items)),
            sources: [],
            destinationDirectory: VFSPath(backend: .sftp(config.location), path: config.remotePath)
        )
    }

    @Test("a batch goes up as one ordered run, and the server has the edited bytes")
    func batchLandsEveryFile() async throws {
        try await offCooperativePool {
            let (backend, config) = try makeBackend()
            let prefix = "wb-\(UUID().uuidString.prefix(8))"
            let pairs = try (1...4).map {
                try pair(config, "\(prefix)-\($0).txt", edited: "edited \($0)")
            }
            defer {
                for pair in pairs { try? FileManager.default.removeItem(atPath: pair.onDisk) }
            }

            let report = WriteBackRunner.run(
                operation(pairs.map(\.item), config),
                using: backend
            )
            #expect(report.succeeded)
            #expect(report.completedItems == 4)
            // The destinations, in the order the batch was assembled — which is what the caller
            // re-baselines from, one at a time.
            #expect(report.writtenBack == pairs.map(\.item.destination))
            // The OS is the independent judge: `put` truncated the original and left the edit.
            for (index, pair) in pairs.enumerated() {
                #expect(
                    try String(contentsOfFile: pair.onDisk, encoding: .utf8) == "edited \(index + 1)"
                )
            }
        }
    }

    @Test("an item the account cannot write does not abandon the rest")
    func oneRefusalDoesNotStopTheBatch() async throws {
        try await offCooperativePool {
            let (backend, config) = try makeBackend()
            let prefix = "wb-\(UUID().uuidString.prefix(8))"
            let first = try pair(config, "\(prefix)-a.txt", edited: "edited a")
            let last = try pair(config, "\(prefix)-c.txt", edited: "edited c")
            defer {
                try? FileManager.default.removeItem(atPath: first.onDisk)
                try? FileManager.default.removeItem(atPath: last.onDisk)
            }
            // A real refusal from the server rather than an injected one: a path under `/etc` that
            // this account cannot write, sitting between two it can.
            let unwritable = RemoteWriteBackItem(
                localPath: first.item.localPath,
                destination: VFSPath(backend: .sftp(config.location), path: "/etc/hosts"),
                byteSize: 8,
                name: "hosts"
            )

            let report = WriteBackRunner.run(
                operation([first.item, unwritable, last.item], config),
                using: backend
            )
            #expect(!report.succeeded)
            #expect(report.failures.count == 1)
            #expect(report.writtenBack == [first.item.destination, last.item.destination])
            // The item *after* the refusal is the one that matters: thirty-nine edits must not be
            // lost because the fortieth file's server said no.
            #expect(try String(contentsOfFile: last.onDisk, encoding: .utf8) == "edited c")
            // And nothing was written where the server refused.
            #expect(try String(contentsOfFile: "/etc/hosts", encoding: .utf8) != "edited a")
        }
    }

    @Test("stopping leaves the files it had not reached alone, and claims nothing it interrupted")
    func stoppingLeavesTheRestAlone() async throws {
        try await offCooperativePool {
            let (backend, config) = try makeBackend()
            let prefix = "wb-\(UUID().uuidString.prefix(8))"
            let pairs = try (1...3).map {
                try pair(config, "\(prefix)-\($0).txt", edited: "edited \($0)")
            }
            defer {
                for pair in pairs { try? FileManager.default.removeItem(atPath: pair.onDisk) }
            }
            // Stop once the **second** file's bytes have landed, read off the file itself. Two
            // earlier versions of this got the trigger wrong and each read as a bug in the runner:
            // counting how many times `isCancelled` was asked assumed a poll rhythm that belongs to
            // the transport, and stopping on the *first* file's bytes cancels the very transfer
            // that produced them. The bytes of a *later* item are the one signal that is the
            // runner's own — item 1 is finished by then, whatever the transport is doing.
            let second = pairs[1].onDisk
            let report = WriteBackRunner.run(
                operation(pairs.map(\.item), config),
                using: backend,
                onProgress: { _ in },
                isCancelled: {
                    (try? String(contentsOfFile: second, encoding: .utf8)) == "edited 2"
                }
            )
            #expect(report.wasCancelled)
            // Only the item that finished before the stop is claimed.
            #expect(report.writtenBack == [pairs[0].item.destination])
            #expect(try String(contentsOfFile: pairs[0].onDisk, encoding: .utf8) == "edited 1")
            // The item the stop **interrupted** is never claimed, and this is the finding rather
            // than a detail: its bytes are on the server — `put` had already written them when the
            // transport noticed the cancellation — and the runner cannot tell that from a transfer
            // truncated halfway. Claiming it would have the caller re-baseline against a file whose
            // state it does not know; leaving it unclaimed makes the next save say plainly that it
            // cannot tell, which is true.
            #expect(!(report.writtenBack ?? []).contains(pairs[1].item.destination))
            // The one the run never reached is untouched, which is what Stop has to mean.
            #expect(try String(contentsOfFile: pairs[2].onDisk, encoding: .utf8) == "original")
        }
    }
}
