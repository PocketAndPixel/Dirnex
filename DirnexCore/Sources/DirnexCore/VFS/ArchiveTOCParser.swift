import Foundation

/// Parses the `ls -l`-style table `bsdtar -tvf` prints into `ArchiveTOC`'s tree. Split
/// out of `ArchiveTOC` so the struct body stays small and the (chunky) line scanning is
/// isolated and independently reasoned about.
///
/// A verbose line looks like (columns: mode, links, owner, group, size, month, day,
/// time-or-year, then the name — which may contain spaces, or ` -> target` for a symlink):
///
///     -rw-r--r--  0 501    20         11 Jul 10 16:19 folder/beta.txt
///     drwxr-xr-x  0 501    20          0 Jul 10 16:19 folder/
///     lrwxr-xr-x  0 501    20          0 Jul 10 16:19 link.txt -> alpha.txt
///
/// tar archives prefix every path with `./`; zip does not. Some archives omit
/// intermediate directory lines, so they are synthesized here.
enum ArchiveTOCParser {
    struct Result {
        var children: [String: [ArchiveTOC.Entry]]
        var directories: Set<String>
    }

    /// A single parsed line before it is placed in the tree: normalized path components
    /// plus the entry's metadata.
    private struct RawEntry {
        let components: [String]
        let kind: FileEntry.Kind
        let byteSize: Int64
        let modificationDate: Date
        let symlinkDestination: String?
    }

    static func parse(_ text: String) -> Result {
        // One formatter set, reused across every line. `bsdtar` prints the same time column as
        // `sftp` and FTP's Unix dialect, so the formatters are the shared ones.
        let formatters = ColumnarListing.unixDateFormatters()

        // Full path -> its Entry (name = last component). Explicit lines overwrite
        // synthesized placeholders because their assignment is unconditional; synthesized
        // ancestors only fill a gap (`nodeByPath[p] == nil`), so real metadata always wins.
        var nodeByPath: [String: ArchiveTOC.Entry] = [:]
        var isDirectory: Set<String> = ["/"]

        for line in text.split(whereSeparator: \.isNewline) {
            guard let raw = parseLine(line, formatters: formatters), !raw.components.isEmpty else {
                continue
            }
            let innerPath = "/" + raw.components.joined(separator: "/")
            if raw.kind == .directory { isDirectory.insert(innerPath) }
            nodeByPath[innerPath] = ArchiveTOC.Entry(
                name: raw.components[raw.components.count - 1],
                kind: raw.kind,
                byteSize: raw.byteSize,
                modificationDate: raw.modificationDate,
                symlinkDestination: raw.symlinkDestination
            )
            synthesizeAncestors(of: raw.components, into: &nodeByPath, directories: &isDirectory)
        }

        return assembleTree(nodeByPath: nodeByPath, isDirectory: isDirectory)
    }

    /// Ensure every ancestor directory of an entry exists as a (possibly synthesized)
    /// directory node, so a listing that names only `a/b/c.txt` still exposes `a` and `a/b`.
    private static func synthesizeAncestors(
        of components: [String],
        into nodeByPath: inout [String: ArchiveTOC.Entry],
        directories: inout Set<String>
    ) {
        var ancestors = components
        ancestors.removeLast()
        while !ancestors.isEmpty {
            let path = "/" + ancestors.joined(separator: "/")
            directories.insert(path)
            if nodeByPath[path] == nil {
                nodeByPath[path] = ArchiveTOC.Entry(
                    name: ancestors[ancestors.count - 1],
                    kind: .directory,
                    byteSize: 0,
                    modificationDate: .distantPast
                )
            }
            ancestors.removeLast()
        }
    }

    /// Group every node under its parent directory, forcing directory kind on any node
    /// that turned out to have children (a defensive fix for an archive that lists a
    /// folder without a trailing slash).
    private static func assembleTree(
        nodeByPath: [String: ArchiveTOC.Entry],
        isDirectory: Set<String>
    ) -> Result {
        var children: [String: [ArchiveTOC.Entry]] = [:]
        // Seed known directories so an empty (childless) directory still lists as such.
        for directory in isDirectory { children[directory] = children[directory] ?? [] }

        for (path, entry) in nodeByPath where path != "/" {
            let parent = parentPath(of: path)
            let resolved: ArchiveTOC.Entry
            if isDirectory.contains(path), entry.kind != .directory {
                resolved = ArchiveTOC.Entry(
                    name: entry.name,
                    kind: .directory,
                    byteSize: entry.byteSize,
                    modificationDate: entry.modificationDate
                )
            } else {
                resolved = entry
            }
            children[parent, default: []].append(resolved)
        }
        return Result(children: children, directories: isDirectory)
    }

    // MARK: - Line parsing

    private static func parseLine(
        _ line: Substring,
        formatters: [DateFormatter]
    ) -> RawEntry? {
        // The leading columns never contain spaces, so a collapsing split reads them; the
        // name is taken verbatim after the 8th column to preserve names with spaces.
        let columns = line.split(separator: " ", omittingEmptySubsequences: true)
        guard columns.count >= 9, let mode = columns.first?.first,
              let rawName = ColumnarListing.nameField(in: line, afterColumns: 8)
        else { return nil }

        let byteSize = Int64(columns[4]) ?? 0
        let date = ColumnarListing.date(
            from: "\(columns[5]) \(columns[6]) \(columns[7])", formatters: formatters
        )

        let kind: FileEntry.Kind
        var name = rawName
        var symlinkDestination: String?
        switch mode {
        case "d":
            kind = .directory
        case "l":
            kind = .symlink
            if let range = name.range(of: " -> ") {
                symlinkDestination = String(name[range.upperBound...])
                name = String(name[..<range.lowerBound])
            }
        default:
            kind = .file
        }

        let components = pathComponents(of: name)
        return RawEntry(
            components: components,
            kind: kind,
            byteSize: byteSize,
            modificationDate: date,
            symlinkDestination: symlinkDestination
        )
    }

    /// Normalize an archive path into components: strip tar's leading `./`, drop empty and
    /// `.` segments and a trailing slash. `"./folder/"` → `["folder"]`, `"./"` → `[]`.
    private static func pathComponents(of name: String) -> [String] {
        name.split(separator: "/", omittingEmptySubsequences: true)
            .filter { $0 != "." }
            .map(String.init)
    }

    private static func parentPath(of innerPath: String) -> String {
        var components = innerPath.split(separator: "/", omittingEmptySubsequences: true)
        components.removeLast()
        return "/" + components.joined(separator: "/")
    }
}
