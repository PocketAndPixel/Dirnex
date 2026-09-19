import Foundation
import Testing
@testable import DirnexCore

/// ``RecognizedPageStore`` — what a scanned document was read as, kept for the life of the process
/// so a reader who arrows away and back does not pay for it twice.
@Suite("Recognized page store")
struct RecognizedPageStoreTests {
    private static func identity(_ inode: UInt64) -> ArchiveIdentity {
        ArchiveIdentity(
            deviceID: 1,
            inode: inode,
            byteSize: 4096,
            modified: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    private static func page(_ text: String) -> RecognizedPageText {
        RecognizedPageText(text: text, words: [])
    }

    @Test("a page read once is answered without reading it again")
    func storeAndRead() {
        var store = RecognizedPageStore()
        store.store(Self.page("alpha"), at: 0, for: Self.identity(1))

        #expect(store.pages(for: Self.identity(1))[0]?.text == "alpha")
        #expect(store.count == 1)
    }

    @Test("a document nothing has been read for answers nothing rather than somebody else's pages")
    func aMissIsEmpty() {
        var store = RecognizedPageStore()
        store.store(Self.page("alpha"), at: 0, for: Self.identity(1))

        #expect(store.pages(for: Self.identity(2)).isEmpty)
    }

    @Test("a path that now names different bytes is a different document")
    func identityRatherThanPath() {
        // The two identities differ only in the modification time — the same file, rewritten. A
        // store keyed by path would answer with the old document's text.
        let before = Self.identity(1)
        let after = ArchiveIdentity(
            deviceID: before.deviceID,
            inode: before.inode,
            byteSize: before.byteSize,
            modified: before.modified.addingTimeInterval(60)
        )
        var store = RecognizedPageStore()
        store.store(Self.page("the old scan"), at: 0, for: before)

        #expect(store.pages(for: after).isEmpty)
    }

    @Test("past its limit the least recently used document is dropped, whole")
    func eviction() {
        var store = RecognizedPageStore(pageLimit: 4)
        store.store(Self.page("a0"), at: 0, for: Self.identity(1))
        store.store(Self.page("a1"), at: 1, for: Self.identity(1))
        store.store(Self.page("b0"), at: 0, for: Self.identity(2))
        store.store(Self.page("b1"), at: 1, for: Self.identity(2))
        #expect(store.count == 4)

        // A fifth page, for a third document: the first document is the oldest and goes entirely.
        store.store(Self.page("c0"), at: 0, for: Self.identity(3))
        #expect(store.pages(for: Self.identity(1)).isEmpty)
        #expect(store.pages(for: Self.identity(2)).count == 2)
        #expect(store.pages(for: Self.identity(3)).count == 1)
    }

    @Test("the document being read is never the one dropped, however small the limit")
    func theDocumentBeingReadSurvives() {
        // Otherwise reading a book longer than the limit would throw each page away as it arrived
        // and never finish.
        var store = RecognizedPageStore(pageLimit: 2)
        for index in 0..<6 {
            store.store(Self.page("page \(index)"), at: index, for: Self.identity(1))
        }

        #expect(store.pages(for: Self.identity(1)).count == 6)
    }

    @Test("a document that is read from again is not the next one dropped")
    func touching() {
        var store = RecognizedPageStore(pageLimit: 3)
        store.store(Self.page("a0"), at: 0, for: Self.identity(1))
        store.store(Self.page("b0"), at: 0, for: Self.identity(2))
        store.store(Self.page("c0"), at: 0, for: Self.identity(3))

        // The reader comes back to the first document, and only then is a fourth one read.
        store.touch(Self.identity(1))
        store.store(Self.page("d0"), at: 0, for: Self.identity(4))

        #expect(store.pages(for: Self.identity(1)).count == 1)
        #expect(store.pages(for: Self.identity(2)).isEmpty)
    }

    @Test("touching a document nothing has been read for changes nothing")
    func touchingAStranger() {
        var store = RecognizedPageStore()
        store.touch(Self.identity(9))
        #expect(store.pages(for: Self.identity(9)).isEmpty)
    }
}
