import AppKit
import DirnexCore

/// The paged first-run tour (PLAN.md §M7 "First-run tour: palette-centric, 5 screens max"). The
/// *script* — the screens, their order, their copy, and the fact that every action they point at is
/// a real command — is `DirnexCore.FirstRunTour`; this is only the drawing and the paging.
///
/// It presents as a sheet over the browser window (so it can't be lost behind it), falling back to a
/// centered standalone window when there is none. Each screen shows an illustration, a headline,
/// body copy, and — resolved live from the registry — a small keyboard-reference list of the
/// commands it highlights, printing the same glyphs the menu and the ⌘K palette do. The last screen
/// hands the user straight into the palette, the one thing they have to learn to reach everything
/// else, which is what makes the tour "palette-centric".
@MainActor
final class FirstRunTourWindowController: NSWindowController, NSWindowDelegate {
    /// Called once when the tour ends, however it ends. `primaryChosen` is true only when the user
    /// finished on the last screen's primary button (as opposed to Skip / Not Now / closing the
    /// window) — the presenter uses it to decide what comes next.
    var onFinish: ((_ primaryChosen: Bool) -> Void)?

    /// The last screen's primary button label. The launch flow leaves it "Get Started" (it hands
    /// off to Full Disk Access onboarding next); the on-demand flow sets it to "Open Command
    /// Palette", the palette-centric payoff the tour's copy promises.
    var finalButtonTitle = String(localized: "Get Started")

    private let screens = FirstRunTour.screens
    private var index = 0
    private var didFinish = false
    private weak var sheetParent: NSWindow?

    // Views reconfigured per page rather than rebuilt, so paging never flickers the window.
    private let imageView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let bodyLabel = NSTextField(wrappingLabelWithString: "")
    private let commandsStack = NSStackView()
    private let dotsStack = NSStackView()
    private let backButton = NSButton()
    private let skipButton = NSButton()
    private let nextButton = NSButton()

