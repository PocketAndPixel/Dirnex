import Foundation

@testable import DirnexCore

/// A text file dressed in everything a save must keep (PLAN.md §M33 Slice 3), and a way to read it
/// all back: the probe's fixture, as tests.
enum SavedFileFixture {
    /// Everything stored on a file that a save must leave as it was. The bytes, size and
    /// modification time are what a save changes, so they are not here.
    struct Look: Equatable {
        let inode: UInt64
        let links: UInt16
        let mode: UInt16
        let owner: uid_t
        let group: gid_t
        let created: Date
        let attributes: [String: Data]
        let accessControl: AccessControlList
    }

    static func look(_ path: String) throws -> Look {
        var status = stat()
        guard stat(path, &status) == 0 else { throw VFSError.notFound(.local(path)) }
        let file = VFSPath.local(path)
        var attributes: [String: Data] = [:]
        for attribute in try ExtendedAttributeIO.all(at: file) {
            attributes[attribute.name] = attribute.data
        }
        return Look(
            inode: status.st_ino,
            links: status.st_nlink,
            mode: status.st_mode,
            owner: status.st_uid,
            group: status.st_gid,
            created: Date(timeIntervalSince1970: TimeInterval(status.st_birthtimespec.tv_sec)),
            attributes: attributes,
            accessControl: try AccessControlListIO.read(at: file)
        )
    }

    /// Give the file at `path` a mode, a group other than the folder's when this user has one, two
    /// Finder tags, a private extended attribute, an ACL entry and a creation date in 2020, so a
    /// save that dropped any of them shows.
    static func dress(_ path: String, acl entry: String = "everyone allow read") throws {
        let file = VFSPath.local(path)
        guard chmod(path, 0o640) == 0 else { throw VFSError.fromErrno(errno, path: file) }
        if let group = otherGroup(than: path) {
            guard chown(path, uid_t.max, group) == 0 else { throw VFSError.fromErrno(
                errno,
                path: file
            ) }
        }
        let tags = try PropertyListSerialization.data(
            fromPropertyList: ["Red\n6", "Probe"],
            format: .binary,
            options: 0
        )
        try ExtendedAttributeIO.set("com.apple.metadata:_kMDItemUserTags", to: tags, at: file)
        try ExtendedAttributeIO.set("com.example.note", to: Data("keep me".utf8), at: file)
        try run("/bin/chmod", "+a", entry, path)
        var url = URL(fileURLWithPath: path)
        var values = URLResourceValues()
        values.creationDate = Date(timeIntervalSince1970: 1_577_934_245)
        try url.setResourceValues(values)
    }

    /// One of this user's groups that the file is not in, or `nil` when the user has only one.
    private static func otherGroup(than path: String) -> gid_t? {
        var status = stat()
        guard stat(path, &status) == 0 else { return nil }
        var groups = [gid_t](repeating: 0, count: 64)
        let count = getgroups(Int32(groups.count), &groups)
        return groups.prefix(Int(max(count, 0))).first { $0 != status.st_gid }
    }

    /// Remove every ACL under `root`, so a tree holding a file whose ACL denies delete can be
    /// cleaned up.
    static func clearAccessControl(under root: String) {
        try? run("/bin/chmod", "-RN", root)
    }

    static func run(_ tool: String, _ arguments: String...) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw VFSError.io(path: .local(tool), code: process.terminationStatus)
        }
    }

    static func read(_ path: String) -> String {
        (try? String(contentsOfFile: path, encoding: .utf8)) ?? "<none>"
    }

    static func modificationTime(_ path: String) -> timespec? {
        InPlaceFileWrite.modificationTime(ofFileAt: path)
    }

    /// A document read from `text`, with its last line replaced by `last`: a save's worth of edit.
    static func edited(_ text: String, lastLine last: String) throws -> ComparedDocument {
        var document = try ComparedDocument.decode(Data(text.utf8))
        let end = document.lines.count
        document.apply(LineEdit(
            range: end - 1..<end,
            replacement: [TextLine(content: Substring(last), terminator: .lf)]
        ))
        return document
    }
}
