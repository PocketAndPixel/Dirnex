import Foundation

/// The on-disk filesystem backend.
///
/// Implemented directly on POSIX (`opendir`/`readdir`/`fstatat`/`readlinkat`)
/// rather than `FileManager` for two reasons the fixtures exercise: accurate
/// `errno` mapping, and unambiguous symlink handling — we `lstat` the entry itself
/// and separately follow it to learn whether the target is a directory or dangling
/// (PLAN.md §M1 "unicode/symlink fixtures render correctly").
///
/// A value type with no stored state, so it is trivially `Sendable` and its read
/// methods are safe to call from a background queue.
public struct LocalBackend: VFSBackend {
    public let id: VFSBackendID = .local
    public let capabilities: VFSCapabilities =
        [.read, .write, .trash, .clone, .rename, .watch, .internalCopy]

    /// How the Trash move is actually performed — injected, because the only spelling that works
    /// for a File Provider item lives in AppKit (▸ ``TrashPerformer``). Defaulted so every caller
    /// that never trashes, and every test, keeps constructing `LocalBackend()`.
    public let trashPerformer: any TrashPerformer

    public init(trashPerformer: any TrashPerformer = FileManagerTrashPerformer()) {
        self.trashPerformer = trashPerformer
    }

    /// Disambiguates the `stat` struct from the `stat` free function (both are in
    /// scope from Darwin); we call `fstatat` for all stat operations.
    private typealias StatBuf = Darwin.stat

    public func listDirectory(at path: VFSPath) throws -> [FileEntry] {
        let cPath = (path.path as NSString).fileSystemRepresentation
        guard let dirp = opendir(cPath) else {
            throw VFSError.fromErrno(errno, path: path)
        }
        defer { closedir(dirp) }
        let dirFD = dirfd(dirp)

        var entries: [FileEntry] = []
        while let entPtr = readdir(dirp) {
            // Access d_name in place — readdir reuses one buffer, and the tuple is
            // 1 KB, so copying it per entry would be wasteful on huge directories.
            let entry = withUnsafePointer(to: &entPtr.pointee.d_name) { tuplePtr -> FileEntry? in
                let cName = UnsafeRawPointer(tuplePtr).assumingMemoryBound(to: CChar.self)
                let name = String(cString: cName)
                if name == "." || name == ".." { return nil }
                return makeEntry(dirFD: dirFD, cName: cName, name: name, parent: path)
            }
            if let entry { entries.append(entry) }
        }
        return entries
    }

    public func stat(at path: VFSPath) throws -> FileEntry {
        let cPath = (path.path as NSString).fileSystemRepresentation
        var info = StatBuf()
        guard fstatat(AT_FDCWD, cPath, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
            throw VFSError.fromErrno(errno, path: path)
        }
        var dest: String?
        var targetKind: FileEntry.Kind?
        if (info.st_mode & S_IFMT) == S_IFLNK {
            dest = Self.readLink(dirFD: AT_FDCWD, cName: cPath)
            var target = StatBuf()
            if fstatat(AT_FDCWD, cPath, &target, 0) == 0 {
                targetKind = Self.classify(mode: target.st_mode)
            }
        }
        return assemble(
            path: path,
            name: path.lastComponent,
            st: info,
            dest: dest,
            targetKind: targetKind
        )
    }

    // MARK: - Write operations

    public func createDirectory(at path: VFSPath) throws {
        let cPath = (path.path as NSString).fileSystemRepresentation
        guard mkdir(cPath, 0o755) == 0 else {
            throw VFSError.fromErrno(errno, path: path)
        }
    }

    public func createFile(at path: VFSPath) throws {
        let cPath = (path.path as NSString).fileSystemRepresentation
        // `O_EXCL` is the whole point: the check and the create are one syscall, so an existing
        // file is reported rather than truncated even if it appeared a moment ago.
        let descriptor = open(cPath, O_CREAT | O_EXCL | O_WRONLY, 0o644)
        guard descriptor >= 0 else {
            throw VFSError.fromErrno(errno, path: path)
        }
        close(descriptor)
    }

