import AppKit
import DirnexCore
import Testing

@testable import Dirnex

/// The ⌃Q surface: what it covers of the pane it sits in, and the header it carries (2026-10-14).
///
/// The file it shows comes from the *other* pane, so the covered pane's path bar and item count
/// describe a folder the preview has nothing to do with. The surface reaches over both, and the
/// full-window header takes the path bar's place — which is also the only thing at this size that
/// says `1` / `2` would switch the rendering.
@MainActor
@Suite("Quick View ▸ the pane-size surface")
struct QuickViewPaneSurfaceTests {
    /// Pinned edge for edge rather than "contains": an exact top is also what says the tab strip
    /// above the path bar is left alone.
    @Test("it covers the path bar and the status line as well as the list")
    func coversPathBarAndStatusLine() throws {
        let hosted = windowedPane()
        let pane = hosted.pane

        pane.showQuickViewPreview(of: nil, style: .default, caption: nil)
        pane.view.layoutSubtreeIfNeeded()

        let preview = try #require(pane.quickViewPreview)
        let cover = preview.convert(preview.bounds, to: nil)
        let pathBar = pane.pathBar.convert(pane.pathBar.bounds, to: nil)
        let status = pane.statusLabel.convert(pane.statusLabel.bounds, to: nil)
        #expect(cover.maxY == pathBar.maxY)
        #expect(cover.minY == status.minY)
        #expect(cover.height > pane.scrollView.frame.height)
    }

    @Test("its header names the file, its place and both styles, as the full-window one does")
    func headerCarriesTheCaption() throws {
        let hosted = windowedPane()
        let pane = hosted.pane
        let caption = QuickViewCaption(
            name: "people.csv",
            position: 2,
            count: 5,
            style: .rendered,
            styleKind: .table
        )

        pane.showQuickViewPreview(of: nil, style: .rendered, caption: caption)
        pane.view.layoutSubtreeIfNeeded()

        let preview = try #require(pane.quickViewPreview)
        let header = try #require(
            preview.subviews.lazy.compactMap { $0 as? QuickViewHeaderView }.first
        )
        #expect(header.caption == caption)
        #expect(!header.isHidden)
        #expect(
            header.alphaValue == 1,
            "a floating header would be faded out until the pointer moved"
        )
        #expect(header.frame.height == QuickViewHeaderView.height)
        let texts = header.styleButtons.filter { !$0.isHiddenOrHasHiddenAncestor }.map(\.title)
        for style in QuickViewRenderStyle.allCases {
            let label = style.headerLabel(for: .table)
            #expect(texts.contains { $0.contains(label) }, "\(label) missing from \(texts)")
        }
    }
}
