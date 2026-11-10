import DirnexCore
import Foundation
import Testing

@testable import Dirnex

/// A restored tab inside an SMB share that is not mounted (`PanelViewController+ShareRestore`): that
/// it comes back at all, what its first navigation owes the share, and what is written down for it.
///
/// Dirnex unmounts what it mounted on quit, so a tab left inside a share used to be dropped at the
/// next launch. Nothing here reaches NetFS: the decision is asked of a pane whose view is never
/// loaded, the volume is one no Mac has mounted, and the mounter's NetFS call is a stand-in. A test
/// host's Keychain is `InMemorySecretStore`, and tab state goes to ``TabStateScratch``.
@Suite("A tab inside a share", .serialized)
@MainActor
struct ShareTabRestoreTests {
    private static let volume = "dirnex-share-restore-test"
    private static let share = SMBLocation(host: "share-restore.invalid", share: volume)
    private static var folder: VFSPath { .local("/Volumes/\(volume)/TV") }

    private final class CallCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0

        func increment() { lock.withLock { count += 1 } }
        var value: Int { lock.withLock { count } }
    }

    private static func pane(at path: VFSPath, awaiting share: SMBLocation? = share) -> PanelViewController {
        let vc = PanelViewController(
            backend: CompositeBackend(local: LocalBackend()),
            restoration: nil,
            defaultPath: path,
            restorationKey: "share-restore-test-\(UUID().uuidString)"
        )
        vc.tabStateDefaults = TabStateScratch.defaults
        vc.panel = Panel(path: path)
        vc.tabs[0].awaitedShare = share.flatMap { AwaitedShare(share: $0, at: path) }
        return vc
    }

    private static func persisted(_ path: VFSPath, endpoint: ServerEndpoint?) -> PersistedPane {
        PersistedPane(
            tabs: [PersistedTab(path: path, sort: .default, columns: nil, endpoint: endpoint)],
            activeIndex: 0
        )
    }

    /// The link to the boot volume every Mac keeps in `/Volumes`, which has no mount of its own.
    private static func bootVolumeLink() throws -> String {
        let links = try FileManager.default.contentsOfDirectory(atPath: "/Volumes").filter {
            PanelViewController.isSymlink("/Volumes/\($0)")
        }
        return try #require(links.first)
    }

    // MARK: - Coming back

    @Test("a tab inside a share that is not mounted comes back, waiting on the share")
    func comesBackWaiting() throws {
        let tabs = PanelViewController.restoredTabs(
            from: Self.persisted(Self.folder, endpoint: .smb(Self.share))
        )
        let tab = try #require(tabs.first)
        #expect(tab.panel.path == Self.folder)
        #expect(tab.awaitedShare == AwaitedShare(share: Self.share, at: Self.folder))
    }

    @Test("one written down with no share is dropped, as before")
    func withoutAShareIsDropped() {
        #expect(
            PanelViewController.restoredTabs(from: Self.persisted(Self.folder, endpoint: nil)).isEmpty
        )
    }

    /// On a volume that is there, a missing folder really is gone.
    @Test("one whose folder is gone from a volume that is there is dropped")
    func goneFromAMountedVolumeIsDropped() throws {
        let gone = VFSPath.local("/Volumes/\(try Self.bootVolumeLink())/dirnex-share-restore-gone")
        #expect(
            PanelViewController.restoredTabs(from: Self.persisted(gone, endpoint: .smb(Self.share))).isEmpty
        )
    }

    // MARK: - What its first navigation owes the share

    @Test("the launch activation mounts the share at any floor but 0")
    func launchMounts() {
        let vc = Self.pane(at: Self.folder)
        #expect(
            vc.shareMountVerdict(to: Self.folder, unasked: true, floor: 15) == .connect(
                .smb(Self.share)
            )
        )
        #expect(
            vc.shareMountVerdict(to: Self.folder, unasked: true, floor: 0)
                == .standDown(.serversNotContactedUnasked)
        )
    }

    @Test("a gesture mounts the share at any floor")
    func gestureMounts() {
        let vc = Self.pane(at: Self.folder)
        #expect(
            vc.shareMountVerdict(to: Self.folder, unasked: false, floor: 0) == .connect(
                .smb(Self.share)
            )
        )
    }

    @Test("an account with no saved password stands down instead of asking for one")
    func accountNeedsItsPassword() {
        let missing = SMBLocation(
            host: "share-restore-nosecret.invalid",
            share: Self.volume,
            username: "a"
        )
        let saved = SMBLocation(
            host: "share-restore-secret.invalid",
            share: Self.volume,
            username: "a"
        )
        #expect(SecretKeychain.store(password: "secret", for: saved.server))

        #expect(
            Self.pane(at: Self.folder, awaiting: missing).shareMountVerdict(
                to: Self.folder,
                unasked: false
            )
                == .standDown(.credentialMissing)
        )
        #expect(
            Self.pane(at: Self.folder, awaiting: saved).shareMountVerdict(
                to: Self.folder,
                unasked: false
            )
                == .connect(.smb(saved))
        )
    }

    @Test("a place off the share's volume owes it nothing")
    func otherVolumesOweNothing() {
        let vc = Self.pane(at: Self.folder)
        #expect(vc.shareMountVerdict(to: .local(NSTemporaryDirectory()), unasked: false) == .listNow)
        #expect(
            vc.shareMountVerdict(to: .local("/Volumes/\(Self.volume)-1/TV"), unasked: false) == .listNow
        )
    }

    @Test("a tab that has listed, or waits on no share, owes nothing")
    func onlyAWaitingUnlistedTab() {
        let loaded = Self.pane(at: Self.folder)
        loaded.tabs[0].hasLoaded = true
        #expect(loaded.shareMountVerdict(to: Self.folder, unasked: false) == .listNow)
        #expect(
            Self.pane(at: Self.folder, awaiting: nil).shareMountVerdict(
                to: Self.folder,
                unasked: false
            ) == .listNow
        )
    }

    @Test("a share whose volume is there owes nothing")
    func mountedVolumeOwesNothing() throws {
        let there = VFSPath.local("/Volumes/\(try Self.bootVolumeLink())/TV")
        #expect(Self.pane(at: there).shareMountVerdict(to: there, unasked: false) == .listNow)
    }

    // MARK: - What is written down

    @Test("a tab that never opened is written back down with its share")
    func waitingTabKeepsItsShare() throws {
        let vc = Self.pane(at: Self.folder)
        #expect(vc.shareEndpoint(for: vc.tabs[0]) == .smb(Self.share))
        #expect(vc.shareEndpoint(for: vc.tabs[0], at: .local(NSTemporaryDirectory())) == nil)

        vc.persistState()
        let key = try #require(vc.restorationKey)
        let stored = try #require(TabPersistence.load(paneKey: key, from: TabStateScratch.defaults))
        #expect(stored.tabs.first?.serverEndpoint == .smb(Self.share))
        #expect(
            PanelViewController.restoredTabs(from: stored).first?.awaitedShare == vc.tabs[0].awaitedShare
        )
    }

    @Test("a tab on a share this session mounted is written down with it")
    func mountedShareIsWrittenDown() throws {
        let mount = FileManager.default.temporaryDirectory
            .appendingPathComponent("ShareTabRestore-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: mount) }
        let mounter = SMBMounter.shared
        let isNetworkMount = mounter.isNetworkMount
        mounter.isNetworkMount = { $0 == mount.path || isNetworkMount($0) }
        mounter.record(Self.share, mountedAt: mount.path)
        defer {
            mounter.forget(mountedAt: mount.path)
            mounter.isNetworkMount = isNetworkMount
        }
        let inside = VFSPath.local(mount.appendingPathComponent("TV").path)
        let vc = Self.pane(at: inside, awaiting: nil)
        #expect(vc.shareEndpoint(for: vc.tabs[0]) == .smb(Self.share))
    }

    // MARK: - One mount for both panes

    @Test("two panes asking for one share at once mount it once")
    func concurrentMountsShareOneCall() async throws {
        let mount = FileManager.default.temporaryDirectory
            .appendingPathComponent("ShareTabRestore-\(UUID().uuidString)")
        let mounter = SMBMounter.shared
        let original = mounter.netfsMount
        let calls = CallCounter()
        mounter.netfsMount = { _, _, _ in
            calls.increment()
            Thread.sleep(forTimeInterval: 0.2)
            return SMBMounter.MountOutcome(status: 0, mountPoint: mount)
        }
        defer {
            mounter.netfsMount = original
            mounter.forget(mountedAt: mount.path)
        }

        async let first = mounter.mount(Self.share, username: nil, password: nil)
        async let second = mounter.mount(Self.share, username: nil, password: nil)
        let answers = try await [first, second]

        #expect(answers == [mount, mount])
        #expect(calls.value == 1)
    }
}
