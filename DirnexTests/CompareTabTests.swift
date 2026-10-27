import AppKit
import DirnexCore
import Testing

@testable import Dirnex

/// Press Tab, or ⇧Tab, in `window`: a real key-down sent through it, so it takes the path a pressed
/// key does, the text view's `insertTab:` or a control's own key handling, each ending in the key
/// view loop. Shared with `MergeTabTests`.
@MainActor
func pressTab(in window: NSWindow, backwards: Bool = false) {
    let characters = backwards ? "\u{19}" : "\t"
    let event = NSEvent.keyEvent(
        with: .keyDown,
        location: .zero,
        modifierFlags: backwards ? .shift : [],
        timestamp: 0,
        windowNumber: window.windowNumber,
        context: nil,
        characters: characters,
        charactersIgnoringModifiers: characters,
        isARepeat: false,
        keyCode: 48
    )
    if let event { window.sendEvent(event) }
}

/// Tab in the compare window: the left pane, the right pane, then the toolbar's controls and round
/// again, and the mark on the pane F4 and Find act on.
///
/// Until this, the loop held the two panes only, and a toolbar control that had the keyboard kept it.
@Suite("Compare window Tab")
@MainActor
struct CompareTabTests {
    /// A window on screen whose sides both take copies, so Copy is enabled and joins the loop.
    private func rig() throws -> CompareSaveRig {
        KeyboardReachableControls.install()
        let rig = try CompareSaveRig("a\nB\nc\n", "a\nb\nc\n")
        let window = try #require(rig.controller.window)
        window.animationBehavior = .none
        window.orderFrontRegardless()
        return rig
    }

    private func close(_ rig: CompareSaveRig) {
        rig.controller.window?.orderOut(nil)
        rig.cleanup()
    }

    /// What holds the keyboard, by name, so a wrong stop says which it is.
    private func holder(_ controller: CompareWindowController) -> String {
        let toolbar = controller.toolbar
        let named: [(NSResponder, String)] = [
            (controller.leftPane.textView, "left pane"),
            (controller.rightPane.textView, "right pane"),
            (toolbar.navigation, "changes"),
            (toolbar.copy, "copy"),
            (toolbar.swap, "swap"),
            (toolbar.whitespace, "whitespace"),
            (toolbar.ignoresCase, "ignore case"),
            (toolbar.ignoresLineEndings, "ignore line endings")
        ]
        let responder = controller.window?.firstResponder
        return named.first { $0.0 === responder }?.1 ?? responder.map { "\(type(of: $0))" } ?? "nothing"
    }

    @Test(
        "Tab goes from the left pane to the right, along the toolbar and back, and ⇧Tab the other way"
    )
    func tabGoesRound() throws {
        let rig = try rig()
        defer { close(rig) }
        let controller = rig.controller
        let window = try #require(controller.window)
        #expect(controller.canCopy(to: .right))
        #expect(window.makeFirstResponder(controller.leftPane.textView))

        let stops = [
            "right pane",
            "changes", "copy", "swap", "whitespace", "ignore case", "ignore line endings",
            "left pane"
        ]
        var forwards: [String] = []
        for _ in stops {
            pressTab(in: window)
            forwards.append(holder(controller))
        }
        #expect(forwards == stops)

        var backwards: [String] = []
        for _ in stops {
            pressTab(in: window, backwards: true)
            backwards.append(holder(controller))
        }
        #expect(backwards == Array(stops.dropLast().reversed()) + ["left pane"])
    }

    @Test("Copy is passed over while neither side takes a copy")
    func disabledCopyIsPassedOver() throws {
        let rig = try rig()
        defer { close(rig) }
        let controller = rig.controller
        let window = try #require(controller.window)
        controller.toolbar.enableCopy(toLeft: false, toRight: false)
        #expect(window.makeFirstResponder(controller.toolbar.navigation))
        pressTab(in: window)
        #expect(holder(controller) == "swap")
    }

    @Test("the pane holding the keyboard is marked, and keeps the mark while the toolbar has it")
    func markFollowsTheKeyboard() throws {
        let rig = try rig()
        defer { close(rig) }
        let controller = rig.controller
        let window = try #require(controller.window)
        let accent = AppPreferences.shared.palette.resolvedAccent
        #expect(controller.leftPane.holdsKeyboard, "the window opens with the left pane's keyboard")
        #expect(controller.leftPane.nameLabel.textColor == accent)
        #expect(controller.rightPane.nameLabel.textColor == .labelColor)

        #expect(window.makeFirstResponder(controller.leftPane.textView))
        pressTab(in: window)
        #expect(controller.rightPane.holdsKeyboard)
        #expect(!controller.leftPane.holdsKeyboard)
        #expect(controller.rightPane.nameLabel.textColor == accent)
        #expect(controller.leftPane.nameLabel.textColor == .labelColor)

        pressTab(in: window)
        #expect(holder(controller) == "changes")
        #expect(controller.rightPane.holdsKeyboard, "the toolbar takes the keyboard, not the mark")
        #expect(controller.focusedPane === controller.rightPane)

        // A click in a pane takes the keyboard the same way.
        #expect(window.makeFirstResponder(controller.leftPane.textView))
        #expect(controller.leftPane.holdsKeyboard)
        #expect(!controller.rightPane.holdsKeyboard)
    }
}
