import AppKit
import DirnexCore
import Foundation
import Testing

@testable import Dirnex

/// The session allowance reaching the gestures that teach it and read it (2026-09-12): a preview
/// Download on one file lets the next file about that size arrive on its own, a Stop takes that back,
/// and ⌘D presses the card's button.
///
/// The rules are pinned in the core (`RemotePreviewAllowanceTests`); what these check is the wiring,
/// which is where an allowance that is computed perfectly and never consulted would hide.
///
/// Sizes are derived from the **live** Settings limit rather than written as literals, because the
/// app test target runs inside the app and reads the developer's own preference domain. A machine
/// with automatic downloads turned off has nothing for an allowance to widen, so the suite skips
/// there — visibly — rather than passing without measuring anything.
@MainActor
@Suite("Remote preview allowance reach", .enabled(if: automaticPreviewDownloadsAreOn))
struct RemotePreviewAllowanceReachTests {
    private var limit: Int64 {
        RemoteFetchPolicy.clampedPreviewLimit(AppPreferences.shared.quickViewFetchLimit)
    }

    /// Over the Settings limit, so it is what a card offers to download.
    private var agreed: FileEntry { Fixture.entry("MG_3010.CR2", byteSize: limit + 5_000_000) }
    /// Bigger than `agreed` and inside twice it — the reported folder's next RAW file.
    private var neighbour: FileEntry { Fixture.entry("MG_3186.CR2", byteSize: limit + 9_000_000) }
    /// Past twice what was agreed to.
    private var pastTheCeiling: FileEntry {
        Fixture.entry("P1011960.RW2", byteSize: (limit + 5_000_000) * 2 + 1)
    }

    // MARK: - Learning, and reading what was learned

    @Test(
        "a preview Download teaches the connection, and the next file that size arrives on its own"
    )
    func downloadTeachesTheNextFile() async throws {
        let host = StubPanelHost()
        let transfers = CountingBackend(outcome: .succeed)
        let first = try await pane(listing: agreed, transfers: transfers, host: host)
        let next = try await pane(listing: neighbour, transfers: transfers, host: host)
        let far = try await pane(listing: pastTheCeiling, transfers: transfers, host: host)

        // Before: over the Settings limit, so the cursor-following fetch declines.
        next.prepareRemotePreview()
        #expect(host.remoteFileCache.previewFetchState(for: neighbour) == nil)

        first.openRemotePreview(alreadyConfirmed: true, onReady: {})
        // Synchronously: the transfer starting *is* the agreement.
        #expect(host.remoteFileCache.previewAllowance.ceiling(for: Fixture.backendID)
            == agreed.byteSize * 2)
        #expect(await settle { host.remoteFileCache.cachedURL(for: agreed) != nil })

        next.prepareRemotePreview()
        #expect(host.remoteFileCache.previewFetchState(for: neighbour) == .running)
        host.remoteFileCache.cancelAutomaticFetch()

