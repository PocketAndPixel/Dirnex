import Foundation

/// TeX's atom classes, which decide the spacing around an atom and whether a `+` or `-` is the
/// sign of what follows it (TeXbook ch. 17). MathML's operator dictionary spaces most operators by
/// itself; what it cannot know is TeX's rule that a binary operator after a relation, an opening
/// delimiter or nothing at all is a sign, so `a = -1` is drawn `a = −1` and not `a = − 1`.
enum TeXMathClass: Equatable {
    case ord
    case op
    case bin
    case rel
    case open
    case close
    case punct
}

/// The commands that name one symbol, and the class each draws as (PLAN.md §M39 ▸ Slice 8).
///
/// The glyphs are MathJax's for the same commands, with three exceptions the 2026-11-14 probe found
/// in WebKit (`TeXMath`): `\cdot` is U+22C5, and the accents are in `accents` below.
enum TeXMathSymbols {
    /// Letters: an `<mi>`. Lowercase Greek is italic, as TeX draws it, which a one-letter `<mi>`
    /// is by itself; uppercase Greek and the letterlike symbols are upright.
    static let letters: [String: (glyph: String, upright: Bool)] = {
        var table: [String: (String, Bool)] = [:]
        let lower = [
            "alpha": "α", "beta": "β", "gamma": "γ", "delta": "δ", "epsilon": "ϵ",
            "varepsilon": "ε", "zeta": "ζ", "eta": "η", "theta": "θ", "vartheta": "ϑ",
            "iota": "ι", "kappa": "κ", "varkappa": "ϰ", "lambda": "λ", "mu": "μ", "nu": "ν",
            "xi": "ξ", "omicron": "ο", "pi": "π", "varpi": "ϖ", "rho": "ρ", "varrho": "ϱ",
            "sigma": "σ", "varsigma": "ς", "tau": "τ", "upsilon": "υ", "phi": "ϕ",
            "varphi": "φ", "chi": "χ", "psi": "ψ", "omega": "ω", "ell": "ℓ", "imath": "ı",
            "jmath": "ȷ", "hbar": "ℏ", "hslash": "ℏ", "wp": "℘"
        ]
        let upright = [
            "Gamma": "Γ", "Delta": "Δ", "Theta": "Θ", "Lambda": "Λ", "Xi": "Ξ", "Pi": "Π",
            "Sigma": "Σ", "Upsilon": "Υ", "Phi": "Φ", "Psi": "Ψ", "Omega": "Ω",
            "infty": "∞", "partial": "∂", "nabla": "∇", "emptyset": "∅", "varnothing": "∅",
            "aleph": "ℵ", "beth": "ℶ", "Re": "ℜ", "Im": "ℑ", "angle": "∠", "triangle": "△",
            "top": "⊤", "bot": "⊥", "prime": "′", "backprime": "‵", "degree": "°",
            "checkmark": "✓", "clubsuit": "♣", "diamondsuit": "♢", "heartsuit": "♡",
            "spadesuit": "♠", "flat": "♭", "natural": "♮", "sharp": "♯", "mho": "℧",
            "Box": "□", "square": "□", "blacksquare": "■", "Diamond": "◊", "lozenge": "◊"
        ]
        for (name, glyph) in lower {
            table[name] = (glyph, false)
        }
        for (name, glyph) in upright {
            table[name] = (glyph, true)
        }
        return table
    }()

    /// Operators: an `<mo>`, with the class that spaces it.
    static let operators: [String: (glyph: String, class: TeXMathClass)] = {
        var table: [String: (String, TeXMathClass)] = [:]
        for (name, glyph) in binary {
            table[name] = (glyph, .bin)
        }
        for (name, glyph) in relations {
            table[name] = (glyph, .rel)
        }
        for (name, glyph) in arrows {
            table[name] = (glyph, .rel)
        }
        for (name, glyph) in ordinary {
            table[name] = (glyph, .ord)
        }
        return table
    }()