    public func moveItem(at source: VFSPath, to destination: VFSPath) throws {
        // Two distinct NSStrings, so both C buffers stay valid for the rename(2) call.
        let cSource = (source.path as NSString).fileSystemRepresentation
        let cDest = (destination.path as NSString).fileSystemRepresentation
        guard rename(cSource, cDest) == 0 else {
            // rename(2) reports a same-name-onto-nonempty-dir as ENOTEMPTY and a
            // cross-device move as EXDEV; both are mapped for the caller.
            throw VFSError.fromErrno(errno, path: source)
        }
    }

    public func removeItem(at path: VFSPath) throws {
        // `FileManager.removeItem` deletes a subtree recursively and removes a symlink
        // itself rather than following it — both what a permanent delete wants. Its
        // Cocoa error is normalized back to a `VFSError` for the caller.
        do {
            try FileManager.default.removeItem(atPath: path.path)
        } catch {
            throw Self.mapCocoaError(error, path: path)
        }
    }

    /// Move `path` to the Trash it belongs to (its own volume's), returning where it landed.
    ///
    /// **Refuses an item that is already in a trash.** Probed 2026-07-21: `FileManager.trashItem`
    /// on such an item reports success and returns the path it was handed, having done nothing — so
    /// without this guard a "move to Trash" inside the Trash is a silent no-op that looks like it
    /// worked (PLAN.md §M8). The UI never reaches this, because a trash location advertises no
    /// `.trash` capability and F8 there is already a permanent delete; the guard is here so the
    /// invariant is enforced (and tested) at the layer that touches the bytes rather than resting
    /// on a caller remembering to ask.
    ///
    /// **A volume that has no Trash refuses here, and only here** — see ``trashFailure(_:path:)``
    /// for why that refusal cannot be asked about in advance.
    ///
    /// **The move itself belongs to the injected ``TrashPerformer``** (PLAN.md §M26), because
    /// `FileManager.trashItem` refuses every item inside a File Provider domain — every Dropbox,
    /// OneDrive, Box, Drive and iCloud file — when the app is responsible for itself. Both refusals
    /// above are still decided here, on whatever the performer threw.
    @discardableResult
    public func trashItem(at path: VFSPath) throws -> VFSPath? {
        guard !TrashLocations.isInsideTrash(path) else {
            throw VFSError.unsupported(.alreadyInTrash(name: path.lastComponent))
        }
        do {
            let landed = try trashPerformer.moveToTrash(URL(fileURLWithPath: path.path))
            guard let landed else { return nil }
            return .local(landed.path)
        } catch {
            throw Self.trashFailure(error, path: path)
        }
    }

    /// Translate a `trashItem` failure, which has one outcome the shared mapper cannot express:
    /// **this volume has no Trash at all**, which Cocoa reports as `NSFeatureUnsupportedError`
    /// (3328). Reported by a user 2026-08-25, deleting from a mounted SMB share on a NAS.
    ///
    /// Named rather than left to ``mapCocoaError(_:path:)``, whose `default` branch renders it as
    /// `.io(code: 3328)` — *"The system reported an error (code 3 328)"*, a number, for a volume
    /// that is working perfectly and simply keeps no Trash. It is also the one delete failure that
    /// is **not a failure**: the user asked to throw a file away, and the honest answer is that here
    /// that means for good. So the app reads this case back out (`TrashRefusal`) and re-offers the
    /// permanent delete it already has for a Trash-less backend, exactly as Finder does on a share.
    ///
    /// **The refusal cannot be anticipated, which is why it is handled after the fact rather than
    /// in `capabilities(for:)`.** Probed 2026-08-25 for a cheap pre-check and there is none: no
    /// `VOL_CAP_FMT_*`/`VOL_CAP_INT_*` bit names a Trash, no `URLResourceKey` does either, and
    /// `FileManager.url(for: .trashDirectory, appropriateFor:)` answers the *opposite* way round —
    /// it throws this very code for a volume that trashes fine but has nothing trashed on it yet
    /// (measured on freshly created ExFAT and HFS+ images, both of which then trashed into
    /// `<volume>/.Trashes/501` without complaint). So 3328 from the *lookup* means nothing and 3328
    /// from the *attempt* is the verdict, and the attempt is the only instrument there is.
    ///
    /// The code is read before ``mapCocoaError(_:path:)`` gets the error, which prefers an
    /// underlying POSIX errno. That ordering is deliberate: 3328 is the API's verdict about the
    /// *feature*, and an errno tucked under it is how it found out rather than what it means. A
    /// missing file does not arrive this way — `trashItem` reports that as `NSFileNoSuchFileError`
    /// — so nothing else is being swallowed.
    static func trashFailure(_ error: Error, path: VFSPath) -> VFSError {
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain, nsError.code == NSFeatureUnsupportedError {
            return .unsupported(.trash)
        }
        return mapCocoaError(error, path: path)
    }

