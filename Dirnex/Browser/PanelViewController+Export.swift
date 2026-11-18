import AppKit
import DirnexCore

/// What File ▸ Export… is asked to make: the page `source` draws, as `format`, named `name`, in
/// `folder`, which is on the other pane's backend. `createsFolder` when the folder is not there yet
/// and the user pressed Export a second time to make it (2026-11-18).
struct MarkdownExportRequest {
    let source: FileEntry
    let format: MarkdownExport.Format
    let name: String
    let folder: VFSPath
    var createsFolder = false
}

/// What the export sheet does with the folder its field names (2026-11-18).
enum ExportFolderCheck: Equatable {
    /// There and writable: export into it.
    case ready
    /// Not there, and the user pressed Export again while the field named it: make it, then export.
    case create
    /// Not there: say so under the form, and make it on the next press if the field still names it.
    case offerToCreate(String)
    /// It cannot take the file, for the reason given.
    case refused(String)
}

/// File ▸ Export… (PLAN.md §M39 ▸ Slice 12): the Markdown file under the cursor, rendered as a page
/// of its own and saved as HTML or PDF.
///
/// **It lands like F5**, as decided when M39 opened. A sheet takes the format, the name and the other
/// pane's folder, the last two editable. The page is written to a staged file under its real name
/// (`MarkdownExportStaging`), and the queue copies that file into the folder with F5's conflict
/// question, its undo and every backend F5 writes to.
///
/// **It acts on the cursor's file wherever it is**, with Quick View on or off (Oleg's call): a file on
/// a server or in a zip is brought down first through the funnel Share uses, after the sheet, so a
/// user who backs out has fetched nothing. The page is the preview's, so it holds what the preview
/// drew (`MarkdownExportFile`).
extension PanelViewController {
    @objc func exportRenderedPage(_ sender: Any?) {
        beginExport()
    }

    /// The Markdown file Export acts on: the cursor's, never the marked set, the `..` row or a
    /// folder. A row is recognized by its extension, the preview's list, and a file on this disk by
    /// its type too, as the preview recognizes one.
    var exportableCursorFile: FileEntry? {
        guard !cursorOnParentRow, let entry = panel.currentEntry, entry.kind == .file else {
            return nil
        }
        let extensionName = (entry.name as NSString).pathExtension.lowercased()
        if QuickViewPreviewView.markdownExtensions.contains(extensionName) { return entry }
        guard entry.path.backend == .local else { return nil }
        return QuickViewPreviewView.isRenderableMarkdown(entry.path.localURL) ? entry : nil
    }

    /// Whether Export is offered: a Markdown file under the cursor and a pane to export it into.
    var canExport: Bool {
        exportableCursorFile != nil && host?.panelCounterpart(of: self) != nil
    }

    /// Raise the export sheet over the cursor's Markdown file, or say why the other pane cannot take
    /// the file. Re-checks what the menu checked, since ⌘K and AppleScript arrive without it.
    func beginExport() {
        guard let source = exportableCursorFile,
              let destinationPane = host?.panelCounterpart(of: self) else { return }
        let destination = destinationPane.panel.path
        guard !destinationPane.isVirtualDirectory,
              destinationPane.backend.capabilities(for: destination).contains(.write)
        else {
            presentOperationFailure(
                message: String(
                    localized: "Can’t export here",
                    comment: "Export failure title when the other panel cannot receive a file."
                ),
                detail: String(
                    localized: "Open a folder that can be written to in the other panel to hold the exported file.",
                    comment: "Export failure detail when the other panel cannot receive a file."
                )
            )
            return
        }
        presentExportSheet(source: source, destinationPane: destinationPane)
    }

    // MARK: - Sheet

    private func presentExportSheet(source: FileEntry, destinationPane: PanelViewController) {
        guard let window = view.window else { return }
        let format = MarkdownExportFormatMemory().format
        let alert = NSAlert()
        alert.messageText = String(
            localized: "Export “\(source.name)”",
            comment: "Export sheet title; the argument is the Markdown file's name."
        )
        alert.informativeText = String(
            localized: "Save the rendered page as a file of its own.",
            comment: "Export sheet body, under its title."
        )
        alert.addButton(withTitle: String(
            localized: "Export",
            comment: "Export sheet button that saves the rendered page."
        ))
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.enableEscapeToCancel()

        let name = MarkdownExport.fileName(forSource: source.name, as: format)
        let accessory = MarkdownExportAccessory.make(
            format: format,
            name: name,
            folder: destinationPane.panel.path.path
        )
        alert.accessoryView = accessory.view
        alert.window.initialFirstResponder = accessory.nameField
        accessory.routeExport(through: alert.buttons[0])
        accessory.onHeightChange = { [weak alert] in alert?.layout() }
        accessory.onExport = { [weak self, weak alert, weak accessory] in
            guard let self, let alert, let accessory else { return }
            exportPressed(
                on: alert,
                accessory: accessory,
                source: source,
                destinationPane: destinationPane
            )
        }
        // The closure keeps the accessory, the popup's and the button's target, alive for the
        // sheet's lifetime: `NSControl.target` is weak.
        alert.beginSheetModal(for: window) { _ in accessory.onExport = nil }
        Self.selectStem(of: accessory.nameField)
    }

