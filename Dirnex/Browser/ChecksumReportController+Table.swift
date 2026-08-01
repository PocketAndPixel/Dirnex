import AppKit
import DirnexCore

// Rendering half of the checksum report sheet (PLAN.md §M14 Slice 2): turning one
// `ChecksumVerificationEntry` into its three cells. The controller owns the state and the chrome;
// this file owns the pixels — the same split `SyncDirectoriesController+DiffTable` makes, and for
// the same reason (both types sit near SwiftLint's type-body ceiling).

extension ChecksumReportController: NSTableViewDataSource {
    func numberOfRows(in tableView: NSTableView) -> Int { rowCount }
}

extension ChecksumReportController: NSTableViewDelegate {
    func tableView(
        _ tableView: NSTableView,
        viewFor tableColumn: NSTableColumn?,
        row: Int
    ) -> NSView? {
        guard let column = tableColumn, let entry = self.row(at: row) else { return nil }
        switch column.identifier.rawValue {
        case "status": return glyphCell(for: entry.status)
        case "name": return nameCell(for: entry)
        case "detail": return detailCell(for: entry.status)
        default: return nil
        }
    }

    private func glyphCell(for status: ChecksumEntryStatus) -> NSView {
        let style = Self.style(for: status)
        let field = NSTextField(labelWithString: style.glyph)
        field.alignment = .center
        field.textColor = style.color
        field.toolTip = style.detail
        field.font = .systemFont(ofSize: 13, weight: .semibold)
        // A glyph is silent to VoiceOver, and here it carries the entire verdict.
        field.setAccessibilityLabel(style.detail)
        return field
    }

    private func nameCell(for entry: ChecksumVerificationEntry) -> NSView {
        let field = NSTextField(labelWithString: entry.name)
        // Middle truncation, so `sub/deeper/report.log` keeps both the folder and the file name —
        // tail truncation on a relative path hides exactly the half that identifies the file.
        field.lineBreakMode = .byTruncatingMiddle
        field.toolTip = entry.name
        return field
    }

    /// The detail column. For a mismatch this is the *expected* digest, abbreviated: the whole
    /// point of the row is that two hex strings differ, and the tooltip carries both in full so the
    /// user can compare against whatever the publisher's page says.
    private func detailCell(for status: ChecksumEntryStatus) -> NSView {
        let style = Self.style(for: status)
        let field = NSTextField(labelWithString: style.detail)
        field.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        field.textColor = .secondaryLabelColor
        field.lineBreakMode = .byTruncatingTail
        field.toolTip = style.tooltip ?? style.detail
        return field
    }

    /// Glyph, colour, and words for one verdict.
    ///
    /// Colour is never the only signal — every row carries a distinct glyph *and* a sentence — so
    /// the table reads the same to someone who cannot tell the red from the green.
    private static func style(for status: ChecksumEntryStatus) -> RowStyle {
        switch status {
        case .ok:
            return RowStyle(
                "✓",
                .systemGreen,
                String(
                    localized: "Matches",
                    comment: "Checksum report row: the file's digest is the one claimed."
                )
            )
        case let .mismatch(expected, actual):
            return RowStyle(
                "✕",
                .systemRed,
                String(
                    localized: "Doesn’t match — expected \(abbreviated(expected))",
                    comment: "Checksum report row: digest differs; %@ is the expected digest."
                ),
                tooltip: String(
                    localized: "Expected \(expected)\nFound \(actual)",
                    comment: "Checksum mismatch tooltip; %1$@ expected digest, %2$@ actual digest."
                )
            )
        case .missing:
            return RowStyle(
                "?",
                .systemOrange,
                String(
                    localized: "Not in this folder",
                    comment: "Checksum report row: the manifest names a file that isn't there."
                )
            )
        case .notDownloaded:
            // A plain cloud, not an SF Symbol: a private-use codepoint in a label renders as a
            // missing glyph anywhere the symbol font isn't the one drawing it.
            return RowStyle(
                "☁",
                .systemOrange,
                String(
                    localized: "Not downloaded — nothing was checked",
                    comment: "Checksum report row: a cloud placeholder was deliberately not read."
                ),
                tooltip: String(
                    localized: """
                    This file is stored in the cloud and its bytes aren’t on this Mac. Dirnex \
                    didn’t download it, so it wasn’t checked.
                    """,
                    comment: "Checksum report tooltip explaining why a cloud file was skipped."
                )
            )
        case .unreadable:
            return RowStyle(
                "!",
                .systemOrange,
                String(
                    localized: "Couldn’t be read",
                    comment: "Checksum report row: the file exists but could not be opened."
                )
            )
        case .extra:
            return RowStyle(
                "+",
                .tertiaryLabelColor,
                String(
                    localized: "Here, but not in the checksum file",
                    comment: "Checksum report row: a file the manifest says nothing about."
                )
            )
        }
    }

    /// The first and last eight hex digits of a digest — enough to compare against a published one
    /// at a glance, where 64 characters in a table cell is a wall nobody reads.
    private static func abbreviated(_ digest: String) -> String {
        guard digest.count > 20 else { return digest }
        return "\(digest.prefix(8))…\(digest.suffix(8))"
    }

    private struct RowStyle {
        let glyph: String
        let color: NSColor
        let detail: String
        let tooltip: String?

        init(_ glyph: String, _ color: NSColor, _ detail: String, tooltip: String? = nil) {
            self.glyph = glyph
            self.color = color
            self.detail = detail
            self.tooltip = tooltip
        }
    }
}
