import DirnexCore
import Foundation
import Testing

@testable import Dirnex

/// What a remote copy carries besides bytes, against **real servers** (PLAN.md §M25 Slice 2).
///
/// The live half of the carry, and it has to be live: everything under test is what a server does
/// with what the app sent it, and the two failure directions are both invisible from inside. A copy
/// that quietly dropped a mode looks exactly like one that kept it until somebody inspects the
/// destination, and a copy that *claims* to have kept one is worse than either.
///
/// Split from the two protocol suites rather than added to them — they were at SwiftLint's
/// `file_length`, and this is one concept across two protocols, so it reads better as one file than
/// as the same test written twice.
///
/// Gated on the same config files the suites they came from use, so CI (which has no server) skips
/// them: `/tmp/dirnex_sftp_live_test.json` and `/tmp/dirnex_ftp_live_test.json`.
///
/// **Read the run's issue count, not the per-test ticks.** Every body here runs inside
/// ``offCooperativePool``, which executes it on a `DispatchQueue` thread outside the task — so
/// Swift Testing cannot attribute a failed `#expect` and files it under `Test «unknown»` while the
/// test it came from still prints a tick. Both of this file's first drafts "passed" that way.
@Suite("Remote metadata carry ▸ live", .enabled(if: SFTPLiveEnvironment.current != nil))
struct SFTPMetadataCarryLiveTests {
    private func makeBackend() throws -> (SFTPBackend, SFTPLiveEnvironment.Config) {
        let config = try #require(SFTPLiveEnvironment.current)
        let transport = SFTPProcessTransport(
            location: config.location,
            authentication: .key(identityFile: config.identityFile)
        )
        return (SFTPBackend(location: config.location, transport: transport), config)
    }

    @Test("an upload carries a set-uid mode and the exact modification time")
    func uploadCarriesModeAndTime() async throws {
        try await offCooperativePool {
            let (backend, config) = try makeBackend()
            let source = try LiveCarrySource(mode: 0o4755)
            let remote = VFSPath(
                backend: .sftp(config.location),
                path: config.remotePath + "/dirnex-carry-\(UUID().uuidString).bin"
            )
            defer { try? backend.removeItem(at: remote) }

            try backend.copyFile(
                at: .local(source.path),
                to: remote,
                hint: CopySourceHint(metadata: source.entry),
                progress: { _ in },
                isCancelled: { false }
            )

            // The whole claim, read back off the server's own listing rather than off anything we
            // wrote: `put -p` carries the nine bits and the mtime, and the corrective `chmod` — a
            // second line in the *same* batch — carries the set-uid bit `-p` silently drops.
            let landed = try backend.stat(at: remote)
            #expect(landed.permissions == 0o4755)
            // **A minute, not a second, and it is the read-back that is coarse rather than the
            // carry.** A remote `stat` here is `ls -la`, whose stamp has minute resolution — and
            // for a file older than about six months it drops the time of day entirely, landing the
            // parse at local midnight (docs/NOTES.md ▸ Parsing a year-less timestamp). A first
            // version of this test used a 2018 timestamp and failed by exactly 11:09:10, the source
            // file's own time of day, on a transfer that had carried it perfectly.
            #expect(abs(landed.modificationDate.timeIntervalSince(source.modificationTime)) < 60)
        }
    }

    @Test("an upload with no hint still carries, because its source is on this machine")
    func uploadWithNoHintReadsItsSource() async throws {
        try await offCooperativePool {
            let (backend, config) = try makeBackend()
            let source = try LiveCarrySource(mode: 0o4755)
            let remote = VFSPath(
                backend: .sftp(config.location),
                path: config.remotePath + "/dirnex-plain-\(UUID().uuidString).bin"
            )
            defer { try? backend.removeItem(at: remote) }

            // The oldest spelling of `copyFile`, which every caller predating the hint uses. An
            // upload's source is local, so the backend reads its mode for itself rather than
            // dropping the carry for want of a parameter — and the set-uid bit is what proves it,
            // since `-p` cannot express one and the corrective `chmod` could only have been built
            // from a mode somebody read off the disk.
            try backend.copyFile(
                at: .local(source.path),
                to: remote,
                progress: { _ in },
                isCancelled: { false }
            )
            let landed = try backend.stat(at: remote)
            #expect(landed.permissions == 0o4755)
        }
    }

