import DirnexCore
import Foundation

/// Runs the bundled GoPro RAW decoder, the non-hermetic half of GPR support (PLAN.md §M28).
///
/// The same split every external tool in this app takes: ``DirnexCore/GoProRAW`` decides which files
/// are offered, builds the argv and reads the exit status, all pure and tested; this spawns the
/// process and manages what it wrote (PLAN.md §2).
///
/// ## What it produces, and why that shape
///
/// A GPR is converted to a **DNG in a temporary directory**, which the caller then decodes through
/// the ordinary ``RAWImageDecoder``. Converting to an intermediate rather than to pixels directly is
/// what keeps a GoPro photograph looking like its neighbours: the demosaic, the EXIF orientation and
/// the Display P3 tagging are then the same already-measured code every ARW, NEF and CR2 takes. The
/// tool's own preview outputs were measured and rejected for the reason ``GoProRAW/conversionArguments(inputPath:outputPath:)``
/// records — they are downsampled, and the spelling that asks for full resolution silently writes an
/// empty file.
///
/// ## Why this is a process and not a library
///
/// The decoder is ~168k lines of vendored C++ that calls `abort()` on input it dislikes: measured
/// 2026-09-20, a truncated GPR kills it with an uncaught `dng_exception`. A file manager puts the
/// cursor on half-copied files as a matter of course, so in-process that is Dirnex gone during a
/// preview nobody asked for. Out of process it is a `.crashed` outcome and a blank preview.
///
/// Every entry point blocks on a subprocess, so call them off the main actor.
final class GPRConverter: @unchecked Sendable {
    static let shared = GPRConverter()

    /// How many converted DNGs are kept. A GPR is ~5 MB and its DNG ~23 MB, so this is the disk the
    /// feature costs while the app runs. Three is what makes stepping back and forth between two
    /// GoPro files free without letting a walk through a card's worth of them grow without bound.
    private static let cacheLimit = 3

    /// Where the helper lives inside the bundle. `Contents/Helpers` is the convention for a tool
    /// that is not the app's own executable, and the Copy Files phase that puts it there signs it
    /// on copy — an unsigned nested Mach-O would fail notarization.
    private static let helperName = "gpr_tools"

    /// Converted DNG per source identity. Keyed by ``ArchiveIdentity`` rather than by path for the
    /// reason that type exists: a card re-inserted, or a file deleted and re-copied under the same
    /// name, is a *different* photograph at the same path, and a path-keyed cache would show the
    /// previous one.
    private var converted: [ArchiveIdentity: URL] = [:]
    /// Least-recently-used first, so eviction has an order to read rather than one to invent.
    private var order: [ArchiveIdentity] = []
    private let lock = NSLock()
    private var root: URL?

    private init() {}

    /// The bundled helper, or `nil` if this build does not carry one.
    ///
    /// A missing helper is a build problem, not a user's file problem, so it answers `nil` here and
    /// the preview goes blank rather than the app pretending the file is unreadable.
    static var helperURL: URL? {
        let url = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Helpers", isDirectory: true)
            .appendingPathComponent(helperName, isDirectory: false)
        return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
    }

    /// A DNG holding `url`'s image that macOS can decode, or `nil` if it could not be produced.
    ///
    /// Blocking: it spawns the helper and waits. The result is cached, so stepping back onto a file
    /// already converted costs nothing.
    func decodableCopy(of url: URL) -> URL? {
        guard let identity = ArchiveIdentity.current(ofFileAt: url.path) else { return nil }
        if let cached = cachedCopy(for: identity) { return cached }
        guard let helper = Self.helperURL, let destination = makeDestination() else { return nil }

        let outcome = Self.run(helper: helper, input: url.path, output: destination.path)
        // An exit status is not evidence that a usable file was written — the tool exits 0 having
        // written an empty one when asked for an output it cannot make. The size check is cheap; the
        // decode that follows is the real judge.
        guard outcome == .converted, Self.wroteSomething(at: destination) else {
            try? FileManager.default.removeItem(at: destination)
            return nil
        }
        store(destination, for: identity)
        return destination
    }

