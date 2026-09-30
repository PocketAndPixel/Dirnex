import Foundation

/// `LanguageGrammar.words` under a short name, because it is the most-repeated call in the table.
private func words(_ list: String) -> Set<String> { LanguageGrammar.words(list) }

/// Build and platform files that fit the grammar table but belong to neither family: two from
/// Xcode and two from Windows (docs/HISTORY.md, 2026-09-16). Each takes its delimiters from where
/// they are, rather than from `CFamilyGrammars.base` or `HashFamilyGrammars.base`, because none of
/// the four has quite the shape either base assumes.
enum ToolingGrammars {
    /// An Xcode build settings file: `// comments`, `#include "Other.xcconfig"` and `KEY = value`.
    ///
    /// No block comment, which is the reason this is not a C-family row: an `.xcconfig` has none,
    /// and a `/*` in a value (`HEADER_SEARCH_PATHS = $(SRCROOT)/**`) would otherwise start one and
    /// color the rest of the file. A `//` anywhere is a comment, a URL in a value included, which is
    /// how Xcode reads it too. `#include?` colors its `#include` and leaves the `?` plain.
    static let xcconfig = LanguageGrammar(
        lineComments: ["//"],
        strings: [.doubleQuoted],
        keywords: words("YES NO inherited"),
        preprocessorSigil: "#"
    )

    /// A `.strings` table: `/* comment */ "key" = "value";`. Comments and strings are the whole of
    /// what there is to color, and a key and its value are both strings.
    static let appleStrings = LanguageGrammar(
        lineComments: ["//"],
        blockComment: LanguageGrammar.BlockComment(open: "/*", close: "*/"),
        strings: [.doubleQuoted]
    )

    /// A Windows batch file.
    ///
    /// `REM` is a comment only as a command, and commands are case-insensitive, while a line comment
    /// token is matched exactly — so its spellings are listed. The trailing space is what keeps
    /// `remove` from starting one, and a word that merely ends in `rem` never does, since the scanner
    /// consumes a word whole from its first character. A `REM` with nothing after it colors as a
    /// keyword.
    ///
    /// Quotes take no escape, and `%VARIABLE%` is not scanned: `%1` and `%~dp0` open it with nothing
    /// to close it, and the only way to tell them apart is knowing which form each is.
    static let batch = LanguageGrammar(
        lineComments: ["::", "REM ", "rem ", "Rem ", "@REM ", "@rem "],
        strings: [LanguageGrammar.StringLiteral(open: "\"", close: "\"", escape: nil)],
        keywords: words("""
        call cd chdir cls copy defined del do echo else endlocal equ erase errorlevel exist exit
        for geq goto gtr if in leq lss md mkdir move neq not nul off pause popd pushd rd rem ren
        rename rmdir set setlocal shift
        """),
        annotationSigil: "@",
        keywordsAreCaseInsensitive: true
    )

    /// PowerShell. `$name` colors through the annotation sigil, as Swift's `@MainActor` does, so a
    /// variable reads as the language's own vocabulary rather than as plain text.
    ///
    /// The here-strings (`@"…"@`, `@'…'@`) are listed first for the reason Python's triple quotes
    /// are; a double-quoted string escapes with a backtick; and a single-quoted one has no escape,
    /// its `''` closing and reopening the string, which colors the same.
    static let powerShell = LanguageGrammar(
        lineComments: ["#"],
        blockComment: LanguageGrammar.BlockComment(open: "<#", close: "#>"),
        strings: [
            LanguageGrammar.StringLiteral(open: "@\"", close: "\"@", escape: nil, spansLines: true),
            LanguageGrammar.StringLiteral(open: "@'", close: "'@", escape: nil, spansLines: true),
            LanguageGrammar.StringLiteral(open: "\"", close: "\"", escape: "`"),
            .unescapedSingleQuoted
        ],
        keywords: words("""
        begin break catch class continue data do dynamicparam else elseif end enum exit filter
        finally for foreach function hidden if in param process return static switch throw trap
        try until using while
        """),
        typeNames: words("""
        array bool byte char datetime decimal double float guid hashtable int int32 int64 long
        object pscredential pscustomobject psobject regex scriptblock string timespan void xml
        """),
        annotationSigil: "$",
        keywordsAreCaseInsensitive: true
    )
}
