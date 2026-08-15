import Foundation
import UniformTypeIdentifiers

/// A ``SpotlightQuery`` compiled into a test one ``FileEntry`` at a time — the half of M22 that
/// makes a search runnable where there is no index (PLAN.md §M22).
///
/// It is the *same* query the Spotlight route renders into `kMDItem…`, so "Images larger than 1 MB"
/// has one definition and two readings of it rather than two definitions. Where the readings differ
/// they differ for a reason that is stated at each rule below, and never silently.
///
/// **Construction can fail, and that is the point.** A query asking for something the place cannot
/// answer — file *contents* in a bucket, Finder tags on an FTP server — must not quietly run without
/// that clause: dropping a clause widens a search, so the user gets *more* results under the name of
/// a search they saved, which is the quiet direction. So the proof lives in the type: there is no
/// way to hold a `SearchPredicate` that is ignoring part of its query, and the caller is handed the
/// missing fields by name (``SearchQueryUnanswerable``) to say so.
public struct SearchPredicate: Sendable {
    /// The name substring, or `nil` when the query does not ask about names.
    private let nameNeedle: String?
    /// The selected kinds, already resolved to content types; empty when no kind chip is set.
    private let kindTypes: [UTType]
    /// Whether folders themselves are one of the selected kinds.
    private let wantsFolders: Bool
    private let minSizeBytes: Int64?
    /// The oldest modification date that still matches, or `nil` for no date filter. Resolved once
    /// at construction rather than per entry, so every row in one walk is judged against the same
    /// instant — a walk can run for minutes, and a window that slides underneath it would make the
    /// same file match at the start and miss at the end.
    private let modifiedSince: Date?

    /// Compile `query` for a place answering `fields`.
    ///
    /// - Throws: ``SearchQueryUnanswerable`` when `query` asks about a field outside `fields`.
    public init(
        _ query: SpotlightQuery,
        answering fields: SearchFields,
        now: Date = Date()
    ) throws {
        let missing = Self.unanswerable(in: query, given: fields)
        guard missing.isEmpty else { throw SearchQueryUnanswerable(fields: missing) }

        let name = query.trimmedName
        nameNeedle = name.isEmpty ? nil : name
        wantsFolders = query.kinds.contains(.folder)
        // `SearchKind.contentType` is the identical string the metadata predicate compares against,
        // so the two routes ask one question of two different sources. A type the system cannot
        // resolve is dropped rather than failing the search: it would match nothing anyway, and a
        // whole query refused because one chip is unrecognizable is worse than a chip that finds
        // nothing.
        kindTypes = query.kinds
            .filter { $0 != .folder }
            .compactMap { UTType($0.contentType) }
        minSizeBytes = query.minSizeBytes
        modifiedSince = query.modifiedWithin.map { now.addingTimeInterval(-Double($0.seconds)) }
    }

    /// Whether `entry` satisfies every clause. Clauses AND, exactly as the metadata predicate's do.
    public func matches(_ entry: FileEntry) -> Bool {
        guard matchesName(entry), matchesKind(entry), matchesSize(entry), matchesDate(entry)
        else { return false }
        return true
    }

    /// Case- and diacritic-insensitive substring, which is what the `cd` suffix on the metadata
    /// predicate's `kMDItemFSName` comparison means.
    private func matchesName(_ entry: FileEntry) -> Bool {
        guard let nameNeedle else { return true }
        return entry.name.range(
            of: nameNeedle,
            options: [.caseInsensitive, .diacriticInsensitive]
        ) != nil
    }

    /// The kind chips, decided from the **name** rather than from the bytes.
    ///
    /// This is the one rule that genuinely differs between the two routes, and the difference is
    /// what makes it free: Spotlight knows a JPEG that somebody named `.txt` is an image, and a
    /// listing does not. Asking `UTType` what the extension declares costs no request and no read,
    /// and answers correctly for the overwhelming majority of files, which is what a filter chip
    /// needs to be.
    ///
    /// A **directory** matches only when Folders is selected — never through its own name. A folder
    /// called `holiday.photos` is not an image, and deriving a type from a directory's extension is
    /// how it would become one.
    private func matchesKind(_ entry: FileEntry) -> Bool {
        guard wantsFolders || !kindTypes.isEmpty else { return true }
        if entry.isDirectory { return wantsFolders }
        guard let type = UTType(filenameExtension: entry.fileExtension) else { return false }
        return kindTypes.contains { type.conforms(to: $0) }
    }

    /// A size filter is a question about a **file**, so a directory never satisfies one.
    ///
    /// None of the three connected backends measures a folder — S3 has no such object at all — so
    /// the alternative is a row matching a size question vacuously, which claims something about
    /// the folder where the truth is a claim about the question.
    private func matchesSize(_ entry: FileEntry) -> Bool {
        guard let minSizeBytes else { return true }
        return !entry.isDirectory && entry.byteSize >= minSizeBytes
    }

    /// A date filter likewise, and here the gap is real rather than merely unmeasured: an S3 folder
    /// is a *common prefix* and carries no `LastModified` whatsoever, which arrives as
    /// ``FileEntry/unknownDate``. A row that has no such attribute does not match, rather than
    /// matching because nothing contradicted it.
    private func matchesDate(_ entry: FileEntry) -> Bool {
        guard let modifiedSince else { return true }
        return entry.hasModificationDate && entry.modificationDate >= modifiedSince
    }

    /// The fields `query` asks about that `fields` cannot answer — empty when it is runnable.
    ///
    /// Public so the app can ask *before* offering to run something: a saved search re-run against a
    /// scope that cannot answer it should say which term it cannot honour, not fail at the walk.
    public static func unanswerable(
        in query: SpotlightQuery,
        given fields: SearchFields
    ) -> SearchFields {
        var asked: SearchFields = []
        if !query.trimmedName.isEmpty { asked.insert(.name) }
        if !query.trimmedContent.isEmpty { asked.insert(.content) }
        if !query.trimmedTags.isEmpty { asked.insert(.tags) }
        if !query.kinds.isEmpty { asked.insert(.kind) }
        if query.minSizeBytes != nil { asked.insert(.size) }
        if query.modifiedWithin != nil { asked.insert(.modified) }
        return asked.subtracting(fields)
    }
}

/// Thrown when a ``SpotlightQuery`` asks about something the place it is being run against cannot
/// answer — content or Finder tags on a connected server, in practice.
///
/// Carries *which* fields rather than merely failing, because the sentence the user needs names the
/// term they typed ("this server can't search inside files"), and a bare refusal on a search that
/// works perfectly at home reads as the feature being broken.
public struct SearchQueryUnanswerable: Error, Equatable, Sendable {
    public let fields: SearchFields

    public init(fields: SearchFields) {
        self.fields = fields
    }
}
