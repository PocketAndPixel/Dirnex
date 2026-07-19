import DirnexCore
import Foundation

/// The app-does-I/O half of the Full Disk Access check (PLAN.md §M7). It reads each of the core's
/// TCC-protected sentinels for real and hands the outcomes to `FullDiskAccess.status`, which owns
/// the verdict — the same core-decides-meaning / app-does-I/O split `CloudSyncStatusProvider` has
/// against `CloudItemAttributes`.
///
/// The reads are cheap (a single byte, or one directory listing, and the fold short-circuits at the
/// first readable) but they still touch the disk, so `currentStatus()` runs them off the main
/// thread. A denied read is never surfaced as an error to the user here — it is the answer.
enum FullDiskAccessChecker {
    /// Probe the real home directory and return the verdict, off the main thread.
    static func currentStatus() async -> FullDiskAccessStatus {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return await Task.detached(priority: .utility) {
            status(inHomeDirectory: home)
        }.value
    }

    /// The synchronous probe against a given home directory — the seam the async entry point fills
    /// with the real `~` and a test fills with a temp directory laid out with the sentinel paths.
    static func status(inHomeDirectory home: URL) -> FullDiskAccessStatus {
        FullDiskAccess.status { relative in
            outcome(reading: home.appendingPathComponent(relative))
        }
    }

    /// Try to actually read one sentinel and classify what happened. Existence is checked with a
    /// plain `stat` first (which TCC always allows — the metadata of a protected item is readable,
    /// only its contents aren't), so a sentinel that simply isn't there reads as `.missing` and not
    /// as a permission failure. The content read is what the grant gates: opening the file for a
    /// byte, or listing the directory. Any thrown error is classified by the core.
    private static func outcome(reading url: URL) -> SentinelReadOutcome {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            return .missing
        }
        do {
            if isDirectory.boolValue {
                _ = try fileManager.contentsOfDirectory(atPath: url.path)
            } else {
                let handle = try FileHandle(forReadingFrom: url)
                defer { try? handle.close() }
                _ = try handle.read(upToCount: 1)
            }
            return .readable
        } catch {
            let nsError = error as NSError
            return FullDiskAccess.outcome(domain: nsError.domain, code: nsError.code)
        }
    }
}
