import Foundation

/// What macOS knows about one iCloud app container — the name and icon Finder shows for it,
/// and whether it belongs in iCloud Drive at all (PLAN.md §M9 "app-name / icon resolution").
///
/// Probed 2026-07-21 rather than guessed, and the guess would have been wrong twice over:
///
/// - The mapping is **not** in the container directory. It is cached per container at
///   `~/Library/Application Support/CloudDocs/session/containers/<bundle-id>.plist`, whose
///   `BRContainer…` keys are `bird`'s copy of the app's own `NSUbiquitousContainers`
///   declaration. `BRContainerIsDocumentScopePublic` is the flag that decides whether the
///   container's `Documents` is a public iCloud Drive folder at all.
/// - The icon is **not** available from `NSWorkspace.icon(forFile:)`, which hands back the
///   generic folder icon for these (byte-identical to `~/Documents`'), nor reliably from
///   LaunchServices — half of these apps are iOS-only and not installed on this Mac. The
///   icons are cached PNGs in the sibling `containers/<bundle-id>/` directory.
///
/// One plist can hold several records — Pages ships both `com.apple.Pages` and
/// `com.apple.iWork.Pages` — so parsing takes the union: public if *any* record says so, and
/// the first name any record offers.
public struct ICloudContainerMetadata: Sendable, Hashable {
    /// The container's on-disk directory name under `~/Library/Mobile Documents`, e.g.
    /// `com~apple~Pages`.
    public let containerID: String
    /// The bundle identifier the metadata file is named for, e.g. `com.apple.Pages`. Also
    /// the name of the sibling directory holding the cached icons.
    public let bundleID: String
    /// `BRContainerName` — the name Finder shows, e.g. "Pages", "Shortcuts", "Curve".
    public let name: String
    /// `BRContainerLocalizedNames`, keyed by language code.
    public let localizedNames: [String: String]
    /// `BRContainerIsDocumentScopePublic`: this container's `Documents` folder is meant to
    /// appear in iCloud Drive. Without it the container is private app storage.
    public let isDocumentScopePublic: Bool
    /// `BRContainerIcons` — base names of the cached icon PNGs, e.g. `256x256_OSX`.
    public let iconNames: [String]

    public init(
        containerID: String,
        bundleID: String,
        name: String,
        localizedNames: [String: String] = [:],
        isDocumentScopePublic: Bool,
        iconNames: [String] = []
    ) {
        self.containerID = containerID
        self.bundleID = bundleID
        self.name = name
        self.localizedNames = localizedNames
        self.isDocumentScopePublic = isDocumentScopePublic
        self.iconNames = iconNames
    }

    /// The name to show for `languageCode`, falling back to the unlocalized `BRContainerName`.
    public func name(for languageCode: String?) -> String {
        guard let languageCode, let localized = localizedNames[languageCode] else { return name }
        return localized
    }
}

/// Reads and interprets the cached container metadata. Pure with respect to the bytes: the
/// parse takes `Data`, so it tests against synthesized plists rather than against whatever
/// apps happen to be installed on the machine running the suite.
public enum ICloudContainers {
    /// Where `bird` caches one plist (and one icon directory) per known container.
    public static func metadataDirectory(home: String = NSHomeDirectory()) -> VFSPath {
        VFSPath.local(home)
            .appending("Library")
            .appending("Application Support")
            .appending("CloudDocs")
            .appending("session")
            .appending("containers")
    }

    /// The `~/Library/Mobile Documents` directory name for a bundle identifier: every dot
    /// becomes a tilde (`com.apple.Pages` → `com~apple~Pages`,
    /// `F3LWYJ7GM7.com.apple.garageband10` → `F3LWYJ7GM7~com~apple~garageband10`).
    public static func containerID(forBundleID bundleID: String) -> String {
        bundleID.replacingOccurrences(of: ".", with: "~")
    }

    /// Parse one cached metadata plist. `bundleID` is the file's base name — the plist itself
    /// never states which container it describes.
    ///
    /// Returns `nil` only when the bytes are not a plist dictionary at all. A container with
    /// no public record still parses, reporting `isDocumentScopePublic == false`, because
    /// "known and private" is a different answer from "unreadable" and the caller filters on
    /// the flag rather than on the absence of a value.
    public static func parseMetadata(_ data: Data, bundleID: String) -> ICloudContainerMetadata? {
        guard let root = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let dictionary = root as? [String: Any] else { return nil }

        // Everything except the top-level icon list is a per-app record keyed by bundle id.
        let records = dictionary.compactMap { key, value in
            key == iconsKey ? nil : value as? [String: Any]
        }
        // `1` and `true` both appear in the wild for this key, on the same machine and even
        // within one file, so it is read as a number rather than pattern-matched as a Bool.
        let isPublic = records.contains { ($0[publicScopeKey] as? NSNumber)?.boolValue == true }
        let name = records.compactMap { $0[nameKey] as? String }.first
        let localized = records.compactMap { $0[localizedNamesKey] as? [String: String] }.first

        return ICloudContainerMetadata(
            containerID: containerID(forBundleID: bundleID),
            bundleID: bundleID,
            // A container whose plist carries no name at all falls back to its bundle id;
            // showing the raw id beats showing a blank row.
            name: name ?? bundleID,
            localizedNames: localized ?? [:],
            isDocumentScopePublic: isPublic,
            iconNames: dictionary[iconsKey] as? [String] ?? []
        )
    }

    /// Pick the cached icon to load for a display size in points, at `scale` backing pixels
    /// per point — the `256x256_OSX` style names are pixel dimensions.
    ///
    /// Prefers the macOS icons over the iOS ones (an iOS icon is a square with no macOS
    /// silhouette), and the smallest that still covers the requested pixel size so a sidebar
    /// row doesn't decode a 256 px PNG for a 16 pt glyph. Falls back to the largest available
    /// when nothing is big enough, then to the iOS set, then `nil` — a real outcome, not a
    /// defensive one: several containers here cache no icons at all.
    public static func bestIconName(
        from names: [String],
        pointSize: Double,
        scale: Double = 2
    ) -> String? {
        let wanted = pointSize * scale
        let parsed = names.compactMap(IconName.init(rawValue:))
        let macOS = parsed.filter(\.isMacOS)
        return best(from: macOS.isEmpty ? parsed : macOS, covering: wanted)?.rawValue
    }

    private static func best(from icons: [IconName], covering wanted: Double) -> IconName? {
        let sorted = icons.sorted { $0.pixels < $1.pixels }
        return sorted.first { Double($0.pixels) >= wanted } ?? sorted.last
    }

    /// A cached icon file's base name, e.g. `256x256_OSX`, split into what it says.
    private struct IconName {
        let rawValue: String
        let pixels: Int
        let isMacOS: Bool

        init?(rawValue: String) {
            // "<w>x<h>_<platform>"; the two dimensions are always equal in practice, so the
            // width alone stands for the size.
            let parts = rawValue.split(separator: "_")
            guard parts.count == 2,
                  let width = parts[0].split(separator: "x").first,
                  let pixels = Int(width) else { return nil }
            self.rawValue = rawValue
            self.pixels = pixels
            isMacOS = parts[1] == "OSX"
        }
    }

    private static let iconsKey = "BRContainerIcons"
    private static let publicScopeKey = "BRContainerIsDocumentScopePublic"
    private static let nameKey = "BRContainerName"
    private static let localizedNamesKey = "BRContainerLocalizedNames"
}