        // The narrowness control: a file past twice the agreement still waits for the card.
        far.prepareRemotePreview()
        #expect(host.remoteFileCache.previewFetchState(for: pastTheCeiling) == nil)
    }

    @Test("a preview Download of a file the Settings limit covers teaches nothing")
    func downloadWithinTheLimitTeachesNothing() async throws {
        let host = StubPanelHost()
        let small = Fixture.entry("DSCF8562.JPG", byteSize: limit)
        let pane = try await pane(listing: small, transfers: CountingBackend(), host: host)

        pane.openRemotePreview(alreadyConfirmed: true, onReady: {})
        #expect(await settle { host.remoteFileCache.cachedURL(for: small) != nil })

        #expect(host.remoteFileCache.previewAllowance.isEmpty)
    }

    /// ⌘Y and ⌃Q ask through the prompt, which reads the same allowance: a file about the size the
    /// user already agreed to on this connection starts at once instead of raising the confirmation.
    @Test("the preview confirmation stands aside for a file the session already agreed to")
    func confirmationStandsAside() async {
        let window = Self.retainedWindow()
        let backend = CountingBackend(outcome: .block)
        let cache = RemoteFileCache()
        cache.previewAllowance.recordAgreement(
            toFetch: agreed.byteSize, on: Fixture.backendID, previewLimit: limit
        )
        let started = Tally()

        RemoteFetchPrompt.fetch(
            neighbour,
            for: .preview,
            in: .init(backend: backend, cache: cache, window: window, hasProgressSurface: true),
            onStart: { started.count += 1 },
            then: { _ in },
            onFailure: { _ in }
        )

        #expect(started.count == 1)
        #expect(window.attachedSheet == nil)
        cache.stopPreviewFetch()
        await settle { backend.wasCancelledMidTransfer }
    }

    // MARK: - Withdrawing

    @Test("Stop withdraws the allowance, and walking off the row does not")
    func stopWithdrawsAndLeavingDoesNot() async throws {
        let host = StubPanelHost()
        let first = try await pane(listing: agreed, transfers: CountingBackend(), host: host)
        let blocking = CountingBackend(outcome: .block)
        let next = try await pane(listing: neighbour, transfers: blocking, host: host)
        first.openRemotePreview(alreadyConfirmed: true, onReady: {})
        #expect(await settle { host.remoteFileCache.cachedURL(for: agreed) != nil })

        // Leaving the row is what browsing is: the fetch it cancels is not a refusal.
        next.prepareRemotePreview()
        #expect(host.remoteFileCache.previewFetchState(for: neighbour) == .running)
        next.endRemotePreview()
        #expect(host.remoteFileCache.previewAllowance.ceiling(for: Fixture.backendID)
            == agreed.byteSize * 2)

        // The card's Stop on a download only the allowance let through is.
        next.prepareRemotePreview()
        #expect(await settle { blocking.copyCount == 1 })
        next.stopRemotePreviewFetch()
        #expect(host.remoteFileCache.previewAllowance.isEmpty)
        #expect(await settle { blocking.wasCancelledMidTransfer })
    }

    /// The progress sheet's Stop never goes through the card's action — it sets the transfer's flag
    /// directly — so the explicit gesture has to hear about it from the transfer ending.
    @Test("a Stop that reaches the transfer directly withdraws the allowance too")
    func stopFromTheSheetWithdraws() async throws {
        let host = StubPanelHost()
        let blocking = CountingBackend(outcome: .block)
        let pane = try await pane(listing: agreed, transfers: blocking, host: host)

        pane.openRemotePreview(alreadyConfirmed: true, onReady: {})
        #expect(!host.remoteFileCache.previewAllowance.isEmpty)
        #expect(await settle { blocking.copyCount == 1 })
        host.remoteFileCache.stopPreviewFetch()

        #expect(await settle { host.remoteFileCache.previewAllowance.isEmpty })
        #expect(blocking.wasCancelledMidTransfer)
    }

    // MARK: - ⌘D

    @Test("Download Preview is offered exactly while the card offers its button")
    func commandFollowsTheButton() async throws {
        let host = StubPanelHost()
        let blocking = CountingBackend(outcome: .block)
        let pane = try await pane(listing: agreed, transfers: blocking, host: host)

        #expect(pane.offersRemotePreviewDownload)
        pane.openRemotePreview(alreadyConfirmed: true, onReady: {})
        #expect(!pane.offersRemotePreviewDownload, "nothing to press while it downloads")
        #expect(await settle { blocking.copyCount == 1 })
        pane.stopRemotePreviewFetch()
        #expect(pane.offersRemotePreviewDownload, "a stopped card offers the button again")
        #expect(await settle { blocking.wasCancelledMidTransfer })
    }

    @Test("⌘D is the command's default and reaches the window's action through the built menu")
    func commandIsWired() throws {
        let action = #selector(BrowserWindowController.downloadQuickViewPreview(_:))
        #expect(CommandBinding.selector(for: "view.downloadPreview") == action)
        let command = try #require(CommandCatalog.command(for: "view.downloadPreview"))
        #expect(command.shortcut == CommandShortcut(key: "d", modifiers: .command))

        let item = try #require(Self.flatten(MainMenuBuilder.build()).first { $0.action == action })
        // Against the *effective* binding, since the test host reads the developer's own rebindings.
        if KeyBindingStore.shared.shortcut(for: "view.downloadPreview") == command.shortcut {
            #expect(item.keyEquivalent == "d")
            #expect(item.keyEquivalentModifierMask == .command)
        }
    }

    @Test("the card draws the command's shortcut on its Download button, and nothing when unbound")
    func cardDrawsTheShortcut() {
        let card = QuickViewPlaceholderCard()
        card.onDownload = {}
        let placeholder = RemotePreviewPlaceholder(
            name: "MG_3186.CR2", size: "22,9 MB", byteSize: 22_900_000,
            state: .awaitingRequest(.tooLarge)
        )

        card.downloadShortcut = CommandShortcut(key: "d", modifiers: .command)
        card.show(placeholder)
        #expect(card.downloadButton.title.hasSuffix("⌘D"))
        #expect(!card.downloadButton.isHidden)

        card.downloadShortcut = nil
        card.show(placeholder)
        #expect(!card.downloadButton.title.contains("⌘"))
    }

    // MARK: - Fixtures

    /// A pane listing `row` from a backend whose transfers go through `transfers`, with its cursor on
    /// that row and `host` holding the cache the allowance lives in.
    ///
    /// **The view is loaded and the row really listed**, not seeded by hand: the fetch funnel reads
    /// `view.window`, which loads the view, and a loaded pane lists its directory — so a hand-seeded
    /// model would be replaced a moment later by whatever the backend lists, and the cursor would be
    /// on nothing. One row per pane, so no cursor ever has to move.
    private func pane(
        listing row: FileEntry,
        transfers: CountingBackend,
        host: StubPanelHost
    ) async throws -> PanelViewController {
        let backend = ListingBackend(rows: [row], transfers: transfers)
        let pane = PanelViewController(
            backend: backend,
            restoration: nil,
            defaultPath: VFSPath(backend: Fixture.backendID, path: "/"),
            restorationKey: nil
        )
        pane.host = host
        pane.loadViewIfNeeded()
        try #require(
            await settle { pane.remoteFileUnderCursor == row },
            "the pane never listed \(row.name)"
        )
        return pane
    }

    /// Every item in `menu`, submenus included.
    private static func flatten(_ menu: NSMenu) -> [NSMenuItem] {
        menu.items.flatMap { item in [item] + (item.submenu.map(flatten) ?? []) }
    }

    /// A window the confirmation could attach to, kept for the life of the process: tearing a window
    /// down while a sheet settles crashes a *later* test (docs/NOTES.md ▸ Testing).
    private static var windows: [NSWindow] = []
    private static func retainedWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled],
            backing: .buffered,
            defer: true
        )
        windows.append(window)
        return window
    }

    @discardableResult
    private func settle(within seconds: Double = 30, until isDone: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        // Completion before the clock: a late resume must not report a timeout over finished work.
        while !isDone() {
            guard Date() < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return true
    }
}

