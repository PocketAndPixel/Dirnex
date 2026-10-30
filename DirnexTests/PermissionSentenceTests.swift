import DirnexCore
import Foundation
import Testing

@testable import Dirnex

/// Which remedy a permission failure names, which is a claim about *where* the failure happened
/// (PLAN.md §M26 Slice 3).
///
/// One sentence used to serve every `permissionDenied`, and it named Full Disk Access — a macOS
/// grant. M21 split the remote case off, because that advice is about the wrong machine when the
/// file is on a server. This suite pins the third case: a sync client's mount under
/// `~/Library/CloudStorage`, which is on this Mac and is still not something System Settings can
/// affect, because that directory is not TCC-gated. A fourth followed on 2026-10-30: a refusal by
/// the item's own mode bits (`EACCES`), which no grant lifts, on another account's Documents.
///
/// **The assertions are language-independent on purpose.** The app test target inherits whichever
/// `AppleLanguages` the developer has Dirnex pinned to (docs/NOTES.md ▸ Localization), so what is
/// asserted is *which branch was taken* — which sentences are the same and which differ — rather
/// than any wording. The English literals are checked separately, only when the run is English.
@Suite("Permission sentence")
struct PermissionSentenceTests {
    private static let home = NSHomeDirectory()

    /// A path inside a real provider mount's shape. `GoogleDrive-…` because that is the one whose
    /// refusal is reachable today: the mount root is `dr-x------`, so anything it declines comes
    /// back `EACCES` → `.permissionDenied` (measured 2026-08-31).
    private static let cloudStorage = VFSPath.local(
        home + "/Library/CloudStorage/GoogleDrive-someone@gmail.com/My Drive/report.pdf"
    )
    private static let iCloud = VFSPath.local(
        home + "/Library/Mobile Documents/com~apple~CloudDocs/notes.txt"
    )
    private static let ordinary = VFSPath.local(home + "/Documents/report.pdf")
    private static let remote = VFSPath(
        backend: VFSBackendID.sftp(SFTPLocation(host: "srv", username: "oleg")),
        path: "/home/oleg/report.pdf"
    )

    private func sentence(_ path: VFSPath) -> String {
        VFSErrorText.sentence(for: VFSError.permissionDenied(path))
    }

    /// Whether the *running* app resolves to English (▸ the suite note above).
    private var readsEnglish: Bool {
        Bundle.main.preferredLocalizations.first?.hasPrefix("en") == true
    }

    // MARK: - The fix

    /// The whole slice, stated without naming a language: a `CloudStorage` path must not be handed
    /// the sentence an ordinary local path gets, because that sentence names Full Disk Access.
    @Test("a path inside a sync client's mount does not get the ordinary local sentence")
    func cloudStorageDiffersFromOrdinary() {
        #expect(sentence(Self.cloudStorage) != sentence(Self.ordinary))
    }

    @Test("and it does not borrow the server sentence either — it is on this Mac")
    func cloudStorageDiffersFromRemote() {
        #expect(sentence(Self.cloudStorage) != sentence(Self.remote))
    }

    /// English, guarded. The two halves that matter are that Full Disk Access is *gone* and that
    /// something took its place — a branch returning an empty string would satisfy the structural
    /// assertions above.
    @Test("in English it names the sync client and never Full Disk Access")
    func cloudStorageWordingInEnglish() {
        guard readsEnglish else { return }
        let text = sentence(Self.cloudStorage)
        #expect(!text.contains("Full Disk Access"))
        #expect(text.contains("sync client"))
    }

    // MARK: - Narrowness

    /// The half the fix would be wrong without. `~/Library/Mobile Documents` **is** TCC-gated, so
    /// Full Disk Access is the correct advice for an iCloud path — the two provider roots are twins
    /// for the trash route and opposites here. Without this, "stop saying it inside a provider
    /// domain" quietly becomes true and takes the right advice away with the wrong one.
    @Test("an iCloud path keeps the Full Disk Access sentence")
    func iCloudKeepsTheGrantAdvice() {
        #expect(sentence(Self.iCloud) == sentence(Self.ordinary))
        if readsEnglish {
            #expect(sentence(Self.iCloud).contains("Full Disk Access"))
        }
    }