    private static let binary = [
        "pm": "±", "mp": "∓", "times": "×", "div": "÷", "cdot": "⋅", "ast": "∗", "star": "⋆",
        "circ": "∘", "bullet": "∙", "cap": "∩", "cup": "∪", "uplus": "⊎", "sqcap": "⊓",
        "sqcup": "⊔", "vee": "∨", "lor": "∨", "wedge": "∧", "land": "∧", "setminus": "∖",
        "smallsetminus": "∖", "wr": "≀", "diamond": "⋄", "bigtriangleup": "△",
        "bigtriangledown": "▽", "triangleleft": "◃", "triangleright": "▹", "oplus": "⊕",
        "ominus": "⊖", "otimes": "⊗", "oslash": "⊘", "odot": "⊙", "bigcirc": "◯",
        "dagger": "†", "ddagger": "‡", "amalg": "⨿", "cdotp": "·", "ltimes": "⋉",
        "rtimes": "⋊", "dotplus": "∔"
    ]

    private static let relations = [
        "leq": "≤", "le": "≤", "geq": "≥", "ge": "≥", "neq": "≠", "ne": "≠", "equiv": "≡",
        "approx": "≈", "approxeq": "≊", "sim": "∼", "simeq": "≃", "cong": "≅", "propto": "∝",
        "prec": "≺", "succ": "≻", "preceq": "⪯", "succeq": "⪰", "ll": "≪", "gg": "≫",
        "subset": "⊂", "supset": "⊃", "subseteq": "⊆", "supseteq": "⊇", "subsetneq": "⊊",
        "supsetneq": "⊋", "sqsubset": "⊏", "sqsupset": "⊐", "sqsubseteq": "⊑",
        "sqsupseteq": "⊒", "in": "∈", "ni": "∋", "owns": "∋", "notin": "∉", "vdash": "⊢",
        "dashv": "⊣", "models": "⊨", "mid": "∣", "parallel": "∥", "perp": "⊥",
        "smile": "⌣", "frown": "⌢", "asymp": "≍", "doteq": "≐", "bowtie": "⋈",
        "leqslant": "⩽", "geqslant": "⩾", "lesssim": "≲", "gtrsim": "≳", "nless": "≮",
        "ngtr": "≯", "nleq": "≰", "ngeq": "≱", "nsubseteq": "⊈", "nsupseteq": "⊉",
        "nmid": "∤", "nparallel": "∦", "nsim": "≁", "ncong": "≇", "coloneqq": "≔",
        "triangleq": "≜", "therefore": "∴", "because": "∵", "colon": ":"
    ]

    private static let arrows = [
        "leftarrow": "←", "gets": "←", "rightarrow": "→", "to": "→",
        "leftrightarrow": "↔", "Leftarrow": "⇐", "Rightarrow": "⇒", "Leftrightarrow": "⇔",
        "longleftarrow": "⟵", "longrightarrow": "⟶", "longleftrightarrow": "⟷",
        "Longleftarrow": "⟸", "Longrightarrow": "⟹", "Longleftrightarrow": "⟺",
        "implies": "⟹", "impliedby": "⟸", "iff": "⟺", "mapsto": "↦", "longmapsto": "⟼",
        "uparrow": "↑", "downarrow": "↓", "updownarrow": "↕", "Uparrow": "⇑",
        "Downarrow": "⇓", "Updownarrow": "⇕", "nearrow": "↗", "searrow": "↘",
        "swarrow": "↙", "nwarrow": "↖", "hookrightarrow": "↪", "hookleftarrow": "↩",
        "rightharpoonup": "⇀", "rightharpoondown": "⇁", "leftharpoonup": "↼",
        "leftharpoondown": "↽", "rightleftharpoons": "⇌", "leadsto": "↝",
        "rightsquigarrow": "⇝", "twoheadrightarrow": "↠", "nrightarrow": "↛",
        "nleftarrow": "↚", "nRightarrow": "⇏"
    ]

    private static let ordinary = [
        "forall": "∀", "exists": "∃", "nexists": "∄", "neg": "¬", "lnot": "¬",
        "ldots": "…", "dots": "…", "dotsc": "…", "dotso": "…", "cdots": "⋯",
        "dotsb": "⋯", "dotsm": "⋯", "dotsi": "⋯", "vdots": "⋮", "ddots": "⋱",
        "ldotp": ".", "surd": "√", "backslash": "∖"
    ]

