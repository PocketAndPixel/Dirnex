import Foundation

/// Where the sync records live (PLAN.md §M37 Slice 7).
///
/// One folder per pair, named for ``SyncRecordPair/key``, holding `record.json` and the kept files
/// under opaque names. A record's existence is the user's yes: ``remember(_:)`` makes one when the
/// box is ticked, ``forget(_:)`` removes it when it is unticked, and ``keep(for:using:vaultMountPoints:date:isCancelled:)``
/// keeps nothing for a pair without one (§6: what Dirnex remembers without being asked).
///
/// **Inside a `.noindex` folder, since a kept version is the user's text.** Spotlight indexed a file
/// under Application Support within two seconds, even under a name with no extension, and a folder
/// ending in `.noindex` kept even an explicit `mdimport` out (measured 2026-11-09). Otherwise an
/// older version of a file would turn up in Find Files and Recents, and go on turning up after the
/// file itself had lost those words. The name is set here rather than by the caller, so it cannot be
/// left out.
///
/// A record is rewritten before the files it stops naming are removed, so a crash leaves files
/// nothing names, which ``purge()`` clears at launch, and never a name with no file. Two windows
/// syncing one pair at once can leave a name with no file, and it then reads as no version.
public struct SyncRecordStore: Sendable {
    /// What the store's folder is called inside the one the app hands it.
    static let folderName = "SyncRecords.noindex"
    private static let recordName = "record.json"

    public let root: URL
    public let budget: SyncRecordBudget

    /// `parent` is the folder the store's own goes in. Application Support in the app.
    public init(parent: URL, budget: SyncRecordBudget = .default) {
        root = parent.appendingPathComponent(Self.folderName, isDirectory: true)
        self.budget = budget
    }

    /// What is on the JSON side of a record.
    struct Manifest: Codable {
        let pair: SyncRecordPair
        var versions: [String: SyncRecord.Version]
    }

    // MARK: - The user's yes and no

    /// The pair's record, or `nil` when the user has not asked for one. A record whose file cannot
    /// be read, or that belongs to another pair, counts as none, so nothing is offered on it.
    public func record(for pair: SyncRecordPair) -> SyncRecord? {
        let directory = directory(of: pair)
        guard let manifest = manifest(in: directory), manifest.pair == pair else { return nil }
        return SyncRecord(pair: pair, directory: directory, versions: manifest.versions)
    }

    /// Start keeping versions for this pair. One already remembered keeps what it has.
    public func remember(_ pair: SyncRecordPair) throws {
        guard record(for: pair) == nil else { return }
        let directory = directory(of: pair)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        excludeFromBackup()
        try write(Manifest(pair: pair, versions: [:]), to: directory)
    }

    /// Stop keeping versions for this pair, and remove the ones it has.
    public func forget(_ pair: SyncRecordPair) {
        try? FileManager.default.removeItem(at: directory(of: pair))
    }

    // MARK: - Housekeeping

    /// Remove what no record names: files left by a crash, and folders with no readable record.
    /// Called at launch, since a sync running now has files its record does not name yet.
    public func purge() {
        for name in contents(of: root) {
            let directory = root.appendingPathComponent(name, isDirectory: true)
            guard let manifest = manifest(in: directory), manifest.pair.key == name else {
                try? FileManager.default.removeItem(at: directory)
                continue
            }
            var named = Set(manifest.versions.values.map(\.file.uuidString))
            named.insert(Self.recordName)
            for file in contents(of: directory) where !named.contains(file) {
                try? FileManager.default.removeItem(at: directory.appendingPathComponent(file))
            }
        }
    }

    /// Every record's folder and contents, for a budget that spans them all.
    func allManifests() -> [(directory: URL, manifest: Manifest)] {
        contents(of: root).compactMap { name in
            let directory = root.appendingPathComponent(name, isDirectory: true)
            return manifest(in: directory).map { (directory, $0) }
        }
    }

    // MARK: - Files

    func directory(of pair: SyncRecordPair) -> URL {
        root.appendingPathComponent(pair.key, isDirectory: true)
    }

    func manifest(in directory: URL) -> Manifest? {
        let file = directory.appendingPathComponent(Self.recordName)
        guard let data = try? Data(contentsOf: file) else { return nil }
        return try? JSONDecoder().decode(Manifest.self, from: data)
    }

    func write(_ manifest: Manifest, to directory: URL) throws {
        let data = try JSONEncoder().encode(manifest)
        try data.write(to: directory.appendingPathComponent(Self.recordName), options: .atomic)
    }

    private func contents(of directory: URL) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
    }

    /// Kept versions are Dirnex's bookkeeping about files the user still has, as an archive's undo
    /// snapshots are.
    private func excludeFromBackup() {
        var url = root
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }
}
