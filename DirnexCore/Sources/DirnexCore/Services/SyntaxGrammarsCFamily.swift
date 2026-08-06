import Foundation

/// `LanguageGrammar.words` under a short name, because it is the most-repeated call in the table.
private func words(_ list: String) -> Set<String> { LanguageGrammar.words(list) }

/// The C-family half of the grammar table (PLAN.md §M17 ▸ Slice 1).
///
/// Sixteen languages that differ only in their word lists: `//` and `/* */`, `"…"`, a number, and a
/// set of reserved words. Data, not code — the whole point of `LanguageGrammar` being a value type
/// is that adding a language is adding a row here.
///
/// `typeNames` holds only names the *language* defines. A type the user declared is a type because
/// of a declaration somewhere else, which is a compiler's knowledge and out of scope by name
/// (PLAN.md §M17 ▸ not in scope) — so no "an identifier starting with a capital is a type" rule,
/// which would colour every enum case and constant in the file.
enum CFamilyGrammars {
    /// The shape every row below starts from: `//` line comments, `/* */` blocks, double- and
    /// single-quoted literals with a backslash escape.
    static func base(
        keywords: Set<String>,
        typeNames: Set<String> = [],
        strings: [LanguageGrammar.StringLiteral] = [.doubleQuoted, .singleQuoted],
        lineComments: [String] = ["//"],
        annotationSigil: String? = nil,
        preprocessorSigil: String? = nil,
        keywordsAreCaseInsensitive: Bool = false,
        blockCommentsNest: Bool = false
    ) -> LanguageGrammar {
        LanguageGrammar(
            lineComments: lineComments,
            blockComment: LanguageGrammar.BlockComment(open: "/*", close: "*/"),
            strings: strings,
            keywords: keywords,
            typeNames: typeNames,
            annotationSigil: annotationSigil,
            preprocessorSigil: preprocessorSigil,
            keywordsAreCaseInsensitive: keywordsAreCaseInsensitive,
            blockCommentsNest: blockCommentsNest
        )
    }

    // MARK: - Swift and Objective-C

    /// Swift nests block comments, which is the difference between `/* /* */ */` ending where the
    /// file says it does and colouring the remainder of the file as one comment.
    ///
    /// A raw string (`#"…"#`) is not in the delimiter list: its opener carries a variable number of
    /// `#`, which is a count to remember, and remembering is the boundary this milestone draws
    /// (PLAN.md §6). Such a literal simply colours from its inner quote.
    ///
    /// `prefix` and `postfix` are **absent** on purpose, found by running the scanner over this
    /// repo's own source: both are contextual keywords that only mean anything before `func` or
    /// `operator`, and `prefix` is one of the most common method names in Swift — `data.prefix(n)`
    /// came out coloured as a keyword on three lines of `TextPreview.swift` alone. A scanner with no
    /// parser cannot tell the two apart, and the false positive is louder than the word it colours.
    static let swift = base(
        keywords: words("""
        actor any as associatedtype async await borrowing break case catch class consuming
        continue convenience default defer deinit didSet do dynamic each else enum extension
        fallthrough false fileprivate final for func get guard if import in indirect infix init
        inout internal is isolated lazy let macro mutating nil nonisolated nonmutating open
        operator optional override package precedencegroup private protocol public
        repeat required rethrows return self sending set some static struct subscript super
        switch throw throws true try typealias unowned var weak where while willSet
        """),
        typeNames: words("""
        AnyObject Any Array Bool Character Data Date Dictionary Double Error Float Int Int8 Int16
        Int32 Int64 Never Optional Result Set String UInt UInt8 UInt16 UInt32 UInt64 URL Void
        """),
        strings: [.tripleDoubleQuoted, .doubleQuoted],
        annotationSigil: "@",
        blockCommentsNest: true
    )

    /// `@` is both Objective-C's directive sigil and the opener of `@"a string"`. The scanner takes
    /// it as a keyword only when an identifier follows, which leaves the literal to the string
    /// branch (`SyntaxHighlighter.scanWord`).
    static let objectiveC = base(
        keywords: words("""
        auto autoreleasepool break bycopy byref case catch char class const continue default do
        double dynamic else encode end enum extern finally float for goto id if implementation
        import in include inline inout int interface long nil NO oneway optional out package
        private property protected protocol public register required restrict return selector
        self short signed sizeof static struct super switch synchronized synthesize throw try
        typedef union unsigned void volatile while YES
        """),
        typeNames: words("""
        BOOL CGFloat CGPoint CGRect CGSize Class IBAction IBOutlet id IMP instancetype NSArray
        NSDictionary NSError NSInteger NSNumber NSObject NSString NSUInteger SEL
        """),
        annotationSigil: "@",
        preprocessorSigil: "#"
    )

    // MARK: - C and C++