    /// `\sum` and its kind, with whether its scripts go under and over in display (`limits`).
    /// The integrals keep theirs beside, as TeX's do.
    static let largeOperators: [String: (glyph: String, limits: Bool)] = [
        "sum": ("∑", true), "prod": ("∏", true), "coprod": ("∐", true),
        "bigcup": ("⋃", true), "bigcap": ("⋂", true), "bigvee": ("⋁", true),
        "bigwedge": ("⋀", true), "bigoplus": ("⨁", true), "bigotimes": ("⨂", true),
        "bigodot": ("⨀", true), "biguplus": ("⨄", true), "bigsqcup": ("⨆", true),
        "int": ("∫", false), "iint": ("∬", false), "iiint": ("∭", false),
        "oint": ("∮", false), "oiint": ("∯", false), "intop": ("∫", true)
    ]

    /// `\sin` and its kind: upright names. Those with `limits` take their scripts under in
    /// display, as `\lim_{x \to 0}` does.
    static let functions: [String: (name: String, limits: Bool)] = {
        var table: [String: (String, Bool)] = [:]
        let beside = [
            "arccos", "arcsin", "arctan", "arg", "cos", "cosh", "cot", "coth", "csc", "deg",
            "dim", "exp", "hom", "ker", "lg", "ln", "log", "sec", "sin", "sinh", "tan", "tanh"
        ]
        for name in beside {
            table[name] = (name, false)
        }
        for name in ["det", "gcd", "inf", "lim", "max", "min", "Pr", "sup"] {
            table[name] = (name, true)
        }
        // A six-per-em space, which an `<mo>`'s text keeps where a plain one would collapse.
        table["liminf"] = ("lim\u{2006}inf", true)
        table["limsup"] = ("lim\u{2006}sup", true)
        table["injlim"] = ("inj\u{2006}lim", true)
        table["projlim"] = ("proj\u{2006}lim", true)
        return table
    }()

    /// What a delimiter command draws, for `\left`, `\big` and a plain use alike, and the class a
    /// plain use takes.
    static let delimiters: [String: (glyph: String, class: TeXMathClass)] = [
        "{": ("{", .open), "}": ("}", .close), "lbrace": ("{", .open), "rbrace": ("}", .close),
        "lbrack": ("[", .open), "rbrack": ("]", .close), "langle": ("⟨", .open),
        "rangle": ("⟩", .close), "lceil": ("⌈", .open), "rceil": ("⌉", .close),
        "lfloor": ("⌊", .open), "rfloor": ("⌋", .close), "lvert": ("|", .open),
        "rvert": ("|", .close), "lVert": ("‖", .open), "rVert": ("‖", .close),
        "vert": ("|", .ord), "Vert": ("‖", .ord), "|": ("‖", .ord), "lgroup": ("⟮", .open),
        "rgroup": ("⟯", .close), "ulcorner": ("⌜", .open), "urcorner": ("⌝", .close),
        "llcorner": ("⌞", .open), "lrcorner": ("⌟", .close)
    ]

    /// A character standing alone as a delimiter, as `\left(` and `\big|` write one.
    static let delimiterCharacters: [Character: String] = [
        "(": "(", ")": ")", "[": "[", "]": "]", "|": "|", "/": "/", "<": "⟨", ">": "⟩"
    ]

    /// What an accent draws over (or, for `\underline`, under) its argument. Probed in WebKit 2026-11-14, glyph by glyph: U+00AF draws `\bar` high
    /// above a letter and U+02C9 sits on it; U+02C7 overlaps its letter unless it does not
    /// stretch; U+02DC keeps `\tilde` letter-sized where U+007E widens into `\widetilde`; U+203E
    /// draws `\overline` far above its text, and U+00AF stretches across it.
    static let accents: [String: TeXMathAccent] = [
        "hat": TeXMathAccent("ˆ"), "widehat": TeXMathAccent("^"),
        "check": TeXMathAccent("ˇ", stretchy: false), "widecheck": TeXMathAccent("ˇ"),
        "tilde": TeXMathAccent("˜"), "widetilde": TeXMathAccent("~"), "bar": TeXMathAccent("ˉ"),
        "overline": TeXMathAccent("¯"), "vec": TeXMathAccent("→", scale: "0.6em"),
        "overrightarrow": TeXMathAccent("→"), "overleftarrow": TeXMathAccent("←"),
        "overleftrightarrow": TeXMathAccent("↔"), "dot": TeXMathAccent("˙"),
        "ddot": TeXMathAccent("¨"), "acute": TeXMathAccent("´"), "grave": TeXMathAccent("`"),
        "breve": TeXMathAccent("˘"), "mathring": TeXMathAccent("˚"),
        "underline": TeXMathAccent("_", under: true),
        "underrightarrow": TeXMathAccent("→", under: true),
        "underleftarrow": TeXMathAccent("←", under: true)
    ]