    /// Translate a `FileManager` failure into a `VFSError`, recovering the POSIX errno
    /// when Cocoa tucked one under `NSUnderlyingErrorKey`, else falling back to the
    /// Cocoa file-error code so the UI still gets a specific message.
    private static func mapCocoaError(_ error: Error, path: VFSPath) -> VFSError {
        let nsError = error as NSError
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError,
           underlying.domain == NSPOSIXErrorDomain {
            return VFSError.fromErrno(Int32(underlying.code), path: path)
        }
        switch nsError.code {
        case NSFileNoSuchFileError, NSFileReadNoSuchFileError:
            return .notFound(path)
        case NSFileWriteNoPermissionError, NSFileReadNoPermissionError:
            return .permissionDenied(path)
        case NSFileWriteFileExistsError:
            return .alreadyExists(path)
        default:
            return .io(path: path, code: Int32(nsError.code))
        }
    }

    // MARK: - Entry assembly

    private func makeEntry(
        dirFD: Int32,
        cName: UnsafePointer<CChar>,
        name: String,
        parent: VFSPath
    ) -> FileEntry? {
        var info = StatBuf()
        guard fstatat(dirFD, cName, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
            return nil // entry vanished between readdir and stat — skip it
        }
        var dest: String?
        var targetKind: FileEntry.Kind?
        if (info.st_mode & S_IFMT) == S_IFLNK {
            dest = Self.readLink(dirFD: dirFD, cName: cName)
            var target = StatBuf()
            if fstatat(dirFD, cName, &target, 0) == 0 {
                targetKind = Self.classify(mode: target.st_mode)
            }
        }
        return assemble(
            path: parent.appending(name), name: name, st: info, dest: dest, targetKind: targetKind
        )
    }

    private func assemble(
        path: VFSPath,
        name: String,
        st: StatBuf,
        dest: String?,
        targetKind: FileEntry.Kind?
    ) -> FileEntry {
        let hidden = name.hasPrefix(".") || (st.st_flags & UInt32(UF_HIDDEN)) != 0
        return FileEntry(
            path: path,
            name: name,
            kind: Self.classify(mode: st.st_mode),
            byteSize: Int64(st.st_size),
            modificationDate: Self.date(from: st.st_mtimespec),
            creationDate: Self.date(from: st.st_birthtimespec),
            isHidden: hidden,
            permissions: UInt16(st.st_mode & 0o7777),
            // Free here too — owner, group and the raw flags word all rode in on the same `stat` the
            // listing already did, so the attributes panel (PLAN.md §M14) costs no extra syscall.
            ownerID: st.st_uid,
            groupID: st.st_gid,
            flags: st.st_flags,
            inode: UInt64(st.st_ino),
            symlinkDestination: dest,
            symlinkTargetKind: targetKind,
            // Free here — the flag rides along in the `stat` the listing already did, so
            // knowing a file is an evicted cloud placeholder costs no extra syscall.
            isDataless: (st.st_flags & UInt32(SF_DATALESS)) != 0
        )
    }

    // MARK: - POSIX helpers

    private static func classify(mode: mode_t) -> FileEntry.Kind {
        switch mode & S_IFMT {
        case S_IFDIR: .directory
        case S_IFREG: .file
        case S_IFLNK: .symlink
        default: .other
        }
    }

    private static func readLink(dirFD: Int32, cName: UnsafePointer<CChar>) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        let count = readlinkat(dirFD, cName, &buffer, buffer.count - 1)
        guard count >= 0 else { return nil }
        buffer[count] = 0 // readlinkat does not null-terminate
        return buffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
    }

    private static func date(from time: timespec) -> Date {
        Date(
            timeIntervalSince1970: TimeInterval(time.tv_sec) + TimeInterval(time.tv_nsec) / 1_000_000_000
        )
    }
}
