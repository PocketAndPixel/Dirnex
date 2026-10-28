import AppKit
import Foundation
import Testing

@testable import Dirnex

/// Every sentence Report a Bug's status line can show fits its two lines in every language it ships
/// in (PLAN.md §M30).
///
/// The line is a wrapping label held to two lines (`maximumNumberOfLines`) in a row of fixed height,
/// so a sentence that needs a third loses its end without a word, and the end is the half that says
/// what to do instead. In English the rate-limit sentence already takes both lines, as seen live on
/// 2026-10-24, and that day Email Instead's sentence grew from a claim into a hedge and a way out.
///
/// Measured through the dialog's own label, at the width it wraps at (`preferredMaxLayoutWidth`),
/// against the height the same label gives two lines.
@Suite("Report a Bug status line")
struct BugReportStatusWidthTests {
    /// The sentence that already takes both lines in English.
    static let rateLimitKey =
        "Too many reports came from this network in the last hour. Try again later, or send this one by email."

    /// Every sentence the line shows, keyed by its English text as every app-side literal is.
    static let keys = [
        "Sending…",
        "The email address doesn't look complete.",
        "The description is too long to send.",
        "The steps are too long to send.",
        "Couldn't reach the server. Your report is still here: copy it, or send it by email.",
        rateLimitKey,
        "The server didn't accept the report (%@). Copy it, or send it by email instead.",
        "The server had a problem (%lld). Your report is still here: copy it, or send it by email.",
        "The report is on the clipboard.",
        "Your mail app should open a new email with the report. If it doesn't, copy the report instead.",
        "No mail app opened. Copy the report instead."
    ]

    /// The height `label` gives `text` at the width it wraps at, however many lines that takes.
    @MainActor
    private func height(of text: String, in label: NSTextField) -> CGFloat {
        label.maximumNumberOfLines = 0
        label.stringValue = text
        let bounds = NSRect(
            x: 0,
            y: 0,
            width: label.preferredMaxLayoutWidth,
            height: .greatestFiniteMagnitude
        )
        return label.cell?.cellSize(forBounds: bounds).height ?? 0
    }

    /// `text` with its argument at its widest: the longest refusal the server names
    /// (`unsupportedVersion`, from the contract's shared cases), or a three-digit status.
    private func filled(_ text: String, key: String) -> String {
        if key.contains("%@") { return String(format: text, "unsupportedVersion") }
        if key.contains("%lld") { return String(format: text, 503) }
        return text
    }

    @Test("every sentence fits the line's two lines in every language", arguments: keys)
    @MainActor
    func sentenceFits(key: String) throws {
        let label = BugReportDialogTests.dialog().controller.statusLabel
        try #require(label.maximumNumberOfLines == 2)
        let twoLines = height(of: "A\nA", in: label)
        // A measure that can't count lines passes everything (docs/NOTES.md ▸ Layout under a longer
        // translation), so a third line has to come out taller.
        try #require(height(of: "A\nA\nA", in: label) > twoLines)

        let all = ConnectPlaceholderWidthTests.translations(of: key)
        #expect(all.count >= 14, "expected all 14 shipped languages for \(key), found \(all.count)")
        let over = all.compactMap { language, text in
            let text = filled(text, key: key)
            return height(of: text, in: label) > twoLines ? "\(language): \(text)" : nil
        }
        #expect(over.isEmpty, "more than two lines: \(over.joined(separator: "; "))")
    }

    /// Ties the width to what was seen: live, in English, this sentence took both lines. A width the
    /// label never wraps at would pass every language above.
    @Test("the English rate-limit sentence wraps to a second line, as it did live")
    @MainActor
    func rateLimitWraps() {
        let label = BugReportDialogTests.dialog().controller.statusLabel
        let oneLine = height(of: "A", in: label)
        #expect(height(of: Self.rateLimitKey, in: label) > oneLine)
    }
}
