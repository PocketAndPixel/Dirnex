import DirnexCore
import Foundation

/// Everything the attributes panel shows about one item, read in one go (PLAN.md §M14 Slice 4).
///
/// Three core reads composed for one display — `FileAttributeIO` for the mode/flags/owner/times,
/// `AccessControlListIO` for the ordered ACL, `ExtendedAttributeIO` for the named attributes — plus
/// the two name lookups that turn a uid and a gid into something a person recognizes. The
/// composition lives here rather than in `DirnexCore` because *which* of the three the panel wants
/// is a display decision; each read is already tested where it belongs.
///
/// All three act on the **link itself** for a symlink, matching Finder's Get Info and the rest of
/// the attributes machinery.
struct AttributesSnapshot {
    let entry: FileEntry
    let attributes: FileAttributes
    /// The item is a symlink, so everything here describes the link and not its target.
    let isSymlink: Bool
    let accessControlList: AccessControlList
    /// The attributes worth showing — `com.apple.provenance` is filtered out, because it is on
    /// essentially every file and so says nothing about this one.
    let extendedAttributes: [ExtendedAttribute]
    /// The owning user's name, or `nil` when the uid resolves to no account (a file restored from
    /// another Mac, most often).
    let ownerName: String?
    let groupName: String?

    /// Read one item. Throws only when the item itself cannot be `lstat`ed — a missing ACL is a
    /// normal empty answer, and unreadable extended attributes degrade to none rather than failing
    /// the whole panel, since the mode bits are the part the user came for.
    static func read(_ entry: FileEntry) throws -> AttributesSnapshot {
        let reading = try FileAttributeIO.read(at: entry.path)
        let list = (try? AccessControlListIO.read(
            at: entry.path, actsOnLink: reading.isSymlink
        )) ?? AccessControlList()
        let attributes = (try? ExtendedAttributeIO.all(at: entry.path)) ?? []
        return AttributesSnapshot(
            entry: entry,
            attributes: reading.attributes,
            isSymlink: reading.isSymlink,
            accessControlList: list,
            extendedAttributes: attributes.filter(\.isWorthShowing),
            ownerName: IdentityDirectory.userName(for: reading.attributes.ownerID),
            groupName: IdentityDirectory.groupName(for: reading.attributes.groupID)
        )
    }

    /// Whether an ACL applies on top of the mode bits.
    ///
    /// The panel must never show the nine `rwx` bits without saying so when this is `true` — an ACL
    /// does not change the mode (probed in M14: a file with an ACL still reads 0644), so the mode
    /// alone makes a false claim about the file's permissions on exactly the files where it matters.
    /// That is an M14 exit criterion, not a nicety.
    var hasAccessControlList: Bool { !accessControlList.isEmpty }

    /// `oleg (501)`, or just `501` when the id resolves to no account.
    var ownerDescription: String { Self.describe(ownerName, id: attributes.ownerID) }

    var groupDescription: String { Self.describe(groupName, id: attributes.groupID) }

    private static func describe(_ name: String?, id: UInt32) -> String {
        guard let name else { return String(id) }
        return String(
            localized: "\(name) (\(Int(id)))",
            comment: "An account in the info panel: %1$@ is the user or group name, %2$lld its id."
        )
    }
}
