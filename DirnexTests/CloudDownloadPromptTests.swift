import AppKit
import DirnexCore
import Testing

@testable import Dirnex

/// The multi-path form of the download prompt — what a command that needs *all* of its inputs
/// readable runs before it starts (Compare By Contents, and the checksums that follow).
///
/// What can be pinned here is the ordinary path, which is also the one every compare takes: files
/// whose bytes are already on this disk cost a `stat` each, raise no sheet, and hand control on
/// exactly once. The evicted path cannot be tested — `SF_DATALESS` is the file provider's flag and
/// `chflags` silently drops it (probed), so a real placeholder is unavailable to a test and the
/// download itself needs iCloud. `ByteComparatorPlaceholderTests` covers the decision that leads
/// here; this covers the walk.
@MainActor
@Suite("CloudDownloadPrompt — several paths at once")
struct CloudDownloadPromptTests {
    private func temporaryFile(_ name: String) throws -> VFSPath {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("dirnex-clouddownload-\(UUID().uuidString)-\(name)")
        try Data("x".utf8).write(to: url)
        return VFSPath(backend: .local, path: url.path)
    }

    @Test("local files proceed exactly once, with no sheet")
    func localPathsProceedOnce() async throws {
        let paths = [try temporaryFile("a"), try temporaryFile("b")]
        defer { for path in paths { try? FileManager.default.removeItem(atPath: path.path) } }

        var runs = 0
        await confirmation { proceeded in
            await withCheckedContinuation { continuation in
                CloudDownloadPrompt.materialize(paths, using: LocalBackend(), over: nil) {
                    runs += 1
                    proceeded()
                    continuation.resume()
                }
            }
        }
        #expect(runs == 1)
    }

    @Test("an empty list still hands control on, so a caller needs no special case")
    func emptyListProceeds() async {
        await confirmation { proceeded in
            await withCheckedContinuation { continuation in
                CloudDownloadPrompt.materialize([], using: LocalBackend(), over: nil) {
                    proceeded()
                    continuation.resume()
                }
            }
        }
    }

    /// A path that can't be statted is passed over rather than reported: the operation that follows
    /// describes a vanished file better than an alert from the download prompt would.
    @Test("a path that isn't there is stepped over instead of stalling the command")
    func missingPathProceeds() async {
        let missing = VFSPath(backend: .local, path: "/nowhere/dirnex/\(UUID().uuidString)")
        await confirmation { proceeded in
            await withCheckedContinuation { continuation in
                CloudDownloadPrompt.materialize([missing], using: LocalBackend(), over: nil) {
                    proceeded()
                    continuation.resume()
                }
            }
        }
    }
}
