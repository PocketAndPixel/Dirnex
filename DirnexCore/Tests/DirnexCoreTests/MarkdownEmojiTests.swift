import Foundation
import Testing

@testable import DirnexCore

/// Emoji shortcodes (PLAN.md §M39 ▸ Slice 6).
///
/// Every expected answer below is what GitHub's own renderer gave for the same text (its `/markdown`
/// API, 2026-11-13), because GitHub's rule is written down nowhere and is not a word boundary: the
/// run's first candidate decides for the whole run (`MarkdownEmoji`).
@Suite("Markdown emoji shortcodes")
struct MarkdownEmojiTests {
    private func html(_ text: String) -> String {
        MarkdownDocument.render(text).html
    }

    @Test("the generated table parses whole, with each emoji as gemoji spells it")
    func table() {
        // A count short of the generator's would mean an emoji ran into the name after it.
        #expect(MarkdownEmoji.table.count == MarkdownEmoji.tableCount)
        #expect(MarkdownEmoji.tableCount == 1913)
        #expect(MarkdownEmoji.table["+1"] == "👍")
        #expect(MarkdownEmoji.table["-1"] == "👎")
        #expect(MarkdownEmoji.table["tada"] == "🎉")
        // The presentation selector stays, or ❤ and ⚠ draw as black text glyphs.
        #expect(MarkdownEmoji.table["heart"] == "❤\u{FE0F}")
        #expect(MarkdownEmoji.table["warning"] == "⚠\u{FE0F}")
        // A keycap is three scalars, a subdivision flag seven, and each is one entry.
        #expect(MarkdownEmoji.table["hash"] == "#\u{FE0F}\u{20E3}")
        #expect(MarkdownEmoji.table["england"]?.unicodeScalars.count == 7)
        #expect(MarkdownEmoji.table["t-rex"] == "🦖")
        // GitHub's own pictures have no character, and stay their text.
        #expect(MarkdownEmoji.table["octocat"] == nil)
    }

    @Test(
        "GitHub's answer for where a shortcode is drawn",
        arguments: [
            // Before: the start of the run or ASCII whitespace, nothing else.
            (":smile: x", "😄 x"),
            ("a :smile: b", "a 😄 b"),
            ("Z:smile: Z", "Z:smile: Z"),
            ("1:smile:", "1:smile:"),
            ("-:smile:", "-:smile:"),
            ("(:smile:)", "(:smile:)"),
            ("\":smile:\"", "\":smile:\""),
            ("é:smile:", "é:smile:"),
            ("😀:smile:", "😀:smile:"),
            ("a\u{00A0}:smile:", "a\u{00A0}:smile:"),
            // After: anything at all.
            ("x :smile:a", "x 😄a"),
            ("x :smile:)", "x 😄)"),
            ("x :smile:.", "x 😄."),
            ("x :smile::", "x 😄:"),
            ("x :smile:😀", "x 😄😀"),
            // Back to back, and the first candidate deciding for the run.
            ("x :+1::+1: y", "x 👍👍 y"),
            (":nope::smile: x", ":nope:😄 x"),
            (":smile::nope: x", "😄:nope: x"),
            (":smile:smile:", "😄smile:"),
            (":smile: a:b:c :smile:", "😄 a🅱️c 😄"),
            ("a :b:c :smile:", "a 🅱️c 😄"),
            ("a :nope: and :smile:", "a :nope: and 😄"),
            ("10:30:00 :smile:", "10:30:00 :smile:"),
            ("a:b:c :smile:", "a:b:c :smile:"),
            ("a:B:c :smile:", "a:B:c :smile:"),
            ("a:b-c:d :smile:", "a:b-c:d :smile:"),
            ("one:two:three :smile:", "one:two:three :smile:"),
            ("a::smile:: b", "a::smile:: b"),
            ("10:30 :smile:", "10:30 😄"),
            ("ratio 1:2 :smile:", "ratio 1:2 😄"),
            ("a:b :smile:", "a:b 😄"),
            ("note: :smile: done", "note: 😄 done"),
            ("time 10:30:00 and :1234: x", "time 10:30:00 and :1234: x"),
            ("x :1234: and :nope: and :Smile:", "x 🔢 and :nope: and :Smile:"),
            // The Swift selectors a plain search for names turned into emoji.
            ("call sendEvent(buttonFlags:x:y:)", "call sendEvent(buttonFlags:x:y:)"),
            ("requestOpenLink(source:link:params:)", "requestOpenLink(source:link:params:)"),
            // Names are case-sensitive, and digits, `+` and `-` are part of them.
            (":SMILE:", ":SMILE:"),
            (":100:", "💯"),
            (":1st_place_medal:", "🥇"),
            (":e-mail:", "📧"),
            (":uk: :gb:", "🇬🇧 🇬🇧")
        ]
    )
    func githubRule(_ input: String, _ expected: String) {
        #expect(MarkdownEmoji.converting(input) == expected)
    }

    @Test("a run is the text between two elements, soft breaks included")
    func runs() {
        // One text node across the soft break, so `:b:` decides and nothing is drawn.
        #expect(html("a:b:c\n:smile: soft") == "<p>a:b:c\n:smile: soft</p>")
        // A new line in the same run follows whitespace.
        #expect(html("line\n:smile: after") == "<p>line\n😄 after</p>")
        // Emphasis ends the run, so the shortcode after it opens a new one.
        #expect(html("a:b:c *x* :smile:") == "<p>a:b:c <em>x</em> 😄</p>")
        #expect(html("*:smile:* **bold**:smile: x")
            == "<p><em>😄</em> <strong>bold</strong>😄 x</p>")
        // An escape and an entity are gone by the time the run is read, as on GitHub.
        #expect(html("\\:smile: and &#58;smile&#58;") == "<p>😄 and 😄</p>")
    }

    @Test("code keeps its text, a link's words are drawn, an image's alt is not")
    func contexts() {
        #expect(html("`:smile:`") == "<p><code>:smile:</code></p>")
        #expect(html("```\n:smile:\n```").contains(":smile:"))
        #expect(html("[:rocket: link](https://example.com)")
            == "<p><a href=\"https://example.com\">🚀 link</a></p>")
        #expect(html("![:cat: alt](x.png)").contains("alt=\":cat: alt\""))
    }

    @Test("a heading draws its emoji and anchors on its text as written, as GitHub's does")
    func headingAnchor() {
        // GitHub served `## :bulb: Highlights` (nodelib's fs.walk README) as 💡 with
        // `id="user-content-bulb-highlights"`.
        let rendered = html("[[_TOC_]]\n\n## :bulb: Highlights")
        #expect(rendered.contains("<h2 id=\"bulb-highlights\">💡 Highlights</h2>"))
        #expect(rendered.contains("<a href=\"#bulb-highlights\">💡 Highlights</a>"))
        // A literal emoji has no name to keep, and anchors as before.
        #expect(html("## 🐛 Bugs").contains("id=\"-bugs\""))
    }

    @Test("text with no colon comes back as the same string")
    func untouched() {
        let text = "Plain prose with no shortcode in it."
        #expect(MarkdownEmoji.converting(text) == text)
        #expect(MarkdownEmoji.converting("").isEmpty)
        #expect(MarkdownEmoji.converting(":") == ":")
        #expect(MarkdownEmoji.converting("::") == "::")
    }
}
