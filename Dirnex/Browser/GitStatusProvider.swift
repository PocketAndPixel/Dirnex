import DirnexCore
import Foundation

/// The app's live source of Git state: it spawns `git status` off the main thread, parses it with
/// `DirnexCore.GitStatusParser`, and caches one snapshot per repository root for the panes to render
/// (PLAN.md §M6 "a debounced `git status --porcelain` provider").
///
/// The non-hermetic half of Git awareness — the subprocess, the clock, the cache — lives here, the
/// way `SpotlightSearchRunner` owns `mdfind`; everything about *what* the bytes mean stays in the
/// tested core. Shared, not per-pane, because the unit of caching is the repository: two panes (or
/// two windows) browsing the same working tree ask the same question and must get one answer from
/// one `git` run.
///
/// **Why the rate limiting is not optional.** A pane refreshes on FSEvents, and in a repository the
/// events never stop: a build writes thousands of files, a `git checkout` rewrites the worktree, a
/// save touches one file every few seconds. Spawning `git status` per event would put a process
/// storm behind the user's own editing. So every request is either coalesced into a trailing
/// `debounceInterval` window (a burst becomes one run at its end) or, if the snapshot has already
/// been stale for `maximumStaleness`, run immediately — otherwise a long build's continuous churn
/// would defer the trailing edge forever and the column would freeze for the whole build.
///
/// **Why this cannot feed itself.** `GitCommand` passes `--no-optional-locks`, so the read never
/// writes the index. Without it, our own `git status` would touch `.git/index`, FSEvents would
/// report that as a change, and the pane would ask for another refresh — an infinite spawn loop
/// driven by nothing but our own reading.
@MainActor
final class GitStatusProvider {
    static let shared = GitStatusProvider()

    /// Posted when a repository's snapshot changes, so every pane showing it re-renders. The root
    /// rides in `userInfo` under `repositoryRootKey`; panes ignore roots they aren't browsing.
    static let didChangeNotification = Notification.Name("Dirnex.gitStatusDidChange")
    static let repositoryRootKey = "repositoryRoot"

    /// The scan machine — debounce, LRU cache, per-root serialization — is `DirectoryScanCache`'s;
    /// only the repository walk and the `git status` subprocess below are this provider's.
    ///
    /// Note the unit: one `git status` answers for a whole working tree, so the key here is the
    /// **repository root**, not the directory on screen. A `nil` result — no usable `git`, or a
    /// working tree that went away underneath us — forgets what we knew rather than leaving a stale
    /// column painted over a directory that is no longer a repo.
    private lazy var cache = DirectoryScanCache<Void, GitStatusSnapshot>(
        scan: { root, _ in await GitStatusReader.read(repositoryRoot: root) },
        completion: { [weak self] root, _, _ in
            guard let self else { return }
            NotificationCenter.default.post(
                name: Self.didChangeNotification,
                object: self,
                userInfo: [Self.repositoryRootKey: root]
            )
        }
    )

    // MARK: - Repository discovery

    /// The working tree containing `directory`, or `nil` when it is not in one. Off-main: the walk
    /// is a handful of `stat`s, and it is deliberately *not* cached — `git init` (or a `.git`
    /// someone just deleted) must show up on the next look, and the cost of being right is a few
    /// microseconds per navigation.
    func repositoryRoot(for directory: VFSPath) async -> VFSPath? {
        await Task.detached(priority: .userInitiated) {
            GitRepository.repositoryRoot(for: directory) {
                FileManager.default.fileExists(atPath: $0)
            }
        }.value
    }

    // MARK: - Snapshots

    /// The snapshot already in hand for `root`, or `nil` when none has been read yet. Synchronous
    /// and O(1) — this is what a pane calls while rendering rows.
    func cachedSnapshot(for root: VFSPath) -> GitStatusSnapshot? {
        cache.cachedSnapshot(for: root)
    }

    /// Ask for `root`'s status to be brought up to date, coalescing with any other request in the
    /// same window. The first look at a repository runs immediately (nobody wants to watch a column
    /// appear a third of a second after the folder does); later ones are rate-limited.
    func requestRefresh(for root: VFSPath) {
        cache.requestRefresh(for: root)
    }
}

/// The `git status` subprocess itself: spawn, read, parse. Split from the provider so the provider
/// is nothing but cache and scheduling, and this is nothing but I/O — the same division
/// `SpotlightSearchRunner` draws around `mdfind`.
private enum GitStatusReader {
    /// The `git` to run, resolved once. A miss means no Git awareness at all (a Mac with neither
    /// Homebrew nor the developer tools) and the column simply never appears — the same graceful
    /// degradation as having no external diff tool installed. Resolved lazily and kept, so the
    /// candidate probing does not repeat on every refresh.
    private static let executablePath = GitCommand.executablePath {
        FileManager.default.isExecutableFile(atPath: $0)
    }

    /// Read `repositoryRoot`'s full status, or `nil` when `git` is missing, fails, or the path is
    /// no longer a working tree. Runs entirely off the main thread.
    static func read(repositoryRoot: VFSPath) async -> GitStatusSnapshot? {
        guard let executablePath else { return nil }
        return await Task.detached(priority: .userInitiated) {
            guard let porcelain = output(
                of: executablePath,
                arguments: GitCommand.status(repositoryRoot: repositoryRoot.path)
            ) else { return nil }
            return GitStatusParser.parse(porcelain: porcelain, repositoryRoot: repositoryRoot)
        }.value
    }

    /// Run `git` and return its standard output, or `nil` if it could not be spawned or exited
    /// non-zero (a deleted worktree, a repository owned by another user).
    private static func output(of executablePath: String, arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        // A `detected dubious ownership` warning or similar must never reach the parser.
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return nil
        }
        // Read to EOF before waiting: a dirty repository's status easily outgrows the pipe buffer,
        // and waiting first would deadlock against a `git` blocked on writing it.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }

        // Lossy on purpose, which is why the failable initializer SwiftLint prefers here is wrong:
        // a filename that is not valid UTF-8 is rare but real, and `String(bytes:encoding:)` would
        // answer `nil` for the *whole* output — one broken name in the repository would blank the
        // column for every other row. Decoding lossily costs only that one row's key.
        // swiftlint:disable:next optional_data_string_conversion
        return String(decoding: data, as: UTF8.self)
    }
}
