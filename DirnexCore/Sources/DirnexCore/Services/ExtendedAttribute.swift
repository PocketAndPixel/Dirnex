import Foundation

/// One extended attribute — its name and its raw bytes — plus the classification the panel needs to
/// decide how to *show* it (PLAN.md §M14 Slice 4).
///
/// **Presence carries no information, so this is a list, never a badge.** `com.apple.provenance` is
/// on essentially every file on a modern Mac (verified across the repo, `~`, and freshly created
/// files; `xattr -c` does not keep it away), which is why `ls -l`'s `@` marker is useless and why the
/// M14 probe killed the row badge before it was built. What is worth showing is a *named* attribute
/// the user acts on — `com.apple.quarantine` above all — so ``isWorthShowing`` filters the noise and
/// the panel lists what is left.
public struct ExtendedAttribute: Sendable, Hashable {
    /// The attribute name, e.g. `com.apple.quarantine`. At most `XATTR_MAXNAMELEN` (127) bytes.
    public let name: String
    /// The raw value. Kept as bytes because most of these are not text (see ``Value``).
    public let data: Data

    public init(name: String, data: Data) {
        self.name = name
        self.data = data
    }

    /// The attribute macOS stamps on essentially every file. Never shown — it would light up on
    /// everything and so says nothing about the file it is on.
    public static let provenanceName = "com.apple.provenance"

    /// The quarantine flag Gatekeeper reads: the one attribute a user actually reaches for, and the
    /// one worth offering to remove (docs/NOTES.md records that `xattr -dr` is the form that exits 0).
    public static let quarantineName = "com.apple.quarantine"

    /// Whether this attribute belongs in the panel's list. Only ``provenanceName`` is filtered — a
    /// broader "hide anything `com.apple.*`" rule would hide the quarantine flag and the
    /// where-from URLs, which are the two most useful things here.
    public var isWorthShowing: Bool { name != Self.provenanceName }

    /// How the value should be rendered. Probed against real attributes on this Mac (2026-07-31):
    /// `com.apple.quarantine` is plain UTF-8, `com.apple.metadata:kMDItemWhereFroms` and the Finder
    /// tags are **binary property lists**, and `com.apple.macl` / `com.apple.lastuseddate#PS` /
    /// `com.apple.provenance` are opaque bytes. All three shapes occur on one ordinary download, so
    /// the panel cannot assume any of them.
    public enum Value: Sendable, Hashable {
        /// Printable UTF-8 — shown as itself.
        case text(String)
        /// A property list (binary or XML), shown as its decoded description.
        case propertyList
        /// Anything else — shown as a byte count and a hex preview.
        case binary
    }

    /// The value's shape, decided by inspection rather than by name, so an attribute this build has
    /// never heard of still renders sensibly.
    public var value: Value {
        if data.starts(with: Self.propertyListMagic) { return .propertyList }
        guard let text = String(data: data, encoding: .utf8), text.isPrintable else { return .binary }
        return .text(text)
    }

    /// `bplist` — the leading bytes of a binary property list.
    private static let propertyListMagic = Array("bplist".utf8)

    /// A short, fixed-width hex preview of the first bytes, for the ``Value/binary`` case — the form
    /// `xattr -px` prints, so it can be compared against the stock tool.
    public func hexPreview(limit: Int = 16) -> String {
        let head = data.prefix(limit).map { String(format: "%02X", $0) }.joined(separator: " ")
        return data.count > limit ? head + " …" : head
    }
}

private extension String {
    /// No control characters other than the ordinary whitespace a value may legitimately contain.
    /// A UTF-8 decode alone is not enough: short binary values decode as UTF-8 surprisingly often.
    var isPrintable: Bool {
        !isEmpty && unicodeScalars.allSatisfy { scalar in
            scalar.value >= 0x20 || scalar == "\n" || scalar == "\t" || scalar == "\r"
        }
    }
}
