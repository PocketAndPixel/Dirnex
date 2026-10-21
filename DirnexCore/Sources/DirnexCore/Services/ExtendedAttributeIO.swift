import Foundation

/// Lists and reads extended attributes — the thin syscall half behind
/// ``ExtendedAttribute`` (PLAN.md §M14 Slice 4, §2: metadata-touching I/O lives in the core and is
/// tested).
///
/// Everything acts on the **link itself** (`XATTR_NOFOLLOW`), matching `FileAttributeIO` and
/// `AccessControlListIO` and Finder's Get Info. That is not a formality: probed on a real symlink,
/// following gave the *target's* three attributes and the link's own set was a different one
/// entirely, so a panel that followed would show and delete the wrong file's attributes.
public enum ExtendedAttributeIO {
    /// Every attribute name on the item, in the order the kernel returns them.
    ///
    /// Includes ``ExtendedAttribute/provenanceName``; filtering for display is the caller's job
    /// (``ExtendedAttribute/isWorthShowing``), so a diagnostic caller can still see everything.
    public static func names(at path: VFSPath) throws -> [String] {
        try requireLocal(path)
        let size = listxattr(path.path, nil, 0, XATTR_NOFOLLOW)
        guard size >= 0 else { throw VFSError.fromErrno(errno, path: path) }
        guard size > 0 else { return [] }

        var buffer = [CChar](repeating: 0, count: size)
        let written = listxattr(path.path, &buffer, size, XATTR_NOFOLLOW)
        guard written >= 0 else { throw VFSError.fromErrno(errno, path: path) }
        return Self.splitNames(buffer.prefix(written))
    }

    /// One attribute's raw value, or `nil` when the item does not carry it (`ENOATTR`) — a normal
    /// answer, like `acl_get_file`'s `ENOENT`, not an error.
    public static func value(of name: String, at path: VFSPath) throws -> Data? {
        try requireLocal(path)
        let size = getxattr(path.path, name, nil, 0, 0, XATTR_NOFOLLOW)
        guard size >= 0 else {
            if errno == ENOATTR { return nil }
            throw VFSError.fromErrno(errno, path: path)
        }
        guard size > 0 else { return Data() }

        var bytes = [UInt8](repeating: 0, count: size)
        let read = getxattr(path.path, name, &bytes, size, 0, XATTR_NOFOLLOW)
        guard read >= 0 else {
            if errno == ENOATTR { return nil }
            throw VFSError.fromErrno(errno, path: path)
        }
        return Data(bytes.prefix(read))
    }

    /// Every attribute the item carries, name and value together — what the panel lists.
    ///
    /// An attribute that disappears between the `listxattr` and its `getxattr` is skipped rather
    /// than throwing: another process removing one mid-read is a race, not a failure of this read.
    public static func all(at path: VFSPath) throws -> [ExtendedAttribute] {
        try names(at: path).compactMap { name in
            guard let data = try value(of: name, at: path) else { return nil }
            return ExtendedAttribute(name: name, data: data)
        }
    }

    // MARK: - Helpers

    /// Split the kernel's NUL-separated name buffer. A trailing NUL terminates the last name, so an
    /// empty run is a separator artifact rather than a nameless attribute. A name that is not valid
    /// UTF-8 is dropped rather than replacement-charactered — it could not be passed back to
    /// `getxattr` as the same bytes anyway.
    static func splitNames(_ buffer: some Collection<CChar>) -> [String] {
        buffer
            .split(separator: 0, omittingEmptySubsequences: true)
            .compactMap { String(bytes: $0.map { UInt8(bitPattern: $0) }, encoding: .utf8) }
    }

    private static func requireLocal(_ path: VFSPath) throws {
        // Same guard as `FileAttributeIO`: only a real path on disk has extended attributes, and a
        // synthetic `trash:`/`icloud:` string must never reach a syscall.
        guard path.backend == .local else {
            throw VFSError.io(path: path, code: ENOTSUP)
        }
    }
}
