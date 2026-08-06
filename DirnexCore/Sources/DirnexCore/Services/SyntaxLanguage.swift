import Foundation

/// A language the Quick View text preview knows how to colour, and the routing that picks one for a
/// file (PLAN.md §M17).
///
/// **Extension first**, which inverts the rule the preview backends beside it follow — those route
/// by content type and fall back to the extension (`QuickViewPreviewView.isText`). The inversion is
/// deliberate and `UTType` is the reason: it answers `public.c-header` for a `.h` and cannot say
/// whether that header is C, C++ or Objective-C, and it answers `public.source-code` for a great
/// many things whose grammar differs. A content type is the right question for *"is this text at
/// all"* and the wrong one for *"which language"*.
public enum SyntaxLanguage: String, Sendable, CaseIterable {
    case swift
    case objectiveC
    /// Plain C. Named for the lint floor on identifier length, not for emphasis.
    case cLanguage
    case cPlusPlus
    /// A `.h`, which is one of three languages and says which in nothing but its contents. See
    /// `CFamilyGrammars.cHeader` for why it takes the union rather than a guess.
    case cHeader
    case java
    case kotlin
    case scala
    case cSharp
    case go
    case rust
    case javascript
    case typeScript
    case php
    case dart
    case json
    case sql
    case css
    case python
    case ruby
    case shell
    case perl
    case makefile
    case cmake
    case dockerfile
    case yaml
    case toml
    case ini
    /// XML, HTML, SVG and `.plist` — one scanner, four extensions' worth of files.
    case markup
    case markdown
    /// A unified diff or patch.
    case diff

    /// How a language is scanned: from the grammar table, or by a scanner of its own.
    ///
    /// One switch rather than two. The obvious alternative — an optional `grammar` plus a second
    /// switch for the three that have none — needs a `default` branch that can only ever mean "a
    /// case nobody wired up", and it would return an empty token list rather than fail. That is the
    /// quiet direction, and it is avoidable for free: this way the compiler names any case that is
    /// added without being routed.
    enum Scanning {
        case grammar(LanguageGrammar)
        case markup
        case markdown
        case diff
    }

    var scanning: Scanning {
        switch self {
        case .markup: .markup
        case .markdown: .markdown
        case .diff: .diff
        default: .grammar(tableGrammar)
        }
    }

    /// The grammar, for the languages the table covers, and `nil` for the three with their own
    /// scanner.
    public var grammar: LanguageGrammar? {
        if case let .grammar(grammar) = scanning { return grammar }
        return nil
    }

    /// The table's own answer. Reached only through `scanning`, which is what keeps the three
    /// scanner-backed cases from ever landing here.
    private var tableGrammar: LanguageGrammar {
        switch self {
        case .swift: CFamilyGrammars.swift
        case .objectiveC: CFamilyGrammars.objectiveC
        case .cLanguage: CFamilyGrammars.cLanguage
        case .cPlusPlus: CFamilyGrammars.cPlusPlus
        case .cHeader: CFamilyGrammars.cHeader
        case .java: CFamilyGrammars.java
        case .kotlin: CFamilyGrammars.kotlin
        case .scala: CFamilyGrammars.scala
        case .cSharp: CFamilyGrammars.cSharp
        case .go: CFamilyGrammars.go
        case .rust: CFamilyGrammars.rust
        case .javascript: CFamilyGrammars.javascript
        case .typeScript: CFamilyGrammars.typeScript
        case .php: CFamilyGrammars.php
        case .dart: CFamilyGrammars.dart
        case .json: CFamilyGrammars.json
        case .sql: CFamilyGrammars.sql
        case .css: CFamilyGrammars.css
        case .python: HashFamilyGrammars.python
        case .ruby: HashFamilyGrammars.ruby
        case .shell: HashFamilyGrammars.shell
        case .perl: HashFamilyGrammars.perl
        case .makefile: HashFamilyGrammars.makefile
        case .cmake: HashFamilyGrammars.cmake
        case .dockerfile: HashFamilyGrammars.dockerfile
        case .yaml: HashFamilyGrammars.yaml
        case .toml: HashFamilyGrammars.toml
        case .ini: HashFamilyGrammars.ini
        // Unreachable: `scanning` routes these three before it asks for a grammar, and the switch
        // above is exhaustive over everything else.
        case .markup, .markdown, .diff: LanguageGrammar()
        }
    }

    // MARK: - Routing

    /// The language for `name`, or `nil` for a file nothing here claims — which is not a failure.
    /// An unknown extension renders exactly as it did before this milestone: one colour, correct.
    ///
    /// Takes a file *name*, and tolerates a path by reading its last component, so a caller with a
    /// `URL` and a caller with a `FileEntry` can both ask without preparing the string first.
    public static func forFile(named name: String) -> SyntaxLanguage? {
        let leaf = name.split(separator: "/").last.map(String.init) ?? name
        let lowered = leaf.lowercased()
        // Whole names first: a `Makefile` has no extension, and `.zshrc`'s only dot is its first
        // character — so an extension-only route would read the whole name as the extension.
        if let byName = byFileName[lowered] { return byName }
        guard let dot = lowered.lastIndex(of: "."), dot != lowered.startIndex else { return nil }
        return byExtension[String(lowered[lowered.index(after: dot)...])]
    }

