import AppKit
import DirnexCore
import SwiftUI

/// Settings ▸ License (PLAN.md §M29 "Holding a key"): who the license is for and which versions it
/// covers, a field that takes a pasted key, and Buy or Renew, and Remove.
///
/// The field takes whatever the user copied: the key alone, the key wrapped across lines by a mail
/// client, or either activation link (`LicenseLinks.keyText(fromPasted:)`). A refusal is shown
/// under the field in the words `LicenseKeyError.message` gives, and disappears as soon as the text
/// changes.
///
/// Remove asks first, and says how to get the key back. The key carries no email address and doesn't
/// say whether it was bought, so the message covers both ways back: "Your licenses" on dirnex.app
/// returns every license that has an address, and support finds the rest by name. The license ID
/// isn't in the message: the alert hyphenates, its text is 220 pt wide in English, and many IDs are
/// wider, so one came out broken by a hyphen nobody should type (docs/NOTES.md ▸ AppKit).
struct LicenseSettingsView: View {
    @ObservedObject var store: LicenseStore
    @State private var entry = ""
    @State private var refusal: LicenseKeyError?
    @State private var confirmingRemoval = false

    var body: some View {
        Form {
            statusSection
            entrySection
        }
        .formStyle(.grouped)
        .alert("Remove the license from this Mac?", isPresented: $confirmingRemoval) {
            Button("Remove License", role: .destructive) { store.remove() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                """
                To add it back later, paste the key from your license email, or get it again at \
                dirnex.app/account. If you can’t, write to support@dirnex.app.
                """
            )
        }
    }

    // MARK: - Status

    @ViewBuilder private var statusSection: some View {
        switch store.status {
        case .unlicensed:
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Not licensed")
                        .font(.headline)
                    Text(
                        "Dirnex is free to use. A license removes the reminder and keeps Dirnex going."
                    )
                    .foregroundStyle(.secondary)
                }
                HStack {
                    Spacer()
                    SettingsButton("Buy a License…") { NSWorkspace.shared.open(LicenseLinks.buy) }
                }
            }
        case let .licensed(key):
            keySection(key, covered: true)
        case let .lapsed(key):
            keySection(key, covered: false)
        }
    }

    private func keySection(_ key: LicenseKey, covered: Bool) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                Text("Licensed to \(key.licensee)")
                    .font(.headline)
                Text("Covers every version released until \(key.until.displayText).")
                if !covered {
                    Text(
                        """
                        This version came out later, so the license doesn’t cover it. Renew to cover \
                        this version and the ones after it.
                        """
                    )
                    .foregroundStyle(.secondary)
                }
            }
            LabeledContent("License ID") {
                Text(key.id)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
            }
            HStack {
                SettingsButton("Remove License", role: .destructive) { confirmingRemoval = true }
                Spacer()
                SettingsButton("Renew…", isProminent: !covered) {
                    NSWorkspace.shared.open(LicenseLinks.renew(key))
                }
            }
        }
    }

    // MARK: - Entering a key

    private var entrySection: some View {
        Section {
            // The placeholder goes in `prompt`: in a grouped `Form` the title of a label-hidden field is
            // read by VoiceOver but never drawn, so the field sat empty with no hint (seen live).
            TextField(
                "License Key",
                text: $entry,
                prompt: Text("Paste your license key"),
                axis: .vertical
            )
            // A box like every other text field in the app: a grouped `Form` otherwise draws its
            // fields with no bezel, so this was the one field without a border. Bezeled, it also gets
            // the stronger ring (`FieldBorder`) and a dimmed placeholder (probed 2026-10-09).
            .textFieldStyle(.roundedBorder)
            .labelsHidden()
            .lineLimit(3...6)
            .font(.system(.body, design: .monospaced))
            .onChange(of: entry) { refusal = nil }
            if let refusal {
                Text(refusal.message)
                    .foregroundStyle(.red)
            }
            HStack {
                Spacer()
                SettingsButton("Activate", action: activate)
                    .disabled(entry.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        } header: {
            Text("License Key")
        } footer: {
            Text(
                """
                The key is in the email you got after buying. One license covers all your Macs, and \
                Dirnex checks it right here, without contacting any server.
                """
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private func activate() {
        switch store.activate(LicenseLinks.keyText(fromPasted: entry)) {
        case .success:
            entry = ""
            refusal = nil
        case let .failure(error):
            refusal = error
        }
    }
}
