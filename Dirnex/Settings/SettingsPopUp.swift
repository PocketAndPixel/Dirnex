import AppKit
import SwiftUI

/// A pop-up menu for the Settings window that AppKit draws, so Tab reaches it whatever System
/// Settings ▸ Keyboard ▸ Keyboard navigation says. ``SettingsButton``'s twin, for a menu `Picker`.
///
/// **From macOS 27.2 a menu-style SwiftUI `Picker` in a `Form` has no `NSPopUpButton` behind it.**
/// Probed 2026-11-24 on 27.2.1: in a grouped `Form` the switch, the segmented picker, the color well
/// and the stepper were still AppKit subclasses, and the menu picker had no AppKit view at all. On
/// macOS 26 it was an `NSPopUpButton` subclass (2026-09-13), which `KeyboardReachableControls`' patch
/// on `NSButton` put on the loop. SwiftUI keeps the control it draws itself off the loop while that
/// switch is off, which is the macOS default, as it does a plain `Button` (docs/NOTES.md ▸ AppKit ▸
/// Keyboard focus). An `NSPopUpButton` inside the `Form` joins through the same patch, and Space opens
/// it as it does in any dialog.
///
/// The label is a `LocalizedStringResource`, so a literal is extracted under the key the `Picker`
/// literal had, and it is the pop-up's accessibility label as well as the row's. Without one the
/// pop-up stands alone, for a row that says what it is in other ways. `.disabled(_:)` works as it
/// does on a picker.
struct SettingsPopUp<Value: Hashable>: View {
    enum Item: Equatable {
        case choice(String, Value)
        case separator
    }

    private let label: LocalizedStringResource?
    private let selection: Binding<Value>
    private let items: [Item]

    init(_ label: LocalizedStringResource, selection: Binding<Value>, items: [Item]) {
        self.label = label
        self.selection = selection
        self.items = items
    }

    init(selection: Binding<Value>, items: [Item]) {
        label = nil
        self.selection = selection
        self.items = items
    }

    var body: some View {
        if let label {
            LabeledContent {
                SettingsPopUpButton(
                    label: String(localized: label),
                    selection: selection,
                    items: items
                )
            } label: {
                Text(label)
            }
        } else {
            SettingsPopUpButton(label: nil, selection: selection, items: items)
        }
    }
}

/// The `NSPopUpButton` itself. Its menu is rebuilt only when the items change, so an open menu is not
/// pulled from under the pointer by an unrelated redraw.
private struct SettingsPopUpButton<Value: Hashable>: NSViewRepresentable {
    let label: String?
    let selection: Binding<Value>
    let items: [SettingsPopUp<Value>.Item]

    func makeCoordinator() -> SettingsPopUpTarget {
        SettingsPopUpTarget()
    }

    func makeNSView(context: Context) -> NSPopUpButton {
        let popUp = NSPopUpButton(frame: .zero, pullsDown: false)
        popUp.target = context.coordinator
        popUp.action = #selector(SettingsPopUpTarget.choose(_:))
        popUp.setContentHuggingPriority(.required, for: .horizontal)
        popUp.setContentCompressionResistancePriority(.required, for: .horizontal)
        return popUp
    }

    func updateNSView(_ popUp: NSPopUpButton, context: Context) {
        let target = context.coordinator
        let shape = items.map(Self.title)
        if target.shape != shape {
            // On the menu, not `addItem(withTitle:)`, which drops an earlier item with the same title.
            popUp.removeAllItems()
            for title in shape {
                if let title {
                    popUp.menu?.addItem(withTitle: title, action: nil, keyEquivalent: "")
                } else {
                    popUp.menu?.addItem(.separator())
                }
            }
            target.shape = shape
        }
        target.chosen = { [items, selection] index in
            guard items.indices.contains(index), case let .choice(_, value) = items[index] else { return }
            selection.wrappedValue = value
        }
        let current = selection.wrappedValue
        let index = items.firstIndex { item in
            if case let .choice(_, value) = item { value == current } else { false }
        }
        popUp.selectItem(at: index ?? -1)
        popUp.isEnabled = context.environment.isEnabled
        popUp.setAccessibilityLabel(label)
        // The width follows the selected title (`sizeThatFits`), so a new choice asks for a new layout.
        popUp.invalidateIntrinsicContentSize()
    }

    /// With a label, as wide as the selected title, as SwiftUI's picker is: the widest item's width
    /// left a short choice ("Built-in") a gap before the chevron in a trailing-aligned row. Without
    /// one, as wide as the widest item, so a column of them (the color rules) lines up whatever each
    /// has chosen.
    func sizeThatFits(_: ProposedViewSize, nsView popUp: NSPopUpButton, context _: Context) -> CGSize? {
        guard label != nil else { return popUp.intrinsicContentSize }
        let cell = NSPopUpButtonCell(textCell: "", pullsDown: false)
        cell.font = popUp.font
        cell.controlSize = popUp.controlSize
        cell.addItem(withTitle: popUp.titleOfSelectedItem ?? "")
        return CGSize(width: ceil(cell.cellSize.width), height: popUp.intrinsicContentSize.height)
    }

    /// The item's title, or `nil` for a separator.
    private static func title(_ item: SettingsPopUp<Value>.Item) -> String? {
        switch item {
        case let .choice(title, _): title
        case .separator: nil
        }
    }
}

/// The pop-up's target. Not generic, so its action can be an Objective-C method.
@MainActor
private final class SettingsPopUpTarget: NSObject {
    /// The menu as last built: a title per item, `nil` for a separator.
    var shape: [String?]?
    /// Writes the choice at a menu index back to the selection.
    var chosen: (Int) -> Void = { _ in }

    @objc func choose(_ popUp: NSPopUpButton) {
        chosen(popUp.indexOfSelectedItem)
    }
}
