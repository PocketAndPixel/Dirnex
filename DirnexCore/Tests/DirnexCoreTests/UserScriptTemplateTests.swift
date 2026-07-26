import Foundation
import Testing

@testable import DirnexCore

/// The templates are data the app turns into real scripts, so what is testable here is their
/// *shape*: that each one is a usable seed, that the ids stay stable (they are translation keys),
/// and that the properties the bodies were probed for are the ones actually written down.
@Suite("UserScriptTemplate")
struct UserScriptTemplateTests {
    @Test("the + menu offers exactly the five templates, in order")
    func catalogIsPinned() {
        // Pinned like `CommandCatalog`'s id list: an id is a translation key, so renaming one
        // orphans its strings in every language and nothing in the compiler notices.
        #expect(UserScriptTemplate.all.map(\.id) == [
            "script.template.copyPaths",
            "script.template.archiveToOtherPanel",
            "script.template.imagesToJPEG",
            "script.template.resizeImages",
            "script.template.removeQuarantine"
        ])
    }

    @Test("every template is a usable seed")
    func everyTemplateIsComplete() {
        for template in UserScriptTemplate.all {
            #expect(
                template.id.hasPrefix("script.template."),
                "\(template.id) breaks the key scheme"
            )
            #expect(!template.title.isEmpty, "\(template.id) has no name")
            #expect(!template.command.isEmpty, "\(template.id) has no body")
            #expect(!template.keywords.isEmpty, "\(template.id) is unfindable in the palette")
        }
        let names = Set(UserScriptTemplate.all.map(\.title))
        #expect(names.count == UserScriptTemplate.all.count, "two templates share a name")
    }

    @Test("a template seeds an ordinary script, carrying its mode and keywords")
    func seedsAnOrdinaryScript() {
        let template = UserScriptTemplate.all[0]
        let script = template.script()
        #expect(script.name == template.title)
        #expect(script.command == template.command)
        #expect(script.runMode == template.runMode)
        #expect(script.keywords == template.keywords)
        // A template must never hand out a function key: it cannot know which are free, and
        // `UserScripts.save` steals a taken one — silently unbinding a script the user set up.
        #expect(script.functionKey == nil)
    }

    @Test("a localized name and keywords override the English fallback")
    func localizedOverride() {
        let script = UserScriptTemplate.all[0].script(
            name: "Копировать пути",
            keywords: ["clipboard", "буфер"]
        )
        #expect(script.name == "Копировать пути")
        #expect(script.keywords == ["clipboard", "буфер"])
        // The body is shell code and is never translated.
        #expect(script.command == UserScriptTemplate.all[0].command)
    }

    @Test("a perFile template reads $1, a combined one reads \"$@\"")
    func bodiesMatchTheirRunMode() {
        for template in UserScriptTemplate.all {
            switch template.runMode {
            case .perFile:
                #expect(template.command.contains("\"$1\""), "\(template.id) never reads its file")
                #expect(!template.command.contains("\"$@\""), "\(template.id) is really combined")
            case .combined:
                #expect(
                    template.command.contains("\"$@\""),
                    "\(template.id) never reads the selection"
                )
            }
        }
    }

    @Test("no template splices a path into the command text")
    func noTemplateInterpolatesPaths() {
        // The security boundary `UserScript` documents: a selected path arrives as an inert argv
        // element. A template that reached for `$DIRNEX_SELECTED_PATHS` unquoted, or built a
        // filename by string concatenation, would be teaching the one habit that breaks it.
        for template in UserScriptTemplate.all {
            #expect(
                !template.command.contains("$DIRNEX_SELECTED_PATHS"),
                "\(template.id) should read \"$@\", which is unambiguous for odd filenames"
            )
        }
    }

    @Test("the archive template refuses to run without a second panel")
    func archiveGuardsTheOtherDirectory() {
        // Probed: with `DIRNEX_OTHER_DIR` unset the unguarded form writes to `/`, failing at the
        // root of the disk with a message naming a path the user never chose.
        let archive = try? #require(
            UserScriptTemplate.all.first { $0.id == "script.template.archiveToOtherPanel" }
        )
        let command = archive?.command ?? ""
        #expect(command.contains("[ -n \"$DIRNEX_OTHER_DIR\" ]"))
        #expect(command.contains("exit 1"))
    }

    @Test("the quarantine template uses the exit-0 form of xattr")
    func quarantineUsesRecursiveDelete() {
        // Probed: `xattr -d` exits 1 ("No such xattr") on a file that was never quarantined, which
        // would raise the failure alert for an ordinary selection; `-dr` exits 0 on the same input.
        let quarantine = UserScriptTemplate.all.first { $0.id == "script.template.removeQuarantine" }
        #expect(quarantine?.command.hasPrefix("xattr -dr ") == true)
    }

    @Test("the image templates write beside the original rather than over it")
    func imageTemplatesAreNonDestructive() {
        for id in ["script.template.imagesToJPEG", "script.template.resizeImages"] {
            let template = UserScriptTemplate.all.first { $0.id == id }
            #expect(
                template?.command.contains("--out") == true,
                "\(id) would overwrite the user's original"
            )
        }
    }
}
