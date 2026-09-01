import DirnexCore
import Foundation
import Testing

@testable import Dirnex

/// Get Info's write half against a **real server** (PLAN.md §M25 Slice 5).
///
/// It has to be live, because everything under test is what a server does with what the app sent —
/// and because the finding this slice is built on is only reachable against a real one: `sftp`'s
/// `chmod` reports success for a mode the server did not store. No fake can produce that, since a
/// fake is written by whoever also wrote the expectation.
///
/// Gated on `/tmp/dirnex_sftp_live_test.json`, so CI (which has no server) skips it.
///
/// **Read the run's issue count, not the per-test ticks.** Every body runs inside
/// ``offCooperativePool``, which executes it outside any task, so a failed `#expect` is filed under
/// `Test «unknown»` while the test it came from still prints a tick (docs/NOTES.md ▸ Testing).
@Suite("Remote attribute writing ▸ live", .enabled(if: SFTPLiveEnvironment.current != nil))
struct RemoteAttributeWriteLiveTests {
    private func makeBackend() throws -> (SFTPBackend, SFTPLiveEnvironment.Config) {
        let config = try #require(SFTPLiveEnvironment.current)
        let transport = SFTPProcessTransport(
            location: config.location,
            authentication: .key(identityFile: config.identityFile)
        )
        return (SFTPBackend(location: config.location, transport: transport), config)
    }

