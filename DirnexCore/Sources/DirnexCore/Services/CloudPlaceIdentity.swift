import Foundation

/// The stable identities of the sidebar's **Cloud** places — iCloud Drive, the Photos library, and
/// each provider mount under `~/Library/CloudStorage` (PLAN.md §M8, §M10, §M28).
///
/// Those rows are *discovered* on every rebuild rather than stored, so anything the user decides
/// about one of them has to be kept beside it under a name that survives the rediscovery: its place
/// in the section (``SidebarItemOrder``) and the name they gave it (``SidebarItemNames``). Both
/// stores key off these strings, which is why they are defined once, here, rather than by each.
///
/// **The strings are persisted, so they must never change.** They predate this type — the Cloud
/// order has been stored under them since the section became draggable — and a spelling that drifted
/// would silently send every row the user arranged back to the bottom of the section and drop every
/// name they chose. The tests pin them byte for byte for that reason.
public enum CloudPlaceIdentity {
    /// iCloud Drive. A literal rather than its path: the path is
    /// `~/Library/Mobile Documents/com~apple~CloudDocs`, which carries the user's home directory into
    /// the store and would lose the row's settings on a Mac where that differs.
    public static let iCloudDrive = "icloud"

    /// The Photos library, a literal for the same reason — and because there is only ever one.
    public static let photos = "photos"

    /// A provider mount, keyed off its **directory name** under `~/Library/CloudStorage` — the one
    /// stable thing about it. ``CloudStorageMount/name`` is a display string that changes the moment
    /// a second account of the same provider appears and both rows gain their account label, so
    /// keying off it would forget everything about both rows on the day one is added. The `mount:`
    /// prefix keeps that namespace clear of the two literals above.
    public static func mount(directoryName: String) -> String {
        "mount:\(directoryName)"
    }

    /// The identity of `place`, or `nil` for one that is not in the Cloud section.
    public static func of(_ place: SidebarPlace) -> String? {
        switch place {
        case .iCloudDrive: iCloudDrive
        case .photos: photos
        case let .cloudMount(mount): self.mount(directoryName: mount.directoryName)
        default: nil
        }
    }
}
