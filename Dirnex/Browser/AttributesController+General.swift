import AppKit
import DirnexCore

/// The General tab: where the item is, and the three timestamps (PLAN.md §M14 Slice 4).
///
/// The dates are the reason this tab exists separately from Permissions. macOS keeps three and shows
/// two; the birth time in particular is reachable only through `setattrlist` and is displayed by
/// almost nothing, so having it here is already an answer Dirnex could not give before.
extension AttributesController {
    func makeGeneralTab() -> NSView {
        var rows: [NSView] = [
            AttributeRow.make(
                label: String(
                    localized: "Where:",
                    comment: "Info panel field label: the folder the item is in."
                ),
                value: snapshot.entry.path.parent?.path ?? snapshot.entry.path.path
            )
        ]

        if let destination = snapshot.entry.symlinkDestination {
            rows.append(AttributeRow.make(
                label: String(
                    localized: "Points to:",
                    comment: "Info panel field label: what a symbolic link resolves to."
                ),
                value: destination
            ))
        }

        rows.append(contentsOf: [
            AttributeRow.separator(),
            AttributeRow.make(
                label: String(
                    localized: "Created:",
                    comment: "Info panel field label: the item's birth time (st_birthtime)."
                ),
                value: AttributeFormatting.date(snapshot.attributes.creationDate)
            ),
            AttributeRow.make(
                label: String(
                    localized: "Modified:",
                    comment: "Info panel field label: last content modification (st_mtime)."
                ),
                value: AttributeFormatting.date(snapshot.attributes.modificationDate)
            ),
            AttributeRow.make(
                label: String(
                    localized: "Last opened:",
                    comment: "Info panel field label: last access time (st_atime)."
                ),
                value: AttributeFormatting.date(snapshot.attributes.accessDate)
            )
        ])

        if snapshot.isSymlink {
            rows.append(AttributeRow.note(String(
                localized: """
                This is a symbolic link, so everything shown here describes the link itself — not \
                the item it points to.
                """,
                comment: "Info panel note explaining that a symlink's own attributes are shown."
            )))
        }

        return AttributeRow.pane(rows, width: AttributesController.contentWidth)
    }
}