    private static let contentWidth: CGFloat = 540
    private static let contentHeight: CGFloat = 476
    private static let bodyWidth: CGFloat = contentWidth - 88

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: Self.contentWidth, height: Self.contentHeight),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        super.init(window: window)
        window.delegate = self
        window.contentView = makeContentView()
        configure(for: 0)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Presentation

    /// Show the tour as a sheet over `parent`, or as a centered standalone window when there is
    /// none. Held strongly by the presenter for the duration, so it survives to report `onFinish`.
    func present(over parent: NSWindow?) {
        guard let window else { return }
        if let parent {
            sheetParent = parent
            parent.beginSheet(window) { _ in }
        } else {
            window.center()
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    /// End the tour exactly once, close the sheet/window, and report the outcome. Guarded so the
    /// button paths and a window-close can't both fire it.
    private func finish(primary: Bool) {
        guard !didFinish else { return }
        didFinish = true
        if let window, let sheetParent {
            sheetParent.endSheet(window)
        } else {
            window?.close()
        }
        onFinish?(primary)
    }

    func windowWillClose(_ notification: Notification) {
        // The standalone fallback's red close button lands here; treat it as "not now". A no-op
        // once a button already finished the tour, thanks to the guard.
        finish(primary: false)
    }

    // MARK: - Paging

    @objc private func goNext() {
        if index < screens.count - 1 {
            index += 1
            configure(for: index)
        } else {
            finish(primary: true) // the last screen's primary button
        }
    }

    @objc private func goBack() {
        guard index > 0 else { return }
        index -= 1
        configure(for: index)
    }

    @objc private func skip() {
        finish(primary: false)
    }

    /// Point every reconfigurable view at screen `page` and update the chrome (dots, button titles,
    /// Back's availability) for where in the tour it now sits.
    private func configure(for page: Int) {
        let screen = screens[page]
        let title = LocalizedCatalog.title(for: screen)
        imageView.image = NSImage(
            systemSymbolName: screen.symbol,
            accessibilityDescription: title
        )
        titleLabel.stringValue = title
        bodyLabel.stringValue = LocalizedCatalog.body(for: screen)
        populateCommands(screen.commandIDs)
        updateDots(current: page)

        let isLast = page == screens.count - 1
        backButton.isHidden = page == 0
        nextButton.title = isLast ? finalButtonTitle : String(localized: "Next")
        skipButton.title = isLast
            ? String(localized: "Not Now")
            : String(localized: "Skip Tour")
    }

    // MARK: - Command rows

    /// Rebuild the keyboard-reference list for a screen's highlighted commands. Each row resolves
    /// its title and *effective* shortcut from the registry, so it prints what the menu prints and
    /// tracks the user's rebindings; the whole list hides on the pure-welcome screen.
    private func populateCommands(_ ids: [String]) {
        commandsStack.arrangedSubviews.forEach {
            commandsStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        commandsStack.isHidden = ids.isEmpty
        for id in ids {
            guard let command = LocalizedCatalog.command(for: id) else { continue }
            let shortcut = KeyBindingStore.shared.shortcut(for: id)?.display
            commandsStack.addArrangedSubview(commandRow(title: command.title, shortcut: shortcut))
        }
    }

    /// One reference row: a fixed-width key-cap column (right-aligned, so titles line up whether or
    /// not a command has a shortcut) followed by the command's title.
    private func commandRow(title: String, shortcut: String?) -> NSView {
        let cap = KeyCapView(text: shortcut)
        let capColumn = NSView()
        capColumn.translatesAutoresizingMaskIntoConstraints = false
        capColumn.addSubview(cap)
        NSLayoutConstraint.activate([
            capColumn.widthAnchor.constraint(equalToConstant: 52),
            cap.trailingAnchor.constraint(equalTo: capColumn.trailingAnchor),
            cap.centerYAnchor.constraint(equalTo: capColumn.centerYAnchor),
            cap.topAnchor.constraint(greaterThanOrEqualTo: capColumn.topAnchor),
            cap.bottomAnchor.constraint(lessThanOrEqualTo: capColumn.bottomAnchor)
        ])

        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 13)
        label.textColor = .labelColor

        let row = NSStackView(views: [capColumn, label])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 12
        return row
    }

    // MARK: - Page dots

    private func updateDots(current: Int) {
        for (offset, view) in dotsStack.arrangedSubviews.enumerated() {
            (view as? PageDot)?.isCurrent = offset == current
        }
    }

    // MARK: - Layout

    private func makeContentView() -> NSView {
        let container = NSView()

        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.contentTintColor = .controlAccentColor
        imageView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 48, weight: .regular)

        titleLabel.font = .systemFont(ofSize: 22, weight: .bold)
        titleLabel.alignment = .center
        titleLabel.textColor = .labelColor

        bodyLabel.font = .systemFont(ofSize: 13)
        bodyLabel.alignment = .center
        bodyLabel.textColor = .secondaryLabelColor
        bodyLabel.preferredMaxLayoutWidth = Self.bodyWidth

        commandsStack.orientation = .vertical
        commandsStack.alignment = .leading
        commandsStack.spacing = 8

        let bodyStack = NSStackView(views: [imageView, titleLabel, bodyLabel, commandsStack])
        bodyStack.orientation = .vertical
        bodyStack.alignment = .centerX
        bodyStack.spacing = 14
        bodyStack.setCustomSpacing(20, after: bodyLabel)
        bodyStack.translatesAutoresizingMaskIntoConstraints = false

        let bottomBar = makeBottomBar()
        [bodyStack, bottomBar].forEach(container.addSubview)

        NSLayoutConstraint.activate([
            imageView.heightAnchor.constraint(equalToConstant: 58),
            bodyLabel.widthAnchor.constraint(equalToConstant: Self.bodyWidth),

            bodyStack.topAnchor.constraint(equalTo: container.topAnchor, constant: 34),
            bodyStack.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            bodyStack.leadingAnchor.constraint(
                greaterThanOrEqualTo: container.leadingAnchor,
                constant: 40
            ),

            bottomBar.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            bottomBar.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
            bottomBar.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -18),
            bottomBar.topAnchor.constraint(
                greaterThanOrEqualTo: bodyStack.bottomAnchor,
                constant: 16
            )
        ])
        return container
    }

    /// The bottom bar: page dots on the leading edge, the Skip / Back / Next buttons trailing.
    private func makeBottomBar() -> NSView {
        for _ in screens {
            dotsStack.addArrangedSubview(PageDot())
        }
        dotsStack.orientation = .horizontal
        dotsStack.spacing = 7

        configureButton(backButton, title: String(localized: "Back"), action: #selector(goBack))
        configureButton(skipButton, title: String(localized: "Skip Tour"), action: #selector(skip))
        skipButton.keyEquivalent = "\u{1b}" // ⎋ leaves the tour, like every other Dirnex sheet
        configureButton(nextButton, title: String(localized: "Next"), action: #selector(goNext))
        nextButton.keyEquivalent = "\r" // ⏎ advances / opens the palette; also the default button

        let trailing = NSStackView(views: [skipButton, backButton, nextButton])
        trailing.orientation = .horizontal
        trailing.spacing = 10

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let bar = NSStackView(views: [dotsStack, spacer, trailing])
        bar.orientation = .horizontal
        bar.alignment = .centerY
        bar.translatesAutoresizingMaskIntoConstraints = false
        return bar
    }

    private func configureButton(_ button: NSButton, title: String, action: Selector) {
        button.title = title
        button.bezelStyle = .rounded
        button.target = self
        button.action = action
        button.translatesAutoresizingMaskIntoConstraints = false
    }
}

/// A rounded key-cap that prints a shortcut glyph ("⌘K", "F5") in a subtle filled token, matching
/// how the reference reads in the menus. Draws nothing at all for a command with no shortcut, so its
/// row still occupies the aligned key-cap column but shows an empty slot.
private final class KeyCapView: NSView {
    private let label = NSTextField(labelWithString: "")

    init(text: String?) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 5

        label.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        label.textColor = .secondaryLabelColor
        label.alignment = .center
        label.stringValue = text ?? ""
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 7),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -7)
        ])
        isHidden = (text ?? "").isEmpty
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func updateLayer() {
        // A quinary fill reads as a key cap without competing with the command title beside it, and
        // tracks light/dark because it is resolved here on every appearance change.
        layer?.backgroundColor = NSColor.quaternaryLabelColor.withAlphaComponent(0.35).cgColor
    }

    override var allowsVibrancy: Bool { false }
}

/// One page-position dot in the bottom bar: a small filled circle, tinted for the current page and
/// dimmed for the rest.
private final class PageDot: NSView {
    var isCurrent = false {
        didSet { needsDisplay = true }
    }

    private static let diameter: CGFloat = 7

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Self.diameter),
            heightAnchor.constraint(equalToConstant: Self.diameter)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ dirtyRect: NSRect) {
        let color = isCurrent ? NSColor.controlAccentColor : NSColor.tertiaryLabelColor
        color.setFill()
        NSBezierPath(ovalIn: bounds).fill()
    }
}
