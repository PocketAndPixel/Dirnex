import AppKit
import Testing

@testable import Dirnex

/// The Quick View header leaves the panes divider free (2026-11-20).
///
/// A rendered page's "1 Source · 2 Page (no JavaScript)" resisted at 750, and the name between it
/// and the position is centered, so the strip counted twice: the header would not go below about
/// 405 pt, and it pushed a narrower pane out to that. A surface stays in its pane when Quick View
/// closes, so the pane stayed there after the mode had closed.
@Suite("Quick View ▸ the header leaves the panes their widths")
@MainActor
struct QuickViewHeaderWidthTests {
    /// What the window gives a rendered HTML page with scripts refused, the shipped default and the
    /// header's widest strip.
    private static func pageCaption(named name: String = "index.html") -> QuickViewCaption {
        var caption = QuickViewCaption(name: name, position: 1, count: 3, style: .rendered)
        caption.styleKind = .page
        caption.javaScriptDisabled = true
        return caption
    }

    @Test("a rendered page's styles neither widen a narrow pane nor hold the divider")
    func stylesLeaveDividerFree() throws {
        let panes = try QuickViewPaneSplit()
        panes.moveDivider(to: 700)
        try #require(panes.rightWidth == 300)

        panes.right.showQuickViewPreview(of: nil, style: .rendered, caption: Self.pageCaption())
        panes.layOut()
        #expect(panes.rightWidth == 300, "showing the page moved the divider")

        panes.moveDivider(to: 740)
        #expect(panes.rightWidth == 260)
    }

    @Test("with Quick View closed the pane a page was shown in narrows again")
    func closedPreviewLeavesDividerFree() throws {
        let panes = try QuickViewPaneSplit()
        panes.right.showQuickViewPreview(of: nil, style: .rendered, caption: Self.pageCaption())
        panes.layOut()

        panes.right.hideQuickViewPreview()
        panes.moveDivider(to: 740)
        #expect(panes.rightWidth == 260)
    }

    /// The order things give way in, so the fix is not "the styles truncate whenever a name is
    /// long": the mark goes first, then the name, and the styles last, since they are the only place
    /// the `1` and `2` keys say what they do.
    @Test("short of room, the mark and then the name give way, and the styles stay whole")
    func orderShortOfRoom() throws {
        let panes = try QuickViewPaneSplit()
        panes.moveDivider(to: 700)
        let name = "a rather long page name that cannot fit.html"
        panes.right.showQuickViewPreview(
            of: nil,
            style: .rendered,
            caption: Self.pageCaption(named: name)
        )
        panes.layOut()
        let preview = try #require(panes.right.quickViewPreview)
        let header = try QuickViewCloseButtonTests.header(of: preview)

        for button in header.styleButtons {
            let shown = QuickViewCloseButtonTests.laidOut(button).width
            #expect(
                shown >= button.intrinsicContentSize.width - 1,
                "\(button.title) cut to \(shown)"
            )
        }
        let nameLabel = try QuickViewCloseButtonTests.label(in: header, reading: name)
        let nameWidth = QuickViewCloseButtonTests.laidOut(nameLabel).width
        #expect(nameWidth < nameLabel.intrinsicContentSize.width - 4, "the name gave way")
        #expect(nameWidth > 20, "and still shows some of itself once the mark has gone")
        let mark = try #require(
            header.subviews.lazy.compactMap { $0 as? NSStackView }.first?.arrangedSubviews
                .compactMap { $0 as? NSTextField }
                .first { $0.stringValue.contains(QuickViewHeaderView.noJavaScriptMark) }
        )
        #expect(QuickViewCloseButtonTests.laidOut(mark).width <= 1, "the mark went first")
    }

    /// The control for the order above: with room for everything, nothing gives way.
    @Test("with room, the mark, the styles and the name are all whole")
    func wholeWithRoom() throws {
        let panes = try QuickViewPaneSplit()
        panes.right.showQuickViewPreview(of: nil, style: .rendered, caption: Self.pageCaption())
        panes.layOut()
        let preview = try #require(panes.right.quickViewPreview)
        let header = try QuickViewCloseButtonTests.header(of: preview)
        let strip = try #require(header.subviews.lazy.compactMap { $0 as? NSStackView }.first)
        for view in strip.arrangedSubviews where !view.isHidden {
            let shown = QuickViewCloseButtonTests.laidOut(view).width
            #expect(shown >= view.intrinsicContentSize.width - 1, "\(view) cut to \(shown)")
        }
        let nameLabel = try QuickViewCloseButtonTests.label(in: header, reading: "index.html")
        #expect(
            QuickViewCloseButtonTests.laidOut(nameLabel).width
                >= nameLabel.intrinsicContentSize.width - 1
        )
    }

    /// What holds for a longer translation, whose styles would not fit a pane at its narrowest: no
    /// pane is narrow enough to press the English ones once the mark has gone, so the tests above
    /// pass with the styles above 250 (tried). The squeeze here is just above the panes' 250, and
    /// every piece of the strip has to give way to it, down to what the position needs.
    @Test("pressed just above the panes' 250, the styles give way too")
    func stylesGiveWayBelowThePanes() throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 300),
            styleMask: [.titled],
            backing: .buffered,
            defer: true
        )
        RetainedWindows.all.append(window)
        let preview = QuickViewPreviewView(
            backingColor: .black,
            header: .pinned,
            findOptions: QuickViewFindOptionsStore.scratch()
        )
        let content = try #require(window.contentView)
        content.addSubview(preview)
        let squeeze = preview.widthAnchor.constraint(equalToConstant: 100)
        squeeze.priority = NSLayoutConstraint.Priority(250.5)
        NSLayoutConstraint.activate([
            preview.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            preview.topAnchor.constraint(equalTo: content.topAnchor),
            preview.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            squeeze
        ])
        preview.setCaption(Self.pageCaption())
        content.layoutSubtreeIfNeeded()

        // The strip as a whole: two siblings at one priority do not share a squeeze, and the solver
        // put all of it on one of the styles (docs/NOTES.md ▸ Views, layout and hit testing).
        let header = try QuickViewCloseButtonTests.header(of: preview)
        let whole = header.styleButtons.map(\.intrinsicContentSize.width).reduce(0, +)
        let shown = header.styleButtons.map { QuickViewCloseButtonTests.laidOut($0).width }
            .reduce(0, +)
        #expect(shown < whole - 4, "the styles held \(shown) of \(whole)")
        // 232 pt with the styles held: twice their 92 and the 24 around them, the name centered.
        #expect(preview.frame.width < 200, "the strip held the header at \(preview.frame.width)")
    }

    /// A surface opened with the cursor on `..` gets no caption at all, and a header that was never
    /// given one drew its style buttons with AppKit's own placeholder title, "Button".
    @Test("a header never given a caption shows no styles")
    func freshHeaderShowsNoStyles() throws {
        let hosted = try QuickViewCloseButtonTests.hosted(header: .pinned)
        hosted.preview.setCaption(nil)
        hosted.window.contentView?.layoutSubtreeIfNeeded()
        let header = try QuickViewCloseButtonTests.header(of: hosted.preview)
        let strip = try #require(header.subviews.lazy.compactMap { $0 as? NSStackView }.first)
        let shown = strip.arrangedSubviews.filter { !$0.isHidden }
        #expect(shown.isEmpty, "\(shown)")
    }
}