    /// An ordinary local path is byte-for-byte unchanged, down to the catalog key, so fourteen
    /// translations survive a change that is not about them.
    @Test("an ordinary local path still names the grant")
    func ordinaryIsUnchanged() {
        #expect(sentence(Self.ordinary) == String(localized: """
        You don’t have permission. Dirnex may need Full Disk Access in System Settings.
        """))
    }

    /// And the remote split M21 added is untouched by the branch inserted above it.
    @Test("a server path still gets the server sentence")
    func remoteIsUnchanged() {
        #expect(sentence(Self.remote) == String(localized: """
        The server refused that. This account may not have permission for it.
        """))
    }

    // MARK: - A mounted share

    /// A share's path, decided by the injected answer rather than a mount — the real answer needs
    /// one, and `NetworkVolume.root(of:)` is the same check the recycle-bin wording already rests on.
    private static let share = VFSPath.local("/Volumes/media/#recycle")

    private func sentence(_ path: VFSPath, onShare: Bool) -> String {
        VFSErrorText.sentence(for: VFSError.permissionDenied(path)) { _ in onShare }
    }

    /// Measured 2026-10-11: a Synology share's `#recycle` refuses its listing, and the sheet named
    /// Full Disk Access — a switch on this Mac — for a decision the NAS made.
    @Test("a refusal on a mounted share gets the server sentence, not Full Disk Access")
    func shareGetsTheServerSentence() {
        #expect(sentence(Self.share, onShare: true) == sentence(Self.remote))
        #expect(sentence(Self.share, onShare: true) != sentence(Self.ordinary))
    }

    /// The same path off a share is an ordinary local path, so the branch is the volume's answer and
    /// not anything about `/Volumes` or `#recycle` in the spelling.
    @Test("the same path on a local disk keeps the Full Disk Access sentence")
    func localDiskKeepsTheGrantAdvice() {
        #expect(sentence(Self.share, onShare: false) == sentence(Self.ordinary))
    }

    /// The question costs a syscall, so it is asked only where the answer can change the sentence.
    @Test("the share question is asked only for a local permission failure")
    func shareQuestionIsNarrow() {
        var asked: [VFSPath] = []
        func describe(_ error: VFSError) {
            _ = VFSErrorText.sentence(for: error) { asked.append($0); return true }
        }
        describe(.notFound(Self.share))
        describe(.permissionDenied(Self.remote))
        #expect(asked.isEmpty)
        describe(.permissionDenied(Self.share))
        #expect(asked == [Self.share])
    }

    /// The real check's hermetic half: a folder on this Mac's own disk is not a share, and a server
    /// path is never looked up on this Mac's volumes however its spelling collides with one.
    @Test("the real check says no for a local disk and for a server path")
    func realCheckRefusesNonShares() {
        #expect(NetworkVolume.root(of: .local(Self.home)) == nil)
        #expect(NetworkVolume.root(of: Self.remote) == nil)
    }

    // MARK: - The item's own permissions

    private func sentence(
        _ path: VFSPath,
        refusedBy refusal: PermissionRefusal,
        onShare: Bool = false
    ) -> String {
        VFSErrorText.sentence(for: VFSError.permissionDenied(path, refusedBy: refusal)) { _ in onShare }
    }

    /// Another account's `drwx------` Documents, the reported case (2026-10-30).
    private static let otherAccount = VFSPath.local("/Users/someone/Documents")

    @Test("a refusal by the item's own permissions does not get the Full Disk Access sentence")
    func itemPermissionsDifferFromOrdinary() {
        #expect(sentence(Self.otherAccount, refusedBy: .itemPermissions) != sentence(Self.ordinary))
        #expect(sentence(Self.otherAccount, refusedBy: .itemPermissions) != sentence(Self.remote))
    }

    /// The new sentence still names the grant, to say it cannot help, so the English check is that
    /// it points somewhere else rather than that the words are absent.
    @Test("in English it names the owner and an administrator")
    func itemPermissionsWordingInEnglish() {
        guard readsEnglish else { return }
        let text = sentence(Self.otherAccount, refusedBy: .itemPermissions)
        #expect(text.contains("owner"))
        #expect(text.contains("administrator"))
        #expect(!text.contains("may need Full Disk Access"))
    }

    /// TCC refuses with `EPERM`, which the core leaves unattributed, so the refusals the grant
    /// does lift keep the sentence that names it.
    @Test("an unattributed local refusal keeps the Full Disk Access sentence")
    func unattributedKeepsTheGrantAdvice() {
        #expect(sentence(Self.otherAccount, refusedBy: .unattributed) == sentence(Self.ordinary))
    }

    /// A share's and a sync client's `EACCES` are decisions made somewhere else, and their own
    /// sentences already say so; the mode branch sits below both.
    @Test("a share or a sync client keeps its own sentence for the same errno")
    func moreSpecificPlacesWin() {
        #expect(
            sentence(Self.share, refusedBy: .itemPermissions, onShare: true) == sentence(Self.remote)
        )
        #expect(
            sentence(Self.cloudStorage, refusedBy: .itemPermissions) == sentence(Self.cloudStorage)
        )
    }

    /// The whole route on the real disk: a folder with every mode bit cleared refuses its listing
    /// with the same `EACCES` another account's folder gives, and the sheet's sentence follows.
    @Test("a real mode refusal reaches the new sentence")
    func realModeRefusal() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("dirnex-permission-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(atPath: folder) }
        #expect(chmod(folder, 0) == 0)
        defer { chmod(folder, 0o755) }

        let error = #expect(throws: VFSError.self) {
            try LocalBackend().listDirectory(at: .local(folder))
        }
        let text = error.map { VFSErrorText.sentence(for: $0) { _ in false } }
        #expect(text == sentence(Self.otherAccount, refusedBy: .itemPermissions))
        #expect(text != sentence(Self.ordinary))
    }

    // MARK: - A locked item

    /// The lock can be on the folder rather than on the item an alert's title names, so the sentence
    /// names whichever carries it.
    @Test("a locked refusal names the locked item and is not the Full Disk Access sentence")
    func lockedNamesTheItem() {
        let folder = VFSPath.local("/Users/oleg/Projects/Frozen")
        let text = sentence(Self.ordinary, refusedBy: .locked(folder))
        #expect(text != sentence(Self.ordinary))
        #expect(text != sentence(Self.ordinary, refusedBy: .itemPermissions))
        #expect(text.contains("Frozen"))
        if readsEnglish {
            #expect(text.contains("Locked"))
            #expect(!text.contains("Full Disk Access"))
        }
    }

    /// The whole route on the real disk: a create inside a `chflags uchg` folder fails `EPERM`, the
    /// same errno TCC gives, and the sentence still says which folder is locked.
    @Test("a real create in a locked folder reaches the locked sentence")
    func realLockedFolder() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("dirnex-locked-\(UUID().uuidString)").path
        let folder = root + "/Frozen"
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }
        #expect(chflags(folder, UInt32(UF_IMMUTABLE)) == 0)
        defer { chflags(folder, 0) }

        let error = #expect(throws: VFSError.self) {
            try LocalBackend().createFile(at: .local(folder + "/new.txt"))
        }
        let text = error.map { VFSErrorText.sentence(for: $0) { _ in false } }
        #expect(text == sentence(Self.ordinary, refusedBy: .locked(.local(folder))))
        #expect(text != sentence(Self.ordinary))
    }

    // MARK: - Only permission failures

    /// The branch reads the path, so it could in principle leak into other cases. Nothing else
    /// about a `CloudStorage` path is special.
    @Test("a non-permission failure inside a mount is worded as it always was")
    func otherErrorsAreUntouched() {
        #expect(
            VFSErrorText.sentence(for: VFSError.notFound(Self.cloudStorage))
                == VFSErrorText.sentence(for: VFSError.notFound(Self.ordinary))
        )
    }
}
