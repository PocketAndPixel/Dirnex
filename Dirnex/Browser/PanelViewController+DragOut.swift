import AppKit
import DirnexCore

/// What a drag offers applications other than Dirnex, decided once per drag (PLAN.md §M36 Slice 2).
///
/// `DragOutRoute` is the rule and lives in the core. What this file adds is the one input the rule
/// cannot know: whether an archive is **locked**, meaning it needs a passphrase this session does not
/// hold. That is decision A (2026-11-08) — a member of such an archive drags inside Dirnex and goes
/// to no other app, because the only way to ask for the passphrase would be a sheet on Dirnex's
/// window, behind the app the drop went to.
///
/// It also fulfils a member's promise, the archive half of `PanelViewController+DragPromise`.
extension PanelViewController {
    // MARK: - Routes

    /// The route each of `entries` takes out of Dirnex, keyed by path.
    ///
    /// The lock is read once per archive, however many of its members are dragged: the header read
    /// behind it is 3–4 ms on a 600 MB archive (`ArchiveExtractor.needsPassphrase`), which is nothing
    /// once and would be noticeable per row of a large marked set.
    func dragOutRoutes(for entries: [FileEntry]) -> [VFSPath: DragOutRoute] {
        var locked: [String: Bool] = [:]
        var routes: [VFSPath: DragOutRoute] = [:]
        for entry in entries {
            routes[entry.path] = DragOutRoute.route(for: entry) { archive in
                if let known = locked[archive] { return known }
                let answer = archiveIsLocked(archive)
                locked[archive] = answer
                return answer
            }
        }
        return routes
    }

    /// Whether the archive at `archivePath` needs a passphrase this session does not hold.
    func archiveIsLocked(_ archivePath: String) -> Bool {
        ArchiveExtractor.needsPassphrase(forArchiveAt: archivePath)
            && rememberedPassphrase(forArchiveAt: archivePath) == nil
    }

    /// What extracting each routed member needs, gathered here on the main actor so the extraction
    /// itself can run off it: the passphrase this session holds and the code page the user declared.
    func dragOutExtractions(
        for entries: [FileEntry],
        routes: [VFSPath: DragOutRoute]
    ) -> [VFSPath: DragOutExtraction] {
        var extractions: [VFSPath: DragOutExtraction] = [:]
        for entry in entries where routes[entry.path] == .extract {
            guard let member = Self.archiveMember(for: entry) else { continue }
            extractions[entry.path] = DragOutExtraction(
                archivePath: member.archivePath,
                innerPath: member.innerPath,
                passphrase: rememberedPassphrase(forArchiveAt: member.archivePath),
                nameEncoding: declaredNameEncoding(forArchiveAt: member.archivePath)
            )
        }
        return extractions
    }

    // MARK: - Finder's promise

    /// Put an archive member's bytes at `url` and answer, on every path.
    ///
    /// Extracted through the window's `ArchivePreviewCache`, the same copy a preview or ⏎ makes, so
    /// a member already previewed drags out with no extraction at all. The passphrase is the one the
    /// session holds and is never asked for: the route promised this row only because the archive
    /// was open or unencrypted, and if it has been forgotten since, the extraction refuses and the
    /// promise is answered with that refusal.
    func fulfillMemberPromise(
        _ member: ArchiveMember,
        writingTo url: URL,
        then completionHandler: @escaping @Sendable ((any Error)?) -> Void
    ) {
        guard let cache = host?.archivePreviewCache else {
            // A pane with no window controller cannot be reached by a drag, and still owes an answer.
            completionHandler(CocoaError(.fileReadUnknown))
            return
        }
        let passphrase = rememberedPassphrase(forArchiveAt: member.archivePath)
        let encoding = declaredNameEncoding(forArchiveAt: member.archivePath)
        Task {
            do {
                let source = try await cache.extractedURL(
                    for: member, passphrase: passphrase, nameEncoding: encoding
                )
                completionHandler(Self.placePromisedFile(source, at: url))
            } catch {
                completionHandler(error)
                presentOperationFailure(
                    message: String(localized: "Couldn’t extract from the archive"),
                    detail: describe(error)
                )
            }
        }
    }
}

/// What extracting one dragged archive member needs, as a value that can cross to another thread.
///
/// The handoff to other apps extracts off the main actor, where the window's caches and the
/// session's passphrases are out of reach, so this carries what they would have answered.
struct DragOutExtraction: Sendable {
    let archivePath: String
    let innerPath: String
    let passphrase: ArchivePassphrase?
    let nameEncoding: ArchiveNameEncoding?

    /// Extract the member into its own temp directory and return where it landed. Blocks.
    func run() throws -> URL {
        let extraction = try ArchiveExtractor.extract(
            innerPaths: [innerPath],
            fromArchiveAt: archivePath,
            passphrase: passphrase,
            nameEncoding: nameEncoding
        )
        guard let path = extraction.extractedPaths.first else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        return URL(fileURLWithPath: path)
    }
}
