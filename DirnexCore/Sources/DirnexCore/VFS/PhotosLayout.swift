import Foundation

/// One original as a row of a folder: the name it is listed under, and what it stands for.
public struct PhotosRow: Sendable, Hashable {
    /// The row's name — the original file name, numbered when an earlier row in the folder has it.
    public let name: String
    public let assetIdentifier: String
    public let resource: PhotosResource
    public let captureDate: Date?

    public init(name: String, assetIdentifier: String, resource: PhotosResource, captureDate: Date?) {
        self.name = name
        self.assetIdentifier = assetIdentifier
        self.resource = resource
        self.captureDate = captureDate
    }
}

/// Where things are in the Photos library's folder view, and what they are called (PLAN.md §M28).
///
/// Pure — paths, folder names, calendar grouping and row naming, with no PhotoKit in sight — so every
/// rule the backend rests on is testable with values. The shape is years, then months, then
/// originals, and it is a measurement rather than a taste: a name costs ~1.1 ms per asset, so a
/// folder has to be small enough to be worth naming.
public struct PhotosLayout: Sendable {
    /// A folder of the library's view.
    public enum Folder: Sendable, Hashable {
        /// `/2026`, listing that year's months.
        case year(Int)
        /// `/2026/2026-08`, listing that month's originals.
        case month(year: Int, month: Int)
        /// `/Undated`, listing the originals of assets Photos holds no capture date for.
        case undated

        /// Whether the folder lists originals rather than other folders.
        public var holdsOriginals: Bool {
            if case .year = self { return false }
            return true
        }
    }

    /// What a path in the library's view addresses.
    public enum Location: Sendable, Hashable {
        case root
        case folder(Folder)
        /// One original, by the row name it is listed under, in a folder that holds originals.
        case original(name: String, in: Folder)
    }

    /// The root folder holding assets with no capture date.
    ///
    /// Not localized: it is a path component, and a path is an identity. The app draws a translated
    /// title over it, the way it does for Recents.
    public static let undatedFolderName = "Undated"

    /// Gregorian, in the time zone the layout was made with.
    ///
    /// The time zone is the caller's because PhotoKit exposes none per asset: the app passes the
    /// Mac's own, and a photo taken near midnight somewhere else can land in the neighbouring month.
    public let calendar: Calendar

