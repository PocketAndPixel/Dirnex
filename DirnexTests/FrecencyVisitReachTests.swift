import DirnexCore
import Foundation
import Testing

@testable import Dirnex

/// A landed navigation reports its visit to the pane's host, which is the only way it reaches the
/// frecency index behind the path bar's fuzzy jump (PLAN.md §M3).
///
/// Before, the pane wrote to `FrecencyStore.shared` itself, so every test that navigated a pane
/// wrote into the developer's own index: 280 fixture folders by 2026-09-14 (docs/NOTES.md ▸ Testing).
/// Routing through the host fixes that because no test builds a `BrowserWindowController`. The
/// risk the move adds is a pane that no longer reports at all, which nothing else would notice, so
/// both write sites are pinned here: an ordinary navigation, and leaving a listing that cannot be
/// re-entered from history, which resets the back/forward trail and records the visit separately.
@MainActor
@Suite("Frecency visits reach the host")
struct FrecencyVisitReachTests {
    private static func scratchDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("FrecencyVisitReachTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func pane(at path: VFSPath, host: StubPanelHost) -> PanelViewController {
        let pane = PanelViewController(
            backend: CompositeBackend(local: LocalBackend()),
            restoration: nil,
            defaultPath: path,
            restorationKey: nil
        )
        pane.host = host
        return pane
    }

    @Test("an ordinary navigation reports the directory it landed on")
    func ordinaryNavigationReportsTheVisit() async throws {
        let scratch = try Self.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let host = StubPanelHost()
        let destination = VFSPath.local(scratch.path)
        let pane = Self.pane(at: .local(NSTemporaryDirectory()), host: host)

        pane.navigate(to: destination)

        try await settleUntil { !host.frecencyVisits.isEmpty }
        #expect(host.frecencyVisits == [destination])
    }

    /// The second write site: `navigate` resets the trail when it leaves a listing history cannot
    /// re-enter, and records the visit on that branch. The archive here is never listed, since only
    /// the path the pane is leaving is read.
    @Test("leaving an archive listing for a real directory reports that directory")
    func leavingAVirtualListingReportsTheVisit() async throws {
        let scratch = try Self.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let host = StubPanelHost()
        let destination = VFSPath.local(scratch.path)
        let archive = VFSPath(backend: .archive(forArchiveAt: "/nonexistent/pkg.zip"), path: "/")
        let pane = Self.pane(at: archive, host: host)

        pane.navigate(to: destination)

        try await settleUntil { !host.frecencyVisits.isEmpty }
        #expect(host.frecencyVisits == [destination])
        #expect(pane.panel.path == destination)
    }
}
