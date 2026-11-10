import DirnexCore
import Foundation
import Testing

@testable import Dirnex

/// A pin inside a share that is not mounted (`PinnedShare`): what a new pin records, and which share
/// picking one ends up on. A temporary folder stands in for the mount and a closure for NetFS, so
/// nothing reaches a server, and none of this writes `FavoritesStore`, which in a target that runs
/// inside the app is the real sidebar (docs/NOTES.md ▸ Testing). A test host's Keychain is
/// `InMemorySecretStore`, so the passwords here go nowhere near the developer's own.
@Suite("A pin on an unmounted share", .serialized)
@MainActor
struct PinnedShareFavoriteTests {
    private struct Refusal: LocalizedError {
        let errorDescription: String?
    }

    private static let guestShare = SMBLocation(host: "pinned-guest.invalid", share: "media")
    private static let otherGuestShare = SMBLocation(host: "pinned-other.invalid", share: "media")
    private static let pin = FavoriteEntry(name: "TV", path: .local("/Volumes/media/TV"))

    private static func pane(at path: VFSPath) -> PanelViewController {
        let pane = PanelViewController(
            backend: CompositeBackend(local: LocalBackend()),
            restoration: nil,
            defaultPath: path,
            restorationKey: nil
        )
        pane.panel = Panel(path: path)
        return pane
    }

    /// A folder laid out as a share's mount, holding `TV`, and removed afterwards.
    private static func makeMount() throws -> URL {
        let mount = FileManager.default.temporaryDirectory
            .appendingPathComponent("PinnedShare-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: mount.appendingPathComponent("TV"),
            withIntermediateDirectories: true
        )
        return mount
    }

    /// `share` recorded as mounted at `mount` for the length of `body`, with `isNetwork` as the mount
    /// table's answer. Synchronous, so no other test sees a mount that never happened.
    private static func withRecordedMount(
        _ share: SMBLocation,
        at mount: URL,
        isNetwork: Bool = true,
        _ body: () throws -> Void
    ) rethrows {
        let mounter = SMBMounter.shared
        let isNetworkMount = mounter.isNetworkMount
        mounter.isNetworkMount = { $0 == mount.path ? isNetwork : isNetworkMount($0) }
        mounter.record(share, mountedAt: mount.path)
        defer {
            mounter.forget(mountedAt: mount.path)
            mounter.isNetworkMount = isNetworkMount
        }
        try body()
    }

    // MARK: - What a pin records

    @Test("a folder on a share this app reached records the share")
    func pinRecordsTheShare() throws {
        let mount = try Self.makeMount()
        defer { try? FileManager.default.removeItem(at: mount) }
        Self.withRecordedMount(Self.guestShare, at: mount) {
            let pin = Self.pane(at: .local(mount.appendingPathComponent("TV").path)).currentFolderPin(
            )
            #expect(pin.serverEndpoint == .smb(Self.guestShare))
        }
    }

    @Test("a share that has since been ejected is not recorded")
    func ejectedShareIsNotRecorded() throws {
        let mount = try Self.makeMount()
        defer { try? FileManager.default.removeItem(at: mount) }
        Self.withRecordedMount(Self.guestShare, at: mount, isNetwork: false) {
            let pin = Self.pane(at: .local(mount.appendingPathComponent("TV").path)).currentFolderPin(
            )
            #expect(pin.serverEndpoint == nil)
        }
    }

    @Test("a folder beside a mount, sharing its prefix, is not on it")
    func wholeComponentsOnly() throws {
        let mount = try Self.makeMount()
        defer { try? FileManager.default.removeItem(at: mount) }
        Self.withRecordedMount(Self.guestShare, at: mount) {
            let beside = VFSPath.local(mount.path + "-1/TV")
            #expect(SMBMounter.shared.shareEndpoint(containing: beside) == nil)
            #expect(SMBMounter.shared.shareEndpoint(containing: .local(mount.path)) != nil)
        }
    }

    @Test("a folder on a server is not asked about mounts")
    func serverFolderIsNotOnAShare() {
        let location = SFTPLocation(host: "example.com", username: "oleg")
        let path = VFSPath(backend: .sftp(location), path: "/Volumes/media/TV")
        #expect(SMBMounter.shared.shareEndpoint(containing: path) == nil)
    }

    // MARK: - Which pins are mounted rather than given up on

