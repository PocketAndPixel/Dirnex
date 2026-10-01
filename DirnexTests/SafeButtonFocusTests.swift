import AppKit
import DirnexCore
import Testing

@testable import Dirnex

/// Space presses the button that has the keyboard focus, and an `NSAlert` opens with the focus on its
/// **last** button (measured 2026-09-30 in the running app with Full Keyboard Access off —
/// docs/NOTES.md ▸ AppKit). An alert whose safe choice comes first therefore has to hand the focus to
/// it, or Space picks the very action Return and Escape were kept away from. On the changed host key
/// alert, one Space trusted the new key and connected.
///
/// Each alert is checked **after it is presented**, because presenting is what undoes the fix on a
/// critical alert with a long text: it sets `initialFirstResponder` to the last button over whatever
/// was set before, and a test that only read the alert as built passed against exactly that bug. The
/// three trust alerts are presented by their own `confirm…` methods, so the call that restores the
/// focus is under test too.
///
/// **Presenting is expensive to the neighbours, so this does as little of it as it can.** In the test
/// host `beginSheetModal` holds the main actor ~0.29 s and `endSheet` ~0.27 s, every time, animation
/// behavior or not; four presentations running together failed a main-actor timing suite in 3 of 3
/// full runs (`PanelPassiveRefreshTests`, `EditFileRouteTests`), and 0 of 2 with this suite skipped.
/// So the presentations are serialized, over bare windows rather than a live pane (docs/NOTES.md), and
/// the informational Full Disk Access alert, which keeps the focus it is built with, isn't presented.
@Suite("Alerts whose safe button comes first start focused on it", .serialized)
@MainActor
struct SafeButtonFocusTests {
    private static let certificate = FTPCertificate(
        subject: "CN=nas.local", issuer: "CN=nas.local", notBefore: "Sep 30 00:00:00 2026 GMT",
        notAfter: "Sep 30 00:00:00 2027 GMT", der: Data(repeating: 7, count: 64)
    )

    private static let escape = NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
        context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
        isARepeat: false, keyCode: 53
    )

    /// A window for a sheet to land on, never closed for the reason `windowedPane()` gives.
    private func bareWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 320),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        RetainedWindows.all.append(window)
        return window
    }

    /// The sheet a `confirm…` method has put on `window`. Polled with `Task.sleep`, since the method
    /// presents from a task that only runs once the test suspends.
    private func sheet(on window: NSWindow) async throws -> NSWindow {
        for _ in 0..<100 where window.attachedSheet == nil {
            try await Task.sleep(for: .milliseconds(20))
        }
        return try #require(window.attachedSheet)
    }

    /// The focus starts on the first button, the one Escape answers too. `NSAlert` tags each button
    /// with the response it returns, which names it without the title a translation would change.
    @discardableResult
    private func expectFocusAndEscapeOnFirstButton(_ sheet: NSWindow) throws -> NSButton {
        let focused = try #require(sheet.initialFirstResponder as? NSButton)
        #expect(focused.tag == NSApplication.ModalResponse.alertFirstButtonReturn.rawValue)
        let catcher = sheet.contentView?.subviews.compactMap { $0 as? AlertKeyCatcher }.first
        #expect(catcher?.button(for: try #require(Self.escape)) === focused)
        return focused
    }

    @Test("a changed SSH host key: Cancel, not Trust New Key & Connect")
    func hostKeyChange() async throws {
        let window = bareWindow()
        let answer = Task {
            await PanelViewController.confirmHostKeyChange(
                location: SFTPLocation(host: "nas.local", username: "oleg"),
                change: SFTPHostKeyChange(
                    host: "nas.local", keyType: "ED25519", fingerprint: "SHA256:probe",
                    knownHostsFile: "~/.ssh/known_hosts", line: 3
                ),
                over: window
            )
        }
        let sheet = try await sheet(on: window)
        let focused = try expectFocusAndEscapeOnFirstButton(sheet)
        #expect(sheet.firstResponder === focused)
        window.endSheet(sheet, returnCode: .alertFirstButtonReturn)
        #expect(await answer.value == false)
    }

    @Test("an FTPS certificate seen for the first time: Cancel, not Trust & Connect")
    func certificateTrust() async throws {
        let window = bareWindow()
        let answer = Task {
            await PanelViewController.confirmCertificateTrust(
                location: FTPLocation(host: "nas.local", username: "oleg"),
                certificate: Self.certificate,
                over: window
            )
        }
        let sheet = try await sheet(on: window)
        let focused = try expectFocusAndEscapeOnFirstButton(sheet)
        #expect(sheet.firstResponder === focused)
        window.endSheet(sheet, returnCode: .alertFirstButtonReturn)
        #expect(await answer.value == false)
    }

    @Test("a changed FTPS certificate: Cancel, not Trust New Certificate & Connect")
    func certificateChange() async throws {
        let window = bareWindow()
        let answer = Task {
            await PanelViewController.confirmCertificateChange(
                location: FTPLocation(host: "nas.local", username: "oleg"),
                certificate: Self.certificate,
                over: window
            )
        }
        let sheet = try await sheet(on: window)
        let focused = try expectFocusAndEscapeOnFirstButton(sheet)
        #expect(sheet.firstResponder === focused)
        window.endSheet(sheet, returnCode: .alertFirstButtonReturn)
        #expect(await answer.value == false)
    }

    /// Read as built, the way `AppUpdaterCoverageTests.noticeAlert` reads the update notice: presenting
    /// resets `initialFirstResponder` only on a critical alert, and this one is informational (the
    /// running app kept the focus on OK).
    @Test("Full Disk Access already granted: OK, not Open System Settings")
    func fullDiskAccessGranted() throws {
        let alert = FullDiskAccessOnboarding.alreadyGrantedAlert()
        #expect(alert.alertStyle == .informational)
        #expect(alert.buttons.count == 2)
        #expect(alert.window.initialFirstResponder === alert.buttons.first)
        let catcher = alert.window.contentView?.subviews.compactMap { $0 as? AlertKeyCatcher }.first
        #expect(catcher?.button(for: try #require(Self.escape)) === alert.buttons.first)
    }
}