    /// A file on the server, created locally because the server *is* this Mac — the fixture is the
    /// only part of this that a loopback harness gets for free, and every claim below is read back
    /// through the real transport rather than off the local file.
    private func fixture(
        _ config: SFTPLiveEnvironment.Config,
        mode: mode_t,
        group: gid_t? = nil
    ) throws -> VFSPath {
        let name = "dirnex-attr-\(UUID().uuidString).bin"
        let onDisk = config.remotePath + "/" + name
        try Data("attr".utf8).write(to: URL(fileURLWithPath: onDisk))
        if let group { #expect(chown(onDisk, uid_t(getuid()), group) == 0) }
        #expect(chmod(onDisk, mode) == 0)
        return VFSPath(backend: .sftp(config.location), path: onDisk)
    }

    // MARK: - What the connection offers

    @Test("a live SFTP account offers the mode and not the date")
    func liveAccountOffersModeOnly() async throws {
        try await offCooperativePool {
            let (backend, config) = try makeBackend()
            let path = try fixture(config, mode: 0o644)
            defer { try? backend.removeItem(at: path) }

            let editable = RemoteAttributeEditability.decide(
                for: try backend.stat(at: path),
                capabilities: backend.editableMetadata(at: path)
            )
            #expect(editable.editable == [.permissions])
        }
    }

    // MARK: - Writing

    @Test("a mode the server takes lands exactly, special bits included")
    func modeLandsExactly() async throws {
        try await offCooperativePool {
            let (backend, config) = try makeBackend()
            // Owned by a group this account *is* in, so the server has no reason to refuse.
            let path = try fixture(config, mode: 0o644, group: getgid())
            defer { try? backend.removeItem(at: path) }

            let change = RemoteAttributeChange(permissions: POSIXPermissions(rawValue: 0o4750))
            let refusals = try backend.applyMetadata(change.steps, at: path)
            #expect(refusals.isEmpty)

            let verdict = RemoteAttributeVerdict.weigh(
                change,
                refusals: refusals,
                landed: try backend.stat(at: path)
            )
            #expect(verdict.isComplete)
            #expect(verdict.landed.permissions == 0o4750)
            // The OS is the independent judge: the panel's read-back and this Mac's own `lstat`
            // have to agree, or the parser is what is being tested rather than the write.
            var truth = Darwin.stat()
            #expect(lstat(path.path, &truth) == 0)
            #expect(UInt16(truth.st_mode) & 0o7777 == 0o4750)
        }
    }

    /// **The finding this slice exists for, reproduced on demand.**
    ///
    /// A file whose group the account is not a member of loses set-group-ID: POSIX has `chmod(2)`
    /// clear it for a non-member, and `sftp` reports the whole thing as a success — exit 0, empty
    /// stderr, no refusal to report. So the *only* evidence is the read-back, and a panel that
    /// believed the clean answer would tell the user it had set a bit that is not there.
    @Test("a mode the server silently downgrades is caught by the read-back")
    func silentDowngradeIsCaughtLive() async throws {
        try await offCooperativePool {
            let (backend, config) = try makeBackend()
            // gid 0 (wheel) — an ordinary group for a file under /private/tmp, and one no ordinary
            // account belongs to, which is what makes the downgrade arrangeable rather than lucky.
            let path = try fixture(config, mode: 0o755, group: 0)
            defer { try? backend.removeItem(at: path) }

            let change = RemoteAttributeChange(permissions: POSIXPermissions(rawValue: 0o2755))
            let refusals = try backend.applyMetadata(change.steps, at: path)
            // The half that makes the read-back necessary: the server said nothing was wrong.
            #expect(refusals.isEmpty)

            let verdict = RemoteAttributeVerdict.weigh(
                change,
                refusals: refusals,
                landed: try backend.stat(at: path)
            )
            #expect(!verdict.isComplete)
            #expect(verdict.refused == [.permissions])
            #expect(verdict.landed.permissions == 0o755)
        }
    }

    /// The narrowness control for the case above, in the same run: the *only* difference is the
    /// file's group, so a build that reported a refusal for every write would fail here.
    @Test("the same mode on a file in the account’s own group is not reported refused")
    func sameModeInOwnGroupSucceeds() async throws {
        try await offCooperativePool {
            let (backend, config) = try makeBackend()
            let path = try fixture(config, mode: 0o755, group: getgid())
            defer { try? backend.removeItem(at: path) }

            let change = RemoteAttributeChange(permissions: POSIXPermissions(rawValue: 0o2755))
            let verdict = RemoteAttributeVerdict.weigh(
                change,
                refusals: try backend.applyMetadata(change.steps, at: path),
                landed: try backend.stat(at: path)
            )
            #expect(verdict.isComplete)
            #expect(verdict.landed.permissions == 0o2755)
        }
    }

    // MARK: - Undoing it

    /// The whole round trip against a real server: write a mode, journal what landed, revert it,
    /// and let **this Mac's own `lstat`** say whether the file is back where it started.
    ///
    /// It is the same shape as the write tests above and one step longer, which is the point: ⌘Z
    /// here is a *second write* through the same `applyMetadata`, so every doubt the forward path
    /// has applies to it and the only honest witness is the file.
    @Test("undoing a mode change puts the real file back")
    func undoRestoresTheModeLive() async throws {
        try await offCooperativePool {
            let (backend, config) = try makeBackend()
            let path = try fixture(config, mode: 0o644, group: getgid())
            defer { try? backend.removeItem(at: path) }

            let before = try backend.stat(at: path)
            let change = RemoteAttributeChange(permissions: POSIXPermissions(rawValue: 0o600))
            let verdict = RemoteAttributeVerdict.weigh(
                change,
                refusals: try backend.applyMetadata(change.steps, at: path),
                landed: try backend.stat(at: path)
            )
            #expect(verdict.isComplete)

            // Driven through a real journal rather than by inverting the record by hand, so the
            // stack shuffling `UndoController` relies on is exercised over a real connection too.
            var journal = UndoJournal()
            journal.record(try #require(UndoRecord.remoteAttributeChange(
                from: before, asked: change, verdict: verdict
            )))

            let undone = try #require(journal.takeForUndo()?.fileOperation)
            #expect(UndoJournal.revert(undone, using: backend).succeeded)
            var truth = Darwin.stat()
            #expect(lstat(path.path, &truth) == 0)
            #expect(UInt16(truth.st_mode) & 0o7777 == 0o644)

            // And redo re-applies it off the same record, so the pair really is symmetric over a
            // real connection rather than only over a fake that answers whatever it is told.
            let redone = try #require(journal.takeForRedo()?.fileOperation)
            #expect(UndoJournal.revert(redone, using: backend).succeeded)
            #expect(lstat(path.path, &truth) == 0)
            #expect(UInt16(truth.st_mode) & 0o7777 == 0o600)
        }
    }

    /// The silent downgrade, reversed — the case a record built from *what was asked* would drop.
    ///
    /// The server stores `0755` for a `0o2755` on a `wheel` file, so the verdict calls the write
    /// refused while the file has really moved from `0644`. Journaling nothing there would leave a
    /// change the user can see and cannot undo; this is that rule against the server that produces
    /// the state, rather than against a fake told to produce it.
    @Test("a silently downgraded mode is still undoable")
    func silentDowngradeIsUndoableLive() async throws {
        try await offCooperativePool {
            let (backend, config) = try makeBackend()
            let path = try fixture(config, mode: 0o644, group: 0)
            defer { try? backend.removeItem(at: path) }

            let before = try backend.stat(at: path)
            let change = RemoteAttributeChange(permissions: POSIXPermissions(rawValue: 0o2755))
            let verdict = RemoteAttributeVerdict.weigh(
                change,
                refusals: try backend.applyMetadata(change.steps, at: path),
                landed: try backend.stat(at: path)
            )
            #expect(verdict.refused == [.permissions])
            #expect(verdict.landed.permissions == 0o755)

            let record = try #require(UndoRecord.remoteAttributeChange(
                from: before, asked: change, verdict: verdict
            ))
            #expect(UndoJournal.revert(record, using: backend).succeeded)
            var truth = Darwin.stat()
            #expect(lstat(path.path, &truth) == 0)
            #expect(UInt16(truth.st_mode) & 0o7777 == 0o644)
        }
    }

    /// An undo the server will not take is a **failed step**, named — not an undo reported as done.
    ///
    /// The record is built over a file the account owns and then aimed at one it cannot write, which
    /// is the only way to reach the state without waiting for a permission to change under us. What
    /// it proves is the executor's rule rather than the builder's: a refusal answered by the
    /// transport has to become a failure with a sentence, since a clean `UndoReport` here would tell
    /// the user their ⌘Z had worked.
    @Test("an undo the server refuses is reported rather than believed")
    func refusedUndoIsReportedLive() async throws {
        try await offCooperativePool {
            let (backend, config) = try makeBackend()
            let unwritable = VFSPath(backend: .sftp(config.location), path: "/etc/hosts")
            let step = UndoStep.restoreRemoteAttributes(
                path: unwritable,
                apply: RemoteAttributeChange(permissions: POSIXPermissions(rawValue: 0o600)),
                reverse: RemoteAttributeChange(permissions: POSIXPermissions(rawValue: 0o644))
            )
            let report = UndoJournal.revert(
                UndoRecord(label: .changeAttributes, steps: [step]),
                using: backend
            )
            #expect(!report.succeeded)
            #expect(report.failures.first?.error == .unsupported(
                .remoteAttributeRestoreRefused(name: "hosts")
            ))
            // The file is untouched, which is what makes the refusal a refusal.
            var truth = Darwin.stat()
            #expect(lstat("/etc/hosts", &truth) == 0)
            #expect(UInt16(truth.st_mode) & 0o7777 == 0o644)
        }
    }

    @Test("a change the server refuses outright is answered, not thrown")
    func refusalIsAnswered() async throws {
        try await offCooperativePool {
            let (backend, config) = try makeBackend()
            // A path the account cannot write: the refusal is about the *item*, so it must not latch
            // and must not travel as a failed operation.
            let path = VFSPath(backend: .sftp(config.location), path: "/etc/hosts")

            let refusals = try backend.applyMetadata(
                [.setMode(POSIXPermissions(rawValue: 0o777))],
                at: path
            )
            #expect(!refusals.isEmpty)
            // Still offered afterwards — one unwritable file says nothing about the account.
            #expect(backend.editableMetadata(
                at: VFSPath(backend: .sftp(config.location), path: config.remotePath)
            ) == .changeMode)
        }
    }
}
