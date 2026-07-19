import Foundation

/// Reading and writing a local file's Finder tags (PLAN.md §M6 "Finder tags: … edit from panel").
///
/// It touches bytes on disk, so per §2 it lives in `DirnexCore` and is tested, alongside
/// `ByteComparator` — the other core service that reaches past `VFSBackend` to a local path.
/// The caller decides where it runs; every entry point here is synchronous and blocking, and the
/// panel drives it off the main thread (reading one attribute costs ~10 µs, which is nothing for a
/// selection and about a second across a 100k-row directory — see `tags(at:)`).
///
/// **Why this writes the attribute by hand instead of calling `URLResourceValues.tagNames`**, which
/// is the documented API and the obvious first choice — two independent reasons, either sufficient:
///
/// 1. **Its setter is macOS 26+, and Dirnex targets 14** (§2). It is not an option here at all.
/// 2. **It cannot express a colour.** It takes bare names and looks each colour up itself, in a
///    global name → colour database that only the seven stock tags are in — and that a write of
///    ours does *not* register into. Probed: after storing a purple `Zebra` directly, setting
///    `tagNames = ["Zebra"]` writes `Zebra\n0` and the purple is gone. So even where it exists,
///    routing an edit through it would strip the colour off every custom tag on the file each time
///    the user added or removed an unrelated one — a data-loss bug wearing the documented API's
///    clothes.
///
/// Writing the attribute ourselves preserves each tag's stored colour verbatim, which is why
/// `setTags` takes `FinderTag`s and not names. The *getter* (`tagNamesKey`) is available on 14 and
/// is what the tests read back through, but it drops colours, so it is no use for the column.
///
/// The one thing `tagNames` does that we then have to do ourselves is keep the legacy Finder label
/// byte in sync — see `writeLegacyLabel`.
public enum FinderTagStorage {
    /// The extended attribute Finder tags live in. A binary plist array of `name\ncolour` strings.
    static let tagsAttribute = "com.apple.metadata:_kMDItemUserTags"
    /// The legacy 32-byte Finder info record. Byte 9 carries the pre-tags label colour.
    static let finderInfoAttribute = "com.apple.FinderInfo"
    private static let finderInfoSize = 32
    /// Byte 9's bits 1–3 hold the label index, i.e. the index shifted left by one.
    private static let labelByte = 9
    private static let labelMask: UInt8 = 0b1110

    // MARK: - Reading

    /// The tags on a local file or directory, in stored order; `[]` when it has none.
    ///
    /// Only `.local` paths carry Finder tags — an archive member or an SFTP file has no extended
    /// attributes to read, so those throw `.unsupported` rather than quietly answering `[]`, which
    /// would read as "this remote file definitely has no tags".
    ///
    /// Costs one `getxattr` — measured at ~10 µs, tagged or not. That is cheap per file and
    /// emphatically not free per *row*: ~1 s across a 100k-entry directory, against M1's 150 ms
    /// budget for opening one. So the panel must never fold this into its listing; it fills the
    /// column from a cache off the main thread, the way `GitStatusProvider` does.
    public static func tags(at path: VFSPath) throws -> [FinderTag] {
        guard let data = try attribute(tagsAttribute, at: path) else { return [] }
        return FinderTagPayload.decode(data)
    }

    // MARK: - Writing

    /// Replace the tags on a local file, and bring the legacy label byte along with them.
    ///
    /// An empty list removes the attribute outright rather than storing an empty array, which is
    /// what the system does and what leaves a never-tagged file byte-identical to one whose tags
    /// were cleared.
    public static func setTags(_ tags: [FinderTag], at path: VFSPath) throws {
        try requireLocal(path)
        if tags.isEmpty {
            try removeAttribute(tagsAttribute, at: path)
        } else {
            let data: Data
            do {
                data = try FinderTagPayload.encode(tags)
            } catch {
                throw VFSError.io(path: path, code: EINVAL)
            }
            try writeAttribute(tagsAttribute, data, at: path)
        }
        try writeLegacyLabel(FinderTagPayload.legacyLabel(for: tags), at: path)
    }

    /// Add a tag, keeping the file's existing ones. Adding a tag the file already carries — under
    /// any spelling, since tags are case-insensitively identified — is a no-op rather than a
    /// duplicate row or a silent re-colouring.
    public static func add(_ tag: FinderTag, to path: VFSPath) throws {
        let existing = try tags(at: path)
        guard !existing.contains(tag) else { return }
        try setTags(existing + [tag], at: path)
    }