    /// Drop every converted file. Called when the app is going away, so a session's worth of DNGs
    /// does not outlive it in the temporary directory.
    func purge() {
        lock.lock()
        let directory = root
        converted.removeAll()
        order.removeAll()
        root = nil
        lock.unlock()
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    // MARK: - Cache

    private func cachedCopy(for identity: ArchiveIdentity) -> URL? {
        lock.lock()
        defer { lock.unlock() }
        guard let url = converted[identity] else { return nil }
        // A temporary directory is not ours alone; a file swept from under us is a miss, never a
        // hit that happens to be missing.
        guard FileManager.default.fileExists(atPath: url.path) else {
            converted[identity] = nil
            order.removeAll { $0 == identity }
            return nil
        }
        order.removeAll { $0 == identity }
        order.append(identity)
        return url
    }

    private func store(_ url: URL, for identity: ArchiveIdentity) {
        lock.lock()
        converted[identity] = url
        order.removeAll { $0 == identity }
        order.append(identity)
        var evicted: [URL] = []
        while order.count > Self.cacheLimit {
            let oldest = order.removeFirst()
            if let gone = converted.removeValue(forKey: oldest) { evicted.append(gone) }
        }
        lock.unlock()
        for url in evicted { try? FileManager.default.removeItem(at: url) }
    }

    private func makeDestination() -> URL? {
        lock.lock()
        let existing = root
        lock.unlock()
        let directory: URL
        if let existing, FileManager.default.fileExists(atPath: existing.path) {
            directory = existing
        } else {
            directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("Dirnex-GPR-\(UUID().uuidString)", isDirectory: true)
            do {
                try FileManager.default.createDirectory(
                    at: directory,
                    withIntermediateDirectories: true
                )
            } catch {
                return nil
            }
            lock.lock()
            root = directory
            lock.unlock()
        }
        // The extension is what lets the decoder and every `UTType` lookup downstream see a DNG.
        return directory.appendingPathComponent("\(UUID().uuidString).dng", isDirectory: false)
    }

    // MARK: - Running

    private static func run(helper: URL, input: String, output: String) -> GoProRAW.Conversion {
        let process = Process()
        process.executableURL = helper
        process.arguments = GoProRAW.conversionArguments(inputPath: input, outputPath: output)
        process.environment = ChildProcessLocale.inherited()
        // Both streams go to the null device rather than to pipes. Nothing here parses the tool's
        // chatter — the exit status and the file it wrote are the whole answer — and a pipe nobody
        // drains is the two-pipe deadlock this project has paid for elsewhere.
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice

        let group = DispatchGroup()
        ProcessWaiting.joinTermination(of: process, into: group)
        do {
            try process.run()
        } catch {
            // `joinTermination` entered the group for a process that will never run, so nothing may
            // wait on it. A helper that cannot be launched is a refusal, not a crash.
            group.leave()
            return .refused
        }
        let outcome = ProcessWaiting.wait(
            for: group,
            deadline: .now() + .seconds(conversionBudgetSeconds),
            isCancelled: { false }
        )
        guard outcome == .finished else {
            process.terminate()
            return .refused
        }
        return GoProRAW.outcome(
            exitCode: process.terminationStatus,
            wasSignalled: process.terminationReason == .uncaughtSignal
        )
    }

    /// Generous against a conversion measured at 0.16–0.51 s for a 12 MP HERO7 file. It is a
    /// backstop against a wedged helper, not a performance budget — a preview that is going to be
    /// wrong should still stop being pending.
    private static let conversionBudgetSeconds = 60

    private static func wroteSomething(at url: URL) -> Bool {
        guard let size = try? FileManager.default
            .attributesOfItem(atPath: url.path)[.size] as? Int else { return false }
        // A TIFF header alone is 8 bytes; the empty file the tool writes for an output it cannot
        // make was measured at 11. Anything a camera produced is orders of magnitude larger.
        return size > 1024
    }
}
