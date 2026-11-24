import AppKit
import DirnexCore
import SwiftUI
import Testing

@testable import Dirnex

/// `SettingsPopUp`, the Settings window's menu pickers drawn by AppKit so Tab reaches them. From
/// macOS 27.2 a menu-style SwiftUI `Picker` in a `Form` has no `NSPopUpButton` behind it for
/// `KeyboardReachableControls` to patch (docs/NOTES.md ▸ AppKit ▸ Keyboard focus).
///
/// The real tabs are hosted in a window of their own, as in `SettingsButtonTests`, so a picker left as
/// a SwiftUI `Picker` fails here on a macOS that draws it itself.
@Suite("Settings pop-ups")
@MainActor
struct SettingsPopUpTests {
    @MainActor
    private final class Model: ObservableObject {
        @Published var choice: String? = "b"
    }

    /// A pop-up over `model.choice`, with a separator after its first item, beside a field to Tab from.
    private struct Rig: View {
        @ObservedObject var model: Model
        var isDisabled = false

        var body: some View {
            Form {
                TextField("Field", text: .constant("text"))
                SettingsPopUp(
                    "Letter",
                    selection: $model.choice,
                    items: [.choice("None", nil), .separator, .choice("A", "a"), .choice("B", "b")]
                )
                .disabled(isDisabled)
            }
            .formStyle(.grouped)
        }
    }

    private func window(showing view: some View) -> NSWindow {
        KeyboardReachableControls.install()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 480),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: view)
        return window
    }

    private func views<View: NSView>(_: View.Type, in window: NSWindow) -> [View] {
        func all(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(all) }
        return window.contentView.map(all)?.compactMap { $0 as? View } ?? []
    }

    /// Waits for `find` to answer, laying the window out as it goes. 30 s with one last look after the
    /// deadline, like `SettingsButtonTests.built`: the main actor stalls for seconds in a full run.
    private func built<Found>(in window: NSWindow, _ find: () -> Found?) async throws -> Found? {
        let deadline = ContinuousClock.now + .seconds(30)
        while ContinuousClock.now < deadline {
            if let found = find() { return found }
            window.contentView?.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(50))
        }
        return find()
    }

    private func popUp(_ label: LocalizedStringResource, in window: NSWindow) async throws -> NSPopUpButton {
        let text = String(localized: label)
        return try #require(
            await built(in: window) {
                views(NSPopUpButton.self, in: window).first { $0.accessibilityLabel() == text }
            }
        )
    }

    private func editableField(in window: NSWindow) -> NSTextField? {
        views(NSTextField.self, in: window).first(where: \.isEditable)
    }

    /// The views Tab visits after `start`, in order, until the loop comes back round.
    private func tabStops(in window: NSWindow, from start: NSView) -> [NSView] {
        window.recalculateKeyViewLoop()
        var stops: [NSView] = []
        var current = start
        for _ in 0..<16 {
            window.selectKeyView(following: current)
            guard var next = window.firstResponder as? NSView else { break }
            if let editor = next as? NSTextView, editor.isFieldEditor, let field = editor.delegate as? NSView {
                next = field
            }
            if next === start || stops.contains(where: { $0 === next }) { break }
            stops.append(next)
            current = next
        }
        return stops
    }

    @Test("the menu holds the items in order, a separator included, and shows the selection")
    func menuAndSelection() async throws {
        let window = window(showing: Rig(model: Model()))
        let popUp = try await popUp("Letter", in: window)
        #expect(popUp.itemTitles == ["None", "", "A", "B"])
        #expect(popUp.item(at: 1)?.isSeparatorItem == true)
        #expect(popUp.titleOfSelectedItem == "B")
        #expect(popUp.isEnabled)
    }

    @Test("choosing an item past the separator writes its value, and a change made elsewhere shows")
    func choosingAndFollowing() async throws {
        let model = Model()
        let window = window(showing: Rig(model: model))
        let popUp = try await popUp("Letter", in: window)

        popUp.selectItem(at: 2)
        popUp.sendAction(popUp.action, to: popUp.target)
        #expect(model.choice == "a")

        model.choice = nil
        let shown = try await built(in: window) { popUp.titleOfSelectedItem == "None" ? true : nil }
        #expect(shown == true)
    }

    @Test("a disabled pop-up is not enabled, and Tab passes it over")
    func disabled() async throws {
        let window = window(showing: Rig(model: Model(), isDisabled: true))
        let popUp = try await popUp("Letter", in: window)
        let field = try #require(editableField(in: window))
        #expect(!popUp.isEnabled)
        #expect(!tabStops(in: window, from: field).contains { $0 === popUp })
    }

    @Test("Tab from a field reaches the pop-up")
    func tabReachesIt() async throws {
        let window = window(showing: Rig(model: Model()))
        let popUp = try await popUp("Letter", in: window)
        let field = try #require(editableField(in: window))
        #expect(tabStops(in: window, from: field).contains { $0 === popUp })
    }

    @Test("General's Language picker is an AppKit pop-up on the Tab loop, following the setting")
    func languagePicker() async throws {
        let language = LanguageSettings(defaults: ScratchDefaults.fresh())
        let window = window(
            showing: GeneralSettingsView(
                preferences: AppPreferences(defaults: ScratchDefaults.fresh()),
                language: language
            )
        )
        let popUp = try await popUp("Language", in: window)
        #expect(popUp.canBecomeKeyView)
        #expect(popUp.titleOfSelectedItem == String(localized: "Same as System"))
        #expect(popUp.item(at: 1)?.isSeparatorItem == true)
        #expect(popUp.numberOfItems == AppLanguages.all.count + 2)

        let russian = try #require(AppLanguages.language(for: "ru"))
        let index = try #require(popUp.itemTitles.firstIndex(of: russian.endonym))
        popUp.selectItem(at: index)
        popUp.sendAction(popUp.action, to: popUp.target)
        #expect(language.preference == .explicit(russian))
    }

    @Test("Operations' Compare files with and Edit files with are AppKit pop-ups on the Tab loop")
    func operationsPickers() async throws {
        let preferences = AppPreferences(defaults: ScratchDefaults.fresh())
        let window = window(showing: OperationsSettingsView(preferences: preferences))
        let compare = try await popUp("Compare files with", in: window)
        let edit = try await popUp("Edit files with", in: window)
        #expect(compare.canBecomeKeyView)
        #expect(edit.canBecomeKeyView)
        #expect(compare.indexOfSelectedItem >= 0)
        // "Automatic", named once the tab has looked the system's editor up.
        #expect(edit.indexOfSelectedItem == 0)
        #expect(edit.titleOfSelectedItem?.hasPrefix(String(localized: "Automatic")) == true)
    }
}
