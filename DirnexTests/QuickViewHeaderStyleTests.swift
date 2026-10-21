import AppKit
import Testing

@testable import Dirnex

/// The header's "1 Source · 2 Table" as buttons (2026-10-20): a click picks a style, as its digit does.
@MainActor
@Suite("Quick View ▸ the header's styles are clickable")
struct QuickViewHeaderStyleTests {
    @Test("a click on either style hands that style to the surface's owner")
    func clickPicksTheStyle() throws {
        let hosted = try QuickViewCloseButtonTests.hosted(header: .pinned)
        var picks: [QuickViewRenderStyle] = []
        hosted.preview.onPickStyle = { picks.append($0) }
        hosted.preview.setCaption(Self.tableCaption(showing: .source))

        let header = try QuickViewCloseButtonTests.header(of: hosted.preview)
        try Self.button(.rendered, in: header).performClick(nil)
        try Self.button(.source, in: header).performClick(nil)
        #expect(picks == [.rendered, .source])
    }

    /// `performClick` goes straight to the action, as computer use's press did in the live run, so
    /// neither says a pointer gets there. This one asks the window what is under the pointer — which
    /// runs the surface's own hit test, the one that swallows clicks meant for the panes underneath —
    /// and gives the press to that, with the release queued for the button's tracking loop.
    /// `NSWindow.sendEvent` is not used because in the test host it spends a press on activating the
    /// window (docs/NOTES.md ▸ Testing). The window has to be on screen: off screen the button's loop
    /// took the queued release and sent no action (measured 2026-10-20), a test that fails for the
    /// harness rather than the code. Negative control: with the header off the surface's list of
    /// views that keep the mouse, the press lands on the surface and this fails.
    @Test("a pointer click on a style reaches its button through the surface")
    func pointerClickPicksTheStyle() throws {
        let hosted = try QuickViewCloseButtonTests.hosted(header: .pinned)
        var picks: [QuickViewRenderStyle] = []
        hosted.preview.onPickStyle = { picks.append($0) }
        hosted.preview.setCaption(Self.tableCaption(showing: .rendered))
        hosted.window.contentView?.layoutSubtreeIfNeeded()
        let header = try QuickViewCloseButtonTests.header(of: hosted.preview)
        let button = try Self.button(.source, in: header)
        let content = try #require(hosted.window.contentView)
        let point = button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil)

