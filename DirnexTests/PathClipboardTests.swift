import AppKit
import Testing

@testable import Dirnex

/// The text a "Copy Path" places on the pasteboard, shared by the pane's right-click menu and the
/// path bar's crumb menu. The *routing* (which path each surface copies — an entry, the `..`
/// parent, the pane directory, a crumb) is decided at those call sites; what is pinned here is the
/// shape they all funnel into: one path per line, order preserved.
@MainActor
@Suite("Copy Path clipboard")
struct PathClipboardTests {
    @Test("a single path is copied verbatim")
    func singlePath() {
        #expect(
            PathClipboard.text(for: ["/Users/oleg/jMeter/old-code"]) == "/Users/oleg/jMeter/old-code"
        )
    }

    @Test("multiple paths are newline-joined in order")
    func multiplePaths() {
        let paths = ["/Users/oleg/a", "/Users/oleg/b", "/Users/oleg/c"]
        #expect(PathClipboard.text(for: paths) == "/Users/oleg/a\n/Users/oleg/b\n/Users/oleg/c")
    }

    @Test("no paths yields an empty string rather than a crash")
    func noPaths() {
        #expect(PathClipboard.text(for: []).isEmpty)
    }

    @Test("copy writes the joined text onto the given pasteboard, replacing what was there")
    func copyReplacesContents() {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("com.dirnex.tests.copypath"))
        pasteboard.clearContents()
        pasteboard.setString("stale", forType: .string)

        PathClipboard.copy(["/tmp/one", "/tmp/two"], to: pasteboard)

        #expect(pasteboard.string(forType: .string) == "/tmp/one\n/tmp/two")
    }
}
