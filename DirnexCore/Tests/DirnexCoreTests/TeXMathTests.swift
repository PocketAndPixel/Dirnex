import Foundation
import Testing

@testable import DirnexCore

/// TeX to MathML (PLAN.md §M39 ▸ Slice 8).
///
/// The markup each case expects is the one WebKit was seen to draw right on 2026-11-14 (`TeXMath`),
/// so several pin a choice that looks arbitrary from the markup alone: `stretchy="false"` on a
/// plain parenthesis, a prime drawn after its base, a thin space after `\log`.
@Suite("TeX math")
struct TeXMathTests {
    /// The `<math>` element's content, for an inline formula.
    func body(_ tex: String) -> String? {
        TeXMath.mathML(tex, display: false).map {
            String($0.dropFirst("<math>".count).dropLast("</math>".count))
        }
    }

    @Test("letters, numbers and operators, a sign after a relation")
    func atoms() {
        #expect(body("x") == "<mi>x</mi>")
        #expect(body("1.25") == "<mn>1.25</mn>")
        #expect(body("a+b") == "<mrow><mi>a</mi><mo>+</mo><mi>b</mi></mrow>")
        // `-` is U+2212, and a sign takes no binary spacing.
        #expect(
            body("a = -1") == "<mrow><mi>a</mi><mo>=</mo><mo form=\"prefix\">−</mo><mn>1</mn></mrow>"
        )
        #expect(body("-1") == "<mrow><mo form=\"prefix\">−</mo><mn>1</mn></mrow>")
        #expect(body("a - 1") == "<mrow><mi>a</mi><mo>−</mo><mn>1</mn></mrow>")
        // A parenthesis written plainly does not stretch, as TeX's does not.
        #expect(
            body("(x)") == "<mrow><mo stretchy=\"false\">(</mo><mi>x</mi><mo stretchy=\"false\">)</mo></mrow>"
        )
        // Escaping: the page's own rule, on every character of text.
        #expect(body("a<b") == "<mrow><mi>a</mi><mo>&lt;</mo><mi>b</mi></mrow>")
    }

    @Test("scripts: sub, super, both, in either order, and on nothing")
    func scripts() {
        #expect(body("x^2") == "<msup><mi>x</mi><mn>2</mn></msup>")
        #expect(body("x_i^2") == "<msubsup><mi>x</mi><mi>i</mi><mn>2</mn></msubsup>")
        #expect(body("x^2_i") == "<msubsup><mi>x</mi><mi>i</mi><mn>2</mn></msubsup>")
        // One token: `x^12` raises the `1` alone, as TeX does.
        #expect(body("x^12") == "<mrow><msup><mi>x</mi><mn>1</mn></msup><mn>2</mn></mrow>")
        #expect(body("x^{12}") == "<msup><mi>x</mi><mn>12</mn></msup>")
        #expect(body("{}^{14}C") == "<mrow><msup><mrow></mrow><mn>14</mn></msup><mi>C</mi></mrow>")
    }

    @Test("a prime is drawn after its base, and a superscript lands on both")
    func primes() {
        #expect(body("f'") == "<mrow><mi>f</mi><mo>′</mo></mrow>")
        #expect(body("f''") == "<mrow><mi>f</mi><mo>″</mo></mrow>")
        #expect(body("f'^2") == "<msup><mrow><mi>f</mi><mo>′</mo></mrow><mn>2</mn></msup>")
        #expect(body("f^\\prime") == "<mrow><mi>f</mi><mo>′</mo></mrow>")
    }

    @Test("fractions, roots and binomials")
    func fractions() {
        #expect(body("\\frac{1}{2}") == "<mfrac><mn>1</mn><mn>2</mn></mfrac>")
        #expect(body("\\frac12") == "<mfrac><mn>1</mn><mn>2</mn></mfrac>")
        #expect(
            body("\\dfrac{a}{b}") == "<mstyle displaystyle=\"true\"><mfrac><mi>a</mi><mi>b</mi></mfrac></mstyle>"
        )
        #expect(body("\\sqrt{2}") == "<msqrt><mn>2</mn></msqrt>")
        #expect(body("\\sqrt[3]{x}") == "<mroot><mi>x</mi><mn>3</mn></mroot>")
        #expect(
            body("\\binom{n}{k}")
                == "<mrow><mo stretchy=\"true\">(</mo><mfrac linethickness=\"0\"><mi>n</mi>"
                + "<mi>k</mi></mfrac><mo stretchy=\"true\">)</mo></mrow>"
        )
        #expect(body("a \\over b") == "<mfrac><mi>a</mi><mi>b</mi></mfrac>")
        #expect(
            body("{a+1 \\over b} + c") == "<mrow><mfrac><mrow><mi>a</mi><mo>+</mo><mn>1</mn></mrow><mi>b</mi></mfrac>"
                + "<mo>+</mo><mi>c</mi></mrow>"
        )
    }

    @Test("Greek, letterlike symbols and the font commands")
    func letters() {
        #expect(body("\\alpha") == "<mi>α</mi>")
        // Capital Greek is upright in TeX, which a one-letter `<mi>` needs saying.
        #expect(body("\\Gamma") == "<mi mathvariant=\"normal\">Γ</mi>")
        #expect(body("\\infty") == "<mi mathvariant=\"normal\">∞</mi>")
        #expect(body("\\mathbb{R}") == "<mi>ℝ</mi>")
        #expect(body("\\mathbb{N}_0") == "<msub><mi>ℕ</mi><mn>0</mn></msub>")
        #expect(body("\\mathcal{L}") == "<mi>ℒ</mi>")
        #expect(body("\\mathbf{x}") == "<mi>𝐱</mi>")
        #expect(body("\\mathbf{1}") == "<mn>𝟏</mn>")
        #expect(body("\\boldsymbol{\\alpha}") == "<mi>𝜶</mi>")
        #expect(body("\\mathfrak{g}") == "<mi>𝔤</mi>")
        #expect(body("\\mathrm{d}x") == "<mrow><mi mathvariant=\"normal\">d</mi><mi>x</mi></mrow>")
        #expect(body("{\\bf x}") == "<mi>𝐱</mi>")
    }

    @Test("operators and relations by name, and `\\not`")
    func symbols() {
        #expect(body("a \\le b") == "<mrow><mi>a</mi><mo>≤</mo><mi>b</mi></mrow>")
        #expect(body("x \\to 0") == "<mrow><mi>x</mi><mo>→</mo><mn>0</mn></mrow>")
        #expect(body("a \\cdot b") == "<mrow><mi>a</mi><mo>⋅</mo><mi>b</mi></mrow>")
        #expect(body("\\not=") == "<mo>≠</mo>")
        #expect(body("\\not\\in") == "<mo>∉</mo>")
        #expect(body("\\not\\simeq") == "<mo>≄</mo>")
        #expect(body("\\not\\preceq") == "<mo>⪯\u{0338}</mo>")
        #expect(
            body("1, \\ldots, n") == "<mrow><mn>1</mn><mo>,</mo><mo>…</mo><mo>,</mo><mi>n</mi></mrow>"
        )
    }

    @Test("large operators carry their limits under and over, and the integrals beside")
    func largeOperators() {
        #expect(
            body("\\sum_{i=1}^n i")
                == "<mrow><munderover><mo>∑</mo><mrow><mi>i</mi><mo>=</mo><mn>1</mn></mrow>"
                + "<mi>n</mi></munderover><mi>i</mi></mrow>"
        )
        #expect(body("\\int_0^1") == "<msubsup><mo>∫</mo><mn>0</mn><mn>1</mn></msubsup>")
        #expect(
            body("\\int\\limits_0^1") == "<munderover><mo movablelimits=\"false\">∫</mo><mn>0</mn><mn>1</mn>"
                + "</munderover>"
        )
        #expect(body("\\sum\\nolimits_i") == "<msub><mo>∑</mo><mi>i</mi></msub>")
    }

    @Test("a function's name is upright and spaced from the letter it applies to")
    func functions() {
        #expect(
            body("\\sin x") == "<mrow><mi>sin</mi><mspace width=\"0.1667em\"></mspace><mi>x</mi></mrow>"
        )
        #expect(
            body("\\log(x)") == "<mrow><mi>log</mi><mo stretchy=\"false\">(</mo><mi>x</mi>"
                + "<mo stretchy=\"false\">)</mo></mrow>"
        )
        #expect(
            body("2\\cos\\theta")
                == "<mrow><mn>2</mn><mspace width=\"0.1667em\"></mspace><mi>cos</mi>"
                + "<mspace width=\"0.1667em\"></mspace><mi>θ</mi></mrow>"
        )
        #expect(
            body("\\lim_{x\\to 0} f")
                == "<mrow><munder><mo movablelimits=\"true\" lspace=\"0\" rspace=\"0\">lim</mo>"
                + "<mrow><mi>x</mi><mo>→</mo><mn>0</mn></mrow></munder>"
                + "<mspace width=\"0.1667em\"></mspace><mi>f</mi></mrow>"
        )
        #expect(
            body("\\operatorname{rank} A") == "<mrow><mi>rank</mi><mspace width=\"0.1667em\"></mspace><mi>A</mi></mrow>"
        )
        #expect(
            body("\\quad\\det A") == "<mrow><mspace width=\"1em\"></mspace>"
                + "<mo movablelimits=\"true\" lspace=\"0\" rspace=\"0\">det</mo>"
                + "<mspace width=\"0.1667em\"></mspace><mi>A</mi></mrow>"
        )
    }

    @Test("`\\left` and `\\right` stretch, `\\big` sizes, `.` draws nothing")
    func delimiters() {
        #expect(
            body("\\left( \\frac{1}{2} \\right)")
                == "<mrow><mo stretchy=\"true\">(</mo><mfrac><mn>1</mn><mn>2</mn></mfrac>"
                + "<mo stretchy=\"true\">)</mo></mrow>"
        )
        #expect(body("\\left. x \\right|") == "<mrow><mi>x</mi><mo stretchy=\"true\">|</mo></mrow>")
        #expect(
            body("\\left\\langle x \\right\\rangle")
                == "<mrow><mo stretchy=\"true\">⟨</mo><mi>x</mi><mo stretchy=\"true\">⟩</mo></mrow>"
        )
        #expect(
            body("\\bigl(") == "<mo stretchy=\"true\" minsize=\"1.2em\" maxsize=\"1.2em\">(</mo>"
        )
        #expect(
            body("\\{x\\}") == "<mrow><mo stretchy=\"false\">{</mo><mi>x</mi><mo stretchy=\"false\">}</mo></mrow>"
        )
    }

    @Test("accents sit on their letter, unspaced, and `\\vec`'s arrow is small")
    func accents() {
        #expect(
            body("\\hat{x}") == "<mover accent=\"true\"><mi>x</mi><mo lspace=\"0\" rspace=\"0\">ˆ</mo></mover>"
        )
        #expect(
            body("\\bar x") == "<mover accent=\"true\"><mi>x</mi><mo lspace=\"0\" rspace=\"0\">ˉ</mo></mover>"
        )
        #expect(
            body("\\vec{v}") == "<mover accent=\"true\"><mi>v</mi>"
                + "<mo lspace=\"0\" rspace=\"0\" mathsize=\"0.6em\">→</mo></mover>"
        )
        #expect(
            body("\\underline{x}") == "<munder accentunder=\"true\"><mi>x</mi><mo lspace=\"0\" rspace=\"0\">_</mo>"
                + "</munder>"
        )
        #expect(
            body("\\overbrace{a}^{n}")
                == "<mover><mover><mi>a</mi><mo stretchy=\"true\">⏞</mo></mover><mi>n</mi></mover>"
        )
    }

    @Test("text keeps its spaces as no-break spaces, which WebKit would drop at an edge")
    func text() {
        #expect(body("\\text{if } x") == "<mrow><mtext>if\u{00A0}</mtext><mi>x</mi></mrow>")
        #expect(body("\\text{a  b}") == "<mtext>a\u{00A0}b</mtext>")
        #expect(body("\\textbf{A}") == "<mtext>𝐀</mtext>")
        #expect(body("\\text{\\{x\\}}") == "<mtext>{x}</mtext>")
    }
}