/// Whether this machine's Settings limit lets anything download unasked.
///
/// At file scope, and read straight from the defaults domain: a suite trait cannot name a member of
/// the suite it is attached to (the macro resolves it circularly), and the condition cannot hop to
/// the main actor `AppPreferences` lives on. Absent means the shipped default, which is on.
private var automaticPreviewDownloadsAreOn: Bool {
    let stored = UserDefaults.standard.object(forKey: "Dirnex.pref.quickViewFetchLimit")
    let limit = (stored as? NSNumber)?.int64Value ?? RemoteFetchPolicy.defaultPreviewLimit
    return RemoteFetchPolicy.clampedPreviewLimit(limit) > 0
}

/// A backend that lists the rows it is given and moves bytes through a `CountingBackend`, so a pane
/// can hold a real listing while its transfers stay countable and stoppable.
private final class ListingBackend: VFSBackend, @unchecked Sendable {
    let id = Fixture.backendID
    let capabilities: VFSCapabilities = [.read, .write]
    private let rows: [FileEntry]
    private let transfers: CountingBackend

    init(rows: [FileEntry], transfers: CountingBackend) {
        self.rows = rows
        self.transfers = transfers
    }

    func listDirectory(at path: VFSPath) throws -> [FileEntry] { rows }

    func stat(at path: VFSPath) throws -> FileEntry {
        guard let row = rows.first(where: { $0.path == path }) else { throw VFSError.notFound(path) }
        return row
    }

    func copyFile(
        at source: VFSPath,
        to destination: VFSPath,
        progress: (Int64) -> Void,
        isCancelled: () -> Bool
    ) throws {
        try transfers.copyFile(
            at: source,
            to: destination,
            progress: progress,
            isCancelled: isCancelled
        )
    }
}

/// A main-actor counter a `@MainActor` closure can bump.
@MainActor
private final class Tally {
    var count = 0
}
