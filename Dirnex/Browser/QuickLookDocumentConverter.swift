import DirnexCore
import Foundation

/// Runs macOS's own Quick Look generator over an office document and hands back what it wrote — the
/// non-hermetic half of Quick View's document backend. Why this route and not Quick Look's view is
/// ``DirnexCore/QuickLookPreviewBundle``'s subject; this is only the spawn.
///
/// Each conversion writes into its own UUID directory under ``temporaryRoot``, which is purged at
/// launch like every other temp root the app keeps (race-free, since nothing is converting yet).
/// Within a session the directories belong to ``QuickLookDocumentCache``, which deletes the ones it
/// lets go of — a page loaded from one reads its sheets and images from it *after* the load, so a
/// directory cannot be deleted while it may still be on screen.
enum QuickLookDocumentConverter {
    /// A finished conversion: the `.qlpreview` bundle directory and how to show it.
    struct Conversion: Sendable {
        /// The directory `qlmanage` created — the `.qlpreview` bundle itself.
        let bundle: URL
        /// The UUID directory the bundle was written into, which is what gets deleted.
        let outputDirectory: URL
        let content: QuickLookPreviewBundle.Content

        var page: URL { bundle.appendingPathComponent(QuickLookPreviewBundle.previewFileName) }

        func attachment(_ name: String) -> URL { bundle.appendingPathComponent(name) }
    }

    /// The shared temp root every conversion writes beneath.
    static var temporaryRoot: URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("DirnexQuickView", isDirectory: true)
    }

    static func purgeTemporaries() {
        try? FileManager.default.removeItem(at: temporaryRoot)
    }

    /// How long a conversion may run before it is abandoned. Generous on purpose: the slowest
    /// measured is a 50 000-row workbook at 0.74 s, and a preview that is merely slow should still
    /// arrive, while one that never ends must not hold a process open for the life of the app.
    static let timeout: TimeInterval = 30

    /// Convert `document`, or `nil` when there is nothing to show — the generator declined the file
    /// (a corrupt or password-protected document writes no bundle at all, measured), the tool is
    /// missing, or `isCancelled` turned true first. Blocking; call it off the main actor.
    ///
    /// Output goes nowhere. `qlmanage` prints a line of progress to stdout and a log line to stderr
    /// whatever happens, and neither says anything the bundle does not: its exit status is 0 for a
    /// document that "did not produce any preview" too (measured), so the bundle's existence is the
    /// only answer there is. Sending both streams to the null device also means there are no pipes to
    /// drain, which is the deadlock every other spawn here has to design around.
    static func convert(_ document: URL, isCancelled: () -> Bool) -> Conversion? {
        let output = temporaryRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        } catch {
            return nil
        }
        guard run(document: document, into: output, isCancelled: isCancelled),
              let conversion = read(output: output) else {
            try? FileManager.default.removeItem(at: output)
            return nil
        }
        return conversion
    }

    private static func run(document: URL, into output: URL, isCancelled: () -> Bool) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: QuickLookPreviewBundle.executablePath)
        process.arguments = QuickLookPreviewBundle.arguments(
            documentPath: document.path,
            outputDirectory: output.path
        )
        process.environment = ChildProcessLocale.inherited()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let group = DispatchGroup()
        ProcessWaiting.joinTermination(of: process, into: group)
        do {
            try process.run()
        } catch {
            NSLog("Quick View: couldn't run qlmanage — \(error)")
            return false
        }
        switch ProcessWaiting.wait(
            for: group,
            deadline: .now() + timeout,
            isCancelled: isCancelled
        ) {
        case .finished:
            return true
        case .cancelled, .timedOut:
            process.terminate()
            group.wait()
            return false
        }
    }

    /// Read the one bundle `qlmanage` wrote into `output`. Found by extension rather than by the name
    /// it is given, which is the document's own name and may be anything.
    private static func read(output: URL) -> Conversion? {
        let children = (try? FileManager.default.contentsOfDirectory(
            at: output,
            includingPropertiesForKeys: nil
        )) ?? []
        guard let bundle = children.first(where: {
            $0.pathExtension == QuickLookPreviewBundle.bundleExtension
        }) else { return nil }
        let page = bundle.appendingPathComponent(QuickLookPreviewBundle.previewFileName)
        guard let html = text(at: page) else { return nil }
        let properties = try? Data(
            contentsOf: bundle.appendingPathComponent(QuickLookPreviewBundle.propertiesFileName)
        )
        guard let content = QuickLookPreviewBundle.content(
            previewHTML: html,
            properties: properties,
            attachment: { text(at: bundle.appendingPathComponent($0)) }
        ) else { return nil }
        // Rewritten in place, once, while nothing is loading it: the bundle is this conversion's own
        // copy, and a stylesheet in the file is what reaches the page with or without scripts.
        if case .page(_, centersContent: true, _) = content {
            try? Data(QuickLookPreviewBundle.centering(html).utf8).write(to: page, options: .atomic)
        }
        return Conversion(bundle: bundle, outputDirectory: output, content: content)
    }

    /// A generated page's text. Every bundle measured declares UTF-8; Latin-1 is the fallback that
    /// cannot fail, and the only thing read from it is file names, which are ASCII.
    private static func text(at url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
    }
}