/// The structures: environments, unknown commands and what fails.
extension TeXMathTests {
    @Test("environments: matrices, cases, aligned, array, and lines at the top")
    func environments() {
        #expect(
            body("\\begin{pmatrix} a & b \\\\ c & d \\end{pmatrix}")
                == "<mrow><mo stretchy=\"true\">(</mo><mtable><mtr><mtd><mi>a</mi></mtd><mtd>"
                + "<mi>b</mi></mtd></mtr><mtr><mtd><mi>c</mi></mtd><mtd><mi>d</mi></mtd></mtr>"
                + "</mtable><mo stretchy=\"true\">)</mo></mrow>"
        )
        #expect(
            body("\\begin{cases} 1 & x \\\\ 0 & y \\\\ \\end{cases}")
                == "<mrow><mo stretchy=\"true\">{</mo><mtable><mtr><mtd columnalign=\"left\">"
                + "<mn>1</mn></mtd><mtd columnalign=\"left\"><mi>x</mi></mtd></mtr><mtr>"
                + "<mtd columnalign=\"left\"><mn>0</mn></mtd><mtd columnalign=\"left\"><mi>y</mi>"
                + "</mtd></mtr></mtable></mrow>"
        )
        // Each cell after `&` opens with an empty `<mi>`, so its `=` keeps a relation's spacing.
        #expect(
            body("\\begin{aligned} a &= b \\end{aligned}")
                == "<mtable class=\"math-aligned\"><mtr><mtd columnalign=\"right\"><mi>a</mi>"
                + "</mtd><mtd columnalign=\"left\"><mrow><mi></mi><mo>=</mo><mi>b</mi></mrow>"
                + "</mtd></mtr></mtable>"
        )
        #expect(
            body("\\begin{array}{|l|r|} a & b \\\\ \\hline c & d \\end{array}")?
                .contains(
                    "<mtd columnalign=\"left\"><mi>c</mi></mtd><mtd columnalign=\"right\"><mi>d</mi></mtd>"
                ) == true
        )
        #expect(
            body("a \\\\ b") == "<mtable><mtr><mtd><mi>a</mi></mtd></mtr><mtr><mtd><mi>b</mi></mtd></mtr></mtable>"
        )
    }

    @Test("an unknown command draws as its own text, and what follows is read as usual")
    func unknown() {
        #expect(
            body("\\foo x") == "<mrow><mtext class=\"math-unknown\">\\foo</mtext><mi>x</mi></mrow>"
        )
        #expect(
            body("\\color{red}{x}")?.hasPrefix("<mrow><mtext class=\"math-unknown\">\\color</mtext>") == true
        )
        // A link command is text too: nothing in a formula is ever a link.
        #expect(body("\\href{https://e.com}{x}")?.contains("href=") == false)
        #expect(
            body("\\begin{foo} a \\end{foo}")
                == "<mrow><mtext class=\"math-unknown\">\\begin{foo}</mtext><mtable><mtr><mtd>"
                + "<mi>a</mi></mtd></mtr></mtable>"
                + "<mtext class=\"math-unknown\">\\end{foo}</mtext></mrow>"
        )
    }

    @Test(
        "a structure that does not close fails the formula",
        arguments: [
            "\\frac{1}{2", "x}", "\\left( x", "x \\right)", "\\begin{matrix} a",
            "\\begin{matrix} a \\end{pmatrix}", "\\frac{1}", "x^", "\\sqrt",
            "\\left\\foo x \\right)",
        ]
    )
    func failures(_ tex: String) {
        #expect(TeXMath.mathML(tex, display: false) == nil)
    }

    @Test("a formula nested deeper than anyone writes fails rather than exhausting the stack")
    func depth() {
        let deep = String(repeating: "{", count: 100_000) + "x" + String(
            repeating: "}",
            count: 100_000
        )
        #expect(TeXMath.mathML(deep, display: false) == nil)
        #expect(TeXMath.mathML(String(repeating: "\\frac", count: 100_000), display: false) == nil)
        let fine = String(repeating: "{", count: 20) + "x" + String(repeating: "}", count: 20)
        #expect(TeXMath.mathML(fine, display: false) == "<math><mi>x</mi></math>")
    }

    @Test("comments, spacing commands and display")
    func odds() {
        #expect(body("a % a comment\n+ b") == "<mrow><mi>a</mi><mo>+</mo><mi>b</mi></mrow>")
        #expect(
            body("a\\,b") == "<mrow><mi>a</mi><mspace width=\"0.1667em\"></mspace><mi>b</mi></mrow>"
        )
        #expect(TeXMath.mathML("x", display: true) == "<math display=\"block\"><mi>x</mi></math>")
        #expect(
            body("\\displaystyle x") == "<mstyle displaystyle=\"true\" scriptlevel=\"0\"><mi>x</mi></mstyle>"
        )
    }
}
