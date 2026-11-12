import AppKit
import DirnexCore

/// Following a link clicked in a Quick View page, at any of its three sizes (PLAN.md §M39 ▸ Slice 5).
///
/// The surface works out where the link leads (`QuickViewWebView+Links`); this does it. A file moves
/// the **active** pane's cursor, which is the pane whose cursor the preview is showing, at every size
/// — in ⌃Q the surface sits in the other pane, which is why the window does this and not the pane the
/// click landed in. The preview then follows the cursor as it follows every step, its header naming
/// the new file, and the pane's Back is the way back to the document the link was in.
extension BrowserWindowController {
    func followQuickViewLink(
        _ link: DocumentLink,
        from location: VFSPath,
        on surface: QuickViewPreviewView
    ) {
        switch link {
        case .sameDocument:
            return
        case let .location(target, fragment):
            let pane = focusedPanel
            // The page shows the active pane's cursor file. A click that arrives after the cursor
            // has left it is for a document no longer named, and would move the pane from the
            // wrong place.
            guard isQuickViewEnabled, pane.quickViewSourceLocation == location else { return }
            surface.links.pendingFragment = fragment.map {
                QuickViewLinks.PendingFragment(location: target, fragment: $0)
            }
            pane.revealLinkTarget(target)
        case let .external(url):
            NSWorkspace.shared.open(url)
        case let .refused(refusal):
            presentRefusedLink(refusal)
        }
    }

    private func presentRefusedLink(_ refusal: DocumentLink.Refusal) {
        let alert = NSAlert()
        alert.messageText = String(localized: "Can’t follow this link")
        alert.informativeText = Self.sentence(for: refusal)
        alert.alertStyle = .warning
        alert.addButton(withTitle: String(localized: "OK"))
        alert.enableEscapeToCancel()
        alert.beginSheetIfVisible(over: window)
    }

    /// Why a link leads nowhere, in words: the core says what the link names, and the app says it
    /// (docs/NOTES.md ▸ Localization).
    static func sentence(for refusal: DocumentLink.Refusal) -> String {
        switch refusal {
        case .localFile:
            String(localized: """
            It points to a file on a computer’s own disk, and this document is on a server or in an \
            archive.
            """)
        case let .anotherHost(host):
            String(localized: "It leads to another computer, “\(host)”.")
        case let .scheme(scheme):
            String(localized: "Dirnex doesn’t follow “\(scheme):” links.")
        case .malformed:
            String(localized: "It doesn’t name a place Dirnex can go to.")
        }
    }
}
