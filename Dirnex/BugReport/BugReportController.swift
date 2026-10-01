import AppKit
import DirnexCore

/// The Report a Bug dialog (PLAN.md §M30): a description, optional steps and a reply email, a box
/// for each fact about this Mac, and the exact body under *Show What Will Be Sent…*.
///
/// Nothing reaches the body that the user didn't type or tick, because the body is only ever built
/// by ``BugReportForm/report(system:licensed:crashReport:redaction:)`` from the form this dialog
/// edits. The preview and Send both call ``body()``, and everything it reads is fixed when the
/// dialog opens (the Mac's facts, the crash report), so what Send sends is what the preview showed.
///
/// When the server can't be reached, or refuses, the dialog stays with the text in it, and Copy
/// Report and Email Instead carry the same body another way. They are there from the start, so the
/// report can go by email even when nothing has failed.
@MainActor
final class BugReportController: NSViewController {
    /// What the dialog reads once, when it opens.
    struct Context {
        let endpoint: URL
        let system: BugReportSystemInfo
        /// Whether a license is present, or `nil` in a build that shows nothing about licenses,
        /// which offers no box for it.
        let licensed: Bool?
        let crashReport: CrashReportFile?
        let redaction: BugReportRedaction
    }

    /// The form as the user left it. The presenter keeps it when the dialog closes unsent.
    private(set) var form: BugReportForm
    let context: Context
    private let sender: BugReportSender

    /// Told when the dialog goes away: the form, and what became of the last send, if one happened.
    var onClose: ((BugReportForm, BugReportOutcome?) -> Void)?

    /// What became of the last send, or `nil` before one.
    private(set) var lastOutcome: BugReportOutcome?
    /// The send under way, which a test can await.
    private(set) var sending: Task<Void, Never>?
    /// What the last action has to say (a failed send, Copy Report, Email Instead), shown whenever
    /// the form has no problem to report instead.
    private var notice: (text: String, isError: Bool)?
    /// The crash report, read and trimmed the first time a body needs it, since trimming a large one
    /// takes far too long to repeat on every keystroke (``TrimmedCrashReport``).
    private lazy var trimmedCrashReport: TrimmedCrashReport? = context.crashReport
        .flatMap(CrashReportLocator.text(of:))
        .map { TrimmedCrashReport($0, redaction: context.redaction) }

    // Controls, laid out in `BugReportController+Layout.swift`.
    let descriptionView = BugReportTextView()
    let stepsView = BugReportTextView()
    let emailField = NSTextField.singleLine()
    let versionBox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    let macOSBox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    let modelBox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    let languageBox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    let licenseBox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    let crashBox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    let statusLabel = NSTextField(wrappingLabelWithString: "")
    let spinner = NSProgressIndicator()
    let previewButton = NSButton()
    let copyButton = NSButton()
    let emailButton = NSButton()
    let cancelButton = NSButton()
    let sendButton = NSButton()

    init(form: BugReportForm, context: Context, sender: BugReportSender = BugReportSender()) {
        var form = form
        // A box the dialog doesn't offer can't be ticked.
        if context.licensed == nil { form.includesLicenseState = false }
        if context.crashReport == nil { form.includesCrashReport = false }
        self.form = form
        self.context = context
        self.sender = sender
        super.init(nibName: nil, bundle: nil)
        title = DialogTitle.ofCommand("help.reportBug")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        // Tab from a text field goes by the window's key view loop; keep it current, since boxes are
        // grayed out and the license box hidden depending on the Mac.
        view.window?.autorecalculatesKeyViewLoop = true
        view.window?.makeFirstResponder(descriptionView)
    }

    override func viewDidDisappear() {
        super.viewDidDisappear()
        sending?.cancel()
        let callback = onClose
        onClose = nil
        callback?(form, lastOutcome)
    }

    // MARK: - The report

    /// The report as the form stands now.
    var report: BugReport {
        form.report(
            system: context.system,
            licensed: context.licensed ?? false,
            crashReport: form.includesCrashReport ? trimmedCrashReport : nil,
            redaction: context.redaction
        )
    }

