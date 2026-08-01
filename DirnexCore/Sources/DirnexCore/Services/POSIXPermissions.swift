import Foundation

/// The POSIX permission word (`mode & 0o7777`) — the nine `rwx` bits plus set-uid, set-gid and the
/// sticky bit — modelled so the attributes panel can toggle one checkbox without hand-masking, and
/// so a `chmod` is expressed against a whole word rather than a literal (PLAN.md §M14 Slice 3).
///
/// `FileEntry.permissions` keeps only the low nine bits (`mode & 0o777`) for the row's rendering;
/// this type carries all twelve because the editor has to be able to show and change set-uid/gid and
/// the sticky bit, which the row does not display.
public struct POSIXPermissions: Sendable, Hashable, Codable {
    /// The classes a permission bit belongs to.
    public enum Class: Sendable, CaseIterable { case owner, group, other }
    /// The three ordinary permissions.
    public enum Access: Sendable, CaseIterable { case read, write, execute }

    /// The raw `mode & 0o7777` word.
    public private(set) var rawValue: UInt16

    /// Masks to `0o7777` on the way in, so a full `st_mode` (with the file-type bits) can be handed
    /// over directly.
    public init(rawValue: UInt16) { self.rawValue = rawValue & 0o7777 }

    private static func bit(_ cls: Class, _ access: Access) -> UInt16 {
        let base: UInt16
        switch cls {
        case .owner: base = 0o100
        case .group: base = 0o010
        case .other: base = 0o001
        }
        switch access {
        case .read: return base << 2
        case .write: return base << 1
        case .execute: return base
        }
    }

    public subscript(_ cls: Class, _ access: Access) -> Bool {
        get { rawValue & Self.bit(cls, access) != 0 }
        set {
            let mask = Self.bit(cls, access)
            if newValue { rawValue |= mask } else { rawValue &= ~mask }
        }
    }

    // MARK: Special bits

    /// Set-user-ID on execution (`0o4000`).
    public var setUserID: Bool {
        get { rawValue & 0o4000 != 0 }
        set { setSpecial(0o4000, newValue) }
    }

    /// Set-group-ID on execution (`0o2000`).
    public var setGroupID: Bool {
        get { rawValue & 0o2000 != 0 }
        set { setSpecial(0o2000, newValue) }
    }

    /// The sticky bit (`0o1000`) — on a directory, restricts renames/deletes to the item's owner.
    public var sticky: Bool {
        get { rawValue & 0o1000 != 0 }
        set { setSpecial(0o1000, newValue) }
    }

    private mutating func setSpecial(_ mask: UInt16, _ on: Bool) {
        if on { rawValue |= mask } else { rawValue &= ~mask }
    }

    /// The canonical three-octal-digit string of the nine `rwx` bits, e.g. `"644"` — four digits
    /// when any special bit is set (`"4755"`). What the panel echoes and what a `chmod` argument
    /// reads as.
    public var octalString: String {
        rawValue & 0o7000 == 0 ? String(rawValue, radix: 8) : String(format: "%04o", rawValue)
    }

    /// The 10-character `ls`-style string *without* the leading type character, e.g. `"rwxr-xr-x"`.
    /// The `s`/`t`/`S`/`T` overlays for the special bits follow `ls(1)`.
    public var symbolicString: String {
        var out = ""
        for cls in Class.allCases {
            out.append(self[cls, .read] ? "r" : "-")
            out.append(self[cls, .write] ? "w" : "-")
            out.append(executeGlyph(for: cls))
        }
        return out
    }

    private func executeGlyph(for cls: Class) -> String {
        let x = self[cls, .execute]
        let special: Bool
        switch cls {
        case .owner: special = setUserID
        case .group: special = setGroupID
        case .other: special = sticky
        }
        let lower = cls == .other ? "t" : "s"
        if special { return x ? lower : lower.uppercased() }
        return x ? "x" : "-"
    }
}
