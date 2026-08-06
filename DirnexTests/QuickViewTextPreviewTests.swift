import AppKit
import DirnexCore
import Testing

@testable import Dirnex

/// Quick View's text backend, on the app side. The decoding is `DirnexCore`'s (`TextPreview`) and is
/// tested there; what is left here is the pair of decisions that make a text file *selectable*:
/// which files take this route at all, and whether the surface lets the mouse reach the text view
/// instead of swallowing the click the way it must for everything Quick Look renders.
@Suite("Quick View text preview")
@MainActor
struct QuickViewTextPreviewTests {
    // MARK: - Routing

    @Test("plain text, markup and source code take the text backend")
    func routesTextFiles() throws {
        let tree = try TempDirectory()
        defer { tree.cleanup() }
        for name in ["notes.txt", "README.md", "config.json", "data.xml", "app.swift", "run.sh"] {
            let url = try tree.write(name, contents: "x")
            #expect(QuickViewPreviewView.isText(url), "\(name) should preview as text")
        }
    }

    /// Quick Look renders RTF as the formatted document it describes, and showing its markup
    /// instead would be a regression wearing a feature's clothes.
    ///
    /// HTML used to be in this list and is not any more (PLAN.md §M16) — but `isText` still refuses
    /// it, deliberately. HTML reaches the text view only through `show(_:style:)` in `.source`, so
    /// the rule "a file that is *only* ever text" keeps its single meaning.
    @Test("RTF stays with Quick Look, and HTML is still not plain text")
    func leavesRenderedDocumentsAlone() throws {
        let tree = try TempDirectory()
        defer { tree.cleanup() }
        for name in ["page.html", "letter.rtf"] {
            let url = try tree.write(name, contents: "x")
            #expect(!QuickViewPreviewView.isText(url), "\(name) should not be plain text")
        }
    }

    @Test("binaries and media are not text")
    func leavesNonTextAlone() throws {
        let tree = try TempDirectory()
        defer { tree.cleanup() }
        for name in ["photo.jpg", "paper.pdf", "archive.zip", "clip.mp4"] {
            let url = try tree.write(name, contents: "x")
            #expect(!QuickViewPreviewView.isText(url), "\(name) should not preview as text")
        }
    }

    // MARK: - The mouse

    /// The whole point of the backend. The surface deliberately answers `hitTest` with *itself* so
    /// clicks cannot fall through to the file table underneath — and a text view that never sees a
    /// mouseDown can never be dragged across, which is the state this replaced.
    @Test("a click over the text reaches the text view, not the surface")
    func textKeepsTheMouse() throws {
        let tree = try TempDirectory()
        defer { tree.cleanup() }
        let url = try tree.write("notes.txt", contents: "test 01\n")
        let preview = try Self.loaded(url)

        let hit = try #require(preview.hitTest(NSPoint(x: 200, y: 200)))
        #expect(hit !== preview)
        #expect(Self.enclosingTextView(of: hit) != nil)
    }

    /// The other half of the same invariant: everything Quick Look renders must still be swallowed,
    /// or the covered pane's cursor moves under the preview with nothing on screen to say why.
    ///
    /// RTF rather than the HTML this used to use — §M16 moved HTML to an in-process backend that
    /// *keeps* the mouse, so the file this test is written on has to be one Quick Look still draws.
    @Test("a click over a Quick Look preview is still swallowed by the surface")
    func quickLookKeepsBeingSwallowed() throws {
        let tree = try TempDirectory()
        defer { tree.cleanup() }
        let url = try tree.write("letter.rtf", contents: "{\\rtf1 hi}")
        let preview = try Self.loaded(url)

        #expect(preview.hitTest(NSPoint(x: 200, y: 200)) === preview)
    }

