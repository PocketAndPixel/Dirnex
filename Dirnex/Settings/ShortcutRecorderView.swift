import AppKit
import DirnexCore
import SwiftUI

/// A SwiftUI control for capturing a keyboard shortcut, used by the Settings Shortcuts tab.
/// Wraps an AppKit `RecorderView` because SwiftUI can't intercept raw key-downs (or the
/// ⌘-combinations that would otherwise fire menu items) — the AppKit view becomes first
/// responder while recording and consumes every key event until one resolves to a shortcut.
struct ShortcutRecorder: NSViewRepresentable {
    /// The command's current effective shortcut, shown when idle (`nil` renders the placeholder).
    let shortcut: CommandShortcut?
    /// Draw the pill in a warning tint when this shortcut collides with another command.
    let isConflicting: Bool
    /// Reports the captured shortcut, or `nil` when the user clears it with Delete.
    let onRecord: (CommandShortcut?) -> Void

    func makeNSView(context: Context) -> RecorderView {
        let view = RecorderView()
        view.onRecord = onRecord
        return view
    }

    func updateNSView(_ view: RecorderView, context: Context) {
        view.onRecord = onRecord
        view.update(shortcut: shortcut, conflicting: isConflicting)
    }

    /// The AppKit key-capture control. Idle it shows the current shortcut, or a `+` glyph when
    /// there is none; clicked, it enters recording mode, becomes first responder, and turns the
    /// next resolvable key combination into a `CommandShortcut`. Esc cancels, Delete clears the
    /// binding.
    ///
    /// **Focus and recording are two states.** Tab reaches the pill like a field — it was always a
    /// key view, with Keyboard navigation off too — and the pill draws the system focus ring while it
    /// has focus. Space or Return then starts recording, as Space presses a focused button. Ending a
    /// recording keeps focus on the pill, so Tab carries on from there, and Tab while recording leaves
    /// as it would from anywhere else: Tab can never be recorded (it is a control key), so nothing is
    /// lost by letting it go.
    ///
    /// Both placeholder states are drawn as a **glyph with the words in the tooltip**, never as
    /// prose in the pill: the pill is a fixed 148 pt (it lines up with the shortcut column), and
    /// measured in its own font "Aggiungi abbreviazione da tastiera" is 252 pt, "Додати
    /// клавіатурне скорочення" 215 pt — and a centered label with no width constraint overruns
    /// rather than truncating, so the text spilled out of the rounded rect on both sides in 7 of
    /// the 14 shipped languages. A glyph fits every language by construction.
    final class RecorderView: NSView {
        var onRecord: ((CommandShortcut?) -> Void)?

        private let label = NSTextField(labelWithString: "")
        private let glyph = NSImageView()
        private var shortcut: CommandShortcut?
        private var isConflicting = false
        private(set) var isRecording = false {
            didSet { needsDisplay = true; refreshContent() }
        }

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
            label.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
            label.alignment = .center
            label.translatesAutoresizingMaskIntoConstraints = false
            glyph.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 11, weight: .medium)
            glyph.translatesAutoresizingMaskIntoConstraints = false
            addSubview(label)
            addSubview(glyph)
            NSLayoutConstraint.activate([
                label.centerXAnchor.constraint(equalTo: centerXAnchor),
                label.centerYAnchor.constraint(equalTo: centerYAnchor),
                glyph.centerXAnchor.constraint(equalTo: centerXAnchor),
                glyph.centerYAnchor.constraint(equalTo: centerYAnchor)
            ])
            refreshContent()
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override var intrinsicContentSize: NSSize { NSSize(width: 148, height: 24) }
        override var acceptsFirstResponder: Bool { true }

        /// The pill's own outline, which AppKit rings while the pill has focus. Without these the
        /// mask is empty and Tab lands on a pill that shows nothing.
        override var focusRingMaskBounds: NSRect { bounds }

        override func drawFocusRingMask() {
            outline(in: bounds).fill()
        }

        func update(shortcut: CommandShortcut?, conflicting: Bool) {
            self.shortcut = shortcut
            isConflicting = conflicting
            refreshContent()
            needsDisplay = true
        }

        // MARK: - Recording

        override func mouseDown(with event: NSEvent) {
            if isRecording {
                endRecording()
            } else {
                beginRecording()
            }
        }

        private func beginRecording() {
            isRecording = true
            window?.makeFirstResponder(self)
        }

