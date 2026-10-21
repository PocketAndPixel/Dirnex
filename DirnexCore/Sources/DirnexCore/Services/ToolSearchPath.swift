import Foundation

/// The `PATH` a user script runs with: the one Dirnex inherited, widened to the directories a login
/// shell would search.
///
/// A LaunchServices-launched app inherits launchd's `/usr/bin:/bin:/usr/sbin:/sbin` and nothing more
/// (`launchctl getenv PATH` answers empty, measured 2026-10-21), so a command that works in Terminal
/// can fail from a script with *command not found*. Two lists close the gap:
///
/// - ``toolDirectories``, the Homebrew and `/usr/local` prefixes, where most command-line tools a
///   script reaches for (`cwebp`, `ffmpeg`, `npm`) are installed or linked.
/// - The system's own list, `/etc/paths` and then every file in `/etc/paths.d`
///   (``systemDirectories(in:home:)``). That is what macOS's `path_helper` reads for a login shell,
///   and it is where an installer registers a directory of its own. The .NET SDK writes
///   `/usr/local/share/dotnet` there and links nothing into `/usr/local/bin`, so with the fixed list
///   alone a script could not find `dotnet` by name (measured on this Mac, 2026-10-21).
///
/// **Both are appended, and nothing is reordered.** `path_helper` puts its list *ahead* of the
/// inherited `PATH`; doing that here would change which copy of a tool wins for every script that
/// already worked. Appending only ever adds a directory that was missing, so a tool found before is
/// found in the same place.
///
/// Neither list sees what the user's shell startup files add, or the order they put it in, which is
/// why a script asks the shell itself first (``ShellPathProbe``). When the shell answers, its
/// `PATH` is the one widened here; these lists are the fallback when it does not.
public enum ToolSearchPath {
    /// The directory holding `paths` and `paths.d` on a real Mac.
    public static let systemRoot = URL(fileURLWithPath: "/etc", isDirectory: true)

    /// Tool directories a login shell usually has and launchd's `PATH` lacks. A directory that does
    /// not exist is inert in `PATH`, so both Homebrew prefixes (Apple silicon and Intel) cost
    /// nothing.
    public static let toolDirectories = [
        "/opt/homebrew/bin", "/opt/homebrew/sbin",
        "/usr/local/bin", "/usr/local/sbin",
        "/usr/bin", "/bin", "/usr/sbin", "/sbin"
    ]

    /// `inherited` with every directory of ``toolDirectories`` and then of `systemDirectories` that
    /// it lacks appended, in that order.
    public static func widening(_ inherited: String?, adding systemDirectories: [String]) -> String {
        var directories = inherited.map { $0.split(separator: ":").map(String.init) } ?? []
        for directory in toolDirectories + systemDirectories where !directories.contains(directory) {
            directories.append(directory)
        }
        return directories.joined(separator: ":")
    }

    /// The directories `<root>/paths` and the files in `<root>/paths.d` name, in `path_helper`'s
    /// order: `paths` first, then `paths.d` by file name in byte order. Measured on this Mac, that
    /// order is `10-cryptex`, `10-pmk-global`, `100-rvictl`, `dotnet`, `dotnet-cli-tools`, because
    /// `-` sorts before `0`.
    ///
    /// A name starting with `.` is skipped, as `path_helper`'s `paths.d/*` glob skips it, so a
    /// `.DS_Store` is never read as a list. A file that cannot be read as UTF-8 text names nothing,
    /// and a missing `paths.d` is an empty one.
    public static func systemDirectories(
        in root: URL = systemRoot,
        home: String = NSHomeDirectory()
    ) -> [String] {
        let pathsDirectory = root.appendingPathComponent("paths.d", isDirectory: true)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: pathsDirectory.path)) ?? []
        let files = [root.appendingPathComponent("paths")] + names
            .filter { !$0.hasPrefix(".") }
            .sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
            .map { pathsDirectory.appendingPathComponent($0) }
        var directories: [String] = []
        for file in files {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            for directory in self.directories(inPathsFile: text, home: home)
                where !directories.contains(directory) {
                directories.append(directory)
            }
        }
        return directories
    }

    /// The directories one `paths` file names: one per line, trimmed, with blank lines skipped. A
    /// last line without a newline counts, as `/etc/paths.d/dotnet-cli-tools` has none.
    ///
    /// - **A leading `~` is expanded against `home`.** `path_helper` passes it through literally
    ///   (measured: it emits `~/.dotnet/tools`), and then bash finds a tool there while zsh, the
    ///   default shell, does not (measured). Expanding it here makes both shells find it.
    /// - **Any other line that is not an absolute path is skipped**, and so is one holding a `:`,
    ///   which cannot be a single `PATH` entry. A relative entry would resolve against the script's
    ///   working directory, which is whatever folder the user is in, perhaps an unpacked download.
    static func directories(inPathsFile text: String, home: String) -> [String] {
        text.split(whereSeparator: \.isNewline).compactMap { line in
            absoluteDirectory(line.trimmingCharacters(in: .whitespaces), home: home)
        }
    }

    /// `entry` as one absolute `PATH` directory, with a leading `~` expanded against `home`, or
    /// `nil` when it is relative or holds a `:`. The rule both a `paths` file and a shell's
    /// answered `PATH` (``ShellPathProbe``) go through.
    static func absoluteDirectory(_ entry: String, home: String) -> String? {
        var directory = entry
        if directory == "~" {
            directory = home
        } else if directory.hasPrefix("~/") {
            directory = home + directory.dropFirst()
        }
        guard directory.hasPrefix("/"), !directory.contains(":") else { return nil }
        return directory
    }
}