/// The conversions Quick View has made this session, so stepping back onto a document shows it again
/// without re-running the generator — and the one owner of their temp directories.
///
/// Keyed by path *and* ``DirnexCore/ArchiveIdentity``, the same stamp the archive caches use to
/// notice a file replaced under its own name: a document saved again is a different document, and
/// a cached page of the old one would be a preview of something that is no longer there.
@MainActor
final class QuickLookDocumentCache {
    static let shared = QuickLookDocumentCache()

    private struct Entry {
        let path: String
        let identity: ArchiveIdentity
        let conversion: QuickLookDocumentConverter.Conversion
    }

    /// Most recent last. Small, because what it saves is a spawn of well under a second, and what it
    /// costs is a converted copy of each document on disk.
    private var entries: [Entry] = []
    private let capacity = 8

    /// The conversion made for the file at `url` as it is now, if there is one.
    func conversion(for url: URL) -> QuickLookDocumentConverter.Conversion? {
        let path = url.path
        guard let index = entries.firstIndex(where: { $0.path == path }) else { return nil }
        let entry = entries[index]
        guard entry.identity.stillDescribesFile(at: path) else {
            entries.remove(at: index)
            discard(entry.conversion)
            return nil
        }
        entries.remove(at: index)
        entries.append(entry)
        return entry.conversion
    }

    /// Remember `conversion` as the one for `url`, stamped with the identity the file had *before*
    /// the conversion started — a file saved again mid-conversion then misses next time rather than
    /// passing off the older bytes as current. Returns the conversion the caller should show.
    ///
    /// Two surfaces can convert the same document at once (the pane's preview and a full-size one
    /// opened while it was still working). The first to land keeps its entry and the second is
    /// discarded, because the first one's page may already be on screen reading from its directory.
    func store(
        _ conversion: QuickLookDocumentConverter.Conversion,
        for url: URL,
        identity: ArchiveIdentity
    ) -> QuickLookDocumentConverter.Conversion {
        let path = url.path
        if let index = entries.firstIndex(where: { $0.path == path }) {
            if entries[index].identity == identity {
                discard(conversion)
                return entries[index].conversion
            }
            discard(entries.remove(at: index).conversion)
        }
        entries.append(Entry(path: path, identity: identity, conversion: conversion))
        while entries.count > capacity {
            discard(entries.removeFirst().conversion)
        }
        return conversion
    }

    private func discard(_ conversion: QuickLookDocumentConverter.Conversion) {
        let directory = conversion.outputDirectory
        // Off the main actor, and off the cooperative pool too: a delete is blocking I/O
        // (docs/NOTES.md ▸ Swift 6 and concurrency).
        Task {
            await BlockingWork.run(qos: .utility) {
                try? FileManager.default.removeItem(at: directory)
            }
        }
    }
}
