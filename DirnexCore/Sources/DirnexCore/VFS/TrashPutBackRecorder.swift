import Foundation

/// Gives an item Dirnex trashed itself the **Put Back** every other trashed item has, by writing
/// the record macOS would have written (PLAN.md §M26 Slice 5).
///
/// `FileManager.trashItem` writes the `ptbL`/`ptbN` pair into the trash's own `.DS_Store`, so every
/// ordinary delete has always been restorable in Finder. An item inside a File Provider domain is
/// one `trashItem` refuses (▸ ``TrashPerformer``), so ``ProviderAwareTrashPerformer`` moves it with
/// a `renamex_np` — and a rename records nothing. Reported by a user 2026-08-31: a file deleted
/// from Dropbox in Dirnex has no Put Back in Finder, while the same file deleted in Finder does.
/// It was never only Dropbox — every OneDrive, Box, Google Drive and iCloud Drive delete had it.
///
/// **Reads first, and gives up rather than overwriting anything it could not read.** The file it
/// rewrites is Finder's database, holding the put-back records for every item Finder or `trashItem`
/// put there — 142 of them in this Mac's own `~/.Trash` — so a parse this build cannot complete, an
/// origin that cannot be expressed, or output that will not read back is answered by leaving the
/// file exactly as it was. Losing one item's Put Back is the bug being fixed; losing everybody
/// else's would be a worse one.
public enum TrashPutBackRecorder {
    /// Record where `landed` came from, so Finder can put it back.
    ///
    /// - Returns: whether the record was written. Callers ignore it — a delete whose bytes have
    ///   moved has succeeded, and this is the difference between one restorable item and one the
    ///   user drags out by hand — but a test needs to be able to tell the two apart.
    @discardableResult
    public static func record(_ origin: TrashOrigin, forItemAt landed: URL) -> Bool {
        let trash = landed.deletingLastPathComponent()
        let store = trash.appendingPathComponent(TrashPutBack.storeName)

        let existing: [DSStoreEntry]
        switch read(at: store) {
        case let .database(entries): existing = entries
        // No database yet — the ordinary state of a File Provider trash until something is deleted
        // into it. Probed 2026-08-31: one created here from nothing gave Google Drive's
        // `<mount>/.Trash` a working Put Back.
        case .absent: existing = []
        case .unreadable: return false
        }

        guard let merged = TrashPutBack.recording(
            origin,
            forItemNamed: landed.lastPathComponent,
            inTrashAt: .local(trash.path),
            into: existing
        ),
            let data = DSStoreWriter.data(for: merged),
            readsBack(data, as: merged)
        else {
            return false
        }
        return (try? data.write(to: store, options: .atomic)) != nil
    }

    private enum Store {
        case database([DSStoreEntry])
        case absent
        case unreadable
    }

    /// **Only a file that genuinely is not there counts as "no database yet".**
    ///
    /// The distinction is the whole safety of the write. `~/.Trash` is behind Full Disk Access, so
    /// a build without that grant is refused the read — and a refusal read as an empty database
    /// would have this replace the 142 put-back records Finder has written there with the single
    /// row it came to add. Nothing would report it; the user would simply find that Put Back had
    /// stopped working for everything they ever deleted.
    private static func read(at store: URL) -> Store {
        do {
            return .database(try DSStoreReader.entries(in: try Data(contentsOf: store)))
        } catch let error as NSError where error.domain == NSCocoaErrorDomain {
            let absent = error.code == NSFileReadNoSuchFileError || error.code == NSFileNoSuchFileError
            return absent ? .absent : .unreadable
        } catch {
            // A `DSStoreError`, or anything else: a file that is there and did not parse.
            return .unreadable
        }
    }

    /// Parse what is about to be written, before it replaces anything.
    ///
    /// The one guard that is about *this* code rather than about the filesystem: a writer bug would
    /// otherwise replace a working database with an unreadable one, and nothing downstream would
    /// say so — Finder would simply stop offering Put Back for items it had recorded itself.
    private static func readsBack(_ data: Data, as entries: [DSStoreEntry]) -> Bool {
        guard let parsed = try? DSStoreReader.entries(in: data) else { return false }
        return parsed == entries.sorted(by: DSStoreEntry.isOrderedBefore)
    }
}
