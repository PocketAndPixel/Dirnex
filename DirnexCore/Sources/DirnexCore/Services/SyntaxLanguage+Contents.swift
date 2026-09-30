import Foundation

/// Routing a file whose name does not settle its language, by what its text opens with.
public extension SyntaxLanguage {
    /// The language for a file named `name` whose text is `text`.
    ///
    /// **The name first**, because a name is the one routing that never needs the file's bytes, and
    /// because where a name and the contents both answer they agree on everything but the rare file
    /// whose name and contents disagree — and there the name is what the author chose to call it.
    ///
    /// The contents are asked in two cases:
    /// - **The name claims nothing.** Then a `#!` line (`forShebang(in:)`), an XML declaration, or
    ///   the shape of an nginx configuration decides: `gradlew`, a `default` in nginx's
    ///   `sites-available`, an `.mobileconfig`'s XML.
    /// - **The name claims `.ini`**, which is a family of formats rather than a language (see
    ///   `HashFamilyGrammars.ini`). A `.conf` is nginx's (`default.conf`), fontconfig's XML, Apache's
    ///   or `key=value`, and the first two say so in their text.
    static func forFile(named name: String, text: String) -> SyntaxLanguage? {
        guard let byName = forFile(named: name) else {
            return forShebang(in: text) ?? forContents(of: text)
        }
        return byName == .ini ? forContents(of: text) ?? .ini : byName
    }

    /// The language `text`'s contents name without help from a file name, or `nil`.
    ///
    /// Only the two shapes that are unambiguous when they are there. An XML declaration can open
    /// nothing but XML, and it has to be the file's first characters — a byte-order mark is already
    /// gone, `TextPreview` strips it. An nginx configuration is recognized by
    /// `SyntaxNginxScanner.looksLikeConfiguration`, whose doc comment has the measurement.
    internal static func forContents(of text: String) -> SyntaxLanguage? {
        if text.hasPrefix("<?xml") { return .markup }
        if SyntaxNginxScanner.looksLikeConfiguration(text) { return .nginx }
        return nil
    }
}
