import Foundation

/// The two pure questions a Trash move asks before it touches anything (PLAN.md §M26): *is this
/// item inside a File Provider domain*, and *what should it be called once it lands*.
///
/// Separated from ``ProviderAwareTrashPerformer`` because both are decisions and only the rename is
/// I/O — the same split ``LocalBackend`` already makes when it keeps the two refusals and hands the
/// move to a performer.
public enum TrashLanding {
    /// Where every File Provider mount on this Mac lives, relative to the home directory.
    ///
    /// Insurance rather than the gate: the ubiquity attribute below answers `true` for all five
    /// providers (Box, Dropbox, OneDrive, Google Drive, iCloud — measured 2026-08-31, and four
    /// separate passes before it, docs/NOTES.md). This list is only consulted when the attribute
    /// read gives no answer *at all*, so an item nobody can classify still takes the route that
    /// works rather than the one that is refused.
    public static let providerRoots = ["Library/CloudStorage", "Library/Mobile Documents"]

    /// Whether `path` is inside a File Provider domain, and therefore one `FileManager.trashItem`
    /// will refuse (▸ ``TrashPerformer``).
    ///
    /// **A successful `false` is authoritative, and that is the half worth stating.** Google Drive
    /// in *mirror* mode puts a symlink at `<mount>/My Drive` pointing out to `~/My Drive`, so a file
    /// "in Drive" is an ordinary local file outside every domain — measured, its ubiquity read
    /// succeeds and answers nothing (`nil`), while the enclosing mount path answers `true`. Reading
    /// the attribute as authoritative sends that file down `trashItem`, which works there and keeps
    /// Finder's Put Back; falling through to the path prefix would take Put Back away from it for
    /// no reason. So the prefix is reached only when the read itself failed.
    ///
    /// - Parameter isUbiquitous: what `URLResourceValues.isUbiquitousItem` answered — with an
    ///   absent key read as `false`, which is what it means — or `nil` when the read itself failed.
    public static func isProviderItem(
        isUbiquitous: Bool?,
        path: String,
        home: String = NSHomeDirectory()
    ) -> Bool {
        if let isUbiquitous { return isUbiquitous }
        return providerRoots.contains { path.hasPrefix(home + "/" + $0 + "/") }
    }

    /// What `FileManager.trashItem` renames an item to when the Trash already holds that name.
    ///
    /// Reproduced rather than invented, because a Trash holding items Dirnex named one way and
    /// Finder another is a surface the user reads. Measured 2026-08-31 by trashing the same name
    /// three times in a row:
    ///
    /// ```
    /// m26-collide.txt     -> m26-collide.txt     m26-collide.txt 01-14-42-179.txt
    /// m26-collide-noext   -> m26-collide-noext   m26-collide-noext 01-14-42-346
    /// m26-collide.tar.gz  -> m26-collide.tar.gz  m26-collide.tar.gz 01-14-42-527.gz
    /// ```
    ///
    /// Note the shape, which is not the obvious one: the **whole original name is kept, extension
    /// included**, the stamp is appended after a space, and only then is the *last* path extension
    /// re-appended — so `.tar.gz` gains `.gz` and a name with no extension gains nothing.
    public static func collisionName(for name: String, stamp: String) -> String {
        let ext = (name as NSString).pathExtension
        return ext.isEmpty ? "\(name) \(stamp)" : "\(name) \(stamp).\(ext)"
    }

    /// The `HH-MM-SS-mmm` stamp the name above carries, in local time.
    ///
    /// `en_US_POSIX` so the hour stays 24-hour: a region on a 12-hour clock would otherwise stamp a
    /// name with a period designator, which is a different format in thirteen of the fourteen
    /// languages this app ships (▸ docs/NOTES.md ▸ Localization).
    public static func stamp(for date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "HH-mm-ss-SSS"
        return formatter.string(from: date)
    }
}