    @Test("a pin on a volume that is not there has shares to try")
    func unmountedVolumeHasShares() {
        let entry = FavoriteEntry(path: .local("/Volumes/pinned-share-test-volume/TV"))
        let server = SMBLocation(host: "nas", username: "oleg")
        let saved = [ServerConnection(name: "SMB", endpoint: .smb(server))]
        #expect(PanelViewController.sharesToMount(for: entry, saved: saved) == [
            server.share(named: "pinned-share-test-volume")
        ])
    }

    @Test("a folder deleted from this Mac has none, and still offers to unpin")
    func localFolderHasNoShares() {
        let server = SMBLocation(host: "nas", username: "oleg")
        let saved = [ServerConnection(name: "SMB", endpoint: .smb(server))]
        let entry = FavoriteEntry(path: .local("/Users/oleg/pinned-share-test-gone"))
        #expect(PanelViewController.sharesToMount(for: entry, saved: saved).isEmpty)
    }

    /// The real link on the real Mac: this is the one the pure test can only describe.
    @Test("a deleted folder under /Volumes/<boot volume> has none")
    func bootVolumeLinkHasNoShares() throws {
        let links = try FileManager.default.contentsOfDirectory(atPath: "/Volumes").filter {
            (try? FileManager.default.destinationOfSymbolicLink(atPath: "/Volumes/\($0)")) != nil
        }
        let link = try #require(links.first)
        let entry = FavoriteEntry(path: .local("/Volumes/\(link)/pinned-share-test-gone"))
        let saved = [ServerConnection(name: "SMB", endpoint: .smb(SMBLocation(host: "nas")))]
        #expect(PanelViewController.sharesToMount(for: entry, saved: saved).isEmpty)
    }

    // MARK: - Which share it ends up on

    @Test("the share mounts and the pane lands on the pinned folder inside it")
    func landsInsideTheMount() async throws {
        let mount = try Self.makeMount()
        defer { try? FileManager.default.removeItem(at: mount) }
        let pane = Self.pane(at: .local(NSTemporaryDirectory()))

        let result = await pane.mountPinnedShare(Self.pin, from: [Self.guestShare]) { _, _ in mount }

        #expect(result == .landed(
            .local(mount.appendingPathComponent("TV").path),
            share: Self.guestShare
        ))
    }

    @Test("a share that refuses is passed over for the next")
    func refusalMovesToTheNext() async throws {
        let mount = try Self.makeMount()
        defer { try? FileManager.default.removeItem(at: mount) }
        let pane = Self.pane(at: .local(NSTemporaryDirectory()))
        var tried: [SMBLocation] = []

        let result = await pane.mountPinnedShare(
            Self.pin,
            from: [Self.guestShare, Self.otherGuestShare]
        ) { share, _ in
            tried.append(share)
            guard share == Self.otherGuestShare else {
                throw Refusal(errorDescription: "not this one")
            }
            return mount
        }

        #expect(tried == [Self.guestShare, Self.otherGuestShare])
        #expect(result == .landed(
            .local(mount.appendingPathComponent("TV").path),
            share: Self.otherGuestShare
        ))
    }

    @Test("the first share that mounts ends the search")
    func stopsAtTheFirstMount() async throws {
        let mount = try Self.makeMount()
        defer { try? FileManager.default.removeItem(at: mount) }
        let pane = Self.pane(at: .local(NSTemporaryDirectory()))
        var tried: [SMBLocation] = []

        _ = await pane.mountPinnedShare(Self.pin, from: [Self.guestShare, Self.otherGuestShare]) { share, _ in
            tried.append(share)
            return mount
        }

        #expect(tried == [Self.guestShare])
    }

    @Test("when every share refuses, the first refusal is the one reported")
    func reportsTheFirstRefusal() async {
        let pane = Self.pane(at: .local(NSTemporaryDirectory()))

        let result = await pane.mountPinnedShare(
            Self.pin,
            from: [Self.guestShare, Self.otherGuestShare]
        ) { share, _ in
            throw Refusal(errorDescription: share == Self.guestShare ? "first" : "second")
        }

        #expect(result == .failed("first"))
    }

    @Test("a share that mounts without the folder says the folder is gone")
    func mountedWithoutTheFolder() async throws {
        let mount = try Self.makeMount()
        defer { try? FileManager.default.removeItem(at: mount) }
        try FileManager.default.removeItem(at: mount.appendingPathComponent("TV"))
        let pane = Self.pane(at: .local(NSTemporaryDirectory()))

        let result = await pane.mountPinnedShare(Self.pin, from: [Self.guestShare]) { _, _ in mount }

        #expect(result == .folderGone)
    }

    // MARK: - Passwords

    @Test("an account's password comes from the share's item, then the server's")
    func passwordLookupOrder() async throws {
        let mount = try Self.makeMount()
        defer { try? FileManager.default.removeItem(at: mount) }
        let onItsServer = SMBLocation(host: "pinned-server.invalid", share: "media", username: "a")
        let onItself = SMBLocation(host: "pinned-share.invalid", share: "media", username: "b")
        #expect(SecretKeychain.store(password: "server secret", for: onItsServer.server))
        #expect(SecretKeychain.store(password: "share secret", for: onItself))
        #expect(SecretKeychain.store(password: "ignored", for: onItself.server))
        let pane = Self.pane(at: .local(NSTemporaryDirectory()))
        var used: [String?] = []

        for share in [onItsServer, onItself] {
            _ = await pane.mountPinnedShare(Self.pin, from: [share]) { _, password in
                used.append(password)
                return mount
            }
        }

        #expect(used == ["server secret", "share secret"])
    }

    @Test("an account with no saved password is not tried, and a guest share needs none")
    func missingPasswordIsPassedOver() async throws {
        let mount = try Self.makeMount()
        defer { try? FileManager.default.removeItem(at: mount) }
        let noSecret = SMBLocation(host: "pinned-nosecret.invalid", share: "media", username: "a")
        let pane = Self.pane(at: .local(NSTemporaryDirectory()))
        var tried: [SMBLocation] = []

        let result = await pane.mountPinnedShare(Self.pin, from: [noSecret, Self.guestShare]) { share, _ in
            tried.append(share)
            return mount
        }

        #expect(tried == [Self.guestShare])
        #expect(result == .landed(
            .local(mount.appendingPathComponent("TV").path),
            share: Self.guestShare
        ))
    }

    @Test("with nothing it could try, the failure is the plain connect sentence")
    func nothingToTry() async {
        let noSecret = SMBLocation(host: "pinned-nosecret.invalid", share: "media", username: "a")
        let pane = Self.pane(at: .local(NSTemporaryDirectory()))

        let result = await pane.mountPinnedShare(Self.pin, from: [noSecret]) { _, _ in
            Issue.record("nothing should have been mounted")
            return URL(fileURLWithPath: "/")
        }

        #expect(result == .failed(PanelViewController.genericConnectError))
    }
}
