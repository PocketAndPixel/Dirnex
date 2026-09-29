import AppKit
import DirnexCore
import Testing

@testable import Dirnex

/// The license reminder's sheet (PLAN.md §M29 Slice 4): Escape and Return leave it up, OK closes it,
/// and Buy is never the default button.
@Suite("License reminder sheet")
@MainActor
struct LicenseReminderSheetTests {
    private static let escape: UInt16 = 53
    private static let returnKey: UInt16 = 36
    private static let keypadEnter: UInt16 = 76
    private static let space: UInt16 = 49

    private func parentWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.orderFront(nil)
        return window
    }

    /// A sheet on screen over a fresh window, and the choices it reports.
    private struct Presented {
        let sheet: LicenseReminderSheet
        let parent: NSWindow
        let log: ChoiceLog
    }

    private func presented(_ variant: LicenseReminderVariant = .buy) async throws -> Presented {
        let parent = parentWindow()
        let sheet = LicenseReminderSheet(variant: variant)
        let log = ChoiceLog()
        sheet.onChoice = { log.choices.append($0) }
        sheet.present(over: parent)
        try await settleUntil { parent.attachedSheet === sheet.window }
        return Presented(sheet: sheet, parent: parent, log: log)
    }

    private func press(_ keyCode: UInt16, _ characters: String, in window: NSWindow) throws {
        let event = try #require(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: keyCode
        ))
        // The order `NSApplication.sendEvent` uses for a key window: key equivalents first, then the
        // window. `NSWindow.sendEvent` alone skips the first step, and the negative control below
        // failed until this matched it.
        if !window.performKeyEquivalent(with: event) {
            window.sendEvent(event)
        }
    }

    @Test("Escape, Return and keypad Enter leave the sheet up and choose nothing")
    func inertKeys() async throws {
        let presented = try await presented()
        let (sheet, parent, log) = (presented.sheet, presented.parent, presented.log)
        let window = try #require(sheet.window)
        try press(Self.escape, "\u{1b}", in: window)
        try press(Self.returnKey, "\r", in: window)
        try press(Self.keypadEnter, "\u{3}", in: window)
        window.cancelOperation(nil)
        try await Task.sleep(for: .milliseconds(200))
        #expect(parent.attachedSheet === window)
        #expect(log.choices.isEmpty)
        sheet.okButton.performClick(nil)
        parent.close()
    }

    @Test("negative control: the same Escape does close it once a button answers Escape")
    func escapeReachesTheSheet() async throws {
        // Without this the test above could pass by the event never arriving at all.
        let presented = try await presented()
        let (sheet, parent, log) = (presented.sheet, presented.parent, presented.log)
        let window = try #require(sheet.window)
        sheet.okButton.keyEquivalent = "\u{1b}"
        try press(Self.escape, "\u{1b}", in: window)
        try await settleUntil { parent.attachedSheet == nil }
        #expect(log.choices == [.ok])
        parent.close()
    }

    @Test("OK closes the sheet and says so")
    func okCloses() async throws {
        let presented = try await presented()
        let (sheet, parent, log) = (presented.sheet, presented.parent, presented.log)
        sheet.okButton.performClick(nil)
        try await settleUntil { parent.attachedSheet == nil }
        #expect(log.choices == [.ok])
        parent.close()
    }

    @Test("no button answers Return or Escape, so Buy is never the default")
    func noKeyEquivalents() async throws {
        let presented = try await presented()
        let (sheet, parent) = (presented.sheet, presented.parent)
        for button in [sheet.buyButton, sheet.enterLicenseButton, sheet.okButton] {
            #expect(button.keyEquivalent.isEmpty, "\(button.title)")
        }
        #expect(sheet.window?.defaultButtonCell == nil)
        sheet.okButton.performClick(nil)
        parent.close()
    }

    @Test(
        "nothing has focus when it opens, Tab reaches every button, and Space presses the focused one"
    )
    func keyboardReachable() async throws {
        let presented = try await presented()
        let (sheet, parent, log) = (presented.sheet, presented.parent, presented.log)
        let window = try #require(sheet.window)
        #expect(!(window.firstResponder is NSButton))
        for button in [sheet.buyButton, sheet.enterLicenseButton, sheet.okButton] {
            #expect(button.canBecomeKeyView, "\(button.title)")
        }
        window.makeFirstResponder(sheet.okButton)
        try press(Self.space, " ", in: window)
        try await settleUntil { parent.attachedSheet == nil }
        #expect(log.choices == [.ok])
        parent.close()
    }

    @Test("each button reports its own choice")
    func choices() async throws {
        for (button, expected) in [
            (\LicenseReminderSheet.buyButton, LicenseReminderSheet.Choice.buy),
            (\LicenseReminderSheet.enterLicenseButton, .enterLicense)
        ] {
            let presented = try await presented()
            let (sheet, parent, log) = (presented.sheet, presented.parent, presented.log)
            sheet[keyPath: button].performClick(nil)
            try await settleUntil { parent.attachedSheet == nil }
            #expect(log.choices == [expected])
            parent.close()
        }
    }

    @Test("without a key it asks to buy; with an ended key it asks to renew and names the day")
    func variants() throws {
        let until = try #require(LicenseDay("2027-03-12"))
        let buy = LicenseReminderSheet(variant: .buy)
        let renew = LicenseReminderSheet(variant: .renew(until: until))
        #expect(buy.buyButton.title == String(localized: "Buy a License…"))
        #expect(renew.buyButton.title != buy.buyButton.title)
        #expect(renew.bodyLabel.stringValue.contains(until.displayText))
        #expect(!buy.bodyLabel.stringValue.contains(until.displayText))
        #expect(buy.titleLabel.stringValue == renew.titleLabel.stringValue)
    }
}

@MainActor
final class ChoiceLog {
    var choices: [LicenseReminderSheet.Choice] = []
}