    /// Extensions that route here, lowercased and without the dot. Kept beside the case rather than
    /// in one big literal so that adding a language is one edit in one place.
    var fileExtensions: [String] {
        switch self {
        case .swift: ["swift"]
        case .objectiveC: ["m", "mm"]
        case .cLanguage: ["c"]
        case .cPlusPlus: ["cpp", "cc", "cxx", "c++", "hpp", "hh", "hxx", "ipp", "inl"]
        case .cHeader: ["h"]
        case .java: ["java"]
        case .kotlin: ["kt", "kts"]
        case .scala: ["scala", "sc"]
        case .cSharp: ["cs"]
        case .go: ["go"]
        case .rust: ["rs"]
        case .javascript: ["js", "mjs", "cjs", "jsx"]
        case .typeScript: ["ts", "tsx", "mts", "cts"]
        case .php: ["php", "phtml"]
        case .dart: ["dart"]
        // `.xcstrings` is JSON, not XML — probed against this repo's own catalogs, which open with
        // `{ "sourceLanguage": … }`. PLAN.md §M17 lists it with the markup family; that is a slip,
        // and it belongs here.
        case .json: ["json", "jsonc", "json5", "geojson", "xcstrings", "ipynb"]
        case .sql: ["sql", "psql", "mysql", "ddl"]
        case .css: ["css", "scss", "less", "sass"]
        case .python: ["py", "pyw", "pyi"]
        case .ruby: ["rb", "rake", "gemspec", "podspec"]
        case .shell: ["sh", "bash", "zsh", "ksh", "command"]
        case .perl: ["pl", "pm"]
        case .makefile: ["mk", "mak", "make"]
        case .cmake: ["cmake"]
        case .dockerfile: ["dockerfile"]
        case .yaml: ["yml", "yaml"]
        case .toml: ["toml"]
        case .ini: ["ini", "conf", "cfg", "properties"]
        // `.xhtml` is `public.xhtml` and does not conform to `public.html` (docs/NOTES.md), which
        // is why the family is named by extension here rather than derived from one conformance.
        case .markup:
            [
                "xml", "html", "htm", "xhtml", "shtml", "svg", "plist", "entitlements",
                "storyboard", "xib", "xsd", "xsl", "xslt", "rss", "atom", "pom", "resx"
            ]
        case .markdown: ["md", "markdown", "mdown", "mkd", "mdx"]
        case .diff: ["diff", "patch"]
        }
    }

    /// Whole file names that route here, lowercased. The dot-files are matched here rather than as
    /// extensions on purpose — see `forFile(named:)`.
    var fileNames: [String] {
        switch self {
        case .makefile: ["makefile", "gnumakefile", "bsdmakefile"]
        case .cmake: ["cmakelists.txt"]
        case .dockerfile: ["dockerfile", "containerfile"]
        case .ruby: ["gemfile", "rakefile", "podfile", "brewfile", "fastfile", "appfile"]
        case .shell:
            [
                ".bashrc",
                ".bash_profile",
                ".bash_aliases",
                ".profile",
                ".zshrc",
                ".zprofile",
                ".zshenv",
                ".kshrc"
            ]
        case .ini: [".editorconfig", ".gitconfig", ".npmrc", ".curlrc"]
        default: []
        }
    }

    /// Built once, and last-one-wins is never exercised: no extension appears on two cases, which
    /// `SyntaxLanguageTests` asserts rather than leaves to review.
    private static let byExtension: [String: SyntaxLanguage] = {
        var table: [String: SyntaxLanguage] = [:]
        for language in allCases {
            for suffix in language.fileExtensions { table[suffix] = language }
        }
        return table
    }()

    private static let byFileName: [String: SyntaxLanguage] = {
        var table: [String: SyntaxLanguage] = [:]
        for language in allCases {
            for name in language.fileNames { table[name] = language }
        }
        return table
    }()
}

// MARK: - Fenced code blocks

public extension SyntaxLanguage {
    /// The language a Markdown fence's info string names — ```` ```swift ````, ```` ```bash ```` —
    /// or `nil` for one nothing here claims, which is what leaves an undecorated fence uncoloured
    /// (PLAN.md §M17 ▸ Slice 3).
    ///
    /// Its own entry point rather than a call to `forFile(named:)`, because an info string is not a
    /// file name and the two vocabularies genuinely disagree in both directions. `makefile` and
    /// `dockerfile` are whole *names* on that side and would be read as extensions here; and the
    /// spelled-out `python`, `javascript`, `shell`, `objective-c` — what people actually type above
    /// a fence — are neither a name nor an extension, so they need a table of their own. What the
    /// two *do* share is the extension table, which already answers `swift`, `bash`, `json`, `py`
    /// and the rest, so nothing is duplicated to get them.
    static func forFenceInfo(_ info: String) -> SyntaxLanguage? {
        // CommonMark: the info string's first word is the language, and anything after it belongs
        // to whatever renders the document (`js title="app.js"`), not to the name.
        guard let word = info.split(whereSeparator: { $0 == " " || $0 == "\t" }).first else {
            return nil
        }
        let lowered = word.lowercased()
        return fenceAliases[lowered] ?? byFileName[lowered] ?? byExtension[lowered]
    }

    /// The spellings that are neither a file name nor an extension. Kept short on purpose: an alias
    /// nobody writes above a fence is dead data, and a fence this misses renders as plain text —
    /// which is the same thing it did before embedded highlighting existed.
    private static let fenceAliases: [String: SyntaxLanguage] = [
        "objective-c": .objectiveC, "objectivec": .objectiveC, "objc": .objectiveC,
        "csharp": .cSharp,
        "golang": .go,
        "javascript": .javascript, "node": .javascript,
        "typescript": .typeScript,
        "python": .python, "python3": .python,
        "ruby": .ruby,
        "rust": .rust,
        "kotlin": .kotlin,
        "perl": .perl,
        // A fenced shell block is as often a transcript as a script, and both are shell.
        "shell": .shell, "shell-session": .shell, "console": .shell, "terminal": .shell
    ]
}
