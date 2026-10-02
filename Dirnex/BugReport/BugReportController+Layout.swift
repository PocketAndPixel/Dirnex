import AppKit
import DirnexCore

/// The Report a Bug dialog's layout. One column at a fixed size: the texts, the boxes, then the
/// status line and the buttons. The status line keeps two lines of room whether or not it says
/// anything, so nothing moves when a message appears.
///
/// *Show What Will Be Sent…* sits under the boxes rather than in the button row, because it is about
/// what they include, and because a row of five buttons does not fit in German or Russian.
extension BugReportController {
    static let contentWidth: CGFloat = 560
    private static let fieldWidth = contentWidth - 2 * DialogLayout.inset

    override func loadView() {
        let container = NSView()
        let stack = DialogLayout.fill(container, with: [
            makeIntro(),
            makeTextSection(Self.whatHappenedLabel, descriptionView, height: 96),
            makeTextSection(Self.stepsLabel, stepsView, height: 72),
            makeEmailSection(),
            makeBoxes(),
            makeStatus(),
            makeButtons()
        ])
        stack.setCustomSpacing(18, after: stack.arrangedSubviews[3])
        container.widthAnchor.constraint(equalToConstant: Self.contentWidth).isActive = true
        view = container
        fillControls()
        formChanged()
    }

    private func makeIntro() -> NSView {
        let intro = NSTextField(wrappingLabelWithString: Self.introText)
        intro.textColor = .secondaryLabelColor
        intro.preferredMaxLayoutWidth = Self.fieldWidth
        intro.widthAnchor.constraint(equalToConstant: Self.fieldWidth).isActive = true
        return intro
    }

    private func makeTextSection(_ title: String, _ textView: BugReportTextView, height: CGFloat) -> NSView {
        textView.isRichText = false
        textView.allowsUndo = true
        textView.font = .systemFont(ofSize: NSFont.systemFontSize)
        textView.textContainerInset = NSSize(width: 2, height: 4)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.setAccessibilityLabel(title)
        textView.onChange = { [weak self] in self?.formChanged() }

        let scroll = NSScrollView()
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            scroll.widthAnchor.constraint(equalToConstant: Self.fieldWidth),
            scroll.heightAnchor.constraint(equalToConstant: height)
        ])
        return section(title, scroll)
    }

    private func makeEmailSection() -> NSView {
        emailField.target = self
        emailField.action = #selector(boxChanged(_:))
        emailField.delegate = self
        emailField.setAccessibilityLabel(Self.emailLabel)
        emailField.widthAnchor.constraint(equalToConstant: Self.fieldWidth).isActive = true
        return section(Self.emailLabel, emailField)
    }

    private func section(_ title: String, _ control: NSView) -> NSView {
        let label = NSTextField(labelWithString: title)
        let stack = NSStackView(views: [label, control])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        return stack
    }

    private func makeBoxes() -> NSView {
        let boxes = [versionBox, macOSBox, modelBox, languageBox, licenseBox, crashBox]
        for box in boxes {
            box.target = self
            box.action = #selector(boxChanged(_:))
            box.lineBreakMode = .byTruncatingMiddle
            box.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        configure(previewButton, title: Self.previewTitle, action: #selector(showPreview(_:)))
        let views = [NSTextField(labelWithString: Self.includeLabel)] + boxes + [previewButton]
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.setCustomSpacing(10, after: crashBox)
        return stack
    }

    private func makeStatus() -> NSView {
        statusLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.preferredMaxLayoutWidth = Self.fieldWidth - 24
        statusLabel.maximumNumberOfLines = 2
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        let row = NSStackView(views: [spinner, statusLabel])
        row.orientation = .horizontal
        row.alignment = .top
        row.spacing = 6
        NSLayoutConstraint.activate([
            row.widthAnchor.constraint(equalToConstant: Self.fieldWidth),
            row.heightAnchor.constraint(equalToConstant: 32)
        ])
        return row
    }

    private func makeButtons() -> NSView {
        configure(copyButton, title: Self.copyTitle, action: #selector(copyReport(_:)))
        configure(emailButton, title: Self.emailTitle, action: #selector(emailInstead(_:)))
        configure(cancelButton, title: String(localized: "Cancel"), action: #selector(cancel(_:)))
        cancelButton.keyEquivalent = "\u{1b}"
        // ⌘Return, not Return: Return starts a new line in the two text fields, and a default
        // button's Return would send the report from the middle of a sentence.
        configure(sendButton, title: Self.sendTitle, action: #selector(send(_:)))
        sendButton.keyEquivalent = "\r"
        sendButton.keyEquivalentModifierMask = .command
        sendButton.bezelColor = AppPreferences.shared.palette.resolvedAccent

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let row = NSStackView(views: [copyButton, emailButton, spacer, cancelButton, sendButton])
        row.orientation = .horizontal
        row.spacing = 8
        row.widthAnchor.constraint(equalToConstant: Self.fieldWidth).isActive = true
        return row
    }

    private func configure(_ button: NSButton, title: String, action: Selector) {
        button.title = title
        button.bezelStyle = .rounded
        button.target = self
        button.action = action
    }

    /// Puts the form into the controls, and each fact into its box's title, so the user reads what
    /// a box sends rather than a description of it.
    private func fillControls() {
        descriptionView.string = form.whatHappened
        stepsView.string = form.steps
        emailField.stringValue = form.email
        let system = context.system
        let version = [system.appVersion, system.appBuild.map { "(\($0))" }].compactMap(\.self)
            .joined(separator: " ")
        setBox(
            versionBox,
            Self.versionBoxTitle,
            version.isEmpty ? nil : version,
            form.includesVersion
        )
        setBox(macOSBox, Self.macOSBoxTitle, system.macOS, form.includesMacOS)
        setBox(modelBox, Self.modelBoxTitle, system.macModel, form.includesMacModel)
        setBox(languageBox, Self.languageBoxTitle, system.language, form.includesLanguage)
        if let licensed = context.licensed {
            licenseBox.title = Self.licenseBoxTitle(licensed)
            licenseBox.state = form.includesLicenseState ? .on : .off
        } else {
            licenseBox.isHidden = true
        }
        let crashName = context.crashReport?.url.lastPathComponent
        setBox(crashBox, Self.crashBoxTitle, crashName, form.includesCrashReport)
        if crashName == nil { crashBox.title = Self.noCrashReportTitle }
    }

    /// A box whose fact couldn't be read is grayed out and empty, since it would send nothing.
    private func setBox(
        _ box: NSButton,
        _ title: (String?) -> String,
        _ value: String?,
        _ isOn: Bool
    ) {
        box.title = title(value)
        box.isEnabled = value != nil
        box.state = isOn && value != nil ? .on : .off
    }
}

extension BugReportController: NSTextFieldDelegate {
    func controlTextDidChange(_ notification: Notification) {
        formChanged()
    }
}
