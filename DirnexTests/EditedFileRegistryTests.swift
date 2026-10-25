import DirnexCore
import Foundation
import Testing

@testable import Dirnex

/// The edit watch telling Dirnex's own write to a copy from an editor's save (PLAN.md §M33 Slice 4).
/// The compare window writes a copy F4 may also have open and carries it back itself, so the watch
/// must not offer that write a second time, and must still offer the editor's next save.
@Suite("Edit watch")
@MainActor
struct EditedFileRegistryTests {
    private final class Offers {
        var count = 0
    }

    @Test("a write Dirnex acknowledged is not offered back, and the editor's next save is")
    func acknowledgedWriteIsNotOffered() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("dirnex-edit-watch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("notes.txt")
        try Data("one\n".utf8).write(to: file)

        let registry = EditedFileRegistry()
        let offers = Offers()
        registry.onEdited = { _ in offers.count += 1 }
        registry.watch(EditedFile(
            destination: .remoteFile(VFSPath(backend: Handoff.remoteID, path: "/srv/notes.txt")),
            temporaryURL: file,
            name: "notes.txt"
        ))
        defer { registry.stopWatching(file) }
        // A save that must be offered, so the watch is known to be delivering before the write
        // whose offer must not come is counted. Without it, a stream that never started would pass.
        try await offerSave("an editor's first save\n", to: file, until: 1, offers)

        try Data("written by the compare window, which acknowledges it\n".utf8).write(to: file)
        registry.acknowledgeWrite(to: file)
        try await Task.sleep(for: .seconds(1))
        #expect(offers.count == 1)

        // The control: the editor's own save, which nobody acknowledged, is offered.
        try await offerSave(
            "the editor's next save, longer again than that\n",
            to: file,
            until: 2,
            offers
        )
    }

    /// Write `text` as an editor would and wait for the watch to offer it, writing again while it
    /// has not, since "since now" is approximate at a stream's start (docs/NOTES.md ▸ FSEvents).
    private func offerSave(_ text: String, to file: URL, until count: Int, _ offers: Offers) async throws {
        for attempt in 0..<20 where offers.count < count {
            try Data((text + String(repeating: " ", count: attempt)).utf8).write(to: file)
            try await Task.sleep(for: .milliseconds(250))
        }
        try await settleUntil { offers.count >= count }
        try await Task.sleep(for: .milliseconds(300))
        #expect(offers.count == count)
    }

    @Test("acknowledging a copy nobody watches starts no watch")
    func unwatchedCopyStaysUnwatched() {
        let registry = EditedFileRegistry()
        let file = URL(fileURLWithPath: "/tmp/dirnex-not-watched-\(UUID().uuidString).txt")
        registry.acknowledgeWrite(to: file)
        #expect(!registry.isWatching(file))
    }
}
