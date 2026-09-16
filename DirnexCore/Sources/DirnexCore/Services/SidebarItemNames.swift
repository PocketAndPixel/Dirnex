import Foundation

/// Names the user gave to sidebar rows the app **discovers** rather than stores — today the Cloud
/// section: iCloud Drive, the Photos library and each provider mount (PLAN.md §M8, §M10, §M28).
///
/// A Favorites row carries its own name because the row *is* the stored entry. A discovered row
/// comes back from a scan every rebuild, so what the user called it has to be kept beside it, keyed
/// by an identity that survives the scan — the same shape ``SidebarItemOrder`` gives the section's
/// order, and the same identities (``CloudPlaceIdentity``).
///
/// **Only a name differs from what the app would draw is ever kept.** Renaming a row back to its
/// default forgets the entry rather than pinning the string, because the default is not constant:
/// "iCloud Drive" is translated, and a mount's label gains its account the day a second account of
/// the same provider appears. A stored copy of either would freeze the row at whatever it said on
/// the day it was typed.
///
/// Nothing here renames anything on disk or in a cloud account. The mount directories belong to the
/// sync clients, and the library and iCloud Drive have no name a file manager may change — this is a
/// label, and the app shows it wherever it names the place.
public struct SidebarItemNames: Equatable, Sendable, Codable {
    /// The chosen names by identity. Every value is already ``normalized(_:)``.
    public private(set) var names: [String: String]

    public init(names: [String: String] = [:]) {
        // Through the same normalization a rename applies, so a hand-edited store cannot hand the
        // sidebar a blank row or a name with a line break in it.
        self.names = names.compactMapValues(Self.normalized)
    }

    /// The name chosen for `identity`, or `nil` when the row keeps its default.
    public func name(for identity: String) -> String? {
        names[identity]
    }

    /// What to call the row: the chosen name, or `defaultName` when there is none.
    public func title(for identity: String, default defaultName: String) -> String {
        names[identity] ?? defaultName
    }

    /// Give `identity` the name `proposed`, returning whether anything changed.
    ///
    /// A name that normalizes to nothing, or to exactly `defaultName`, clears the entry — which is
    /// what makes an emptied field mean "use the original name again".
    @discardableResult
    public mutating func rename(
        _ identity: String,
        to proposed: String,
        defaultName: String
    ) -> Bool {
        guard let name = Self.normalized(proposed), name != defaultName else {
            return reset(identity)
        }
        guard names[identity] != name else { return false }
        names[identity] = name
        return true
    }

    /// Forget the name chosen for `identity`, returning whether there was one.
    @discardableResult
    public mutating func reset(_ identity: String) -> Bool {
        names.removeValue(forKey: identity) != nil
    }

    /// `proposed` as a row label: control characters removed — a pasted line break would otherwise
    /// draw a second line the row has no room for — and surrounding whitespace trimmed. `nil` when
    /// nothing is left.
    public static func normalized(_ proposed: String) -> String? {
        let scalars = proposed.unicodeScalars.filter { !isControl($0) }
        let name = String(String.UnicodeScalarView(scalars))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }

    /// The C0 and C1 controls, plus the two Unicode separators that break a line without being one.
    private static func isControl(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .control, .lineSeparator, .paragraphSeparator: true
        default: false
        }
    }

    // MARK: - Codable

    // A bare object of identity → name, like ``SidebarItemOrder``'s bare array: it is one mapping,
    // and the stored value is meant to be readable (PLAN.md §2 "boring and debuggable").
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        // Through the normalizing initializer, so a hand-edited store is sanitized on the way in.
        self.init(names: try container.decode([String: String].self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(names)
    }
}
