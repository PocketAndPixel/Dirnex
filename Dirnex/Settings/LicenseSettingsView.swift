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
struct LicenseSettingsView: View {
    @ObservedObject var store: LicenseStore
    @State private var entry = ""
    @State private var refusal: LicenseKeyError?

    var body: some View {
        Form {
            statusSection
            entrySection
        }
        .formStyle(.grouped)
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
                SettingsButton("Remove License", role: .destructive) { store.remove() }
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
