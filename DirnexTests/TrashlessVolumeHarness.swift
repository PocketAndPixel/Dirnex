import AppKit
import DirnexCore
import Foundation
import Testing

@testable import Dirnex

/// Shared harness for the three flows that can meet a volume with no Trash — F8, the F6 move into
/// an archive, and a directory sync's deletes. One fake and one set of probes, because the thing
/// under test is that all three reach the *same* offer; a second copy of either could drift from
/// the flow it was written for and still pass.

/// Build a pane on `backend`, hosted in `window` so an alert attaches as a sheet rather than
/// falling back to `runModal()`, which wedges the run instead of failing it (docs/NOTES.md).
@MainActor
enum TrashlessProbe {
    static let directory = VFSPath.local("/Volumes/Photos")

    static func pane(with backend: any VFSBackend, in window: NSWindow) -> PanelViewController {
        _ = scratchPutBackStore
        let pane = PanelViewController(
            backend: backend,
            restoration: nil,
            defaultPath: directory,
            restorationKey: nil
        )
        window.contentViewController = pane
        pane.loadViewIfNeeded()
        pane.panel = Panel(
            model: DirectoryModel(listing: DirectoryListing(path: directory, entries: []))
        )
        return pane
    }

    static func file(_ name: String) -> FileEntry {
        FileEntry(
            path: directory.appending(name),
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

    /// A window to host a pane, **kept alive for the rest of the process**.
    ///
    /// Not a leak to tidy away: tearing a window down while a sheet it carried is still settling
    /// segfaults the test host inside AppKit's own animation teardown — measured here as
    /// `objc_release` under `-[_NSWindowTransformAnimation dealloc]`, from a Core Animation
    /// transaction committing *one test later*, which is why the crash landed on a test that
    /// presented no sheet at all. xcodebuild then restarts and lists whatever was in flight under
    /// "Failing tests:", so it reads as several broken features (docs/NOTES.md ▸ Testing).
    /// Waiting for `attachedSheet` to go `nil` first is **not** enough; only never tearing down is.
    /// A handful of retained windows in a test host costs nothing by comparison.
    static func window() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 320),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        retained.append(window)
        return window
    }

    private static var retained: [NSWindow] = []

    /// Point ``TrashOriginStore/shared`` at a scratch domain for the life of the test host.
    ///
    /// The app test target runs **inside the app**, so its `UserDefaults.standard` is the
    /// developer's own `com.dirnex.Dirnex` — and every pane built here can reach `runDelete`, which
    /// files a put-back record. Without this, running the suite writes fake origins naming
    /// `/Volumes/Photos` into the store a real Put Back reads from. Same shape as the S3 live
    /// suites' Keychain capture (docs/NOTES.md): a store keyed by what it describes cannot tell who
    /// wrote it, so the isolation has to be arranged rather than assumed.
    ///
    /// Installed from `pane(_:in:)` rather than left to each test to remember, and a `static let` so
    /// it runs once however many tests race into it. A test that wants to *watch* the writes swaps
    /// in its own store afterwards.
    private static let scratchPutBackStore: Void = {
        guard let suite = UserDefaults(suiteName: "com.dirnex.tests.putback.host") else { return }
        TrashOriginStore.shared = TrashOriginStore(defaults: suite, isInVault: { _ in false })
    }()

    /// The button an alert binds Return to — found through `defaultButtonCell`, never by title,
    /// which would pass in English and fail in thirteen languages (docs/NOTES.md ▸ Localization).
    static func defaultButton(in window: NSWindow) -> NSButton? {
        if let button = window.defaultButtonCell?.controlView as? NSButton { return button }
        guard let content = window.contentView else { return nil }
        return button(under: content, keyEquivalent: "\r")
    }

    /// The button that answers Escape. On the ordinary `Delete[⏎] Cancel[⎋]` confirmation that is
    /// the safe one, which `enableEscapeToCancel` binds — again by binding, never by title.
    static func cancelButton(in window: NSWindow) -> NSButton? {
        guard let content = window.contentView else { return nil }
        return button(under: content, keyEquivalent: "\u{1b}")
    }

    /// Whether `sheet` is a failure *report* rather than the permanent-delete *offer* — told
    /// apart by their shape, never by their words: the offer is a two-button question whose safe
    /// button answers Escape, and a report is a lone OK (`enableEscapeToCancel` leaves a single
    /// button holding Return and hangs Escape on a catcher view instead, docs/NOTES.md). Reading a
    /// title would pass in English and fail in thirteen languages.
    static func isFailureReport(_ sheet: NSWindow) -> Bool {
        cancelButton(in: sheet) == nil
    }

    private static func button(under view: NSView, keyEquivalent: String) -> NSButton? {
        for subview in view.subviews {
            if let button = subview as? NSButton, button.keyEquivalent == keyEquivalent {
                return button
            }
            if let found = button(under: subview, keyEquivalent: keyEquivalent) { return found }
        }
        return nil
    }
}

/// Poll until `isDone` — `await`, never a run-loop spin, since these flows run off the main actor
/// and a spin never suspends them (docs/NOTES.md ▸ Testing). Generous on purpose: a satisfied
/// predicate returns on the next poll, so the budget only sets how much scheduling delay is
/// absorbed before the code is blamed.
@MainActor
@discardableResult
func settle(within seconds: Double = 10, until isDone: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if isDone() { return true }
        try? await Task.sleep(for: .milliseconds(25))
    }
    return isDone()
}

/// Wait long enough to show something does *not* happen. Fixed, unlike ``settle``: here the length
/// is the claim itself, so it cannot be widened to suit a slow machine.
@MainActor
func hold(until isHappening: () -> Bool = { false }) async {
    _ = await settle(within: 2.5, until: isHappening)
}

/// A backend whose `trashItem` refuses the way a volume with no Trash does, and which records the
/// permanent deletes it is asked for.
///
/// A fake rather than a real volume because the state cannot be arranged on this Mac: every
/// filesystem `hdiutil` can make trashes fine (measured 2026-08-25 on ExFAT and HFS+), so the
/// refusal needs a network share. What is under test here is the app's chain, and the syscall that
/// raises the refusal is pinned separately in `LocalBackendTrashRefusalTests`.
final class RefusingBackend: VFSBackend, @unchecked Sendable {
    enum Refusal {
        /// What a volume with no Trash answers (`NSFeatureUnsupportedError`, mapped).
        case noTrashOnVolume
        /// A real failure, which must keep its own report.
        case permissionDenied
        /// An ordinary volume — the control that keeps the fallback from firing everywhere.
        case trashesNormally
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
        case .trashesNormally: return .local("/.Trash/\(path.lastComponent)")
        }
    }

    func removeItem(at path: VFSPath) throws {
        lock.withLock { removed.append(path) }
    }
}
