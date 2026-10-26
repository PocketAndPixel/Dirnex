import Foundation

/// Finding the `zstd` program that a `.tar.zst` needs, which a Dock-launched Dirnex cannot find
/// on its own.
///
/// **macOS's libarchive has no Zstandard built in, and macOS ships no `zstd`.** Measured 2026-10-26
/// against libarchive 3.7.4 on macOS 26.7: `archive_libzstd_version()` answers NULL, and both
/// `archive_read_support_filter_zstd` and `archive_write_add_filter_zstd` answer `ARCHIVE_WARN`,
/// *Using external zstd program*. So `bsdtar` runs `zstd -d -qq` to read one and
/// `zstd --no-check -3` to write one, and the in-process reader (``EncryptedArchiveReader``) runs
/// the same read command. Each is looked up by `posix_spawnp` in the `PATH` of whatever spawns it.
/// Compression.framework and AppleArchive have no zstd either. Homebrew's is the usual copy.
///
/// A LaunchServices-launched app has launchd's `/usr/bin:/bin:/usr/sbin:/sbin`. Measured in the
/// Debug build launched that way, browsing into a `.tar.zst` answered *Couldn't read the archive*,
/// while a `.tar.gz` beside it opened, and so did the same build with `/opt/homebrew/bin` on `PATH`.
///
/// - **The search** is the inherited `PATH`, then ``ToolSearchPath``'s directories (both Homebrew
///   prefixes, `/usr/local`, and what `/etc/paths` and `/etc/paths.d` name), then MacPorts'
///   `/opt/local/bin`, which MacPorts adds in shell startup files rather than in `/etc/paths.d`.
///   The inherited `PATH` comes first, so a build launched from a shell uses the copy the shell
///   would.
/// - **A `bsdtar` child** gets the found directory appended to its `PATH` (``childPath(_:zstd:)``,
///   through ``BsdtarEnvironment``), so its argv is unchanged and `bsdtar` finds the program
///   itself.
/// - **The in-process reader** is handed the absolute path (``readCommand(zstd:)``), since its
///   lookup uses Dirnex's own `PATH`. Every archive rewrite starts with that reader's inspection,
///   so a fix to the `bsdtar` children alone would have left F8 and paste inside a `.tar.zst`
///   failing.
/// - **With no `zstd` anywhere**, a Zstandard archive is refused by name
///   (``refusal(forArchiveAt:zstd:)``) instead of as unreadable.
public enum ZstdTool {
    /// The program's file name.
    public static let executableName = "zstd"

    /// MacPorts' tool directory, searched after ``ToolSearchPath``'s.
    static let macPortsDirectory = "/opt/local/bin"

    /// The first four bytes of a Zstandard frame, `0xFD2FB528` little-endian.
    public static let frameSignature: [UInt8] = [0x28, 0xB5, 0x2F, 0xFD]

    /// The first four bytes of the first skippable frame, `0x184D2A50` little-endian. `pzstd` starts
    /// every archive with one (measured: `50 2a 4d 18`, then a standard frame), and libarchive's own
    /// zstd filter bids on it, so the reader needs a filter for it too.
    public static let skippableFrameSignature: [UInt8] = [0x50, 0x2A, 0x4D, 0x18]

    /// The directories ``locate()`` searches instead of the real ones, when set: a test's way to
    /// stand for a Mac with no `zstd` (`[]`) or with one in a fixture directory, without touching
    /// the process's `PATH`. `nil`, the default, searches for real.
    @TaskLocal public static var searchDirectoriesOverride: [String]?

    /// The absolute path of the `zstd` this Mac has, or `nil` when there is none in the search.
    /// Looked up on each call, so a `zstd` installed while Dirnex runs is found at the next archive
    /// opened. It costs a stat per directory and a read of `/etc/paths.d`.
    public static func locate() -> String? {
        let directories = searchDirectoriesOverride ?? searchDirectories(
            inheritedPath: ProcessInfo.processInfo.environment["PATH"],
            systemDirectories: ToolSearchPath.systemDirectories(),
            home: NSHomeDirectory()
        )
        return locate(in: directories) { path in
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
                && !isDirectory.boolValue
                && FileManager.default.isExecutableFile(atPath: path)
        }
    }

