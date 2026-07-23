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

        let apply: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            let format = ArchivePacking.Format.allCases[
                max(0, accessory.formatPopup.indexOfSelectedItem)
            ]
            let name = ArchivePacking.archiveFileName(
                baseName: accessory.nameField.stringValue,
                format: format
            )
            self?.confirmAndPack(
                sources: sources,
                archiveName: name,
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

    /// The pack sheet's accessory controls the completion handler reads back — a name field over a
    /// format popup. Boxed in a struct rather than a tuple to stay within SwiftLint's limits.
    private struct PackAccessory {
        let view: NSView
        let nameField: NSTextField
        let formatPopup: NSPopUpButton
    }

    /// Build the sheet's accessory: a name field over a format popup. The label column is sized to
    /// the wider of the two localized captions rather than a fixed width — the 48 pt that "Name:" /
    /// "Format:" fit in English clipped Russian "Формат:", and a translation's fit is a live concern.
    private func makePackAccessory(baseName: String) -> PackAccessory {
        let width: CGFloat = 340
        let nameLabel = packLabel(String(localized: "Name:"), y: 32)
        let formatLabel = packLabel(String(localized: "Format:"), y: 4)
        let labelWidth = ceil(max(
            nameLabel.intrinsicContentSize.width,
            formatLabel.intrinsicContentSize.width
        ))
        let fieldX = labelWidth + 8
        for label in [nameLabel, formatLabel] {
            label.frame = NSRect(x: 0, y: label.frame.minY, width: labelWidth, height: 18)
        }

        let container = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 56))

        let field = NSTextField(frame: NSRect(x: fieldX, y: 30, width: width - fieldX, height: 24))
        field.stringValue = baseName
        field.placeholderString = String(localized: "Archive name")

        let popup = NSPopUpButton(frame: NSRect(x: fieldX, y: 0, width: 220, height: 26))
        for format in ArchivePacking.Format.allCases { popup.addItem(withTitle: format.displayName) }
        popup.selectItem(at: 0)

        container.addSubview(nameLabel)
        container.addSubview(field)
        container.addSubview(formatLabel)
        container.addSubview(popup)
        return PackAccessory(view: container, nameField: field, formatPopup: popup)
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
                self?.runPack(sources: sources, target: target, destinationPane: destinationPane)
            }
            if let window = view.window {
                alert.beginSheetModal(for: window, completionHandler: proceed)
            } else {
                proceed(alert.runModal())
            }
            return
        }
        runPack(sources: sources, target: target, destinationPane: destinationPane)
    }

    /// Spawn `bsdtar` off-main to create the archive, then re-list the destination pane with the
    /// new archive selected. On failure the partial file is already cleaned up by `ArchivePacker`.
    private func runPack(
        sources: [FileEntry],
        target: VFSPath,
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
                        toArchiveAt: archivePath
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
