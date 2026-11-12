import Foundation
import UniformTypeIdentifiers

/// The files a change of default application would reach, for Open With ▸ Always Open … With
/// (2026-11-12): one type, and how the menu names it.
///
/// macOS keeps the default application **per type**, not per extension or per file:
/// `NSWorkspace.setDefaultApplication(at:toOpen:)` takes a `UTType`, and every file of that type
/// follows it. So the change is offered only for a selection of **one** type, and the menu names
/// that type by the extension the user is looking at whenever every row has the same one, which is
/// also how macOS's own question names it ("all documents with the extension “.m4v”"). A selection
/// of `.jpg` and `.jpeg` rows is one type with two extensions, and naming either would understate
/// the change, so it is named by the type's description instead.
///
/// Pure: a row's type is handed in, since reading it is the app's I/O (a local row is typed by the
/// file, a remote one by its name), and the rule is tested without LaunchServices.
public struct DefaultApplicationScope: Sendable, Hashable {
    /// How the menu names the files the change reaches.
    public enum Name: Sendable, Hashable {
        /// Every file with this extension: lowercased, without its dot ("m4v").
        case fileExtension(String)
        /// The type's own description, which the app asks the system for.
        case typeDescription
    }

    /// The uniform type identifier whose default application changes.
    public let typeIdentifier: String
    public let name: Name

    public init(typeIdentifier: String, name: Name) {
        self.typeIdentifier = typeIdentifier
        self.name = name
    }
}

public extension DefaultApplicationScope {
    /// The scope of a change for `entries`, or `nil` when there is none to offer.
    ///
    /// `nil` for an empty selection, for a row with no type, for rows of more than one type, and for
    /// a type that is not a kind of document (``isDocumentType(_:)``).
    static func of(
        _ entries: [FileEntry],
        typeOf: (FileEntry) -> String?
    ) -> DefaultApplicationScope? {
        guard !entries.isEmpty else { return nil }
        var identifiers: Set<String> = []
        for entry in entries {
            guard let identifier = typeOf(entry) else { return nil }
            identifiers.insert(identifier)
            if identifiers.count > 1 { return nil }
        }
        guard let identifier = identifiers.first,
              let type = UTType(identifier),
              isDocumentType(type) else { return nil }
        return DefaultApplicationScope(
            typeIdentifier: identifier,
            name: name(of: entries, type: type)
        )
    }

    /// Whether changing what opens this type is a change about **documents**.
    ///
    /// Not for a folder, a volume or an application: VLC claims `public.folder`, and making it the
    /// default there would open every folder double-clicked in Finder in VLC. A package that is a
    /// document (`.rtfd`, `.key`) is a document. And not for a type no extension maps to, such as
    /// `public.data` or `public.item`: those are what a file is when nothing more is known, so the
    /// change would reach every file of an unknown kind on the Mac at once.
    static func isDocumentType(_ type: UTType) -> Bool {
        if type.conforms(to: .application) { return false }
        if type.conforms(to: .directory), !type.conforms(to: .package) { return false }
        return !(type.tags[.filenameExtension] ?? []).isEmpty
    }

    /// The extension when every row has the same one and it is one of the type's own, the type's
    /// description otherwise.
    private static func name(of entries: [FileEntry], type: UTType) -> Name {
        let extensions = Set(entries.map { $0.fileExtension.lowercased() })
        let own = Set((type.tags[.filenameExtension] ?? []).map { $0.lowercased() })
        guard extensions.count == 1, let only = extensions.first, own.contains(only) else {
            return .typeDescription
        }
        return .fileExtension(only)
    }
}
