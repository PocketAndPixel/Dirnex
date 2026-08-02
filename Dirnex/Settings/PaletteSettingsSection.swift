import SwiftUI

/// The Panels tab's three colour wells (PLAN.md §M15 Slice 2) — accent, cursor and mark — each
/// defaulting to Follow System.
///
/// In its own file rather than inline in `PanelsSettingsView` for the same reason
/// `LanguageSettingsSection` is: the other rows there are a toggle apiece, while each of these is a
/// well *plus* the state of having been overridden at all, which needs a control of its own to get
/// back out of. The three rows are one view used three times, so a colour cannot end up wired to
/// the wrong preference by a copy-paste.
struct PaletteSettingsSection: View {
    @ObservedObject var preferences: AppPreferences

    var body: some View {
        Section {
            PaletteColorRow(
                title: String(
                    localized: "Accent",
                    comment: "Settings ▸ Panels: color of the current path crumb and active tab"
                ),
                hex: $preferences.accentColorHex,
                systemColor: .controlAccentColor
            )
            PaletteColorRow(
                title: String(
                    localized: "Cursor row",
                    comment: "Settings ▸ Panels: background color of the selected file row"
                ),
                hex: $preferences.cursorColorHex,
                systemColor: .selectedContentBackgroundColor
            )
            PaletteColorRow(
                title: String(
                    localized: "Marked files",
                    comment: "Settings ▸ Panels: text color of files selected with Space/Insert"
                ),
                hex: $preferences.markColorHex,
                systemColor: .systemRed
            )

            if !preferences.palette.isFollowingSystem {
                HStack {
                    Spacer()
                    Button("Use System Colors") { preferences.resetPalette() }
                }
            }
        } header: {
            Text("Colors")
        } footer: {
            Text(
                """
                Each color follows macOS until you change it. Text on the cursor row is chosen for \
                you — black or white, whichever stays readable — so a pale cursor color can’t hide \
                the file names.
                """
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }
}

/// One colour: a well, and — once it has been overridden — the way back to the system's.
private struct PaletteColorRow: View {
    let title: String
    @Binding var hex: String
    /// What this colour resolves to while it is following the system, so the well shows the real
    /// starting point instead of an empty swatch. Resolved at render, which is also why the reset
    /// button matters: there is no third "following" state a colour well can display.
    let systemColor: NSColor

    var body: some View {
        HStack {
            ColorPicker(title, selection: binding, supportsOpacity: false)
            if !hex.isEmpty {
                Button {
                    hex = ""
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                }
                .buttonStyle(.borderless)
                .help(String(
                    localized: "Follow the system color",
                    comment: "Tooltip on the button that clears a custom color in Settings ▸ Panels"
                ))
            }
        }
    }

    /// Reads the stored hex, falling back to the resolved system colour so the well is never blank;
    /// writes hex back, which is what turns Follow System into an override. Picking the *same*
    /// colour the system was already showing therefore counts as an override — which is honest:
    /// nothing else distinguishes it from picking any other colour, and the reset button is right
    /// there.
    private var binding: Binding<Color> {
        Binding(
            get: { Color(nsColor: PanelPalette.color(fromHex: hex) ?? systemColor) },
            set: { hex = PanelPalette.hex(from: NSColor($0)) ?? "" }
        )
    }
}
