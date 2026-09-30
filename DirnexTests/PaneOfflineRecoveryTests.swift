import DirnexCore
import Foundation
import Testing

@testable import Dirnex

/// A restored tab that could not be listed says why in its status line — and a later **re-list**
/// that succeeds has to take that sentence away, not only a navigation (PLAN.md §M28 Slice 3, found
/// live: a Photos tab restored before its grant went on saying the library could not be read over
/// the rows the pane's timer had since read).
@Suite("Pane recovering from a failed restore")
@MainActor
struct PaneOfflineRecoveryTests {
    /// A real directory with one file in it, and a pane on the routing backend the app holds, whose
    /// view is never loaded.
    private static func pane() throws -> (PanelViewController, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PaneOfflineRecoveryTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: directory.appendingPathComponent("one.txt"))
        let path = VFSPath.local(directory.path)
        let vc = PanelViewController(
            backend: CompositeBackend(local: LocalBackend()),
            restoration: nil,
            defaultPath: path,
            restorationKey: nil
        )
        vc.panel = Panel(path: path)
        vc.recordRestoreFailure(VFSError.permissionDenied(path), in: vc.tabs[0])
        return (vc, directory)
    }

    @Test("a passive re-list that succeeds clears the reason the restore left behind")
    func passiveRefreshClearsTheReason() async throws {
        let (vc, directory) = try Self.pane()
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(vc.tabs[0].offlineReason != nil)
        let explaining = vc.statusLabel.stringValue

        let plan = try #require(vc.listRefreshPlan(for: vc.panel.path))
        await vc.performListRefresh(plan, wake: .poll)

        #expect(vc.panel.displayedEntries.map(\.name) == ["one.txt"])
        #expect(vc.tabs[0].offlineReason == nil)
        #expect(vc.statusLabel.stringValue != explaining)
    }

    /// The narrowness control: a re-list that fails again has answered nothing, so the reason stays.
    @Test("a re-list that fails again leaves the reason standing")
    func failedRefreshKeepsTheReason() async throws {
        let (vc, directory) = try Self.pane()
        try FileManager.default.removeItem(at: directory)

        let plan = try #require(vc.listRefreshPlan(for: vc.panel.path))
        await vc.performListRefresh(plan, wake: .poll)

        #expect(vc.tabs[0].offlineReason != nil)
    }
}
