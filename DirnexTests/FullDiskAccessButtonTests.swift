import AppKit
import DirnexCore
import Testing

@testable import Dirnex

/// An alert that says Dirnex may need Full Disk Access carries the button that opens it (asked for
/// 2026-10-30), and every other alert is left as it was.
///
/// Built and read, never presented: presenting holds the test host's main actor for ~0.3 s each way
/// and has failed neighbouring timing suites (docs/NOTES.md ▸ Alerts, sheets and dialogs). That the
/// handed-on click really closes a sheet was probed in a throwaway app and seen in the running one.
@Suite("Full Disk Access button")
@MainActor
struct FullDiskAccessButtonTests {
    private static let escape = NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
        context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
        isARepeat: false, keyCode: 53
    )

    private static let local = VFSPath.local("/Users/someone/Library/Mail")

    /// A report the way the presenters build one: the text, a lone OK, Escape, then the offer.
    private func report(_ text: String, open: @escaping @MainActor () -> Void = {}) -> NSAlert {
        let alert = NSAlert()
        alert.informativeText = text
        alert.addButton(withTitle: String(localized: "OK", comment: "Dismiss button."))
        alert.enableEscapeToCancel()
        alert.offerFullDiskAccessSettings(open: open)
        return alert
    }

    private func opener(in alert: NSAlert) -> FullDiskAccessSettingsOpener? {
        alert.window.contentView?.subviews.compactMap { $0 as? FullDiskAccessSettingsOpener }.first
    }

    private func escapeButton(in alert: NSAlert) throws -> NSButton? {
        let catcher = alert.window.contentView?.subviews.compactMap { $0 as? AlertKeyCatcher }.first
        return catcher?.button(for: try #require(Self.escape))
    }

    @Test("the Full Disk Access sentence gets Open System Settings after OK")
    func adviceGetsTheButton() {
        let alert = report(VFSErrorText.sentence(for: VFSError.permissionDenied(Self.local)))
        #expect(alert.buttons.count == 2)
        #expect(alert.buttons.last?.title == String(localized: "Open System Settings"))
        let second = NSApplication.ModalResponse.alertSecondButtonReturn
        #expect(alert.buttons.last?.tag == second.rawValue)
    }

    /// The button goes last, where an alert's focus lands and Escape goes by default, so both have
    /// to be put back on OK or Space and Escape would open System Settings.
    @Test("Return, Escape and the focus stay on OK")
    func keysStayOnOK() throws {
        let alert = report(VFSErrorText.fullDiskAccessAdvice)
        let ok = try #require(alert.buttons.first)
        #expect(ok.keyEquivalent == "\r")
        #expect(try escapeButton(in: alert) === ok)
        #expect(alert.window.initialFirstResponder === ok)
        #expect(alert.buttons.last?.keyEquivalent.isEmpty == true)
    }

    /// The undo report ends a line with the sentence rather than showing it alone.
    @Test("the sentence at the end of a longer line still gets it")
    func embeddedAdvice() {
        let alert = report("3 items couldn’t be put back: " + VFSErrorText.fullDiskAccessAdvice)
        #expect(alert.buttons.count == 2)
    }

    /// The refusals the grant cannot lift say so in sentences of their own, and must not be offered
    /// a switch that cannot help them.
    @Test("other sentences, including the item-permissions and locked ones, get no button")
    func otherTextIsLeftAlone() {
        let remote = VFSPath(
            backend: VFSBackendID.sftp(SFTPLocation(host: "srv", username: "oleg")), path: "/home/x"
        )
        let errors: [VFSError] = [
            .permissionDenied(Self.local, refusedBy: .itemPermissions),
            .permissionDenied(Self.local, refusedBy: .locked(Self.local)),
            .permissionDenied(remote),
            .notFound(Self.local)
        ]
        for text in errors.map({ VFSErrorText.sentence(for: $0) }) {
            let alert = report(text)
            #expect(alert.buttons.count == 1)
            #expect(opener(in: alert) == nil)
        }
    }

    /// The click opens the pane and is then handed to the alert's own action for the button, the
    /// one OK has too, which is what closes a sheet or a modal.
    @Test("a click opens the pane and hands the click on to the alert")
    func clickOpensThenCloses() throws {
        var opened = 0
        let alert = report(VFSErrorText.fullDiskAccessAdvice) { opened += 1 }
        let ok = try #require(alert.buttons.first)
        let dismissal = try #require(opener(in: alert)?.dismissal)
        #expect(dismissal.target === ok.target)
        #expect(dismissal.action == ok.action)
        #expect(alert.buttons.last?.target === opener(in: alert))
        // Pressed with the hand-on cleared, since the alert is not on screen to close.
        opener(in: alert)?.dismissal = nil
        alert.buttons.last?.performClick(nil)
        #expect(opened == 1)
    }

    /// `ErrorDialog`'s shape: the copy waits on Retry, Skip or Abort, so the dialog stays up after
    /// the pane opens, and Abort keeps Escape and the focus.
    @Test("a dialog that must stay up keeps its safe button and is not closed")
    func staysUpForTheCopy() throws {
        var opened = 0
        let alert = NSAlert()
        alert.informativeText = VFSErrorText.fullDiskAccessAdvice
        alert.addButton(withTitle: String(localized: "Retry"))
        alert.addButton(withTitle: String(localized: "Skip"))
        alert.addButton(withTitle: String(localized: "Abort"))
        alert.enableEscapeToCancel()
        alert.offerFullDiskAccessSettings(closesAlert: false) { opened += 1 }

        let abort = alert.buttons[2]
        #expect(alert.buttons.count == 4)
        #expect(try escapeButton(in: alert) === abort)
        #expect(alert.window.initialFirstResponder === abort)
        #expect(alert.buttons[0].keyEquivalent == "\r")
        #expect(opener(in: alert)?.dismissal == nil)
        alert.buttons.last?.performClick(nil)
        #expect(opened == 1)
    }
}