    @Test("a refused metadata step is answered, not thrown — the batch's exit 1 is not a failure")
    func refusedMetadataStepIsNotAFailure() async throws {
        try await offCooperativePool {
            let config = try #require(SFTPLiveEnvironment.current)
            let transport = SFTPProcessTransport(
                location: config.location,
                authentication: .key(identityFile: config.identityFile)
            )

            // A `chmod` at a path that is not there is refused, and under `-b` a refused command
            // aborts the batch and exits **1** — which is why the follow-up rides allowed-to-fail
            // and why an exit explained *entirely* by metadata refusals is read as a transfer that
            // worked. Measured 2026-08-28: without that rule this throws, and a copy whose bytes
            // are sitting on the server is reported as failed.
            let refusals = try transport.applyMetadata(
                [.setMode(POSIXPermissions(rawValue: 0o755))],
                to: config.remotePath + "/dirnex-absent-\(UUID().uuidString)/x"
            )
            #expect(refusals.count == 1)
        }
    }
}

/// The same claims over FTP, where every carried fact is an explicit command rather than a flag.
/// What the server does with a same-account duplicate, on an account that **offers OpenSSH's
/// `copy-data` extension** (PLAN.md §M25 Slice 3).
///
/// That precondition is in the suite's name because it cannot be asked in advance — the client
/// refuses on its own after reading what the server advertised, so the only way to learn it is to
/// send `cp`. Pointed at an account without it (reproduce one with `sftp-server -P copy-data`) every
/// test here fails with `.unsupported(.remoteToRemoteCopy)`, which is the *right* answer and not a
/// broken feature: it is what sends the pane's own backend to ``RelayCopy`` instead, and
/// ``SFTPServerSideCopyRouteLiveTests`` is the suite that holds on either kind of server.
@Suite(
    "Server-side copy ▸ live (an account offering copy-data)",
    .enabled(if: SFTPLiveEnvironment.current != nil)
)
struct SFTPServerSideCopyLiveTests {
    private func makeBackend() throws -> (SFTPBackend, SFTPLiveEnvironment.Config) {
        let config = try #require(SFTPLiveEnvironment.current)
        let transport = SFTPProcessTransport(
            location: config.location,
            authentication: .key(identityFile: config.identityFile)
        )
        return (SFTPBackend(location: config.location, transport: transport), config)
    }

    @Test("a duplicate inside one account is copied by the server, with its full mode")
    func serverSideCopyCarriesTheMode() async throws {
        try await offCooperativePool {
            let (backend, config) = try makeBackend()
            let source = try LiveCarrySource(mode: 0o4755)
            let first = VFSPath(
                backend: .sftp(config.location),
                path: config.remotePath + "/dirnex-cp-src-\(UUID().uuidString).bin"
            )
            let second = first.parent!.appending("dirnex-cp-dst-\(UUID().uuidString).bin")
            defer {
                try? backend.removeItem(at: first)
                try? backend.removeItem(at: second)
            }
            try backend.copyFile(
                at: .local(source.path),
                to: first,
                hint: CopySourceHint(metadata: source.entry),
                progress: { _ in },
                isCancelled: { false }
            )

            let listed = try backend.stat(at: first)
            var reported: Int64 = 0
            try backend.copyFile(
                at: first,
                to: second,
                // Exactly what the pane's own `CopyEngine` hands down: the entry it just listed.
                hint: CopySourceHint(listed),
                progress: { reported += $0 },
                isCancelled: { false }
            )

            let landed = try backend.stat(at: second)
            // `cp` brings the nine bits; the corrective `chmod` — a second line in the *same* batch —
            // brings the set-uid bit it drops, exactly as `-p` needs.
            #expect(landed.permissions == 0o4755)
            #expect(landed.byteSize == listed.byteSize)
            #expect(reported == listed.byteSize)
        }
    }