    /// In pane mode the preview covers the *inactive* pane and is a subview of it, so a text view
    /// the user clicked into puts first responder inside that pane's hierarchy. Left alone, every
    /// nil-targeted command then dispatches to the covered pane's controller — F5 copied a folder
    /// out of the pane nobody was looking at, silently and in the wrong direction. The surface hands
    /// the chain to the window instead, exactly as the full-size modes already do by construction.
    @Test("the surface hands unhandled commands to the window, not to the pane it covers")
    func chainSkipsTheCoveredPane() throws {
        let preview = QuickViewPreviewView(backingColor: .textBackgroundColor, header: .none)
        let controller = NSViewController()
        controller.view = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 400))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 400),
            styleMask: [.titled],
            backing: .buffered,
            defer: true
        )
        window.contentViewController = controller
        controller.view.addSubview(preview)

        // The controller *is* in the chain for its own view — that is the hazard being avoided.
        #expect(controller.view.nextResponder === controller)
        #expect(preview.nextResponder === window)
    }

    /// The Esc monitor stands aside for every `NSText` — a rename field editor owns Esc — and
    /// recognizes the preview's text view by type to make it the exception. Both halves of that
    /// have to hold or Esc stops closing a preview the user clicked into.
    @Test("the preview's text view is an NSText the Esc monitor can tell apart")
    func escapeMonitorCanIdentifyTheTextView() {
        let textView = QuickViewDocumentTextView()
        #expect(textView is NSText)
        #expect(!(NSTextView() is QuickViewDocumentTextView))
    }

    // MARK: - The keyboard

    /// What the mouse fix left behind: a click into the text to select it puts first responder on
    /// the text view, and from there the arrows are the text view's — so ← / → (and ↑ / ↓) stopped
    /// walking the file list in all three sizes, while the two-finger swipe went on working because
    /// it is a window monitor. The window's key monitor hands the arrows back to the file table, and
    /// this is the gate it asks first: is focus *inside* one of the preview surfaces.
    @Test("focus inside a preview is told apart from focus anywhere else")
    func focusInsideAPreviewIsRecognized() throws {
        let tree = try TempDirectory()
        defer { tree.cleanup() }
        let url = try tree.write("notes.txt", contents: "test 01\n")
        let preview = try Self.loaded(url)
        let other = QuickViewPreviewView(backingColor: .textBackgroundColor, header: .none)
        // Nested `#require` expands recursively and will not compile — hoist the hit out first.
        let hit = try #require(preview.hitTest(NSPoint(x: 200, y: 200)))
        let textView = try #require(Self.enclosingTextView(of: hit))

        #expect(QuickViewPreviewView.hasFocus(textView, among: [nil, preview]))
        // The two cases that must not be mistaken for it: another surface (a mode change hides one
        // without moving focus), and the file table itself, which owns the arrows already.
        #expect(!QuickViewPreviewView.hasFocus(textView, among: [nil, other]))
        #expect(!QuickViewPreviewView.hasFocus(FileTableView(), among: [preview, other]))
        #expect(!QuickViewPreviewView.hasFocus(nil, among: [preview, other]))
    }

    // MARK: - Helpers

    /// A preview surface with a window and a real frame, showing `url` — awaiting the backend's
    /// asynchronous read, which is what puts the text view on screen.
    static func loaded(
        _ url: URL,
        style: QuickViewRenderStyle = .source
    ) throws -> QuickViewPreviewView {
        let preview = QuickViewPreviewView(backingColor: .textBackgroundColor, header: .none)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 400),
            styleMask: [.titled],
            backing: .buffered,
            defer: true
        )
        window.contentView?.addSubview(preview)
        NSLayoutConstraint.activate([
            preview.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor),
            preview.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor),
            preview.topAnchor.constraint(equalTo: window.contentView!.topAnchor),
            preview.bottomAnchor.constraint(equalTo: window.contentView!.bottomAnchor)
        ])
        preview.show(url, style: style)
        // The read runs off the main actor; spin the run loop until the layout it triggers settles.
        for _ in 0..<20 {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
            window.contentView?.layoutSubtreeIfNeeded()
        }
        return preview
    }

    static func enclosingTextView(of view: NSView) -> NSTextView? {
        var candidate: NSView? = view
        while let current = candidate {
            if let textView = current as? NSTextView { return textView }
            candidate = current.superview
        }
        return nil
    }
}

/// A throwaway directory for the files these tests classify. Content type resolution reads the real
/// item, so the files have to exist. Internal rather than file-private: the HTML backend's suite
/// classifies files the same way and there is no reason for two of these.
struct TempDirectory {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("dirnex-quickview-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func write(_ name: String, contents: String) throws -> URL {
        let url = root.appendingPathComponent(name)
        try Data(contents.utf8).write(to: url)
        return url
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }
}