    static let cLanguage = base(
        keywords: words("""
        _Alignas _Alignof _Atomic _Bool _Complex _Generic _Noreturn _Static_assert _Thread_local
        auto break case char const continue default do double else enum extern false float for
        goto if inline int long NULL register restrict return short signed sizeof static struct
        switch typedef union unsigned void volatile while
        """),
        typeNames: words("""
        char16_t char32_t FILE int8_t int16_t int32_t int64_t intptr_t ptrdiff_t size_t ssize_t
        uint8_t uint16_t uint32_t uint64_t uintptr_t va_list wchar_t
        """),
        preprocessorSigil: "#"
    )

    static let cPlusPlus = base(
        keywords: cLanguage.keywords.union(words("""
        alignas alignof and and_eq asm bitand bitor catch class co_await co_return co_yield compl
        concept const_cast consteval constexpr constinit decltype delete dynamic_cast explicit
        export friend mutable namespace new noexcept not not_eq nullptr operator or or_eq private
        protected public reinterpret_cast requires static_assert static_cast template this
        thread_local throw true try typeid typename using virtual xor xor_eq
        """)),
        typeNames: cLanguage.typeNames.union(words("nullptr_t")),
        preprocessorSigil: "#"
    )

    /// A `.h` is C, C++ or Objective-C and nothing in the file's *type* says which — which is the
    /// reason `SyntaxLanguage.forFile(named:)` routes by extension in the first place. So a header
    /// gets the union: the superset keywords plus Objective-C's `@` directives, since a word
    /// coloured that no other dialect uses is invisible in the files that do not use it, while
    /// picking one dialect leaves `class` or `@interface` flat in the other two.
    static let cHeader: LanguageGrammar = {
        var grammar = cPlusPlus
        grammar.keywords.formUnion(objectiveC.keywords)
        grammar.typeNames.formUnion(objectiveC.typeNames)
        grammar.annotationSigil = "@"
        return grammar
    }()

    // MARK: - The JVM and .NET family

    static let java = base(
        keywords: words("""
        abstract assert boolean break byte case catch char class const continue default do double
        else enum extends false final finally float for goto if implements import instanceof int
        interface long native new null package permits private protected public record return
        sealed short static strictfp super switch synchronized this throw throws transient true
        try var void volatile while yield
        """),
        typeNames: words("""
        ArrayList Boolean Byte Character Double Exception Float Integer List Long Map Object
        Optional Set Short Stream String StringBuilder
        """),
        annotationSigil: "@"
    )

    static let kotlin = base(
        keywords: words("""
        abstract actual annotation as break by catch class companion const constructor continue
        crossinline data delegate do dynamic else enum expect external false field file final
        finally for fun get if import in infix init inline inner interface internal is lateinit
        noinline null object open operator out override package param private property protected
        public receiver reified return sealed set setparam super suspend tailrec this throw true
        try typealias typeof val value var vararg when where while
        """),
        typeNames: words("""
        Any Array Boolean Byte Char Double Float Int List Long Map MutableList MutableMap
        MutableSet Nothing Number Set Short String Unit
        """),
        annotationSigil: "@"
    )

    static let scala = base(
        keywords: words("""
        abstract case catch class def do else enum export extends false final finally for forSome
        given if implicit import lazy match new null object override package private protected
        return sealed super then this throw trait true try type using val var while with yield
        """),
        typeNames: words("""
        Any AnyRef AnyVal Array Boolean Byte Char Double Float Future Int List Long Map Nothing
        Option Seq Set Short String Unit
        """),
        annotationSigil: "@",
        blockCommentsNest: true
    )

    static let cSharp = base(
        keywords: words("""
        abstract as async await base bool break byte case catch char checked class const continue
        decimal default delegate do double dynamic else enum event explicit extern false finally
        fixed float for foreach global goto if implicit in init int interface internal is lock
        long nameof namespace new null object operator out override params partial private
        protected public readonly record ref return sbyte sealed short sizeof stackalloc static
        string struct switch this throw true try typeof uint ulong unchecked unsafe ushort using
        var virtual void volatile when where while yield
        """),
        typeNames: words("""
        Boolean Decimal Dictionary Double Exception IEnumerable Int32 Int64 List Object String
        Task
        """),
        preprocessorSigil: "#"
    )

    // MARK: - Go and Rust

    static let go = base(
        keywords: words("""
        break case chan const continue default defer else fallthrough false for func go goto if
        import interface iota map nil package range return select struct switch true type var
        """),
        typeNames: words("""
        any bool byte complex64 complex128 error float32 float64 int int8 int16 int32 int64 rune
        string uint uint8 uint16 uint32 uint64 uintptr
        """)
    )