        hosted.window.orderFront(nil)
        defer { hosted.window.orderOut(nil) }
        let hit = try #require(content.hitTest(content.convert(point, from: nil)))
        #expect(hit === button, "the press would land on \(hit)")
        NSApp.postEvent(
            try Self.mouseEvent(.leftMouseUp, at: point, in: hosted.window),
            atStart: true
        )
        hit.mouseDown(with: try Self.mouseEvent(.leftMouseDown, at: point, in: hosted.window))
        #expect(picks == [.source])
    }

    /// In ⌃Q the surface sits in the *covered* pane, which does not own the preference, so the click
    /// has to reach the window through the pane's host.
    @Test("in the pane-size surface it asks the host for the style")
    func paneSurfaceAsksTheHost() throws {
        let hosted = windowedPane()
        hosted.pane.showQuickViewPreview(
            of: nil,
            style: .rendered,
            caption: Self.tableCaption(showing: .rendered)
        )
        hosted.pane.view.layoutSubtreeIfNeeded()

        let preview = try #require(hosted.pane.quickViewPreview)
        let header = try QuickViewCloseButtonTests.header(of: preview)
        try Self.button(.source, in: header).performClick(nil)
        #expect(hosted.host.quickViewStylePicks == [.source])
    }

    @Test("each button reads its digit and name, the current style bright and the other dimmed")
    func titlesAndColors() throws {
        let hosted = try QuickViewCloseButtonTests.hosted(header: .pinned)
        hosted.preview.setCaption(Self.tableCaption(showing: .rendered))
        let header = try QuickViewCloseButtonTests.header(of: hosted.preview)

        for style in QuickViewRenderStyle.allCases {
            let button = try Self.button(style, in: header)
            #expect(button.title == "\(style.digit) \(style.headerLabel(for: .table))")
            #expect(!button.isHiddenOrHasHiddenAncestor)
            let color = button.attributedTitle.attribute(
                .foregroundColor,
                at: 0,
                effectiveRange: nil
            )
            let expected: NSColor = style == .rendered ? .labelColor : .secondaryLabelColor
            #expect(color as? NSColor == expected, "\(style) drawn in \(String(describing: color))")
        }
    }

    /// The buttons replaced one label, and a plain button pads its title about 2.5 pt a side, which
    /// pushed the first style right of the 12 pt margin the position readout keeps on the other side
    /// and opened a gap around the dot. The inset subclass is what holds the text where the label drew
    /// it. Measured on the titles rather than the frames, since a frame that starts at 12 says nothing
    /// about where the button centers its text inside it: a plain button passes that and fails this.
    @Test("the styles' text sits where the one label drew it")
    func textSitsWhereTheLabelDrewIt() throws {
        let hosted = try QuickViewCloseButtonTests.hosted(header: .pinned)
        hosted.preview.setCaption(Self.tableCaption(showing: .source))
        hosted.window.contentView?.layoutSubtreeIfNeeded()
        let header = try QuickViewCloseButtonTests.header(of: hosted.preview)

        let sourceButton = try Self.button(.source, in: header)
        let renderedButton = try Self.button(.rendered, in: header)
        let source = Self.titleRect(of: sourceButton, in: header)
        let rendered = Self.titleRect(of: renderedButton, in: header)
        let whole = NSAttributedString(
            string: "\(sourceButton.title) · \(renderedButton.title)",
            attributes: [.font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)]
        )
        #expect(abs(source.minX - 12) <= 1, "first style's text starts at \(source.minX)")
        #expect(
            abs(rendered.maxX - source.minX - whole.size().width) <= 2,
            "the run is \(rendered.maxX - source.minX) wide, the label's was \(whole.size().width)"
        )
        #expect(abs(rendered.midY - header.bounds.midY) <= 1)
    }

    /// The narrowness control for the strip: a file with one honest rendering shows no styles, and
    /// the strip takes no room from a long name.
    @Test("a file with one rendering shows no styles and leaves the strip empty")
    func singleRenderingHidesTheStrip() throws {
        let hosted = try QuickViewCloseButtonTests.hosted(header: .pinned)
        hosted.preview.setCaption(Self.tableCaption(showing: .rendered))
        hosted.preview.setCaption(QuickViewCaption(name: "notes.txt", position: 1, count: 3))
        hosted.window.contentView?.layoutSubtreeIfNeeded()
        let header = try QuickViewCloseButtonTests.header(of: hosted.preview)

        let allHidden = header.styleButtons.allSatisfy(\.isHidden)
        #expect(allHidden)
        let strip = try #require(header.subviews.lazy.compactMap { $0 as? NSStackView }.first)
        #expect(strip.fittingSize.width == 0)
    }

    @Test("the no-JavaScript mark follows a rendered page only")
    func noJavaScriptMark() throws {
        let hosted = try QuickViewCloseButtonTests.hosted(header: .pinned)
        let header = try QuickViewCloseButtonTests.header(of: hosted.preview)
        func markShown() -> Bool {
            header.subviews.lazy.compactMap { $0 as? NSStackView }.first?.arrangedSubviews
                .compactMap { $0 as? NSTextField }
                .contains { $0.stringValue.contains(QuickViewHeaderView.noJavaScriptMark) && !$0.isHidden }
                == true
        }
        var caption = QuickViewCaption(name: "index.html", position: 1, count: 1, style: .rendered)
        caption.javaScriptDisabled = true
        hosted.preview.setCaption(caption)
        #expect(markShown())
        caption.style = .source
        hosted.preview.setCaption(caption)
        #expect(!markShown(), "no script runs in source either way")
        caption.style = .rendered
        caption.javaScriptDisabled = false
        hosted.preview.setCaption(caption)
        #expect(!markShown())
    }

    /// The close button's rule, now the whole header's: a faded full-screen header must not switch
    /// the style from a click on a strip of photograph. The shown header is the control.
    @Test("a faded floating header keeps the styles out of reach, a shown one does not")
    func fadedHeaderRefusesTheClick() throws {
        let floating = try QuickViewCloseButtonTests.hosted(header: .floating)
        floating.preview.setCaption(Self.tableCaption(showing: .rendered))
        floating.window.contentView?.layoutSubtreeIfNeeded()
        let header = try QuickViewCloseButtonTests.header(of: floating.preview)
        let button = try Self.button(.source, in: header)
        let point = button.convert(
            NSPoint(x: button.bounds.midX, y: button.bounds.midY),
            to: floating.preview.superview
        )

        #expect(header.alphaValue == 0, "a floating header starts faded out")
        #expect(floating.preview.hitTest(point) === header)
        header.alphaValue = 1
        #expect(floating.preview.hitTest(point) === button)
    }

    @Test("the buttons never take focus from the file list")
    func refuseFocus() throws {
        let hosted = try QuickViewCloseButtonTests.hosted(header: .pinned)
        let header = try QuickViewCloseButtonTests.header(of: hosted.preview)
        let allRefuse = header.styleButtons.allSatisfy(\.refusesFirstResponder)
        #expect(allRefuse)
    }

    // MARK: - Helpers

    static func tableCaption(showing style: QuickViewRenderStyle) -> QuickViewCaption {
        QuickViewCaption(name: "people.csv", position: 2, count: 5, style: style, styleKind: .table)
    }

    static func mouseEvent(
        _ type: NSEvent.EventType,
        at point: NSPoint,
        in window: NSWindow
    ) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(
            with: type,
            location: point,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: type == .leftMouseDown ? 1 : 0
        ))
    }

    static func button(_ style: QuickViewRenderStyle, in header: QuickViewHeaderView) throws -> NSButton {
        try #require(header.styleButtons.first { $0.identifier?.rawValue == style.rawValue })
    }

    /// Where `button` draws its title, in the header's coordinates: a borderless button centers the
    /// text in its frame.
    static func titleRect(of button: NSButton, in header: QuickViewHeaderView) -> NSRect {
        let size = button.attributedTitle.size()
        let text = NSRect(
            x: button.bounds.midX - size.width / 2,
            y: button.bounds.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
        return button.convert(text, to: header)
    }
}
