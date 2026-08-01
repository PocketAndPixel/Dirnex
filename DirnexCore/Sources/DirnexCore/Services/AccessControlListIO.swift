import Foundation

/// Reads and writes a file's ACL through the C API, with ``AccessControlList``'s pure parse/serialize
/// in the middle (PLAN.md §M14 Slice 3). `acl_get_file` → ``AccessControlList/parse(_:)`` on the way
/// in, ``AccessControlList/canonicalText()`` → `acl_from_text` → `acl_set_file` on the way out.
///
/// Acts on the **link itself** for a symlink (`acl_get_link_np` / `acl_set_link_np`), like the rest of
/// the attributes machinery. `acl_get_file` returning `nil` with `ENOENT` is the OS's normal way of
/// saying *this file has no ACL* — mapped to an empty list, not an error. Writing an empty list
/// removes the ACL entirely (an `acl_init(0)`), which is the "delete the last entry" case the editor
/// reaches.
public enum AccessControlListIO {
    /// Read a file's ACL, or an empty list when it has none.
    public static func read(at path: VFSPath, actsOnLink: Bool = false) throws -> AccessControlList {
        errno = 0
        let handle = actsOnLink
            ? acl_get_link_np(path.path, ACL_TYPE_EXTENDED)
            : acl_get_file(path.path, ACL_TYPE_EXTENDED)
        guard let handle else {
            if errno == ENOENT { return AccessControlList() } // no ACL is a normal answer
            throw VFSError.fromErrno(errno, path: path)
        }
        defer { acl_free(UnsafeMutableRawPointer(handle)) }

        guard let text = acl_to_text(handle, nil) else {
            throw VFSError.fromErrno(errno == 0 ? EINVAL : errno, path: path)
        }
        defer { acl_free(UnsafeMutableRawPointer(mutating: text)) }
        return try AccessControlList.parse(String(cString: text))
    }

    /// Write a file's ACL. An empty list removes the ACL; anything else replaces it, entry order
    /// preserved exactly (the exit criterion).
    public static func write(
        _ list: AccessControlList,
        to path: VFSPath,
        actsOnLink: Bool = false
    ) throws {
        guard let handle = try makeACL(from: list) else {
            throw VFSError.fromErrno(errno == 0 ? EINVAL : errno, path: path)
        }
        defer { acl_free(UnsafeMutableRawPointer(handle)) }

        let rc = actsOnLink
            ? acl_set_link_np(path.path, ACL_TYPE_EXTENDED, handle)
            : acl_set_file(path.path, ACL_TYPE_EXTENDED, handle)
        guard rc == 0 else { throw VFSError.fromErrno(errno, path: path) }
    }

    /// An `acl_t` for the list — an empty one (`acl_init`) for removal, else parsed from the canonical
    /// text. The caller owns the result and must `acl_free` it.
    private static func makeACL(from list: AccessControlList) throws -> acl_t? {
        errno = 0
        if list.isEmpty {
            return acl_init(0)
        }
        return acl_from_text(list.canonicalText())
    }
}
