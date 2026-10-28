import AppKit
import Foundation
import Testing

@testable import Dirnex

/// Every placeholder in the Connect to Server form fits its field in every language it ships in
/// (PLAN.md §M32, Slice 6's look at the sheet in other languages).
///
/// Each control is pinned to ``ConnectFormFactory/fieldWidth`` and a field truncates at the
/// **head**, so an over-long placeholder loses its start, which is the word that names the field.
/// The WebDAV user hint shipped at **405 pt in Brazilian Portuguese** against the 364 pt field, so a
/// blank field read as the remark about public shares with nothing to say it wanted a user name.
/// Ukrainian (384) and Russian (367) were over too. Every other placeholder, in every language,
/// measured 308 pt or less, so the hint was the outlier rather than the first of many.
///
/// Measured the way docs/NOTES.md ▸ Layout under a longer translation says a placeholder can be:
/// the text as the *value* of the factory's own field, `sizeToFit()`, and the frame. A placeholder
/// is drawn in the value's rect with the value's font. Asking for the placeholder's own size reads
/// 0, which would pass every language.
@Suite("Connect form placeholder widths")
struct ConnectPlaceholderWidthTests {
    /// The form's localized placeholders, keyed by their English text as every app-side literal is.
    /// The host, port, path and key-file hints are examples (`nas.local`, `443`) and not translated.
    static let keys = [
        "username",
        "password",
        "Optional — save in sidebar",
        "bucket name — leave blank to browse all",
        "secret access key",
        "guest (leave blank)",
        "password (blank for guest)",
        "username (blank for a public share)"
    ]

    /// Measured through the field the form builds. A secure field's own value would measure its
    /// bullets, so every placeholder is measured as plain text, which is how it is drawn.
    @MainActor
    private func width(_ text: String) -> CGFloat {
        let field = ConnectFormFactory.textField(placeholder: "")
        field.stringValue = text
        field.sizeToFit()
        return field.frame.width
    }

    /// Every shipped translation of `key`, read from the **compiled** `.strings` in the app bundle,
    /// as ``StatusSentenceWidthTests`` reads them: the bundle is what runs.
    static func translations(of key: String) -> [(language: String, text: String)] {
        let bundle = Bundle(for: PanelViewController.self)
        var found: [(language: String, text: String)] = []
        for lproj in bundle.paths(forResourcesOfType: "lproj", inDirectory: nil) {
            let language = (lproj as NSString).lastPathComponent
                .replacingOccurrences(of: ".lproj", with: "")
            let table = (lproj as NSString).appendingPathComponent("Localizable.strings")
            guard let strings = NSDictionary(contentsOfFile: table) as? [String: String],
                  let value = strings[key] else { continue }
            found.append((language, value))
        }
        return found.sorted { $0.language < $1.language }
    }

    @Test("every placeholder fits its field in every language", arguments: keys)
    @MainActor
    func placeholderFits(key: String) throws {
        let all = Self.translations(of: key)
        #expect(all.count >= 14, "expected all 14 shipped languages for \(key), found \(all.count)")
        // A measure that cannot see its subject passes everything, which is how the placeholder's
        // own size fails (NOTES.md). The English has to come out as a real width first.
        try #require(width(key) > 40, "the field measured \(width(key)) pt for \(key)")

        let over = all.compactMap { language, text in
            let measured = width(text)
            return measured > ConnectFormFactory.fieldWidth ? "\(language) \(Int(measured)) pt: \(text)" : nil
        }
        #expect(
            over.isEmpty,
            "over the \(Int(ConnectFormFactory.fieldWidth)) pt field: \(over.joined(separator: "; "))"
        )
    }

    /// The negative control: the check must be able to fail. The text measured is the Brazilian
    /// Portuguese hint that shipped and overran the field.
    @Test("the field rejects the hint that overran it")
    @MainActor
    func fieldRejectsTheHintThatOverran() {
        let shipped = "nome de usuário (em branco para um compartilhamento público)"
        #expect(width(shipped) > ConnectFormFactory.fieldWidth)
    }
}
