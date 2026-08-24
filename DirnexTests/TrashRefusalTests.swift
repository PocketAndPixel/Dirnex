import AppKit
import DirnexCore
import Foundation
import Testing

@testable import Dirnex

/// The app half of a move-to-Trash the volume cannot perform: which failures stop being failures
/// and become the offer of a permanent delete instead (a mounted SMB share, reported 2026-08-25).
///
/// The offer itself is not driven here, and the reason belongs with the suite: it ends in an
/// `NSAlert` that on a window-less pane falls back to `runModal()`, which **wedges** the run rather
/// than failing it — the hazard `QueuedRenameReachTests` and `RenameReachTests` both measured. So
/// what is pinned is the decision either side of the sheet: the classification, which is what
/// routes 3328 away from the errno alert, and the fact that an empty target list raises nothing.
/// The keystroke is verified live against a real share.
@MainActor
@Suite("Trash refusal")
struct TrashRefusalTests {
    private static let path = VFSPath.local("/Volumes/Photos/t.txt")

    // MARK: - What counts as "this volume has no Trash"

    @Test("the named volume refusal is recognised")
    func recognisesRefusal() {
        #expect(TrashRefusal.isVolumeWithoutTrash(VFSError.unsupported(.trash)))
    }

    /// The controls that keep the offer from firing on a real failure. Each of these leaves the
    /// file where it is for a reason the user has to be told, and answering any of them with
    /// "shall I delete it permanently instead?" would be the app offering to do harm in response
    /// to something going wrong.
    @Test("no other failure is read as a missing Trash")
    func otherFailuresAreNotRefusals() {
        let path = Self.path
        #expect(!TrashRefusal.isVolumeWithoutTrash(VFSError.permissionDenied(path)))
        #expect(!TrashRefusal.isVolumeWithoutTrash(VFSError.notFound(path)))
        #expect(!TrashRefusal.isVolumeWithoutTrash(VFSError.io(path: path, code: 3328)))
        #expect(!TrashRefusal.isVolumeWithoutTrash(VFSError.io(path: path, code: EACCES)))
        #expect(!TrashRefusal.isVolumeWithoutTrash(CancellationError()))
        // The neighbouring `.unsupported` reasons, and the one that matters most: an item already
        // in a trash is refused by `LocalBackend` itself, and re-offering *that* as a permanent
        // delete would answer a question nobody asked.
        #expect(!TrashRefusal.isVolumeWithoutTrash(
            VFSError.unsupported(.alreadyInTrash(name: "t.txt"))
        ))
        #expect(!TrashRefusal.isVolumeWithoutTrash(VFSError.unsupported(.removeItem)))
    }

    // MARK: - The offer

    /// A delete pass in which nothing was refused must raise no sheet at all. Without the guard,
    /// every ordinary Trash delete on every volume would end in a permanent-delete confirmation —
    /// which is the one way this fix could be worse than the bug.
    @Test("an empty refusal list raises nothing")
    func emptyRefusalRaisesNothing() async {
        let window = Self.probeWindow()
        defer { window.close() }
        let backend = RefusingBackend()
        let pane = Self.pane(with: backend, in: window)

        pane.offerPermanentDelete(forVolumeWithoutTrash: [])

        await hold(until: { window.attachedSheet != nil })
        #expect(window.attachedSheet == nil)
        #expect(backend.removedPaths.isEmpty)
    }

    // MARK: - The whole chain

    /// The reported bug end to end: F8 over a volume that keeps no Trash must not report a number.
    /// It asks, and answering **Delete** must actually delete — which is the only thing that can
    /// tell this build from one that merely worded the failure more kindly.
    ///
    /// The assertion is the backend's `removeItem`, for the reason `RemoteFetchPromptTests` rests
    /// on its copy count: nothing about the *decision* was broken before, so only whether the work
    /// was asked for separates the two versions.
    @Test("a refused Trash delete asks, and the answer performs the permanent delete")
    func refusedTrashOffersAndDeletes() async throws {
        let window = Self.probeWindow()
        defer { window.close() }
        let backend = RefusingBackend()
        let pane = Self.pane(with: backend, in: window)
        let entry = Self.file("t.txt")

        pane.runDelete([entry], permanent: false)

        await settle { window.attachedSheet != nil }
        let sheet = try #require(window.attachedSheet, "the offer never appeared")
        // Nothing may have been deleted while the question is still on screen: the refusal happens
        // before any bytes move, so this is a question and not a report of something already done.
        #expect(backend.removedPaths.isEmpty)
        try #require(Self.defaultButton(in: sheet)).performClick(nil)
        await settle { !backend.removedPaths.isEmpty }

        #expect(backend.removedPaths == [entry.path])
        // And the Trash was genuinely attempted first — this is a fallback, not a replacement.
        #expect(backend.trashAttempts == 1)
    }

    /// The narrowness control, and the half that keeps "offer a permanent delete" from becoming
    /// "offer it whenever anything goes wrong". A permission failure is a real failure: it keeps
    /// its own report, and nothing is deleted.
    @Test("a genuine failure is not turned into an offer to delete for good")
    func realFailureIsNotAnOffer() async {
        let window = Self.probeWindow()
        defer { window.close() }
        let backend = RefusingBackend(refusal: .permissionDenied)
        let pane = Self.pane(with: backend, in: window)

        pane.runDelete([Self.file("t.txt")], permanent: false)

        await settle { window.attachedSheet != nil }
        // The failure alert is what appears here; whichever sheet it is, pressing its default
        // button must not delete anything.
        if let sheet = window.attachedSheet, let button = Self.defaultButton(in: sheet) {
            button.performClick(nil)
        }
        await hold(until: { !backend.removedPaths.isEmpty })
        #expect(backend.removedPaths.isEmpty)
    }

    // MARK: - Harness

    private static func pane(
        with backend: any VFSBackend,
        in window: NSWindow
    ) -> PanelViewController {
        let path = VFSPath.local("/Volumes/Photos")
        let pane = PanelViewController(
            backend: backend,
            restoration: nil,
            defaultPath: path,
            restorationKey: nil
        )
        window.contentViewController = pane
        pane.loadViewIfNeeded()
        pane.panel = Panel(model: DirectoryModel(listing: DirectoryListing(path: path, entries: [])))
        return pane
    }

    private static func file(_ name: String) -> FileEntry {
        FileEntry(
            path: VFSPath.local("/Volumes/Photos/\(name)"),
            name: name,
            kind: .file,
            byteSize: 3,
            modificationDate: Date(timeIntervalSince1970: 1_700_000_000),
            creationDate: Date(timeIntervalSince1970: 1_700_000_000),
            isHidden: false,
            permissions: 0o644,
            inode: 0
        )
    }

    private static func probeWindow() -> NSWindow {
        NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 320),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
    }

    /// The button an alert binds Return to — found through `defaultButtonCell`, never by title,
    /// which would pass in English and fail in thirteen languages (docs/NOTES.md ▸ Localization).
    private static func defaultButton(in window: NSWindow) -> NSButton? {
        if let button = window.defaultButtonCell?.controlView as? NSButton { return button }
        guard let content = window.contentView else { return nil }
        return defaultButton(under: content)
    }

    private static func defaultButton(under view: NSView) -> NSButton? {
        for subview in view.subviews {
            if let button = subview as? NSButton, button.keyEquivalent == "\r" { return button }
            if let found = defaultButton(under: subview) { return found }
        }
        return nil
    }

    /// Poll until `isDone` — `await`, never a run-loop spin, since the delete runs off the main
    /// actor and a spin never suspends it (docs/NOTES.md ▸ Testing).
    @discardableResult
    private func settle(within seconds: Double = 10, until isDone: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if isDone() { return true }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return isDone()
    }

    /// Wait long enough to show something does *not* happen. Bounded, unlike ``settle``: here the
    /// length is the claim itself, so it cannot be widened to suit a slow machine.
    private func hold(until isHappening: () -> Bool = { false }) async {
        _ = await settle(within: 2.5, until: isHappening)
    }
}

