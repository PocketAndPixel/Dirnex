import Foundation

@testable import DirnexCore

/// Builds the two halves of an iCloud app container inside a `TempTree`: the metadata plist
/// `bird` caches under `Application Support/CloudDocs`, and the container directory under
/// `Mobile Documents`. Shared by both `ICloudDrive` suites — Swift's `private` does not cross
/// files (docs/NOTES.md), and the suites are split because one struct holding them all
/// overruns SwiftLint's `type_body_length`.
enum ICloudFixture {
    /// Metadata *and* a `Documents` folder holding `contents`. Returns the folder's path.
    @discardableResult
    static func makeContainer(
        _ temp: TempTree,
        bundleID: String,
        name: String,
        public isPublic: Bool,
        contents: [String],
        localizedNames: [String: String] = [:]
    ) throws -> String {
        try writeMetadata(
            temp,
            bundleID: bundleID,
            name: name,
            public: isPublic,
            localizedNames: localizedNames
        )
        let containerID = ICloudContainers.containerID(forBundleID: bundleID)
        let documents = "Library/Mobile Documents/\(containerID)/Documents"
        try temp.makeDir(documents)
        for item in contents { try temp.writeFile("\(documents)/\(item)", bytes: 1) }
        return temp.path(documents)
    }

    /// Just the cached metadata — the shape of a container this Mac knows about but has no
    /// folder for.
    static func writeMetadata(
        _ temp: TempTree,
        bundleID: String,
        name: String,
        public isPublic: Bool,
        localizedNames: [String: String] = [:]
    ) throws {
        let directory = "Library/Application Support/CloudDocs/session/containers"
        try temp.makeDir(directory)
        var record: [String: Any] = [
            "BRContainerName": name,
            "BRContainerIsDocumentScopePublic": isPublic
        ]
        if !localizedNames.isEmpty { record["BRContainerLocalizedNames"] = localizedNames }
        let plist: [String: Any] = ["BRContainerIcons": ["32x32_OSX"], bundleID: record]
        let data = try PropertyListSerialization.data(
            fromPropertyList: plist,
            format: .binary,
            options: 0
        )
        try data.write(to: URL(fileURLWithPath: temp.path("\(directory)/\(bundleID).plist")))
    }
}