    /// The directories searched, in order and each once: `inheritedPath`'s absolute entries, then
    /// ``ToolSearchPath``'s with `systemDirectories`, then MacPorts'. A relative entry is skipped,
    /// since it would resolve against whatever folder the user is in.
    static func searchDirectories(
        inheritedPath: String?,
        systemDirectories: [String],
        home: String
    ) -> [String] {
        let widened = ToolSearchPath.widening(
            inheritedPath,
            adding: systemDirectories + [macPortsDirectory]
        )
        var directories: [String] = []
        for entry in widened.split(separator: ":") {
            guard let directory = ToolSearchPath.absoluteDirectory(String(entry), home: home),
                  !directories.contains(directory) else { continue }
            directories.append(directory)
        }
        return directories
    }

    /// The first `<directory>/zstd` that `isExecutable` accepts.
    static func locate(in directories: [String], isExecutable: (String) -> Bool) -> String? {
        directories
            .map { ($0 as NSString).appendingPathComponent(executableName) }
            .first(where: isExecutable)
    }

    /// The `PATH` for a child that may need `zstd`: `inherited` with the directory holding `zstd`
    /// appended when it is not already there. Appended rather than prepended, as
    /// ``ToolSearchPath`` does, so no other program a child finds by name changes. With no `PATH`
    /// at all the child would search `posix_spawnp`'s default, which is kept in front.
    public static func childPath(_ inherited: String?, zstd: String?) -> String? {
        guard let zstd else { return inherited }
        let directory = (zstd as NSString).deletingLastPathComponent
        let base = inherited ?? "/usr/bin:/bin"
        guard !base.split(separator: ":").contains(Substring(directory)) else { return base }
        return base.isEmpty ? directory : base + ":" + directory
    }

    /// The command the in-process reader runs to decompress, `bsdtar`'s own read flags behind the
    /// absolute path. The path is double-quoted with `\` and `"` escaped, which is how libarchive's
    /// command-line parser takes a path with a space (measured: unquoted, it ran the path's first
    /// word and failed).
    public static func readCommand(zstd: String) -> String {
        var quoted = "\""
        for character in zstd {
            if character == "\\" || character == "\"" { quoted.append("\\") }
            quoted.append(character)
        }
        return quoted + "\" -d -qq"
    }

    /// Whether `bytes` begin a Zstandard stream: a frame, or any of the sixteen skippable frames
    /// (`0x184D2A50`–`0x184D2A5F`) the format lets a stream start with.
    public static func isZstandard(_ bytes: some Collection<UInt8>) -> Bool {
        let prefix = Array(bytes.prefix(4))
        guard prefix.count == 4 else { return false }
        if prefix == frameSignature { return true }
        return prefix[0] & 0xF0 == 0x50 && prefix[1...] == skippableFrameSignature[1...]
    }

    /// Whether the file at `path` begins a Zstandard stream. Reads four bytes; a file that cannot
    /// be read is not one.
    public static func isZstandard(fileAt path: String) -> Bool {
        guard let handle = FileHandle(forReadingAtPath: path) else { return false }
        defer { try? handle.close() }
        return (try? handle.read(upToCount: 4)).map { isZstandard($0) } ?? false
    }

    /// Why the archive at `path` cannot be opened, when the answer is that `zstd` is missing: it is
    /// a Zstandard stream and `zstd` is `nil`. `nil` otherwise, so the caller reports whatever
    /// failure it had.
    public static func refusal(forArchiveAt path: String, zstd: String?) -> VFSUnsupportedReason? {
        guard zstd == nil, isZstandard(fileAt: path) else { return nil }
        return .archiveNeedsZstd(archive: (path as NSString).lastPathComponent)
    }
}
