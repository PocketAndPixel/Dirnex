import DirnexCore
import Foundation
import Testing

@testable import Dirnex

/// Owner and group against a **real server** (PLAN.md §M38 Slice 2).
///
/// Live because what is under test is what a real `chown` does: that a group change clears set-id
/// bits on a real file, that the re-sent mode puts them back, and that the undo does it again.
///
/// Gated on `/tmp/dirnex_sftp_live_test.json`, so CI (which has no server) skips it. Driven through
/// a `CompositeBackend`, because that router is what a pane really calls.
///
/// **Read the run's issue count, not the per-test ticks.** Every body runs inside
/// ``offCooperativePool``, so a failed `#expect` is filed under `Test «unknown»` (docs/NOTES.md ▸
/// Testing).
@Suite("Remote owner and group ▸ live", .enabled(if: SFTPLiveEnvironment.current != nil))
struct RemoteOwnershipLiveTests {
    private func makeBackend() throws -> (CompositeBackend, SFTPLiveEnvironment.Config) {
        let config = try #require(SFTPLiveEnvironment.current)
        let composite = CompositeBackend(local: LocalBackend())
        composite.connectSFTP(
            location: config.location,
            authentication: .key(identityFile: config.identityFile)
        )
        return (composite, config)
    }

    /// A file on the server, in the account's primary group, created locally because the server is
    /// this Mac. Every claim below is read back through `lstat`, which is the independent judge.
    private func fixture(_ config: SFTPLiveEnvironment.Config, mode: mode_t) throws -> VFSPath {
        let onDisk = config.remotePath + "/dirnex-owner-\(UUID().uuidString).bin"
        try Data("owner".utf8).write(to: URL(fileURLWithPath: onDisk))
        #expect(chown(onDisk, getuid(), getgid()) == 0)
        #expect(chmod(onDisk, mode) == 0)
        return VFSPath(backend: .sftp(config.location), path: onDisk)
    }

    private func onDisk(_ path: VFSPath) -> (group: gid_t, mode: UInt16) {
        var truth = Darwin.stat()
        #expect(lstat(path.path, &truth) == 0)
        return (truth.st_gid, UInt16(truth.st_mode) & 0o7777)
    }

    private func identity(
        of backend: CompositeBackend,
        at path: VFSPath
    ) throws -> RemoteAccountIdentity {
        let answer = try backend.accountIdentity(at: path, isCancelled: { false })
        return try #require(answer)
    }

    /// A group this account belongs to, other than the one the fixture starts in.
    private func otherGroup(of identity: RemoteAccountIdentity) throws -> RemotePrincipal {
        try #require(identity.groups.first { $0.id != getgid() })
    }

    @Test("the account's identity comes back through the router")
    func identityIsThisAccount() async throws {
        try await offCooperativePool {
            let (backend, config) = try makeBackend()
            let path = VFSPath(backend: .sftp(config.location), path: config.remotePath)
            let identity = try identity(of: backend, at: path)
            #expect(identity.user.id == getuid())
            #expect(identity.groups.contains { $0.id == getgid() })
            #expect(!identity.isSuperuser)
        }
    }

    @Test("a real group change keeps the set-id bits, and the undo puts both back")
    func groupChangeKeepsSetIDAndUndoes() async throws {
        try await offCooperativePool {
            let (backend, config) = try makeBackend()
            let path = try fixture(config, mode: 0o6755)
            defer { try? backend.removeItem(at: path) }
            let identity = try identity(of: backend, at: path)
            let target = try otherGroup(of: identity)
            let before = try backend.stat(at: path)
            let editable = RemoteAttributeEditability.decide(
                for: before,
                capabilities: backend.editableMetadata(at: path),
                identity: identity
            )
            #expect(editable.allows(.group))
            #expect(!editable.allows(.owner))

            let change = RemoteAttributeChange.between(
                current: before,
                permissions: POSIXPermissions(rawValue: 0o6755),
                modificationTime: nil,
                shownModificationTime: nil,
                group: target,
                editable: editable
            )
            #expect(change.group == target)
            #expect(change.permissions?.rawValue == 0o6755)

            let refusals = try backend.applyMetadata(change.steps, at: path)
            let verdict = RemoteAttributeVerdict.weigh(
                change,
                refusals: refusals,
                landed: try backend.stat(at: path)
            )
            #expect(refusals.isEmpty)
            #expect(verdict.isComplete)
            #expect(onDisk(path).group == gid_t(try #require(target.id)))
            #expect(onDisk(path).mode == 0o6755)

            // Driven through the real journal, since ⌘Z is a second group change and clears the
            // bits again unless the mode goes with it.
            var journal = UndoJournal()
            journal.record(try #require(UndoRecord.remoteAttributeChange(
                from: before, asked: change, verdict: verdict
            )))
            let undone = try #require(journal.takeForUndo()?.fileOperation)
            #expect(UndoJournal.revert(undone, using: backend).succeeded)
            #expect(onDisk(path).group == getgid())
            #expect(onDisk(path).mode == 0o6755)

            let redone = try #require(journal.takeForRedo()?.fileOperation)
            #expect(UndoJournal.revert(redone, using: backend).succeeded)
            #expect(onDisk(path).group == gid_t(try #require(target.id)))
            #expect(onDisk(path).mode == 0o6755)
        }
    }

    @Test("a group the account is not in is refused in the server's words, and changes nothing")
    func strangerGroupIsRefused() async throws {
        try await offCooperativePool {
            let (backend, config) = try makeBackend()
            let path = try fixture(config, mode: 0o644)
            defer { try? backend.removeItem(at: path) }

            let change = RemoteAttributeChange(group: RemotePrincipal(name: "daemon"))
            let refusals = try backend.applyMetadata(change.steps, at: path)
            let verdict = RemoteAttributeVerdict.weigh(
                change,
                refusals: refusals,
                landed: try backend.stat(at: path)
            )
            #expect(verdict.refused == [.group])
            #expect(verdict.serverWords?.isEmpty == false)
            #expect(onDisk(path).group == getgid())
        }
    }

    @Test("a name no server has is refused the same way")
    func unknownGroupIsRefused() async throws {
        try await offCooperativePool {
            let (backend, config) = try makeBackend()
            let path = try fixture(config, mode: 0o644)
            defer { try? backend.removeItem(at: path) }

            let change = RemoteAttributeChange(group: RemotePrincipal(name: "dirnex-no-such-group"))
            let verdict = RemoteAttributeVerdict.weigh(
                change,
                refusals: try backend.applyMetadata(change.steps, at: path),
                landed: try backend.stat(at: path)
            )
            #expect(verdict.refused == [.group])
            #expect(verdict.serverWords?.contains("dirnex-no-such-group") == true)
            #expect(onDisk(path).group == getgid())
        }
    }
}