    /// Remove a tag by name. Removing one the file does not carry is a no-op — no read-back, no
    /// error — so applying "remove Red" across a mixed selection does the obvious thing.
    public static func remove(_ tag: FinderTag, from path: VFSPath) throws {
        let existing = try tags(at: path)
        guard existing.contains(tag) else { return }
        try setTags(existing.filter { $0 != tag }, at: path)
    }

    // MARK: - The legacy label

    /// Keep `com.apple.FinderInfo`'s label byte in step with the tag list.
    ///
    /// Tags superseded labels in Mavericks, but the system still maintains the old byte, and a raw
    /// attribute write does not: probed, `tagNames = ["Red"]` leaves Spotlight reporting
    /// `kMDItemFSLabel = 6` where writing the same tag by hand leaves it 0. Since the whole reason
    /// this file writes by hand is to be *more* faithful than the documented API, leaving a file
    /// in a state the OS would never produce — tag says Red, label says none — is not a trade
    /// worth making for a few lines.
    ///
    /// Read-modify-write: the other 31 bytes are type/creator codes and flags belonging to whoever
    /// wrote them, and clobbering them to zero to set a colour would be its own data loss.
    private static func writeLegacyLabel(_ label: Int, at path: VFSPath) throws {
        let existing = try attribute(finderInfoAttribute, at: path)
        // Nothing there and nothing to say: a colourless tag should not conjure the record, which
        // is exactly what the system does — a file tagged only `Work` has no FinderInfo at all.
        if existing == nil, label == 0 { return }

        var bytes = [UInt8](existing ?? Data())
        if bytes.count < finderInfoSize {
            bytes.append(contentsOf: [UInt8](repeating: 0, count: finderInfoSize - bytes.count))
        }
        bytes[labelByte] = (bytes[labelByte] & ~labelMask) | (UInt8(label) << 1)

        // An all-zero record carries nothing; drop it rather than leave 32 bytes of padding behind.
        if bytes.allSatisfy({ $0 == 0 }) {
            try removeAttribute(finderInfoAttribute, at: path)
        } else {
            try writeAttribute(finderInfoAttribute, Data(bytes), at: path)
        }
    }

    // MARK: - Attribute primitives

    /// Read one extended attribute whole, or `nil` when the file simply does not carry it.
    ///
    /// Size-then-read is two calls and therefore racy in principle — the attribute can grow in
    /// between — so a mid-race `ERANGE` retries once at the new size rather than returning a
    /// truncated plist, which would decode to `[]` and read as "no tags".
    private static func attribute(_ name: String, at path: VFSPath) throws -> Data? {
        try requireLocal(path)
        for _ in 0..<2 {
            let size = getxattr(path.path, name, nil, 0, 0, 0)
            if size < 0 {
                if errno == ENOATTR { return nil }
                throw error(errno, path)
            }
            if size == 0 { return Data() }

            var data = Data(count: size)
            let read = data.withUnsafeMutableBytes { getxattr(
                path.path,
                name,
                $0.baseAddress,
                size,
                0,
                0
            ) }
            if read >= 0 { return data.prefix(read) }
            if errno == ENOATTR { return nil }
            if errno == ERANGE { continue } // it grew between the two calls — size it again
            throw error(errno, path)
        }
        throw VFSError.io(path: path, code: ERANGE)
    }

    private static func writeAttribute(_ name: String, _ data: Data, at path: VFSPath) throws {
        let result = data.withUnsafeBytes { setxattr(
            path.path,
            name,
            $0.baseAddress,
            data.count,
            0,
            0
        ) }
        if result < 0 { throw error(errno, path) }
    }

    /// Remove an attribute; a file that never had it is already in the requested state.
    private static func removeAttribute(_ name: String, at path: VFSPath) throws {
        if removexattr(path.path, name, 0) < 0, errno != ENOATTR {
            throw error(errno, path)
        }
    }

    private static func requireLocal(_ path: VFSPath) throws {
        guard path.backend == .local else {
            throw VFSError.unsupported("Only local files carry Finder tags.")
        }
    }

    /// `ENOATTR` shares a value with `ENODATA` and means "no such attribute", never "no such file";
    /// callers handle it before reaching here. Everything else maps the way the rest of the VFS
    /// layer maps errno.
    private static func error(_ code: Int32, _ path: VFSPath) -> VFSError {
        VFSError.fromErrno(code, path: path)
    }
}