    /// The exact bytes Send sends and the preview shows.
    func body() throws -> Data {
        try report.body()
    }

    /// Copies the controls into the form, then updates what depends on it.
    func formChanged() {
        form.whatHappened = descriptionView.string
        form.steps = stepsView.string
        form.email = emailField.stringValue
        form.includesVersion = versionBox.state == .on
        form.includesMacOS = macOSBox.state == .on
        form.includesMacModel = modelBox.state == .on
        form.includesLanguage = languageBox.state == .on
        form.includesLicenseState = licenseBox.state == .on
        form.includesCrashReport = crashBox.state == .on
        updateChrome()
    }

    /// Send, Copy and Email follow whether the server would take the report. The status line says,
    /// in this order: that a send is under way, what is wrong with the form when the user can do
    /// something about it, or what the last action had to say. A blank description says nothing:
    /// the disabled Send is enough, and a message would scold before anything was typed.
    func updateChrome() {
        let problem = report.problem
        let isSending = sending != nil
        sendButton.isEnabled = problem == nil && !isSending
        copyButton.isEnabled = problem == nil
        emailButton.isEnabled = problem == nil
        let status: (text: String, isError: Bool) = if isSending {
            (Self.sendingMessage, false)
        } else if let message = problem.flatMap(Self.message(for:)) {
            (message, false)
        } else {
            notice ?? ("", false)
        }
        statusLabel.stringValue = status.text
        statusLabel.textColor = status.isError ? .systemRed : .secondaryLabelColor
    }

    private func announce(_ text: String, isError: Bool) {
        notice = (text, isError)
        updateChrome()
    }

    // MARK: - Actions

    @objc func boxChanged(_ sender: NSButton) {
        formChanged()
    }

    @objc func showPreview(_ sender: Any?) {
        guard let body = try? body() else { return }
        presentAsSheet(BugReportPreviewController(body: body))
    }

    @objc func cancel(_ sender: Any?) {
        dismiss(sender)
    }

    @objc func send(_ sender: Any?) {
        guard report.problem == nil, sending == nil, let body = try? body() else { return }
        notice = nil
        spinner.startAnimation(nil)
        sending = Task { [weak self, sender = self.sender, endpoint = context.endpoint] in
            let outcome = await sender.send(body, to: endpoint)
            self?.finish(outcome)
        }
        updateChrome()
    }

    private func finish(_ outcome: BugReportOutcome) {
        sending = nil
        spinner.stopAnimation(nil)
        lastOutcome = outcome
        if outcome.isSent {
            dismiss(nil)
            return
        }
        announce(Self.message(for: outcome), isError: true)
    }

    /// The body as text, as Copy Report and Email Instead hand it on.
    private var bodyText: String? {
        (try? body()).flatMap { String(bytes: $0, encoding: .utf8) }
    }

    @objc func copyReport(_ sender: Any?) {
        guard let text = bodyText else { return }
        Self.putOnClipboard(text)
        announce(Self.copiedMessage, isError: false)
    }

    @objc func emailInstead(_ sender: Any?) {
        guard let link = try? BugReportMail.link(
            for: report,
            subject: Self.mailSubject,
            crashReportLeftOut: Self.crashReportLeftOutOfMail
        ) else { return }
        // The mail says the whole report is on the clipboard, so it has to be.
        if link.leavesOutCrashReport, let text = bodyText { Self.putOnClipboard(text) }
        let opened = NSWorkspace.shared.open(link.url)
        announce(opened ? Self.mailOpenedMessage : Self.noMailAppMessage, isError: !opened)
    }

    private static func putOnClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// The two multi-line fields. Tab and Shift-Tab move to the next control rather than typing a tab,
/// since a tab character in a bug report is never what was meant and the keyboard must be able to
/// leave the field.
final class BugReportTextView: NSTextView {
    /// Told after every edit.
    var onChange: (() -> Void)?

    override func insertTab(_ sender: Any?) {
        window?.selectNextKeyView(self)
    }

    override func insertBacktab(_ sender: Any?) {
        window?.selectPreviousKeyView(self)
    }

    override func didChangeText() {
        super.didChangeText()
        onChange?()
    }
}
