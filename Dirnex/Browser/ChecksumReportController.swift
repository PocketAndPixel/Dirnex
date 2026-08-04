import AppKit
import DirnexCore

/// The verification report (PLAN.md §M14 Slice 2) — what a checksum file said, and what the
/// files on disk actually are. Presented via `presentAsMovableWindow`, which retains it for its
/// on-screen lifetime; a report the user may want to read against the pane behind it is exactly the
/// case a sheet cannot serve, since a sheet cannot be moved.
///
/// The Synchronize dialog's diff table is the shape this borrows: one row per name, a glyph column
/// carrying the verdict, and a status line that answers before the table is read. What it does not
/// borrow is the checkboxes — nothing here is actionable. A verification is a *statement*, and the
/// one thing it must do is be unambiguous about which of five things happened to each name.
///
/// **The headline answer is the point.** A user checking a downloaded ISO wants one sentence, and
/// `ChecksumVerificationReport.isVerified` is that sentence: it is `false` if anything mismatched,
/// went missing, or could not be read — including a file left undownloaded, because nothing was
/// compared there and nothing may be asserted.
@MainActor
final class ChecksumReportController: NSViewController {
    private let report: ChecksumVerificationReport
    private let manifestName: String

    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private let verdictLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")

    /// Rows in the order the core produced them — manifest order, then extras — filtered to what is
    /// worth showing. Passing rows are collapsed away unless *everything* passed: on a report with
    /// one bad file among two hundred, a list of 199 green rows is where that file hides.
    private let rows: [ChecksumVerificationEntry]

    init(report: ChecksumVerificationReport, manifestName: String) {
        self.report = report
        self.manifestName = manifestName
        rows = report.isVerified && report.extraCount == 0
            ? report.entries
            : report.entries.filter { $0.status != .ok }
        super.init(nibName: nil, bundle: nil)
        title = DialogTitle.ofCommand("file.checksumVerify")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - View

    override func loadView() {
        let container = EscapeDismissingView()
        container.onEscape = { [weak self] in self?.close(nil) }
        DialogLayout.fill(container, with: [makeHeader(), makeTable(), makeFooter()])
        NSLayoutConstraint.activate([
            container.widthAnchor.constraint(equalToConstant: 660),
            container.heightAnchor.constraint(equalToConstant: 460)
        ])
        view = container
    }

    // MARK: - Row access (for the table extension)

    var rowCount: Int { rows.count }

    func row(at index: Int) -> ChecksumVerificationEntry? {
        rows.indices.contains(index) ? rows[index] : nil
    }

    @objc private func close(_ sender: Any?) { dismiss(sender) }
}

// MARK: - Construction

private extension ChecksumReportController {
    func makeHeader() -> NSView {
        // Whole sentences per branch rather than a spliced adjective (docs/NOTES.md): a language
        // that inflects or reorders cannot build a verdict from a verb and a noun.
        verdictLabel.stringValue = report.isVerified
            ? String(
                localized: "Everything checks out",
                comment: "Checksum report headline: every file the manifest names verified."
            )
            : String(
                localized: "Some files didn’t check out",
                comment: "Checksum report headline: at least one file failed or couldn't be read."
            )
        verdictLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        verdictLabel.textColor = report.isVerified ? .systemGreen : .systemRed

        detailLabel.stringValue = summary()
        detailLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.lineBreakMode = .byTruncatingTail

        let header = NSStackView(views: [verdictLabel, detailLabel])
        header.orientation = .vertical
        header.alignment = .leading
        header.spacing = 4
        header.widthAnchor.constraint(equalToConstant: 620).isActive = true
        return header
    }

    /// The counts, as whole clauses joined by `·`. Only the non-zero ones appear — a report reading
    /// "0 missing · 0 unreadable" invites the eye to skim past the number that is not zero.
    func summary() -> String {
        var parts: [String] = [
            String(
                localized: "\(manifestName) · \(report.algorithm.displayName)",
                comment: "Checksum report subtitle; %1$@ is the file name, %2$@ the algorithm."
            ),
            String(
                localized: "\(report.okCount) verified",
                comment: "Checksum report count: files whose digest matched. Plural."
            )
        ]
        if report.mismatchCount > 0 {
            parts.append(String(
                localized: "\(report.mismatchCount) failed",
                comment: "Checksum report count: files whose digest did not match. Plural."
            ))
        }
        if report.missingCount > 0 {
            parts.append(String(
                localized: "\(report.missingCount) missing",
                comment: "Checksum report count: files the manifest names that aren't there. Plural."
            ))
        }
        if report.notDownloadedCount > 0 {
            parts.append(String(
                localized: "\(report.notDownloadedCount) not downloaded",
                comment: "Checksum report count: cloud files left unfetched, so unchecked. Plural."
            ))
        }
        if report.unreadableCount > 0 {
            parts.append(String(
                localized: "\(report.unreadableCount) unreadable",
                comment: "Checksum report count: files that couldn't be read at all. Plural."
            ))
        }
        if report.extraCount > 0 {
            parts.append(String(
                localized: "\(report.extraCount) not listed",
                comment: "Checksum report count: files present that the manifest omits. Plural."
            ))
        }
        return parts.joined(separator: " · ")
    }

    func makeTable() -> NSView {
        addColumn("status", title: "", width: 26)
        addColumn(
            "name",
            title: String(
                localized: "File",
                comment: "Checksum report table column header: the file's relative path."
            ),
            width: 300
        )
        addColumn(
            "detail",
            title: String(
                localized: "Result",
                comment: "Checksum report table column header: what happened to the file."
            ),
            width: 280
        )
        tableView.rowHeight = 20
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsColumnResizing = true
        tableView.dataSource = self
        tableView.delegate = self

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.widthAnchor.constraint(equalToConstant: 620).isActive = true
        scrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 300).isActive = true
        return scrollView
    }

    func addColumn(_ identifier: String, title: String, width: CGFloat) {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(identifier))
        column.title = title
        column.width = width
        tableView.addTableColumn(column)
    }

    func makeFooter() -> NSView {
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let doneButton = NSButton(
            title: String(localized: "Done", comment: "Button that closes a results sheet."),
            target: self,
            action: #selector(close(_:))
        )
        doneButton.bezelStyle = .rounded
        doneButton.keyEquivalent = "\r"

        let footer = NSStackView(views: [spacer, doneButton])
        footer.orientation = .horizontal
        footer.spacing = 10
        footer.widthAnchor.constraint(equalToConstant: 620).isActive = true
        return footer
    }
}
