import Foundation
import Testing

@testable import DirnexCore

/// The backend seam a save-back is routed through, and what a backend that cannot carry a
/// precondition does about one (PLAN.md §4 ▸ *Still open*, taken 2026-09-01).
///
/// One rule and it is asymmetric, which is why it is worth its own suite: an **unconditional**
/// write falls through to `copyFile` — what a save-back over SFTP or FTP has always been — and a
/// **conditional** one throws rather than writing unguarded. The forbidden outcome is the quiet
/// one: a caller told its write was protected, whose write was not.
@Suite("Save-back seam")
struct WriteBackSeamTests {
    private let remote = VFSPath(
        backend: .sftp(SFTPLocation(host: "srv", username: "oleg")),
        path: "/home/oleg/notes.txt"
    )

    @Test("the default writes an unconditional save-back through copyFile")
    func defaultWritesUnconditionally() throws {
        let backend = PlainBackend()
        let guarded = try backend.writeBack(
            localPath: "/tmp/edits/notes.txt",
            to: remote,
            condition: .unconditional,
            progress: { _ in },
            isCancelled: { false }
        )
        // The dispatch is the claim: an unconditional save-back is the ordinary copy this path has
        // always been, from the temp copy to the remote file.
        #expect(backend.copies == [Copy(from: .local("/tmp/edits/notes.txt"), to: remote)])
        // Never claims a guard it did not ask for: the answer is about this client, and there was
        // no precondition to send.
        #expect(!guarded)
    }

    @Test("the default refuses a precondition rather than dropping it")
    func defaultRefusesAConditionItCannotCarry() {
        let backend = PlainBackend()
        #expect(throws: S3WriteConditionUnsupported.self) {
            try backend.writeBack(
                localPath: "/tmp/edits/notes.txt",
                to: remote,
                condition: .ifMatches(entityTag: "\"abc\""),
                progress: { _ in },
                isCancelled: { false }
            )
        }
        // The half that makes it a refusal rather than a failure after the fact: **nothing was
        // written**. A backend that threw after copying would have overwritten the very file it was
        // refusing to overwrite, which is the outcome the whole rule exists to prevent.
        #expect(backend.copies.isEmpty)
    }

    @Test("a backend that implements the verb is used instead of the default")
    func anOverrideIsPreferred() throws {
        // The dispatch itself, which is what the S3 side rests on: without it a guarded save-back
        // to a bucket would take the default's throw and every conditional save would fail.
        let backend = ConditionalBackend()
        let guarded = try backend.writeBack(
            localPath: "/tmp/a.txt",
            to: .local("/tmp/b.txt"),
            condition: .ifMatches(entityTag: "\"abc\""),
            progress: { _ in },
            isCancelled: { false }
        )
        #expect(guarded)
        #expect(backend.conditions == [.ifMatches(entityTag: "\"abc\"")])
    }
}

/// One copy the default asked for.
struct Copy: Equatable {
    let from: VFSPath
    let to: VFSPath
}

/// A backend with no save-back of its own — every remote transport but S3.
///
/// It records rather than copying, because what is under test is the **dispatch**: that the default
/// forwards to `copyFile`, and that it forwards *nothing at all* when it is holding a precondition
/// it cannot carry. Performing a real copy would drag in whatever the performing backend does with
/// an occupied destination, which is its own answer and a different question.
private final class PlainBackend: VFSBackend, @unchecked Sendable {
    private(set) var copies: [Copy] = []

    var id: VFSBackendID { VFSBackendID("test-plain") }
    var capabilities: VFSCapabilities { [.read, .write] }
    func listDirectory(at _: VFSPath) throws -> [FileEntry] { [] }
    func stat(at path: VFSPath) throws -> FileEntry { throw VFSError.notFound(path) }
    func copyFile(
        at source: VFSPath,
        to destination: VFSPath,
        progress: (Int64) -> Void,
        isCancelled _: () -> Bool
    ) throws {
        copies.append(Copy(from: source, to: destination))
        progress(1)
    }
}

/// A backend that carries one — S3's shape, with the transport removed.
private final class ConditionalBackend: VFSBackend, @unchecked Sendable {
    private(set) var conditions: [S3WriteCondition] = []

    var id: VFSBackendID { VFSBackendID("test-conditional") }
    var capabilities: VFSCapabilities { [.read, .write] }
    func listDirectory(at _: VFSPath) throws -> [FileEntry] { [] }
    func stat(at path: VFSPath) throws -> FileEntry { throw VFSError.notFound(path) }

    func writeBack(
        localPath _: String,
        to _: VFSPath,
        condition: S3WriteCondition,
        progress _: (Int64) -> Void,
        isCancelled _: () -> Bool
    ) throws -> Bool {
        conditions.append(condition)
        return condition.isConditional
    }
}
