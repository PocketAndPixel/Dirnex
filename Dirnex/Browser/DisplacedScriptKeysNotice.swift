import AppKit
import DirnexCore

/// Tells the user when a user script's function key has stopped being theirs (PLAN.md §M11).
///
/// The case this exists for is **F4**. It was assignable for the whole of M6–M10 —
/// `FunctionBar.assignableFunctionKeys` answered `[1, 4, 9, 10, 12]` — and became "Edit" in M11.
/// A script left on it keeps everything else and still runs from the palette and the right-click
/// submenu, but the *key* now fires Edit: a bar slot and a menu key-equivalent are both dispatched
/// before the pane's key handler is ever asked. That degrades in the quiet direction — the script
/// is still listed everywhere, so the only symptom is a key that suddenly does something else —
/// which is why it is said out loud instead.
///
/// Shown **once per script-and-key pair**, latched in `UserDefaults`: rebinding to another key that
/// later gets taken warns again, but relaunching does not. A fresh install cannot reach this at all
/// (it has no scripts), so it can never collide with the first-run tour.
@MainActor
enum DisplacedScriptKeysNotice {
    private static let key = "Dirnex.warnedDisplacedScriptKeys"

    /// Warn about any script holding a key it can no longer fire from, if we haven't already.
    static func presentIfNeeded(over window: NSWindow?) {
        let displaced = FunctionBar.displacedScripts(
            UserScriptStore.load().scripts,
            bindings: KeyBindingStore.shared.bindings
        )
        let unwarned = displaced.filter { !warned.contains(latchKey(for: $0)) }
        guard !unwarned.isEmpty else { return }
        warned.formUnion(unwarned.map(latchKey(for:)))
        present(unwarned, over: window)
    }

    private static func present(_ scripts: [UserScript], over window: NSWindow?) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = scripts.count == 1
            ? "“\(scripts[0].name)” no longer runs from its function key"
            : "\(scripts.count) scripts no longer run from their function keys"
        alert.informativeText = describe(scripts)
        alert.addButton(withTitle: "Manage Scripts…")
        alert.addButton(withTitle: "OK")
        alert.enableEscapeToCancel()
        let handle: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .alertFirstButtonReturn else { return }
            NSApp.sendAction(
                #selector(PanelViewController.manageUserScripts(_:)),
                to: nil,
                from: nil
            )
        }
        if let window {
            alert.beginSheetModal(for: window, completionHandler: handle)
        } else {
            handle(alert.runModal())
        }
    }

    /// Name each script, its key, and what took it — a message that only says "a key was taken"
    /// leaves the user hunting for which one.
    private static func describe(_ scripts: [UserScript]) -> String {
        let lines = scripts.map { script -> String in
            let key = script.functionKey.map { "F\($0)" } ?? "its key"
            return "• \(script.name) — \(key) now runs \(claimant(of: script.functionKey))."
        }
        return lines.joined(separator: "\n")
            + "\n\nEach script still runs from the ⌘K palette and the Scripts submenu. "
            + "Give it a free key in Manage Scripts to get the keystroke back."
    }

    /// What now owns a function key: a bar slot's command, or macOS itself.
    private static func claimant(of functionKey: Int?) -> String {
        guard let functionKey else { return "something else" }
        if FunctionBar.systemReservedFunctionKeys.contains(functionKey) {
            return "a macOS shortcut"
        }
        let slot = FunctionBar.slot(forFunctionKey: functionKey, in: FunctionBar.defaultSlots)
        guard let commandID = slot?.commandID,
              let command = CommandCatalog.command(for: commandID) else {
            return "a Dirnex command"
        }
        return "“\(command.title)”"
    }

    // MARK: - The latch

    private static func latchKey(for script: UserScript) -> String {
        "\(script.name)#\(script.functionKey.map(String.init) ?? "-")"
    }

    private static var warned: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: key) ?? []) }
        set { UserDefaults.standard.set(Array(newValue).sorted(), forKey: key) }
    }
}
