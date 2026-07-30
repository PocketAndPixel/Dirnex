import Foundation

/// Reads a file's ``FileAttributes`` and applies an ``AttributeChangePlan`` to it — the thin,
/// metadata-touching half the pure model sits behind (PLAN.md §2: if it touches the filesystem it
/// lives in the core and is tested).
///
/// Everything acts on the **link itself** for a symlink (`lstat`, `lchmod`, `lchown`, `lchflags`,
/// `lutimes`, `setattrlist` with `FSOPT_NOFOLLOW`), matching Finder's Get Info and the decision
/// recorded in ``AttributeChangePlan``. The unprivileged cases — nearly everything for a file the
/// user owns — are covered by real temp-file tests; the locked-file unlock/relock ordering is proven
/// live against a real immutable file, since that `EPERM` is the one this whole design exists to
/// avoid.
public enum FileAttributeIO {
    /// What ``read(at:)`` returns: the attributes, plus whether the item is itself a symlink (so the
    /// caller can pass `actsOnLink` through to the plan and the applier).
    public struct Reading: Sendable, Equatable {
        public let attributes: FileAttributes
        public let isSymlink: Bool
    }

    /// Read one item's attributes with a single `lstat` — the link's own, never its target's.
    public static func read(at path: VFSPath) throws -> Reading {
        try requireLocal(path)
        var status = Darwin.stat()
        guard lstat(path.path, &status) == 0 else {
            throw VFSError.fromErrno(errno, path: path)
        }
        let attributes = FileAttributes(
            permissions: POSIXPermissions(rawValue: status.st_mode),
            flags: BSDFileFlags(rawValue: status.st_flags),
            ownerID: status.st_uid,
            groupID: status.st_gid,
            accessDate: Self.date(from: status.st_atimespec),
            modificationDate: Self.date(from: status.st_mtimespec),
            creationDate: Self.date(from: status.st_birthtimespec)
        )
        return Reading(
            attributes: attributes,
            isSymlink: (status.st_mode & S_IFMT) == S_IFLNK
        )
    }

    /// Run a plan's steps against `path`, in order. A failure at any step throws, leaving the earlier
    /// steps applied — the panel re-reads afterwards, so a partial apply shows the user exactly how
    /// far it got rather than a stale dialog.
    public static func apply(_ plan: AttributeChangePlan, to path: VFSPath) throws {
        try requireLocal(path)
        for step in plan.steps {
            try apply(step, to: path, actsOnLink: plan.actsOnLink)
        }
    }

    // MARK: - One step

    private static func apply(
        _ step: AttributeChangePlan.Step,
        to path: VFSPath,
        actsOnLink link: Bool
    ) throws {
        let cPath = path.path
        switch step {
        case let .setOwnership(userID, groupID):
            let user = userID ?? UInt32.max // (uid_t)-1 means "leave unchanged"
            let group = groupID ?? UInt32.max
            try check(link ? lchown(cPath, user, group) : chown(cPath, user, group), path)
        case let .setPermissions(permissions):
            let mode = mode_t(permissions.rawValue)
            try check(link ? lchmod(cPath, mode) : chmod(cPath, mode), path)
        case let .setTimes(access, modification):
            var times = [Self.makeTimeval(from: access), Self.makeTimeval(from: modification)]
            try check(link ? lutimes(cPath, &times) : utimes(cPath, &times), path)
        case let .setCreationDate(date):
            try setCreationDate(date, at: cPath, actsOnLink: link, path: path)
        case let .setFlags(flags):
            try check(link ? lchflags(cPath, flags.rawValue) : chflags(cPath, flags.rawValue), path)
        }
    }

    /// `setattrlist(ATTR_CMN_CRTIME)` — the birth time `utimes` cannot reach.
    private static func setCreationDate(
        _ date: Date,
        at cPath: String,
        actsOnLink link: Bool,
        path: VFSPath
    ) throws {
        var attributes = attrlist()
        attributes.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        attributes.commonattr = attrgroup_t(ATTR_CMN_CRTIME)
        var value = Self.makeTimespec(from: date)
        let options: UInt32 = link ? UInt32(FSOPT_NOFOLLOW) : 0
        let rc = withUnsafeMutablePointer(to: &value) { pointer in
            setattrlist(cPath, &attributes, pointer, MemoryLayout<timespec>.size, options)
        }
        try check(rc, path)
    }

    // MARK: - Helpers

    private static func requireLocal(_ path: VFSPath) throws {
        // The panel only ever asks for attributes of a local item; the guard keeps the syscalls from
        // running against a virtual path string. `ENOTSUP` needs no new user-facing vocabulary.
        guard path.backend == .local else {
            throw VFSError.io(path: path, code: ENOTSUP)
        }
    }

    private static func check(_ rc: Int32, _ path: VFSPath) throws {
        guard rc == 0 else { throw VFSError.fromErrno(errno, path: path) }
    }

    private static func date(from time: timespec) -> Date {
        Date(
            timeIntervalSince1970: TimeInterval(time.tv_sec) + TimeInterval(time.tv_nsec) / 1_000_000_000
        )
    }

    private static func makeTimeval(from date: Date) -> timeval {
        let interval = date.timeIntervalSince1970
        let seconds = interval.rounded(.down)
        return timeval(
            tv_sec: Int(seconds),
            tv_usec: __darwin_suseconds_t((interval - seconds) * 1_000_000)
        )
    }

    private static func makeTimespec(from date: Date) -> timespec {
        let interval = date.timeIntervalSince1970
        let seconds = interval.rounded(.down)
        return timespec(tv_sec: Int(seconds), tv_nsec: Int((interval - seconds) * 1_000_000_000))
    }
}