    public init(timeZone: TimeZone) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        self.calendar = calendar
    }

    // MARK: - Paths

    /// What `path` addresses, or `nil` for a path this layout never produces.
    ///
    /// Strict on purpose: `/2026/08` or `/2026/2025-08` would otherwise resolve to *something*, and a
    /// path that reads back as a different folder than the one that was typed is a wrong answer
    /// rather than a missing one.
    public func location(of path: VFSPath) -> Location? {
        let components = path.path.split(separator: "/").map(String.init)
        switch components.count {
        case 0:
            return .root
        case 1:
            return folder(named: components[0]).map(Location.folder)
        case 2:
            if components[0] == Self.undatedFolderName {
                return .original(name: components[1], in: .undated)
            }
            return month(components[0], components[1]).map(Location.folder)
        case 3:
            return month(components[0], components[1]).map { .original(name: components[2], in: $0) }
        default:
            return nil
        }
    }

    /// The path that lists `folder`.
    public func path(of folder: Folder) -> VFSPath {
        switch folder {
        case .year, .undated:
            VFSPath(backend: .photos, path: "/" + name(of: folder))
        case let .month(year, _):
            VFSPath(backend: .photos, path: "/" + name(of: .year(year)) + "/" + name(of: folder))
        }
    }

    /// The folder's own name: `2026`, `2026-08`, `Undated`.
    ///
    /// A month carries its year so a folder copied out of the library still says what it holds.
    public func name(of folder: Folder) -> String {
        switch folder {
        case let .year(year): String(format: "%04d", year)
        case let .month(year, month): String(format: "%04d-%02d", year, month)
        case .undated: Self.undatedFolderName
        }
    }

    private func folder(named component: String) -> Folder? {
        if component == Self.undatedFolderName { return .undated }
        return Self.yearNumber(component).map(Folder.year)
    }

    private func month(_ yearComponent: String, _ monthComponent: String) -> Folder? {
        guard let year = Self.yearNumber(yearComponent),
              let month = Self.monthNumber(monthComponent, inYear: year)
        else { return nil }
        return .month(year: year, month: month)
    }

    static func yearNumber(_ component: String) -> Int? {
        guard component.count == 4,
              component.allSatisfy({ $0.isASCII && $0.isNumber }),
              let year = Int(component), year > 0
        else { return nil }
        return year
    }

    static func monthNumber(_ component: String, inYear year: Int) -> Int? {
        let digits = component.dropFirst(5)
        guard component.count == 7,
              component.hasPrefix(String(format: "%04d-", year)),
              digits.allSatisfy({ $0.isASCII && $0.isNumber }),
              let month = Int(digits), (1...12).contains(month)
        else { return nil }
        return month
    }

    // MARK: - Calendar

    /// The span of capture dates `folder` covers, or `nil` for `Undated`, which covers none.
    public func interval(of folder: Folder) -> DateInterval? {
        switch folder {
        case let .year(year): interval(of: .year, year: year, month: 1)
        case let .month(year, month): interval(of: .month, year: year, month: month)
        case .undated: nil
        }
    }

    private func interval(of unit: Calendar.Component, year: Int, month: Int) -> DateInterval? {
        guard let start = calendar.date(from: DateComponents(year: year, month: month, day: 1))
        else { return nil }
        return calendar.dateInterval(of: unit, for: start)
    }

    /// The month folder an asset captured at `date` lists under — `Undated` when there is no date.
    public func month(containing date: Date?) -> Folder {
        guard let date else { return .undated }
        let parts = calendar.dateComponents([.year, .month], from: date)
        return .month(year: parts.year ?? 0, month: parts.month ?? 0)
    }

    /// The year an asset captured at `date` lists under.
    public func year(of date: Date) -> Int {
        calendar.component(.year, from: date)
    }

    /// The assets that belong to `folder`, in the order they were given.
    ///
    /// The backend asks the library for an interval and then filters here, because the calendar that
    /// decides is this one: a transport that answers a little wide cannot put a row in the wrong
    /// month.
    public func members(of folder: Folder, among assets: [PhotosAsset]) -> [PhotosAsset] {
        assets.filter { asset in
            switch folder {
            case .undated:
                return asset.captureDate == nil
            case let .year(year):
                guard let date = asset.captureDate else { return false }
                return self.year(of: date) == year
            case .month:
                return month(containing: asset.captureDate) == folder
            }
        }
    }

    // MARK: - Rows

    /// The rows a folder of `assets` lists: each asset's originals, in capture order, named.
    ///
    /// Capture order decides who keeps a contested name, with the identifier breaking a tie, so the
    /// numbering does not depend on the order a fetch happened to return. It does depend on what else
    /// is in the folder: importing an older photo with the same name later renumbers the newer one.
    public func rows(for assets: [PhotosAsset], resources: [String: [PhotosResource]]) -> [PhotosRow] {
        let ordered = assets.sorted { lhs, rhs in
            let left = lhs.captureDate ?? .distantPast
            let right = rhs.captureDate ?? .distantPast
            return left == right ? lhs.identifier < rhs.identifier : left < right
        }
        var taken: Set<String> = []
        var rows: [PhotosRow] = []
        for asset in ordered {
            let originals = (resources[asset.identifier] ?? [])
                .filter(\.kind.isOriginal)
                .sorted { lhs, rhs in
                    lhs.kind.rank == rhs.kind.rank
                        ? lhs.originalFilename < rhs.originalFilename
                        : lhs.kind.rank < rhs.kind.rank
                }
            for resource in originals {
                let name = Self.numbered(
                    Self.rowName(for: resource.originalFilename),
                    avoiding: &taken
                )
                rows.append(PhotosRow(
                    name: name,
                    assetIdentifier: asset.identifier,
                    resource: resource,
                    captureDate: asset.captureDate
                ))
            }
        }
        return rows
    }

    /// An original file name made into a usable path component.
    ///
    /// The name came from whatever imported the file, so nothing promises it is one: a `/` would split
    /// the path, and `..` would climb out of it. A slash becomes `:`, which is how Finder spells a
    /// slash on disk.
    static func rowName(for originalFilename: String) -> String {
        let name = originalFilename.replacingOccurrences(of: "/", with: ":")
        switch name {
        case "": return "Untitled"
        case ".", "..": return "_" + name
        default: return name
        }
    }

    /// `name`, or the first `name (2)`, `name (3)`, … not already in `taken`, which it then joins.
    ///
    /// Compared case- and normalization-insensitively, as APFS compares names: two rows a copy out
    /// would land on one file are two rows with one name.
    static func numbered(_ name: String, avoiding taken: inout Set<String>) -> String {
        let extensionPart = (name as NSString).pathExtension
        let stem = (name as NSString).deletingPathExtension
        var candidate = name
        var counter = 2
        while taken.contains(collisionKey(candidate)) {
            candidate = extensionPart.isEmpty
                ? "\(stem) (\(counter))"
                : "\(stem) (\(counter)).\(extensionPart)"
            counter += 1
        }
        taken.insert(collisionKey(candidate))
        return candidate
    }

    private static func collisionKey(_ name: String) -> String {
        name.precomposedStringWithCanonicalMapping.lowercased()
    }
}