    /// Put the name's stem under the insertion point, extension left out, as a Save sheet does.
    private static func selectStem(of field: NSTextField) {
        field.selectText(nil)
        let stem = (field.stringValue as NSString).deletingPathExtension
        field.currentEditor()?.selectedRange = NSRange(
            location: 0,
            length: (stem as NSString).length
        )
    }

    /// Check the name and the folder with the sheet still up, then take it down and export, or say
    /// what is wrong under the form and put the cursor where the fix goes.
    private func exportPressed(
        on alert: NSAlert,
        accessory: MarkdownExportAccessory,
        source: FileEntry,
        destinationPane: PanelViewController
    ) {
        let name = accessory.nameField.stringValue
        if let problem = MarkdownExport.problem(withName: name) {
            accessory.showError(Self.sentence(for: problem, name: name))
            alert.window.makeFirstResponder(accessory.nameField)
            return
        }
        let base = destinationPane.panel.path
        let folder = Self.exportFolder(typed: accessory.folderField.stringValue, from: base)
        let backend = destinationPane.backend
        accessory.setBusy(true)
        Task { [weak self] in
            // The other pane's own folder was checked before the sheet went up.
            let check: ExportFolderCheck = folder == base
                ? .ready
                : await Self.folderCheck(folder, confirmed: accessory.folderToCreate, on: backend)
            accessory.setBusy(false)
            switch check {
            case .ready, .create:
                break
            case let .offerToCreate(sentence):
                // Asked once, under the form, because the field takes a path from a root: a typo
                // there would otherwise make a stray folder somewhere nobody is looking (Oleg's call,
                // 2026-11-18). The next press with the field unchanged is the answer.
                accessory.folderToCreate = folder
                accessory.showError(sentence)
                alert.window.makeFirstResponder(accessory.folderField)
                return
            case let .refused(sentence):
                accessory.folderToCreate = nil
                accessory.showError(sentence)
                alert.window.makeFirstResponder(accessory.folderField)
                return
            }
            MarkdownExportFormatMemory().format = accessory.format
            alert.window.sheetParent?.endSheet(alert.window, returnCode: .alertFirstButtonReturn)
            self?.runExport(MarkdownExportRequest(
                source: source,
                format: accessory.format,
                name: name,
                folder: folder,
                createsFolder: check == .create
            ))
        }
    }

    /// The folder typed text names, on `base`'s backend: `base` itself when the field is empty, a
    /// path taken from `base` when it does not start at a root, `~` expanded on this disk only.
    static func exportFolder(typed text: String, from base: VFSPath) -> VFSPath {
        var path = text.trimmingCharacters(in: .whitespaces)
        if base.backend == .local { path = (path as NSString).expandingTildeInPath }
        if path.isEmpty { return base }
        if !path.hasPrefix("/") { path = base.path + "/" + path }
        while path.count > 1, path.hasSuffix("/") {
            path.removeLast()
        }
        return VFSPath(backend: base.backend, path: path)
    }

    /// What the sheet does with `folder`: export into it, offer to make it, make it, or refuse.
    ///
    /// A folder that is not there was refused outright until 2026-11-18. Now it is offered: the first
    /// press says so, and a second press while the field still names it (`confirmed`) makes it and
    /// every folder on its way. What it needs is the deepest folder on the way that is there, and that
    /// folder has to take writes. A file standing on the way is named, as F7 names it; a file standing
    /// where the folder itself would be keeps the sentence it always had.
    static func folderCheck(
        _ folder: VFSPath,
        confirmed: VFSPath?,
        on backend: any VFSBackend
    ) async -> ExportFolderCheck {
        let state = await BlockingWork.run {
            Result { try NestedCreation.state(of: folder, using: backend) }
        }
        switch state {
        case .success(.present):
            return backend.capabilities(for: folder).contains(.write)
                ? .ready
                : .refused(readOnlySentence(folder))
        case let .success(.missing(under)):
            guard backend.capabilities(for: under).contains(.write) else {
                return .refused(readOnlySentence(under))
            }
            return confirmed == folder
                ? .create
                : .offerToCreate(String(
                    localized: "There’s no folder “\(folder.path)”. Press Export again to create it.",
                    comment: """
                    Export sheet note: the typed folder does not exist yet, and pressing Export once more \
                    makes it. The argument is its path; “Export” is the sheet's button.
                    """
                ))
        case let .failure(error):
            if case let .notADirectory(blocker)? = error as? VFSError, blocker != folder {
                return .refused(fileInTheWaySentence(blocker))
            }
            return .refused(String(
                localized: "There’s no folder “\(folder.path)”.",
                comment: "Export sheet error: the typed folder does not exist. The argument is its path."
            ))
        }
    }

