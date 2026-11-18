import AppKit
import Testing

@testable import Dirnex

/// The ⌘K palette's keys (PLAN.md §M40 Slice 1): ⌘Return opens a place in a new tab, Return runs
/// the row, and the rest keep what they did.
///
/// The events are built by hand, since the palette reads them off `NSApp.currentEvent` and a test
/// cannot press a key. The first test pins the half that is the text system's rather than ours.
@Suite("Palette keys")
@MainActor
struct PaletteKeyTests {
    private func key(
        _ keyCode: UInt16,
        _ characters: String,
        _ flags: NSEvent.ModifierFlags = []
    ) -> NSEvent? {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: flags,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: keyCode
        )
    }

    private var commandReturn: NSEvent? { key(36, "\r", .command) }

    /// The text view a field editor is, recording the command each key turns into.
    private final class CommandRecorder: NSTextView {
        var commands: [Selector] = []
        override func doCommand(by selector: Selector) {
            commands.append(selector)
        }
    }

    @Test("the text system sends ⌘Return as noop:, and Return as insertNewline:")
    func textSystemSendsNoopForCommandReturn() throws {
        let recorder = CommandRecorder()
        recorder.isFieldEditor = true
        try recorder.interpretKeyEvents([#require(commandReturn), #require(key(36, "\r"))])
        #expect(
            recorder.commands == [
                PaletteKey.noop,
                #selector(NSResponder.insertNewline(_:))
            ]
        )
    }

    @Test("⌘Return and ⌘ with keypad Enter open in a new tab")
    func commandReturnOpensInANewTab() {
        let noop = PaletteKey.noop
        #expect(PaletteKey.action(for: noop, event: commandReturn) == .run(inNewTab: true))
        #expect(
            PaletteKey.action(for: noop, event: key(76, "\u{3}", [.command, .numericPad])) == .run(
                inNewTab: true
            )
        )
        #expect(
            PaletteKey.action(for: noop, event: key(36, "\r", [.command, .capsLock])) == .run(
                inNewTab: true
            )
        )
    }

    @Test("Return and ⇧Return run the row where it is")
    func returnRunsInPlace() {
        let newline = #selector(NSResponder.insertNewline(_:))
        #expect(PaletteKey.action(for: newline, event: key(36, "\r")) == .run(inNewTab: false))
        #expect(
            PaletteKey.action(for: newline, event: key(36, "\r", .shift)) == .run(inNewTab: false)
        )
        #expect(PaletteKey.action(for: newline, event: nil) == .run(inNewTab: false))
    }

    @Test(
        "a noop: that is not ⌘Return stays the field's: another ⌘ key, or ⌘ with a second modifier"
    )
    func otherNoopsStayTheFields() {
        let noop = PaletteKey.noop
        #expect(PaletteKey.action(for: noop, event: key(0, "a", .command)) == nil)
        #expect(PaletteKey.action(for: noop, event: key(36, "\r", [.command, .shift])) == nil)
        #expect(PaletteKey.action(for: noop, event: key(36, "\r", [.command, .option])) == nil)
        #expect(PaletteKey.action(for: noop, event: nil) == nil)
    }

    @Test("the arrows, Escape and anything else keep what they did")
    func otherKeysAreUnchanged() {
        #expect(PaletteKey.action(for: #selector(NSResponder.moveUp(_:)), event: nil) == .moveUp)
        #expect(PaletteKey.action(for: #selector(NSResponder.moveDown(_:)), event: nil) == .moveDown)
        #expect(
            PaletteKey.action(for: #selector(NSResponder.cancelOperation(_:)), event: nil) == .close
        )
        #expect(PaletteKey.action(for: #selector(NSResponder.insertTab(_:)), event: nil) == nil)
    }

    @Test("a ⌘-click opens in a new tab, and a click with any other modifier does not")
    func commandClick() {
        func click(_ flags: NSEvent.ModifierFlags) -> NSEvent? {
            NSEvent.mouseEvent(
                with: .leftMouseUp,
                location: .zero,
                modifierFlags: flags,
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                eventNumber: 0,
                clickCount: 1,
                pressure: 0
            )
        }
        #expect(PaletteKey.isCommandClick(click(.command)))
        #expect(!PaletteKey.isCommandClick(click([])))
        #expect(!PaletteKey.isCommandClick(click([.command, .shift])))
        #expect(!PaletteKey.isCommandClick(nil))
    }
}
