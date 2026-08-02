import AppKit
import DirnexCore

/// The path bar's **edit mode**: Cmd+L (or a double-click on the bar's empty area) swaps the crumb
/// row for a text field, and Tab completes against the child directories of what's typed.
///
/// Split out of `PathBarView` proper, which had reached SwiftLint's 500-line ceiling, and split by
/// *concept* rather than by line count (CLAUDE.md ▸ file splitting): the two halves of this view are
/// a row of buttons that displays a location and a text field that accepts one, and only the second
/// one has a lifecycle — begin, complete, commit or cancel — with the completion cache and the
/// `NSTextFieldDelegate` conformance that serves it. Everything it touches on the view had to widen
/// from `private` to internal, because a cross-file extension does not share the type's private
/// scope.
extension PathBarView {
    // MARK: - Edit mode

    /// Enter Cmd+L text-edit mode, prefilled with `base` and fully selected.
    func beginEditing(base: VFSPath) {
        guard !isEditing else { return }
        isEditing = true
        editBase = base
        completionDirectory = nil
        completionChildren = []

        editField.stringValue = base.path
        crumbStack.isHidden = true
        editField.isHidden = false
        delegate?.pathBarDidBeginEditing(self)
        window?.makeFirstResponder(editField)
        editField.currentEditor()?.selectAll(nil)
    }

    func endEditing(restoreFocus: Bool) {
        guard isEditing else { return }
        isEditing = false
        editField.isHidden = true
        crumbStack.isHidden = false
        if restoreFocus {
            delegate?.pathBarDidCancel(self)
        }
    }

    private func commit() {
        let raw = editField.stringValue
        let target = resolvedPath(from: raw)
        endEditing(restoreFocus: false)
        delegate?.pathBar(self, didCommit: raw, resolved: target)
    }

    /// Resolve typed text into a location: expand a leading `~`, and treat non-absolute
    /// input as relative to the directory Cmd+L was pressed in.
    private func resolvedPath(from text: String) -> VFSPath {
        var full = (text as NSString).expandingTildeInPath
        if full.isEmpty {
            full = editBase.path
        } else if !full.hasPrefix("/") {
            full = editBase.path + "/" + full
        }
        return VFSPath(backend: editBase.backend, path: full)
    }

    // MARK: - Completion

    /// The directory to complete within and the partial name being typed, derived from
    /// the raw text so a trailing slash (list all children) is distinct from a partial.
    private func completionContext(for text: String) -> (directory: VFSPath, partial: String) {
        let full = (text as NSString).expandingTildeInPath
        let absolute = full.hasPrefix("/") ? full : editBase.path + "/" + full
        if let slash = absolute.range(of: "/", options: .backwards) {
            let directory = VFSPath(
                backend: editBase.backend,
                path: String(absolute[..<slash.lowerBound])
            )
            let partial = String(absolute[slash.upperBound...])
            return (directory, partial)
        }
        return (editBase, absolute)
    }

    private func requestCompletion() {
        let (directory, _) = completionContext(for: editField.stringValue)
        if directory == completionDirectory {
            showCompletions()
            return
        }
        completionDirectory = directory
        Task { [weak self] in
            guard let self else { return }
            let names = await delegate?.pathBar(self, childDirectoriesOf: directory) ?? []
            guard isEditing, completionDirectory == directory else { return }
            completionChildren = names
            showCompletions()
        }
    }

    private func showCompletions() {
        guard isEditing, let editor = editField.currentEditor() else { return }
        isCompleting = true
        editor.complete(nil)
        isCompleting = false
    }

    // MARK: - NSTextFieldDelegate

    func controlTextDidEndEditing(_ obj: Notification) {
        // Losing first responder (a click on the table or the other pane) abandons the
        // edit and drops back to breadcrumbs — no commit, no focus grab. Return and Esc
        // reach endEditing through their own paths first, so isEditing is already false
        // by the time this fires for them and it's a no-op.
        endEditing(restoreFocus: false)
    }

    func controlTextDidChange(_ obj: Notification) {
        guard isEditing, !isCompleting else { return }
        // Warm the completion cache for the directory being typed so Tab is instant,
        // without popping a list on every keystroke.
        let (directory, _) = completionContext(for: editField.stringValue)
        guard directory != completionDirectory else { return }
        completionDirectory = directory
        Task { [weak self] in
            guard let self else { return }
            let names = await delegate?.pathBar(self, childDirectoriesOf: directory) ?? []
            guard isEditing, completionDirectory == directory else { return }
            completionChildren = names
        }
    }

    func control(
        _ control: NSControl,
        textView: NSTextView,
        completions words: [String],
        forPartialWordRange charRange: NSRange,
        indexOfSelectedItem index: UnsafeMutablePointer<Int>
    ) -> [String] {
        let partial = (textView.string as NSString).substring(with: charRange).lowercased()
        return completionChildren.filter { partial.isEmpty || $0.lowercased().hasPrefix(partial) }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            commit()
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            endEditing(restoreFocus: true)
            return true
        case #selector(NSResponder.insertTab(_:)):
            requestCompletion()
            return true
        case #selector(NSResponder.insertBacktab(_:)):
            return true
        default:
            return false
        }
    }
}
