import Foundation

/// One application that can open a file — the value the "Open With" submenu is built from
/// (PLAN.md §M6 "Share sheet, 'Open With' submenu, Services integration").
///
/// Identified by its **bundle path**, not its bundle identifier: two copies of the same app (a
/// release in `/Applications` and a beta elsewhere) share an identifier but are genuinely
/// different choices, and LaunchServices reports both. The identifier is carried anyway because
/// it is the stable thing to persist a user's preference against.
public struct ApplicationRef: Sendable, Hashable, Identifiable {
    public var id: String { bundlePath }

    /// Absolute path to the `.app` bundle — the identity, and what the app launcher opens with.
    public let bundlePath: String
    /// The name shown in the menu ("TextEdit"), without the `.app` extension.
    public let displayName: String
    /// The bundle identifier, when it has one. Only used to persist a choice.
    public let bundleIdentifier: String?

    public init(bundlePath: String, displayName: String, bundleIdentifier: String? = nil) {
        self.bundlePath = bundlePath
        self.displayName = displayName
        self.bundleIdentifier = bundleIdentifier
    }
}

/// The applications offered for a selection: the one macOS would use, and the rest.
///
/// The split is the menu's shape, not decoration — the default goes first and is the item a
/// plain double-click would have hit, so it is what the user is confirming rather than choosing.
public struct OpenWithCandidates: Sendable, Hashable {
    /// The application macOS opens these items with today, when the whole selection agrees on one.
    public let defaultApplication: ApplicationRef?
    /// Every other application that can open **all** of the items, ordered by name.
    public let others: [ApplicationRef]

    /// No application can open the whole selection. The menu still offers "Other…" — this only
    /// says the list above it is empty.
    public var isEmpty: Bool { defaultApplication == nil && others.isEmpty }

    /// Default first, then the rest — the menu's order.
    public var all: [ApplicationRef] {
        (defaultApplication.map { [$0] } ?? []) + others
    }

    /// Nothing can open this selection (or there is no selection).
    public static let none = OpenWithCandidates(defaultApplication: nil, others: [])

    public init(defaultApplication: ApplicationRef?, others: [ApplicationRef]) {
        self.defaultApplication = defaultApplication
        self.others = others
    }
}

/// Works out which applications a selection can be opened with.
///
/// Pure, like `ExternalDiffTool`: LaunchServices is reached through injected probes, so the whole
/// rule is tested without depending on which apps happen to be installed on the machine running
/// the tests (per PLAN.md §2 — the logic lives here and has tests, the app is a thin shell).
public enum OpenWithApplications {
    /// The applications that can open **every** item in `paths`.
    ///
    /// - Parameters:
    ///   - paths: the selection. Order only matters for reading the default.
    ///   - typeOf: a path's uniform type identifier, or `nil` when it has none.
    ///   - applications: every application that can open items of a type.
    ///   - defaultApplication: the application macOS would use for a type.
    ///
    /// `applications` and `defaultApplication` are called **once per distinct type**, not once per
    /// file: measured against LaunchServices, asking what opens a file costs ~25x what reading its
    /// type does, and files of one type always answer identically (verified live before this was
    /// written). So a thousand marked photos cost one question, not a thousand.
    public static func candidates(
        for paths: [String],
        typeOf: (String) -> String?,
        applications: (String) -> [ApplicationRef],
        defaultApplication: (String) -> ApplicationRef?
    ) -> OpenWithCandidates {
        guard let types = distinctTypes(of: paths, typeOf: typeOf) else { return .none }
        guard let shared = intersect(types, applications: applications) else { return .none }
        let unanimous = unanimousDefault(
            across: types,
            within: shared,
            defaultApplication: defaultApplication
        )
        let others = shared.values
            .filter { $0.bundlePath != unanimous?.bundlePath }
            .sorted(by: byDisplayName)
        return OpenWithCandidates(defaultApplication: unanimous, others: others)
    }

    /// The distinct types in `paths`, first-seen order — or `nil` when the selection is empty or
    /// contains an item with no type at all.
    ///
    /// An untypeable item collapses the whole answer rather than being skipped, and that is the
    /// safe reading: a file macOS can't type is a file it can't open, so no application opens
    /// *every* item. It is also what LaunchServices does on its own — an unknown extension
    /// genuinely reports zero applications, so this only reaches the same answer sooner, without
    /// asking. (A file that vanished between listing and right-click lands here too.)
    private static func distinctTypes(
        of paths: [String],
        typeOf: (String) -> String?
    ) -> [String]? {
        guard !paths.isEmpty else { return nil }
        var types: [String] = []
        var seen: Set<String> = []
        for path in paths {
            guard let type = typeOf(path) else { return nil }
            if seen.insert(type).inserted { types.append(type) }
        }
        return types
    }

    /// Applications common to every type, keyed by bundle path — `nil` once nothing is left.
    private static func intersect(
        _ types: [String],
        applications: (String) -> [ApplicationRef]
    ) -> [String: ApplicationRef]? {
        var shared: [String: ApplicationRef] = [:]
        for (index, type) in types.enumerated() {
            var byPath: [String: ApplicationRef] = [:]
            for app in applications(type) where byPath[app.bundlePath] == nil {
                byPath[app.bundlePath] = app
            }
            shared = index == 0 ? byPath : shared.filter { byPath[$0.key] != nil }
            // Nothing common already — the remaining types can only narrow it further, so stop
            // asking LaunchServices questions whose answer can't matter.
            if shared.isEmpty { return nil }
        }
        return shared.isEmpty ? nil : shared
    }

    /// The default only when **every** type names the same one and it survived the intersection.
    ///
    /// A mixed selection where the types disagree has no default — offering one side's would put
    /// "the app this opens in" on a menu that opens the other side in something else. The menu
    /// then lists the intersection flat, with nothing promoted.
    private static func unanimousDefault(
        across types: [String],
        within shared: [String: ApplicationRef],
        defaultApplication: (String) -> ApplicationRef?
    ) -> ApplicationRef? {
        let defaults = types.map(defaultApplication)
        // `.first` on an array of optionals is doubly optional; flatten it rather than coalescing,
        // which reads as redundant (and SwiftLint agrees).
        guard let first = defaults.first.flatMap({ $0 }),
              defaults.allSatisfy({ $0?.bundlePath == first.bundlePath }) else { return nil }
        // Return the intersection's copy, not the probe's: same app, and this keeps one source for
        // the display name the menu shows.
        return shared[first.bundlePath]
    }

    /// By name, then bundle path. The tie-break is not pedantry: two copies of one app sort equal
    /// by name, and an unstable order would reshuffle the menu between right-clicks.
    private static func byDisplayName(_ lhs: ApplicationRef, _ rhs: ApplicationRef) -> Bool {
        let byName = lhs.displayName.caseInsensitiveCompare(rhs.displayName)
        if byName != .orderedSame { return byName == .orderedAscending }
        return lhs.bundlePath < rhs.bundlePath
    }
}
