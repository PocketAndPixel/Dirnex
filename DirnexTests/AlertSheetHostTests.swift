import AppKit
import Testing

@testable import Dirnex

/// Where an alert hangs while an app-modal window is up (PLAN.md §M38 Slice 10).
///
/// A plain window cannot take a click while the Synchronize window is modal, so its alerts go on the
/// modal window. A compare or merge window can (`CompareWindow.worksWhenModal`), and its alerts stay
/// on it: hung on the modal window, the question ordered that window over the one it was about. Such
/// an alert takes its host's `worksWhenModal`, since a sheet is a window of its own and would
/// otherwise draw and drop every click.
@Suite("Alert sheet host")
@MainActor
struct AlertSheetHostTests {
    private static let frame = NSRect(x: 0, y: 0, width: 300, height: 200)

    private func plainWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: Self.frame,
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        return window
    }

    private func compareWindow() -> NSWindow {
        let window = CompareWindow(
            contentRect: Self.frame,
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        return window
    }

    /// Run `body` inside a modal session for `modal`, as the Synchronize window's.
    private func whileModal(_ modal: NSWindow, _ body: () -> Void) {
        let session = NSApp.beginModalSession(for: modal)
        defer {
            NSApp.endModalSession(session)
            modal.orderOut(nil)
        }
        body()
    }

    @Test("a compare window over a modal window hosts its own alert")
    func compareWindowHostsItsOwn() {
        let modal = plainWindow()
        let compare = compareWindow()
        compare.orderFront(nil)
        defer { compare.orderOut(nil) }

        whileModal(modal) {
            #expect(NSApp.modalWindow === modal)
            #expect(NSAlert.sheetHost(over: compare) === compare)
        }
    }

    @Test("a plain window's alert still goes on the modal window")
    func plainWindowDefersToModal() {
        let modal = plainWindow()
        let plain = plainWindow()
        plain.orderFront(nil)
        defer { plain.orderOut(nil) }

        whileModal(modal) {
            #expect(NSAlert.sheetHost(over: plain) === modal)
        }
    }

    @Test("a compare window that is not on screen leaves its alert to the modal window")
    func hiddenCompareWindowDefersToModal() {
        let modal = plainWindow()
        let compare = compareWindow()

        whileModal(modal) {
            #expect(NSAlert.sheetHost(over: compare) === modal)
        }
    }

    @Test("an alert hung on a compare window takes clicks while another window is modal")
    func alertOnCompareWindowWorksWhenModal() throws {
        let compare = compareWindow()
        compare.orderFront(nil)
        defer { compare.orderOut(nil) }
        let alert = NSAlert()
        let panel = try #require(alert.window as? NSPanel)
        #expect(!panel.worksWhenModal, "an alert's panel does not by default")

        alert.beginSheet(on: compare)
        defer { compare.endSheet(alert.window) }

        #expect(panel.worksWhenModal)
        #expect(compare.attachedSheet === alert.window)
    }

    @Test("an alert hung on a plain window is left as it was")
    func alertOnPlainWindowUnchanged() throws {
        let plain = plainWindow()
        plain.orderFront(nil)
        defer { plain.orderOut(nil) }
        let alert = NSAlert()
        let panel = try #require(alert.window as? NSPanel)

        alert.beginSheet(on: plain)
        defer { plain.endSheet(alert.window) }

        #expect(!panel.worksWhenModal)
    }

    @Test("with no modal window, a compare window hosts its own alert")
    func noModalWindow() {
        let compare = compareWindow()
        compare.orderFront(nil)
        defer { compare.orderOut(nil) }

        #expect(NSApp.modalWindow == nil)
        #expect(NSAlert.sheetHost(over: compare) === compare)
        #expect(NSAlert.sheetHost(over: nil) == nil)
    }
}
