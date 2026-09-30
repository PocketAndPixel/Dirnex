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
/// affect, because that directory is not TCC-gated.
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
