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
    /// Both placeholder states are drawn as a **glyph with the words in the tooltip**, never as
    /// prose in the pill: the pill is a fixed 148 pt (it lines up with the shortcut column), and
    /// measured in its own font "Aggiungi abbreviazione da tastiera" is 252 pt, "Додати
    /// клавіатурне скорочення" 215 pt — and a centred label with no width constraint overruns
    /// rather than truncating, so the text spilled out of the rounded rect on both sides in 7 of
    /// the 14 shipped languages. A glyph fits every language by construction.
    final class RecorderView: NSView {
        var onRecord: ((CommandShortcut?) -> Void)?

        private let label = NSTextField(labelWithString: "")
        private let glyph = NSImageView()
        private var shortcut: CommandShortcut?
        private var isConflicting = false
        private var isRecording = false {
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
                isRecording = true
                window?.makeFirstResponder(self)
            }
        }

        /// While recording, swallow ⌘-combinations that would otherwise dispatch as menu key
        /// equivalents (⌘T, ⌘W …) and turn them into the recorded shortcut instead.
        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            guard isRecording else { return super.performKeyEquivalent(with: event) }
            handle(event)
            return true
        }

        override func keyDown(with event: NSEvent) {
            guard isRecording else { super.keyDown(with: event); return }
            handle(event)
        }

        private func handle(_ event: NSEvent) {
            switch event.keyCode {
            // Escape — cancel without changing the binding. The `EscapeKeyConsuming` conformance
            // below is what keeps the Settings window's own Escape-to-close off this key while the
            // pill is recording; without it, cancelling a recording would close the window instead.
            case 53:
                endRecording()
            case 51, 117: // Delete / Forward Delete — clear the binding.
                onRecord?(nil)
                endRecording()
            default:
                guard let recorded = CommandShortcut(event: event) else { return } // keep waiting
                onRecord?(recorded)
                endRecording()
            }
        }

        private func endRecording() {
            isRecording = false
            if window?.firstResponder == self { window?.makeFirstResponder(nil) }
        }

        override func resignFirstResponder() -> Bool {
            isRecording = false
            return super.resignFirstResponder()
        }

        // The view only holds first responder *while recording* (`mouseDown` takes it,
        // `endRecording` and `resignFirstResponder` give it back), so being focused and wanting
        // Escape are the same state — nothing further to test.

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

        override func draw(_ dirtyRect: NSRect) {
            let path = NSBezierPath(
                roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
                xRadius: 5,
                yRadius: 5
            )
            let fill = isRecording
                ? NSColor.controlAccentColor.withAlphaComponent(0.12)
                : NSColor.controlBackgroundColor
            fill.setFill()
            path.fill()
            if isRecording {
                NSColor.controlAccentColor.setStroke()
                path.lineWidth = 2
            } else {
                NSColor.separatorColor.setStroke()
                path.lineWidth = 1
            }
            path.stroke()
        }
    }
}

/// Escape belongs to the recorder while it is recording — it cancels the capture. Marked so the
/// Settings window's Escape-to-close stands aside rather than closing over an in-progress recording.
extension ShortcutRecorder.RecorderView: EscapeKeyConsuming {}
