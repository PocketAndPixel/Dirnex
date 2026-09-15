import Foundation

/// The names that route a file to each language: its extensions, whole file names, and name
/// prefixes. `SyntaxLanguage.forFile(named:)` asks them in that order — whole name, extension,
/// prefix.
///
/// The additions of 2026-09-16 came from a survey of the text files under `~/Dev` that no route
/// claimed (docs/HISTORY.md): .NET project and Razor files, `.env` files, ignore files, `.bat`,
/// `.xcconfig`, `.strings`, `Package.resolved`, `dockerfile.dev`, and the nginx configurations.
extension SyntaxLanguage {
    /// Extensions that route here, lowercased and without the dot. Kept beside the case rather than
    /// in one big literal so that adding a language is one edit in one place.
    var fileExtensions: [String] {
        switch self {
        case .swift: ["swift", "swiftinterface"]
        case .objectiveC: ["m", "mm"]
        case .cLanguage: ["c"]
        // Metal's shading language is C++ with a few qualifiers of its own.
        case .cPlusPlus: ["cpp", "cc", "cxx", "c++", "hpp", "hh", "hxx", "ipp", "inl", "metal"]
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
        // JSON Lines and the rest are JSON too, and resolve to no registered type on a Mac, so only
        // their names say so (2026-09-15, Quick View's JSON tree). Unreal's `.uplugin` and
        // `.uproject` and VS Code's `.code-workspace` are JSON with no type of their own either.
        case .json:
            [
                "json", "jsonc", "json5", "geojson", "xcstrings", "ipynb", "jsonl", "ndjson",
                "topojson", "webmanifest", "har", "avsc", "uplugin", "uproject", "code-workspace"
            ]
        case .sql: ["sql", "psql", "mysql", "ddl"]
        case .css: ["css", "scss", "less", "sass"]
        case .python: ["py", "pyw", "pyi"]
        case .ruby: ["rb", "rake", "gemspec", "podspec"]
        case .shell: ["sh", "bash", "zsh", "ksh", "command"]
        case .perl: ["pl", "pm"]
        case .makefile: ["mk", "mak", "make"]
        case .cmake: ["cmake"]
        case .dockerfile: ["dockerfile", "containerfile"]
        case .yaml: ["yml", "yaml"]
        case .toml: ["toml"]
        case .ini: ["ini", "conf", "cfg", "properties"]
        case .dotenv: ["env"]
        case .nginx: ["nginx"]
        case .xcconfig: ["xcconfig"]
        case .appleStrings: ["strings"]
        case .batch: ["bat", "cmd"]
        case .powerShell: ["ps1", "psm1", "psd1"]
        // `Swift.gitignore` is how GitHub's template collection names them.
        case .ignoreFile: ["gitignore", "dockerignore"]
        case .gitAttributes: ["gitattributes"]
        // `.xhtml` is `public.xhtml` and does not conform to `public.html` (docs/NOTES.md), which
        // is why the family is named by extension here rather than derived from one conformance.
        // An SDK-style `.csproj` opens with `<Project Sdk=…>` and no XML declaration, so the
        // `<?xml` check in `forFile(named:text:)` cannot stand in for naming the .NET family.
        // `.config` is XML in 28 of the 29 found under `~/Dev` (`App.config`, `packages.config`).
        case .markup:
            [
                "xml", "html", "htm", "xhtml", "shtml", "svg", "plist", "entitlements",
                "storyboard", "xib", "xsd", "xsl", "xslt", "rss", "atom", "pom", "resx",
                "stringsdict", "xcprivacy", "xcscheme", "xcworkspacedata", "xcsettings", "sdef",
                "xliff", "xlf", "csproj", "vbproj", "fsproj", "vcxproj", "shproj", "projitems",
                "props", "targets", "nuspec", "slnx", "config", "xaml", "axaml", "cshtml", "razor",
                "iml", "vue", "svelte"
            ]
        // `.mdc` is a Cursor rules file: Markdown under a front matter block.
        case .markdown: ["md", "markdown", "mdown", "mkd", "mdx", "mdc"]
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
        case .ruby:
            [
                "gemfile", "rakefile", "podfile", "brewfile", "fastfile", "appfile", "matchfile",
                "pluginfile", "snapfile", "scanfile", "gymfile", "deliverfile", "dangerfile",
                "vagrantfile", "guardfile", "berksfile", "capfile", ".irbrc", ".pryrc"
            ]
        case .shell:
            [
                ".bashrc", ".bash_profile", ".bash_aliases", ".bash_login", ".bash_logout",
                ".profile", ".zshrc", ".zprofile", ".zshenv", ".zlogin", ".zlogout", ".kshrc",
                // direnv's file, which it sources as a shell script.
                ".envrc"
            ]
        case .ini:
            [
                ".editorconfig", ".gitconfig", ".gitmodules", ".npmrc", ".curlrc", ".flake8",
                ".pylintrc", ".coveragerc"
            ]
        // All three of each found under `~/Dev` were JSON; they may also be YAML, which the JSON
        // grammar still colors the strings and literals of.
        case .json:
            [
                ".babelrc", ".eslintrc", ".prettierrc", ".stylelintrc", ".swcrc", ".jshintrc",
                ".watchmanconfig", ".firebaserc", "package.resolved", "composer.lock",
                "pipfile.lock", "flake.lock"
            ]
        case .yaml: [".clang-format", ".clang-tidy", ".clangd", "podfile.lock", "pubspec.lock"]
        case .toml: ["pipfile", "cargo.lock", "poetry.lock", "uv.lock"]
        case .dotenv: [".env", ".flaskenv"]
        case .nginx: ["nginx.conf"]
        case .ignoreFile:
            [
                ".gitignore", ".dockerignore", ".containerignore", ".npmignore", ".prettierignore",
                ".eslintignore", ".stylelintignore", ".vscodeignore", ".gcloudignore",
                ".vercelignore", ".slugignore", ".helmignore", ".hgignore", ".ignore", ".rgignore",
                ".fdignore"
            ]
        case .gitAttributes: [".gitattributes", "codeowners"]
        default: []
        }
    }

    /// Name prefixes that route here, lowercased, for the families that vary the *end* of a name:
    /// `dockerfile.dev`, `Dockerfile.prod`, `.env.local`, `.env.example`. Asked only after the whole
    /// name and the extension have both claimed nothing.
    var fileNamePrefixes: [String] {
        switch self {
        case .dockerfile: ["dockerfile.", "containerfile."]
        case .dotenv: [".env."]
        default: []
        }
    }
}
