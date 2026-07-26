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

    /// Quick Look renders these as the *document* they describe — a rendered page, formatted text —
    /// and showing their markup instead would be a regression wearing a feature's clothes.
    @Test("HTML and RTF stay with Quick Look")
    func leavesRenderedDocumentsAlone() throws {
        let tree = try TempDirectory()
        defer { tree.cleanup() }
        for name in ["page.html", "letter.rtf"] {
            let url = try tree.write(name, contents: "x")
            #expect(!QuickViewPreviewView.isText(url), "\(name) should stay with Quick Look")
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
    @Test("a click over a Quick Look preview is still swallowed by the surface")
    func quickLookKeepsBeingSwallowed() throws {
        let tree = try TempDirectory()
        defer { tree.cleanup() }
        let url = try tree.write("page.html", contents: "<p>hi</p>")
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

    // MARK: - Helpers

    /// A preview surface with a window and a real frame, showing `url` — awaiting the backend's
    /// asynchronous read, which is what puts the text view on screen.
    private static func loaded(_ url: URL) throws -> QuickViewPreviewView {
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
        preview.show(url)
        // The read runs off the main actor; spin the run loop until the layout it triggers settles.
        for _ in 0..<20 {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
            window.contentView?.layoutSubtreeIfNeeded()
        }
        return preview
    }

    private static func enclosingTextView(of view: NSView) -> NSTextView? {
        var candidate: NSView? = view
        while let current = candidate {
            if let textView = current as? NSTextView { return textView }
            candidate = current.superview
        }
        return nil
    }
}

/// A throwaway directory for the files these tests classify. Content type resolution reads the real
/// item, so the files have to exist.
private struct TempDirectory {
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