        /// While recording, swallow ⌘-combinations that would otherwise dispatch as menu key
        /// equivalents (⌘T, ⌘W …) and turn them into the recorded shortcut instead.
        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            guard isRecording else { return super.performKeyEquivalent(with: event) }
            handle(event)
            return true
        }

        override func keyDown(with event: NSEvent) {
            guard isRecording else {
                if Self.startsRecording(event) { beginRecording() } else { super.keyDown(with: event) }
                return
            }
            handle(event)
        }

        /// Space, Return or keypad Enter with no ⌘, ⌃ or ⌥: the keys that press a focused button.
        static func startsRecording(_ event: NSEvent) -> Bool {
            [49, 36, 76].contains(event.keyCode)
                && event.modifierFlags.isDisjoint(with: [.command, .control, .option])
        }

        private func handle(_ event: NSEvent) {
            switch event.keyCode {
            // Escape — cancel without changing the binding. The `EscapeKeyConsuming` conformance
            // below is what keeps the Settings window's own Escape-to-close off this key while the
            // pill is recording; without it, canceling a recording would close the window instead.
            case 53:
                endRecording()
            case 51, 117: // Delete / Forward Delete — clear the binding.
                onRecord?(nil)
                endRecording()
            case 48: // Tab — stop and hand the key on, so it moves focus as it does from any control.
                endRecording()
                super.keyDown(with: event)
            default:
                guard let recorded = CommandShortcut(event: event) else { return } // keep waiting
                onRecord?(recorded)
                endRecording()
            }
        }

        private func endRecording() {
            isRecording = false
        }

        override func resignFirstResponder() -> Bool {
            isRecording = false
            return super.resignFirstResponder()
        }

        // MARK: - Appearance

        private func refreshContent() {
            if isRecording {
                showGlyph(
                    named: "keyboard",
                    tint: .controlAccentColor,
                    description: String(
                        localized: "Type shortcut…",
                        comment: """
                        Tooltip on the shortcut recorder while it captures keys; the pill itself \
                        shows a keyboard glyph. A tooltip, not text in the pill, so its length \
                        is free — translate it as a full phrase.
                        """
                    )
                )
            } else if let shortcut {
                glyph.isHidden = true
                label.isHidden = false
                label.stringValue = shortcut.display
                label.textColor = isConflicting ? .systemRed : .labelColor
                toolTip = nil
                setAccessibilityLabel(shortcut.display)
            } else {
                showGlyph(
                    named: "plus",
                    tint: .tertiaryLabelColor,
                    description: String(
                        localized: "Add Shortcut",
                        comment: """
                        Tooltip on the shortcut recorder when no shortcut is set; the pill itself \
                        shows a + glyph. A tooltip, not text in the pill, so its length is free \
                        — translate it as a full phrase.
                        """
                    )
                )
            }
        }

        /// Put a placeholder glyph in the pill and the words in the tooltip (and in the
        /// accessibility label, which is the only thing VoiceOver has to read here).
        private func showGlyph(named name: String, tint: NSColor, description: String) {
            label.isHidden = true
            glyph.isHidden = false
            glyph.image = NSImage(systemSymbolName: name, accessibilityDescription: description)
            glyph.contentTintColor = tint
            toolTip = description
            setAccessibilityLabel(description)
        }

        /// The pill's rounded rectangle within `rect`.
        private func outline(in rect: NSRect) -> NSBezierPath {
            NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5)
        }

        override func draw(_ dirtyRect: NSRect) {
            let path = outline(in: bounds.insetBy(dx: 0.5, dy: 0.5))
            let fill = isRecording
                ? NSColor.controlAccentColor.withAlphaComponent(0.12)
                : NSColor.controlBackgroundColor
            fill.setFill()
            path.fill()
            // A recording pill always has focus, so the focus ring is already around it: a 1 pt accent
            // edge inside that ring, as a focused field has, rather than a wider one the ring merges into.
            (isRecording ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
            path.lineWidth = 1
            path.stroke()
        }
    }
}

/// Escape belongs to the recorder while it is recording — it cancels the capture. Marked so the
/// Settings window's Escape-to-close stands aside rather than closing over an in-progress recording;
/// a pill that only has focus leaves Escape to close the window, as any other control does.
extension ShortcutRecorder.RecorderView: EscapeKeyConsuming {
    var consumesEscape: Bool { isRecording }
}