    /// A Rust lifetime (`'a`) opens the single-quote literal and is closed by the end of the line,
    /// so it colours as a very short string. That is the deliberate trade `StringLiteral.spansLines`
    /// describes: a wrong colour on one token, never a wrong colour on the rest of the file.
    static let rust = base(
        keywords: words("""
        as async await break const continue crate dyn else enum extern false fn for if impl in
        let loop macro_rules match mod move mut pub ref return self Self static struct super
        trait true type union unsafe use where while
        """),
        typeNames: words("""
        Arc bool Box char f32 f64 HashMap i8 i16 i32 i64 i128 isize Option Rc Result str String
        u8 u16 u32 u64 u128 usize Vec
        """)
    )

    // MARK: - The web family

    /// A JavaScript **regex literal** (`/re/`) is not scanned. Telling it from division needs to
    /// know what the previous token was, which is a parser's job (PLAN.md §M17) — so a `/` stays
    /// plain, and a regex containing `//` will colour the rest of its line as a comment.
    static let javascript = base(
        keywords: words("""
        async await break case catch class const continue debugger default delete do else enum
        export extends false finally for from function get if import in instanceof let new null
        of return set static super switch this throw true try typeof var void while with yield
        """),
        typeNames: words("""
        Array Boolean Date Error JSON Map Math Number Object Promise RegExp Set String Symbol
        WeakMap
        """),
        strings: [.doubleQuoted, .singleQuoted, .backtickQuoted]
    )

    static let typeScript = base(
        keywords: javascript.keywords.union(words("""
        abstract as asserts declare implements infer interface is keyof module namespace
        override private protected public readonly require satisfies type unique
        """)),
        typeNames: javascript.typeNames.union(words("""
        any bigint boolean never number Omit Partial Pick Readonly Record string symbol unknown
        """)),
        strings: [.doubleQuoted, .singleQuoted, .backtickQuoted],
        annotationSigil: "@"
    )

    /// A **heredoc** (`<<<EOT`) is not scanned, for the same reason as a Swift raw string: its
    /// terminator is chosen at the opening and has to be remembered.
    static let php = base(
        keywords: words("""
        abstract and array as break callable case catch class clone const continue declare
        default do echo else elseif empty enddeclare endfor endforeach endif endswitch endwhile
        enum extends final finally fn for foreach function global goto if implements include
        include_once instanceof insteadof interface isset list match namespace new null or parent
        print private protected public readonly require require_once return self static switch
        throw trait true try unset use var while xor yield false
        """),
        typeNames: words("bool float int iterable mixed never object string void"),
        lineComments: ["//", "#"]
    )

    static let dart = base(
        keywords: words("""
        abstract as assert async await base break case catch class const continue covariant
        default deferred do else enum export extends extension external factory false final
        finally for get hide if implements import in interface is late library mixin new null on
        operator part required rethrow return sealed set show static super switch sync this throw
        true try typedef var while with yield
        """),
        typeNames: words("""
        bool double dynamic Future int Iterable List Map num Object Set Stream String void
        """),
        annotationSigil: "@"
    )

    // MARK: - Data and query languages

    /// `//` and `/* */` are here for JSONC and JSON5 rather than for JSON, which has no comments —
    /// and they cost strict JSON nothing, since neither sequence can occur outside a string.
    static let json = base(
        keywords: words("false null true"),
        strings: [.doubleQuoted]
    )

    /// The one grammar on the case-insensitive flag: `SELECT` and `select` are the same word, so
    /// both sets below are stored lowercased and the scanner folds the file's word before looking
    /// it up.
    static let sql = base(
        keywords: words("""
        add all alter analyze and as asc begin between by cascade case cast check coalesce commit
        constraint create cross declare default delete desc distinct do drop else end exec
        execute exists explain foreign from full function grant group having if in index inner
        insert into is join key left like limit loop natural not nothing null offset on or order
        outer primary procedure recursive references replace return returning revoke right
        rollback select set table then to transaction trigger truncate union unique update using
        vacuum values view when where while with
        """),
        typeNames: words("""
        array bigint bigserial blob bool boolean bytea char clob date datetime decimal double
        float int integer interval json jsonb numeric precision real serial smallint text time
        timestamp tinyint uuid varchar
        """),
        strings: [.doubleQuoted, .singleQuoted],
        lineComments: ["--"],
        keywordsAreCaseInsensitive: true
    )

    /// CSS, SCSS and LESS ride here with **no keywords**, which is honest about being approximate:
    /// a selector/property/value scanner is explicitly out of scope (PLAN.md §M17 ▸ Slice 2). What
    /// it does get is comments, strings, numbers and — through `annotationSigil` — the at-rules
    /// (`@media`, `@import`, `@mixin`), which is most of what makes a stylesheet readable.
    static let css = base(
        keywords: [],
        strings: [.doubleQuoted, .singleQuoted],
        annotationSigil: "@"
    )
}
