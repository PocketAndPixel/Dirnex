import AppKit

/// "Copy Path" — put file-system locations on the pasteboard as plain text.
///
/// Shared by the file pane's right-click menu (a row, the `..` row, or the empty space below the
/// list) and the path bar's crumb menu, so every "Copy Path" in the app produces the same shape:
/// one absolute path per line, in the order they were shown. This is the *textual* sibling of ⌘C
/// (`PanelViewController+Clipboard`), which instead writes file URLs Finder pastes as files — a
/// copy-path is for typing a location into a shell or a text field, not for moving bytes.
enum PathClipboard {
    /// The string a "Copy Path" of `paths` places on the pasteboard: one per line, order kept.
    static func text(for paths: [String]) -> String {
        paths.joined(separator: "\n")
    }

    /// Replace the pasteboard's contents with `paths` as newline-joined text. Defaults to the
    /// general pasteboard; a named one is injectable so a test can assert without clobbering the
    /// user's clipboard.
    static func copy(_ paths: [String], to pasteboard: NSPasteboard = .general) {
        pasteboard.clearContents()
        pasteboard.setString(text(for: paths), forType: .string)
    }
}
