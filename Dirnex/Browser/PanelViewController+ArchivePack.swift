import AppKit
import DirnexCore

/// Pack (Alt+F5) — TC's "create an archive from the selected files" (PLAN.md §M4 "pack via
/// F5-with-archive-target"), the inverse of F5 copy-out from inside an archive.
///
/// Packing isn't a cross-backend copy through `CopyEngine`; it writes one archive file directly.
/// The marked/cursor items of this (real, local) pane are handed to `bsdtar` via `ArchivePacker`,
/// which creates the archive in the *other* pane's folder — the same default destination as F5.
/// A small sheet picks the base name and container format; the new archive lands selected in the
/// other pane, immediately browsable (its suffix is one `ArchiveType.isBrowsable` recognizes).
extension PanelViewController {
    @objc func packSelection(_ sender: Any?) {
        beginArchivePacking()
    }

    /// Whether this pane can be a pack *source*: a real on-disk folder (not a read-only archive or
    /// a virtual search-results listing), where every selected item shares one parent directory so
    /// a single `bsdtar -C` covers them.
    var canPackFromHere: Bool {
        panel.path.backend == .local && !isVirtualDirectory
    }

    /// Validate the marked/cursor items, resolve the destination (the other pane), and raise the
    /// pack sheet. Re-checks `canPackFromHere` since Alt+F5 can arrive via the key model.
    func beginArchivePacking() {
        guard canPackFromHere else { return }
        let sources = selectionTargets()
        guard !sources.isEmpty, let destPane = host?.panelCounterpart(of: self) else { return }

        // The archive is written straight into the other pane, so it must be a real writable folder.
        guard destPane.panel.path.backend == .local,
              destPane.backend.capabilities.contains(.write) else {
            presentOperationFailure(
                message: String(localized: "Can’t pack here"),
                detail: String(
                    localized: "Open a folder on disk in the other panel to hold the new archive."
                )
            )
            return
        }
        presentPackSheet(sources: sources, destinationPane: destPane)
    }

    // MARK: - Sheet