    @Test("copying onto an occupied name takes the source's mode, not the file that was there")
    func serverSideCopyOverwritesTheDestinationsOwnMode() async throws {
        try await offCooperativePool {
            let (backend, config) = try makeBackend()
            let source = try LiveCarrySource(mode: 0o640)
            let occupant = try LiveCarrySource(mode: 0o600)
            let first = VFSPath(
                backend: .sftp(config.location),
                path: config.remotePath + "/dirnex-cp-occ-src-\(UUID().uuidString).bin"
            )
            let second = first.parent!.appending("dirnex-cp-occ-dst-\(UUID().uuidString).bin")
            defer {
                try? backend.removeItem(at: first)
                try? backend.removeItem(at: second)
            }
            for (local, remote) in [(source, first), (occupant, second)] {
                try backend.copyFile(
                    at: .local(local.path),
                    to: remote,
                    hint: CopySourceHint(metadata: local.entry),
                    progress: { _ in },
                    isCancelled: { false }
                )
            }
            #expect(try backend.stat(at: second).permissions == 0o600)

            try backend.copyFile(
                at: first,
                to: second,
                hint: CopySourceHint(try backend.stat(at: first)),
                progress: { _ in },
                isCancelled: { false }
            )

            // The measurement this case exists for: `cp` **overwrites in place** and leaves the
            // destination's own mode standing (a bare `cp` here really does leave `100600`), so the
            // corrective `chmod` is worth sending for an ordinary mode too and not only for a
            // special bit. It is also the only live case that can tell the two plans apart — a mode
            // carrying set-uid gets its `chmod` under either rule, so a test using one measures
            // nothing about this decision.
            #expect(try backend.stat(at: second).permissions == 0o640)
        }
    }

    @Test("the server-side copy loses the modification time, and says so rather than claiming it")
    func serverSideCopyReportsTheLostTime() async throws {
        try await offCooperativePool {
            let (backend, config) = try makeBackend()
            let source = try LiveCarrySource(mode: 0o644)
            let first = VFSPath(
                backend: .sftp(config.location),
                path: config.remotePath + "/dirnex-cp-time-\(UUID().uuidString).bin"
            )
            let second = first.parent!.appending("dirnex-cp-time2-\(UUID().uuidString).bin")
            defer {
                try? backend.removeItem(at: first)
                try? backend.removeItem(at: second)
            }
            try backend.copyFile(
                at: .local(source.path),
                to: first,
                hint: CopySourceHint(metadata: source.entry),
                progress: { _ in },
                isCancelled: { false }
            )
            let listed = try backend.stat(at: first)
            try backend.copyFile(
                at: first,
                to: second,
                hint: CopySourceHint(listed),
                progress: { _ in },
                isCancelled: { false }
            )

            // The trade this route buys its speed with, measured on the server rather than argued:
            // `cp` stamps the copy with *now*, a week away from the source, and `sftp`'s batch
            // language has no verb that could put it back.
            let landed = try backend.stat(at: second)
            #expect(landed.modificationDate.timeIntervalSince(source.modificationTime) > 6 * 86_400)
            // The narrowness control, and it is what makes the line above evidence about `cp`
            // rather than about the fixture: the *upload* that put this file on the server carried
            // the same source's time exactly, minutes ago, over the same connection.
            #expect(abs(listed.modificationDate.timeIntervalSince(source.modificationTime)) < 60)
            // That the connection also *records* the loss is pinned headlessly, where the
            // accumulator is reachable — `SFTPServerSideCopyTests`, with the plan-with-`-p` control
            // that makes a silent claim fail. It is internal to the core, so this target cannot see
            // it, and inventing a public accessor for one assertion is the API-with-no-reader trap
            // this project has paid for before.
        }
    }
}