/// A backend whose `trashItem` refuses the way a volume with no Trash does, and which records the
/// permanent deletes it is asked for.
///
/// A fake rather than a real volume because the state cannot be arranged on this Mac: every
/// filesystem `hdiutil` can make trashes fine (measured 2026-08-25 on ExFAT and HFS+), so the
/// refusal needs a network share. What is under test here is the app's chain, and the syscall that
/// raises the refusal is pinned separately in `LocalBackendTrashRefusalTests`.
private final class RefusingBackend: VFSBackend, @unchecked Sendable {
    enum Refusal {
        /// What a volume with no Trash answers (`NSFeatureUnsupportedError`, mapped).
        case noTrashOnVolume
        /// A real failure, which must keep its own report.
        case permissionDenied
    }

    let id = VFSBackendID.local
    let capabilities: VFSCapabilities = [.read, .write, .trash]

    private let refusal: Refusal
    private let lock = NSLock()
    private var removed: [VFSPath] = []
    private var trashCalls = 0

    init(refusal: Refusal = .noTrashOnVolume) {
        self.refusal = refusal
    }

    var removedPaths: [VFSPath] { lock.withLock { removed } }
    var trashAttempts: Int { lock.withLock { trashCalls } }

    func listDirectory(at path: VFSPath) throws -> [FileEntry] { [] }

    func stat(at path: VFSPath) throws -> FileEntry {
        throw VFSError.notFound(path)
    }

    func trashItem(at path: VFSPath) throws -> VFSPath? {
        lock.withLock { trashCalls += 1 }
        switch refusal {
        case .noTrashOnVolume: throw VFSError.unsupported(.trash)
        case .permissionDenied: throw VFSError.permissionDenied(path)
        }
    }

    func removeItem(at path: VFSPath) throws {
        lock.withLock { removed.append(path) }
    }
}