    private func presentPackSheet(sources: [FileEntry], destinationPane: PanelViewController) {
        let destination = destinationPane.panel.path
        let alert = NSAlert()
        alert.messageText = sources.count == 1
            ? String(localized: "Pack “\(sources[0].name)”")
            : String(localized: "Pack \(sources.count) items")
        alert.informativeText = String(
            localized: "Create an archive in “\(destination.lastComponent)”."
        )
        alert.addButton(withTitle: String(localized: "Pack"))
        alert.addButton(withTitle: String(localized: "Cancel"))

        let baseName = ArchivePacking.defaultBaseName(
            forSourceNames: sources.map(\.name),
            sourceDirectoryName: panel.path.lastComponent
        )
        let accessory = makePackAccessory(baseName: baseName)
        alert.accessoryView = accessory.view
        alert.window.initialFirstResponder = accessory.nameField

        // `accessory` is captured (and so kept alive) by this closure for the sheet's lifetime,
        // which is what keeps the format popup's target — the accessory itself — from being
        // deallocated under it: `NSControl.target` is weak.
        let apply: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            let format = accessory.format
            let name = ArchivePacking.archiveFileName(
                baseName: accessory.nameField.stringValue,
                format: format
            )
            self?.confirmAndPack(
                sources: sources,
                archiveName: name,
                format: format,
                level: accessory.level,
                destinationPane: destinationPane
            )
        }
        if let window = view.window {
            alert.beginSheetModal(for: window, completionHandler: apply)
            accessory.nameField.selectText(nil)
        } else {
            apply(alert.runModal())
        }
    }

    /// Build the sheet's accessory: a name field over a format popup over a compression popup. The
    /// label column is sized to the widest of the three localized captions rather than a fixed
    /// width — the 48 pt that "Name:" / "Format:" fit in English clipped Russian "Формат:", and a
    /// translation's fit is a live concern.
    ///
    /// Rows are laid out bottom-up on a 30 pt pitch: compression at y = 0, format at 30, name at
    /// 60, each label centred on its control.
    private func makePackAccessory(baseName: String) -> PackAccessory {
        let width: CGFloat = 340
        let nameLabel = packLabel(String(localized: "Name:"), y: 62)
        let formatLabel = packLabel(String(localized: "Format:"), y: 34)
        let levelLabel = packLabel(String(localized: "Compression:"), y: 4)
        let labels = [nameLabel, formatLabel, levelLabel]
        let labelWidth = ceil(labels.map(\.intrinsicContentSize.width).reduce(0, max))
        let fieldX = labelWidth + 8
        for label in labels {
            label.frame = NSRect(x: 0, y: label.frame.minY, width: labelWidth, height: 18)
        }

        let container = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 86))

        let field = NSTextField(frame: NSRect(x: fieldX, y: 60, width: width - fieldX, height: 24))
        field.stringValue = baseName
        field.placeholderString = String(localized: "Archive name")

        // Both popups draw through the catalog, not through `displayName`: the core's English is
        // data here, and a literal at a variable-driven call site would extract nothing.
        let formatPopup = NSPopUpButton(frame: NSRect(x: fieldX, y: 30, width: 220, height: 26))
        for format in ArchivePacking.Format.allCases {
            formatPopup.addItem(withTitle: LocalizedCatalog.title(for: format))
        }
        formatPopup.selectItem(at: 0)

        let levelPopup = NSPopUpButton(frame: NSRect(x: fieldX, y: 0, width: 220, height: 26))
        for level in ArchivePacking.CompressionLevel.allCases {
            levelPopup.addItem(withTitle: LocalizedCatalog.title(for: level))
        }
        levelPopup.selectItem(
            at: ArchivePacking.CompressionLevel.allCases.firstIndex(of: .normal) ?? 0
        )

        for subview in labels + [field, formatPopup, levelPopup] {
            container.addSubview(subview)
        }
        return PackAccessory(
            view: container,
            nameField: field,
            formatPopup: formatPopup,
            levelPopup: levelPopup,
            levelLabel: levelLabel
        )
    }

    private func packLabel(_ text: String, y: CGFloat) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.alignment = .right
        label.frame = NSRect(x: 0, y: y, width: 48, height: 18)
        return label
    }

    // MARK: - Conflict + run

    /// Guard an existing file at the target before packing — `bsdtar -c` would silently overwrite
    /// it — then pack. A collision raises a Replace/Cancel confirmation (default Cancel).
    private func confirmAndPack(
        sources: [FileEntry],
        archiveName: String,
        format: ArchivePacking.Format,
        level: ArchivePacking.CompressionLevel,
        destinationPane: PanelViewController
    ) {
        let target = destinationPane.panel.path.appending(archiveName)
        if (try? destinationPane.backend.stat(at: target)) != nil {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = String(localized: "“\(archiveName)” already exists")
            alert.informativeText = String(
                localized: "Replace the existing archive in “\(destinationPane.panel.path.lastComponent)”?"
            )
            alert.addButton(withTitle: String(localized: "Replace"))
            alert.addButton(withTitle: String(localized: "Cancel"))
            let proceed: (NSApplication.ModalResponse) -> Void = { [weak self] response in
                guard response == .alertFirstButtonReturn else { return }
                self?.runPack(
                    sources: sources,
                    target: target,
                    format: format,
                    level: level,
                    destinationPane: destinationPane
                )
            }
            if let window = view.window {
                alert.beginSheetModal(for: window, completionHandler: proceed)
            } else {
                proceed(alert.runModal())
            }
            return
        }
        runPack(
            sources: sources,
            target: target,
            format: format,
            level: level,
            destinationPane: destinationPane
        )
    }

    /// Spawn `bsdtar` off-main to create the archive, then re-list the destination pane with the
    /// new archive selected. On failure the partial file is already cleaned up by `ArchivePacker`.
    private func runPack(
        sources: [FileEntry],
        target: VFSPath,
        format: ArchivePacking.Format,
        level: ArchivePacking.CompressionLevel,
        destinationPane: PanelViewController
    ) {
        let sourceNames = sources.map(\.name)
        let sourceDirectory = panel.path.path
        let archivePath = target.path
        Task {
            do {
                try await Task.detached(priority: .userInitiated) {
                    try ArchivePacker.pack(
                        sourceNames: sourceNames,
                        inDirectory: sourceDirectory,
                        toArchiveAt: archivePath,
                        format: format,
                        level: level
                    )
                }.value
                destinationPane.refreshCurrentDirectory(selecting: target)
            } catch {
                presentOperationFailure(
                    message: String(localized: "Couldn’t create the archive"),
                    detail: describe(error)
                )
            }
        }
    }
}