    private static func readOnlySentence(_ folder: VFSPath) -> String {
        String(
            localized: "Files can’t be written to “\(folder.path)”.",
            comment: "Export sheet error: the typed folder is read-only. The argument is its path."
        )
    }

    private static func sentence(for problem: MarkdownExport.NameProblem, name: String) -> String {
        switch problem {
        case .empty:
            String(
                localized: "Type a name for the exported file.",
                comment: "Export sheet error: the name field is empty."
            )
        case .containsSlash:
            String(
                localized: "File names can’t contain the “/” character.",
                comment: "Create-file failure detail: slash in name."
            )
        case .reserved:
            String(
                localized: "“\(name)” can’t be used as a file name.",
                comment: "Export sheet error: the name is “.” or “..”. The argument is the name."
            )
        }
    }

    // MARK: - Exporting

    /// Bring the source down if it is not on this disk, then write the page and queue its copy.
    func runExport(_ request: MarkdownExportRequest) {
        // A server's file is drawn from a copy alone in a temp folder, so its wiki links are found
        // in this pane's listing, as the preview finds them (`wikiLinkFiles`).
        let locateFile: (@Sendable (String) -> String?)? = request.source.path.backend == .local
            ? nil
            : QuickViewMarkdownWikiLinks.listed(namesListed(beside: request.source.path))
        let name = request.source.name
        materialize([request.source], for: .export, includingPlaceholders: true) {
            Self.exportFailureTitle(name)
        } then: { [weak self] urls in
            guard let self, let url = urls.first else { return }
            Task { await self.export(url, request, locateFile: locateFile) }
        }
    }

    /// Write the page `url` draws into a staged file named as the request asks, and hand its copy to
    /// the queue. Internal so a test can run it with the source already on this disk, since
    /// everything before it is a sheet.
    func export(
        _ url: URL,
        _ request: MarkdownExportRequest,
        locateFile: (@Sendable (String) -> String?)? = nil
    ) async {
        let staged: URL
        do {
            staged = try MarkdownExportStaging.newFile(named: request.name)
            try await MarkdownExportFile.write(
                request.format,
                from: url,
                sourceName: request.source.name,
                locateFile: locateFile,
                to: staged
            )
        } catch {
            presentExportFailure(error, source: request.source.name)
            return
        }
        // The folder the user said to make is made only now, with the page written, so a source
        // that could not be drawn or a download that was stopped leaves no empty folder behind. It is
        // journaled as a New Folder of its own: ⌘Z takes back the copy first and then the folders,
        // each only while empty, which is the order they were made in reverse.
        if request.createsFolder {
            let backend = backend
            let folder = request.folder
            do {
                let made = try await BlockingWork.run {
                    Result { try NestedCreation.makeFolders(upTo: folder, using: backend) }
                }.get()
                if let record = UndoRecord.newFolders(made) { host?.recordUndoableAction(record) }
            } catch {
                MarkdownExportStaging.discard(staged)
                presentOperationFailure(
                    message: Self.exportFailureTitle(request.source.name),
                    detail: describeCreateFailure(error, making: folder)
                )
                return
            }
        }
        do {
            let entry = try LocalBackend().stat(at: .local(staged.path))
            submit(
                FileOperation(kind: .copy, sources: [entry], destinationDirectory: request.folder)
            )
        } catch {
            MarkdownExportStaging.discard(staged)
            presentExportFailure(error, source: request.source.name)
        }
    }

    private func presentExportFailure(_ error: any Error, source: String) {
        presentOperationFailure(
            message: Self.exportFailureTitle(source),
            detail: exportFailureDetail(error)
        )
    }

    private static func exportFailureTitle(_ source: String) -> String {
        String(
            localized: "Couldn’t export “\(source)”",
            comment: "Export failure title; the argument is the Markdown file's name."
        )
    }

    private func exportFailureDetail(_ error: any Error) -> String {
        switch error {
        case MarkdownExportFile.Failure.notText:
            String(
                localized: "The file isn’t text, so there is no page to export.",
                comment: "Export failure detail: the Markdown file holds binary data."
            )
        case MarkdownExportFile.Failure.tooLarge:
            String(
                localized: "Files larger than 64 MB aren’t exported.",
                comment: "Export failure detail: the Markdown file is over the 64 MB export limit."
            )
        case is MarkdownExportPDF.Failure:
            String(
                localized: "The PDF couldn’t be made.",
                comment: "Export failure detail: printing the page to PDF failed."
            )
        default:
            describe(error)
        }
    }
}