/// The route a same-account duplicate takes, through the **pane's own backend** rather than the
/// account's (PLAN.md §M25 Slice 3).
///
/// One claim, and it is deliberately the one that holds on *either* kind of server: the duplicate
/// lands, with the right bytes and the right mode, whether the account offers OpenSSH's `copy-data`
/// extension or the composite has to stage it through this disk. Run it against a server started
/// with `sftp-server -P copy-data` and it exercises the fallback; run it against an ordinary one and
/// it exercises the fast path. Nothing here asserts *which*, because a test that did would fail on
/// half the servers this feature exists to work on.
///
/// What tells them apart, for anyone verifying by hand, is the **modification time**: the staged
/// route carries it exactly (`get -p`/`put -p`) and `cp` stamps the copy with *now*.
@Suite("Server-side copy route ▸ live", .enabled(if: SFTPLiveEnvironment.current != nil))
struct SFTPServerSideCopyRouteLiveTests {
    @Test("a duplicate lands whichever route the account turns out to support")
    func duplicateLandsEitherWay() async throws {
        try await offCooperativePool {
            let config = try #require(SFTPLiveEnvironment.current)
            let composite = CompositeBackend(local: LocalBackend())
            let account = composite.connectSFTP(
                location: config.location,
                authentication: .key(identityFile: config.identityFile)
            )
            let source = try LiveCarrySource(mode: 0o640)
            let first = VFSPath(
                backend: .sftp(config.location),
                path: config.remotePath + "/dirnex-route-src-\(UUID().uuidString).bin"
            )
            let second = first.parent!.appending("dirnex-route-dst-\(UUID().uuidString).bin")
            defer {
                try? account.removeItem(at: first)
                try? account.removeItem(at: second)
            }
            try composite.copyFile(
                at: .local(source.path),
                to: first,
                hint: CopySourceHint(metadata: source.entry),
                progress: { _ in },
                isCancelled: { false }
            )

            let listed = try account.stat(at: first)
            var reported: Int64 = 0
            try composite.copyFile(
                at: first,
                to: second,
                hint: CopySourceHint(listed),
                progress: { reported += $0 },
                isCancelled: { false }
            )

            let landed = try account.stat(at: second)
            #expect(landed.byteSize == listed.byteSize)
            #expect(landed.permissions == 0o640)
            // The count the queue's bar rests on, and it is the same number on both routes: a staged
            // copy reports each leg at half weight and tops up, and a server-side one reports the
            // file once. Either way it is the file's size and never twice it.
            #expect(reported == listed.byteSize)
        }
    }
}

@Suite("Remote metadata carry ▸ live FTP", .enabled(if: FTPLiveEnvironment.current != nil))
struct FTPMetadataCarryLiveTests {
    private func makeBackend() throws -> (FTPBackend, FTPLiveEnvironment.Config) {
        let config = try #require(FTPLiveEnvironment.current)
        let transport = FTPCurlTransport(
            location: config.location,
            authentication: config.authentication,
            password: config.password,
            trustedPublicKey: config.trustedPublicKey
        )
        return (FTPBackend(location: config.location, transport: transport), config)
    }

    @Test("an upload carries the mode and an exact, UTC-anchored modification time")
    func uploadCarriesModeAndTime() async throws {
        try await offCooperativePool {
            let (backend, config) = try makeBackend()
            let source = try FTPLiveCarrySource(mode: 0o754)
            let remote = VFSPath(
                backend: .ftp(config.location),
                path: config.remotePath + "/dirnex-carry-\(UUID().uuidString).bin"
            )
            defer { try? backend.removeItem(at: remote) }

            try backend.copyFile(
                at: .local(source.path),
                to: remote,
                hint: CopySourceHint(metadata: source.entry),
                progress: { _ in },
                isCancelled: { false }
            )

            // `MFMT` is what FTP has that SFTP does not: an exact modification time, anchored to
            // UTC by RFC 3659 rather than to whatever the server's clock is set to. The mode rides
            // `SITE CHMOD` beside it, in one invocation of their own — sent alongside the transfer
            // they would fail it, because `curl` answers a refused quote command with exit 21 after
            // the bytes have already landed.
            let landed = try backend.stat(at: remote)
            #expect(landed.permissions == 0o754)
            // **A day, and the looseness is the read-back's rather than the write's.** `MFMT` is
            // exact to the second and anchored to UTC — probed against the local truth on a host at
            // +0300, so a zone error could not have hidden — but the only thing a *listing* offers
            // to check it with is `LIST`, whose stamp is minute-resolution, year-less and
            // **zone-less on the server's own clock** (docs/NOTES.md ▸ curl). A first version of
            // this assertion allowed a minute and failed by exactly 10800 seconds: this machine's
            // own +0300, on a transfer that had carried the time perfectly.
            //
            // A day still separates the two answers that matter, which is what makes it a test: a
            // carried time lands within one zone offset of the source, and an uncarried one is the
            // moment the upload ran — a week away, by construction of the fixture.
            #expect(abs(landed.modificationDate.timeIntervalSince(source.modificationTime)) < 86_400)
        }
    }

