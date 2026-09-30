import Foundation
import UniformTypeIdentifiers

/// Which files Quick View draws as an XML tree (2026-09-16). The tree itself, and a list of records in
/// the table, are `QuickViewPreviewView+Tree`.
extension QuickViewPreviewView {
    /// Whether `url` is an XML file or a property list this backend draws: by name first, then by
    /// conformance to `public.xml` or to the property-list type — less a page, which renders as one, and
    /// an image, since an SVG conforms to `public.xml` too.
    ///
    /// By name first because much of the family resolves to no registered type — probed: `.csproj`,
    /// `.props`, `.targets`, `.xaml`, `.resx`, `.xsd`, `.xsl`, `.kml`, `.atom` and Xcode's
    /// `.xcworkspacedata` are dynamic types that conform to nothing — and a `.config`, which is XML in 28
    /// of the 29 under `~/Dev`, is declared TOML on this Mac. A file under one of these names that is not
    /// XML after all is shown as its text. `nonisolated` for the reason the table's twin is.
    nonisolated static func isXML(_ url: URL) -> Bool {
        if xmlExtensions.contains(url.pathExtension.lowercased()) { return true }
        let declared = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType
        guard let type = declared ?? UTType(filenameExtension: url.pathExtension),
              type.conforms(to: .xml) || type.conforms(to: .propertyList)
        else { return false }
        return !type.conforms(to: .image) && !type.conforms(to: .html)
            && !type.conforms(to: UTType("public.xhtml") ?? .html)
    }

    /// The XML family by name: the .NET project and resource files, XAML, Xcode's interface, scheme,
    /// workspace and property-list files, schemas and stylesheets, feeds, and GPS and map tracks.
    private nonisolated static let xmlExtensions: Set<String> = [
        "xml", "plist", "stringsdict", "entitlements", "xcprivacy", "xib", "storyboard", "xcscheme",
        "xcworkspacedata", "xcsettings", "sdef", "csproj", "vbproj", "fsproj", "vcxproj", "shproj",
        "projitems", "props", "targets", "nuspec", "slnx", "config", "resx", "xaml", "axaml",
        "xliff",
        "xlf", "xsd", "xsl", "xslt", "wsdl", "rss", "atom", "opml", "pom", "iml", "gpx", "kml",
        "dae"
    ]
}
