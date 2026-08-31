import Foundation
import Testing

@testable import DirnexCore

/// The `.DS_Store` reader and the put-back interpretation on top of it (PLAN.md §M8 restore).
///
/// The fixture is a **real** `.DS_Store`, written by macOS itself: a 20 MB scratch volume was
/// mounted, four items were trashed from it through `FileManager.trashItem`, and the resulting
/// `/Volumes/DirnexProbe/.Trashes/501/.DS_Store` was copied in whole. Its four items are the cases
/// that matter — an item from the volume root, one from a nested folder, a name with a space, and a
/// **collision**, where the trash renamed the newcomer and only `ptbN` still knows what it was
/// called.
@Suite("Trash put-back")
struct TrashPutBackTests {
    private func fixture() throws -> Data {
        let url = try #require(
            Bundle.module.url(
                forResource: "volume-trash",
                withExtension: "dsstore",
                subdirectory: "Fixtures"
            )
        )
        return try Data(contentsOf: url)
    }

    private let trash = VFSPath.local("/Volumes/DirnexProbe/.Trashes/501")

    // MARK: - The reader

    @Test("reads every put-back record out of a real .DS_Store")
    func readsRealStore() throws {
        let records = try DSStoreReader.stringRecords(in: fixture())
        let locations = records.filter { $0.key == TrashPutBack.locationKey }
        #expect(locations.count == 4)
        #expect(records.allSatisfy { $0.key == "ptbL" || $0.key == "ptbN" })

        let byName = Dictionary(
            grouping: records.filter { $0.key == TrashPutBack.locationKey },
            by: \.filename
        ).compactMapValues(\.first?.value)
        #expect(byName["alpha.txt"] == "/")
        #expect(byName["beta file.txt"] == "/deep/nested/")
        #expect(byName["alpha.txt 13-12-35-977.txt"] == "/deep/")
    }

    @Test("bytes that aren't a .DS_Store are refused, not misread")
    func refusesForeignBytes() throws {
        #expect(throws: DSStoreError.notADSStore) {
            try DSStoreReader.stringRecords(in: Data("not a store at all".utf8))
        }
    }

    @Test("a truncated store throws rather than returning a partial answer")
    func refusesTruncatedStore() throws {
        let truncated = try fixture().prefix(2048)
        #expect(throws: (any Error).self) {
            try DSStoreReader.stringRecords(in: truncated)
        }
    }

    // MARK: - Origins

    @Test("each trashed item resolves to the folder it came from, on its own volume")
    func resolvesOrigins() throws {
        let origins = try TrashPutBack.origins(inDSStore: fixture(), ofTrashAt: trash)

        let alpha = try #require(origins["alpha.txt"])
        #expect(alpha.destination.path == "/Volumes/DirnexProbe/alpha.txt")

        let beta = try #require(origins["beta file.txt"])
        #expect(beta.directory.path == "/Volumes/DirnexProbe/deep/nested")
        #expect(beta.destination.path == "/Volumes/DirnexProbe/deep/nested/beta file.txt")
    }

    @Test("a renamed-on-collision item goes back under its original name")
    func restoresOriginalName() throws {
        let origins = try TrashPutBack.origins(inDSStore: fixture(), ofTrashAt: trash)
        let renamed = try #require(origins["alpha.txt 13-12-35-977.txt"])
        #expect(renamed.name == "alpha.txt")
        #expect(renamed.destination.path == "/Volumes/DirnexProbe/deep/alpha.txt")
    }

    @Test("items with no record are absent rather than guessed at")
    func skipsUnrecordedItems() throws {
        let origins = try TrashPutBack.origins(inDSStore: fixture(), ofTrashAt: trash)
        #expect(origins["never-trashed.txt"] == nil)
    }

    // MARK: - Path forms

    @Test("a volume trash resolves against its own volume, a home trash against the boot volume")
    func volumeRoots() {
        #expect(TrashPutBack.volumeRoot(ofTrashAt: trash).path == "/Volumes/DirnexProbe")
        #expect(TrashPutBack.volumeRoot(ofTrashAt: .local("/Users/oleg/.Trash")).path == "/")
    }

    /// Both spellings the system writes, probed on one machine on one day: the volume trash records
    /// a leading slash, `~/.Trash` does not, and Finder's own trashing hides the boot volume behind
    /// its data firmlink.
    @Test("both recorded path forms resolve to the same real folder")
    func normalizesRecordedForms() {
        let boot = VFSPath.local("/")
        #expect(
            TrashPutBack.directory(recordedAs: "Users/oleg/", onVolumeAt: boot).path == "/Users/oleg"
        )
        #expect(
            TrashPutBack.directory(recordedAs: "/Users/oleg/", onVolumeAt: boot).path == "/Users/oleg"
        )
        #expect(
            TrashPutBack.directory(
                recordedAs: "System/Volumes/Data/private/tmp/probe/",
                onVolumeAt: boot
            ).path == "/private/tmp/probe"
        )
        #expect(
            TrashPutBack.directory(recordedAs: "/", onVolumeAt: .local("/Volumes/X")).path
                == "/Volumes/X"
        )
    }

    // MARK: - Writing the record

    /// The inverse is checked against **the strings macOS itself wrote** in the fixture: whatever
    /// `location(of:forTrashAt:)` produces for one of those folders has to be the record that is
    /// already sitting in that file, or Finder is being handed a spelling it did not choose.
    @Test("the recorded location is the one macOS wrote for the same folder")
    func writesTheSameLocationMacOSDid() throws {
        let recorded = try TrashPutBack.origins(inDSStore: fixture(), ofTrashAt: trash)
        for (name, origin) in recorded {
            let written = try DSStoreReader.stringRecords(in: fixture())
                .first { $0.filename == name && $0.key == TrashPutBack.locationKey }?.value
            #expect(TrashPutBack.location(of: origin.directory, forTrashAt: trash) == written)
        }
        #expect(!recorded.isEmpty)
    }

    /// The other spelling, and the one every File Provider delete now takes: a home or provider
    /// trash records against `/` with no leading slash — the form `FileManager.trashItem` leaves in
    /// `~/.Trash`, and the form Finder read back correctly when it was written here by hand
    /// (probed 2026-08-31).
    @Test("a home trash records without the leading slash, a volume trash with it")
    func writesBothPathForms() {
        let home = VFSPath.local("/Users/oleg/.Trash")
        #expect(
            TrashPutBack.location(of: .local("/Users/oleg/Downloads"), forTrashAt: home)
                == "Users/oleg/Downloads/"
        )
        #expect(
            TrashPutBack.location(of: .local("/Volumes/DirnexProbe/deep"), forTrashAt: trash) == "/deep/"
        )
        #expect(TrashPutBack.location(of: .local("/Volumes/DirnexProbe"), forTrashAt: trash) == "/")
    }

    /// A folder on another volume cannot be named in this trash's records at all — the recorded
    /// path is relative to the volume, so there is nothing to write and nothing to guess.
    @Test("a folder on another volume is refused rather than recorded wrongly")
    func refusesAnOffVolumeFolder() {
        #expect(TrashPutBack.location(of: .local("/Users/oleg/Downloads"), forTrashAt: trash) == nil)
    }

    @Test("what is written is what the reader reads back")
    func recordRoundTrips() throws {
        let origin = TrashOrigin(
            directory: .local("/Volumes/DirnexProbe/deep/nested"),
            name: "beta file.txt"
        )
        let entries = try #require(
            TrashPutBack.recording(
                origin,
                forItemNamed: "beta file 01.txt",
                inTrashAt: trash,
                into: []
            )
        )
        let data = try #require(DSStoreWriter.data(for: entries))

        let read = try TrashPutBack.origins(inDSStore: data, ofTrashAt: trash)
        #expect(read["beta file 01.txt"] == origin)
    }
}
