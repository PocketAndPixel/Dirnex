import Foundation
import UniformTypeIdentifiers

/// Which files Quick View draws as a JSON tree (2026-09-15). The tree itself, and a list of records in
/// the table, are `QuickViewPreviewView+Tree`.
extension QuickViewPreviewView {
    /// Whether `url` is a JSON file this backend draws: by name first, then by conformance to
    /// `public.json`, which `.geojson` and `.xcstrings` declare.
    ///
    /// By name first because most of the family resolves to no registered type on a Mac — probed:
    /// `.jsonl`, `.jsonc`, `.json5`, `.ipynb`, `.har` and `.webmanifest` are dynamic types that conform
    /// to nothing, not even `public.text`, so until this backend they went to Quick Look rather than to
    /// the text preview. `nonisolated` for the reason the table's twin is.
    nonisolated static func isJSON(_ url: URL) -> Bool {
        if jsonFileNames.contains(url.lastPathComponent) { return true }
        if jsonExtensions.contains(url.pathExtension.lowercased()) { return true }
        guard let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType else {
            return false
        }
        return type.conforms(to: .json)
    }

    private nonisolated static let jsonExtensions: Set<String> = [
        "json", "jsonl", "ndjson", "jsonc", "json5", "geojson", "topojson", "webmanifest", "har",
        "ipynb", "xcstrings", "avsc"
    ]

    /// JSON under a name with no JSON extension: Swift Package Manager's lock file, 17 of them on this
    /// Mac.
    private nonisolated static let jsonFileNames: Set<String> = ["Package.resolved"]
}