    @Test("a refused metadata step is answered rather than thrown, and does not latch")
    func refusedMetadataStepIsAnswered() async throws {
        try await offCooperativePool {
            let (_, config) = try makeBackend()
            let transport = FTPCurlTransport(
                location: config.location,
                authentication: config.authentication,
                password: config.password,
                trustedPublicKey: config.trustedPublicKey
            )

            // A refusal is **not** a thrown error: the bytes of the transfer it follows are already
            // on the server, so a step that could not be applied has not failed the copy. It comes
            // back as an answer instead, and the caller records a loss rather than reporting a
            // failure.
            let refusals = try transport.applyMetadata(
                [.setModificationTime(Date())],
                to: config.remotePath + "/dirnex-absent-\(UUID().uuidString).bin"
            )

            // And it is the **item's** refusal, not the server's. A missing file answers reply 550,
            // which says nothing about what this account can do — where 500 would mean the verb is
            // absent and every later file could stop paying to find out. Reading the two as one, as
            // this backend did before the slice, means either latching on one unwritable file or
            // never latching at all; the live half of that split is the 550, since no server here
            // lacks `MFMT` to answer the 500 with (``FTPTransportErrorTests`` pins that half).
            #expect(refusals == [.itemRefused("")])
        }
    }
}

/// A real local file with a chosen mode and a distinctive modification time, for the live carry
/// tests — the source half of what the server is then asked to reproduce.
private struct LiveCarrySource {
    let path: String
    let mode: UInt16
    /// Far enough from "now" that a transfer which merely stamped the moment it ran could never
    /// pass by accident, and recent enough that `ls -la` still prints a **time** for it: past about
    /// six months the stamp is a bare date, which no assertion finer than a day can survive
    /// (docs/NOTES.md ▸ Parsing a year-less timestamp). Truncated to the minute, which is all that
    /// column carries.
    let modificationTime = Date(
        timeIntervalSince1970: ((Date().timeIntervalSince1970 - 7 * 86_400) / 60).rounded(.down) * 60
    )

    init(mode: UInt16) throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("dirnex-live-carry-\(UUID().uuidString)")
        try Data("carry".utf8).write(to: url)
        path = url.path
        self.mode = mode
        #expect(chmod(path, mode_t(mode)) == 0)
        try FileManager.default.setAttributes(
            [.modificationDate: modificationTime],
            ofItemAtPath: path
        )
    }

    /// The hint a listing would have produced for this file.
    var entry: RemoteSourceMetadata {
        RemoteSourceMetadata(permissions: mode, modificationTime: modificationTime)
    }
}

/// A real local file with a chosen mode and a recent, minute-truncated modification time — the
/// source half of what the server is then asked to reproduce.
private struct FTPLiveCarrySource {
    let path: String
    let mode: UInt16
    /// Recent enough that a `LIST` still prints a time for it, and far enough from "now" that a
    /// transfer which merely stamped the moment it ran could not pass by accident.
    let modificationTime = Date(
        timeIntervalSince1970: ((Date().timeIntervalSince1970 - 7 * 86_400) / 60).rounded(.down) * 60
    )

    init(mode: UInt16) throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("dirnex-ftp-carry-\(UUID().uuidString)")
        try Data("carry".utf8).write(to: url)
        path = url.path
        self.mode = mode
        #expect(chmod(path, mode_t(mode)) == 0)
        try FileManager.default.setAttributes(
            [.modificationDate: modificationTime],
            ofItemAtPath: path
        )
    }

    var entry: RemoteSourceMetadata {
        RemoteSourceMetadata(permissions: mode, modificationTime: modificationTime)
    }
}
