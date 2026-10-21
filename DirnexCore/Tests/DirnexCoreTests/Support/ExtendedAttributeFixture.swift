import Foundation

@testable import DirnexCore

/// Writing an extended attribute, which only the tests do: the attributes panel lists them and never
/// edits one, so the writer moved here from the core rather than shipping unused.
extension ExtendedAttributeIO {
    static func set(_ name: String, to data: Data, at path: VFSPath) throws {
        let rc = data.withUnsafeBytes { buffer in
            setxattr(path.path, name, buffer.baseAddress, buffer.count, 0, XATTR_NOFOLLOW)
        }
        guard rc == 0 else { throw VFSError.fromErrno(errno, path: path) }
    }
}