    /// Spacing commands, as MathJax sizes them.
    static let spaces: [String: String] = [
        ",": "0.1667em", ":": "0.2222em", ">": "0.2222em", ";": "0.2778em",
        "!": "-0.1667em", "thinspace": "0.1667em", "medspace": "0.2222em",
        "thickspace": "0.2778em", "negthinspace": "-0.1667em", "negmedspace": "-0.2222em",
        "negthickspace": "-0.2778em", "enspace": "0.5em", "quad": "1em", "qquad": "2em"
    ]

    /// `\big` and its kin: the size the delimiter is drawn at, and the class it takes.
    static let bigDelimiters: [String: (size: String, class: TeXMathClass)] = {
        var table: [String: (String, TeXMathClass)] = [:]
        let sizes = ["big": "1.2em", "Big": "1.623em", "bigg": "2.047em", "Bigg": "2.470em"]
        for (name, size) in sizes {
            table[name] = (size, .ord)
            table[name + "l"] = (size, .open)
            table[name + "r"] = (size, .close)
            table[name + "m"] = (size, .rel)
        }
        return table
    }()

    /// The text-size switches, as a `mathsize`.
    static let sizes: [String: String] = [
        "tiny": "0.5em", "scriptsize": "0.7em", "footnotesize": "0.8em", "small": "0.9em",
        "normalsize": "1em", "large": "1.2em", "Large": "1.44em", "LARGE": "1.728em",
        "huge": "2.074em", "Huge": "2.488em"
    ]

    /// `\not` before these draws the negated relation Unicode has a character for. Anything else
    /// takes U+0338 after it, which WebKit draws through the symbol.
    static let negations: [String: String] = [
        "=": "≠", "<": "≮", ">": "≯", "≤": "≰", "≥": "≱", "∈": "∉", "∋": "∌", "≡": "≢",
        "∼": "≁", "≃": "≄", "≅": "≇", "≈": "≉", "⊂": "⊄", "⊃": "⊅", "⊆": "⊈", "⊇": "⊉",
        "∣": "∤", "∥": "∦", "≺": "⊀", "≻": "⊁", "⊢": "⊬", "⊨": "⊭", "→": "↛", "←": "↚",
        "⇒": "⇏", "⇐": "⇍", "⇔": "⇎", "↔": "↮", "∃": "∄"
    ]

    /// The class of a character written as itself, `+` or `≤`: its command's class when one of the
    /// tables above names it, and TeX's for the ASCII ones.
    static func characterClass(_ glyph: String) -> TeXMathClass? {
        characterClasses[glyph]
    }

    private static let characterClasses: [String: TeXMathClass] = {
        var table: [String: TeXMathClass] = [:]
        for (glyph, kind) in operators.values {
            table[glyph] = kind
        }
        for (glyph, _) in largeOperators.values {
            table[glyph] = .op
        }
        let ascii: [String: TeXMathClass] = [
            "+": .bin, "−": .bin, "∗": .bin, "=": .rel, "<": .rel, ">": .rel, ":": .rel,
            "(": .open, "[": .open, ")": .close, "]": .close, "!": .close, "?": .close,
            ",": .punct, ";": .punct
        ]
        table.merge(ascii) { _, ascii in ascii }
        return table
    }()
}

/// An accent's mark and how it is drawn (`TeXMathSymbols.accents`).
struct TeXMathAccent {
    let glyph: String
    /// `false` writes `stretchy="false"`, `nil` leaves it to MathML's operator dictionary.
    let stretchy: Bool?
    /// `\underline` and its kin, drawn under rather than over.
    let under: Bool
    /// `mathsize`, which draws `\vec`'s arrow at the size of TeX's.
    let scale: String?

    init(_ glyph: String, stretchy: Bool? = nil, under: Bool = false, scale: String? = nil) {
        self.glyph = glyph
        self.stretchy = stretchy
        self.under = under
        self.scale = scale
    }
}
