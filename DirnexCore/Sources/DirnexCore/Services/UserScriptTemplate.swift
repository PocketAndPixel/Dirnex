import Foundation

/// A ready-made starting point for a user script — what the scripts organizer's **+** menu offers
/// beside "Blank Script" (PLAN.md §M6 "user actions — shell scripts receiving selection as
/// argv/env").
///
/// A template is a **seed, not a built-in**: picking one saves an ordinary, fully editable
/// `UserScript` into the user's list, and Dirnex forgets it came from here. Live built-ins would owe
/// the user answers Dirnex should not have to give — whether they can be deleted, what happens to an
/// edited one on the next app update — for nothing the seed does not already deliver.
///
/// The templates exist because the organizer's hardest moment is the empty **Command** box. Each one
/// is a worked example of exactly one thing the mechanism can do (`"$@"`, `perFile` mode,
/// `$DIRNEX_OTHER_DIR`), so reading five of them teaches the feature more completely than the help
/// label under the box can.
///
/// **Every template runs on a stock Mac.** `pbcopy`, `sips`, `tar` and `xattr` all ship with macOS —
/// a template that needed Homebrew would be a broken demo on the machine of the person most likely
/// to try one. Each body below was run against real files before it was written down; the
/// non-obvious findings are recorded at the template that depends on them.
///
/// **The runner discards stdout** (`UserScriptRunner` sends it to `/dev/null` and surfaces stderr
/// only on a non-zero exit), so a template that merely *prints* would do nothing visible. Every one
/// here therefore has a side effect — a written file, a changed attribute, or the pasteboard.
///
/// Like `TourScreen` and the command registry, this is `DirnexCore` **data**: the `id` is the stable
/// translation key and `title`/`keywords` are the English fallback the app looks past when the
/// string catalog has an entry (see `LocalizationKey`). The `command` is never localized — it is
/// shell code, and translating it would break it.
public struct UserScriptTemplate: Sendable, Equatable, Identifiable {
    /// Stable, dotted identity ("script.template.copyPaths") — the translation key, never displayed
    /// and never localized. Renaming one orphans its translations in every language, exactly as a
    /// `Command.id` does.
    public let id: String
    /// The English name, and the name of the script the template seeds. The fallback when the app's
    /// catalog has no entry for `id`.
    public let title: String
    /// The shell body, verbatim — never translated (see the type note).
    public let command: String
    /// How the seeded script consumes the selection. Part of the lesson: half these templates exist
    /// to show that `perFile` is where a per-file transform belongs.
    public let runMode: UserScriptRunMode
    /// The English palette keywords the seeded script carries; the app adds the translated ones.
    public let keywords: [String]

    public init(
        id: String,
        title: String,
        command: String,
        runMode: UserScriptRunMode,
        keywords: [String] = []
    ) {
        self.id = id
        self.title = title
        self.command = command
        self.runMode = runMode
        self.keywords = keywords
    }

    /// The script this template seeds, under `name` and `keywords` — which the app passes already
    /// localized, falling back to this template's English. No function key: a template cannot know
    /// which keys are free, and silently stealing one from another script (which `UserScripts.save`
    /// would do) is not a thing a "new script" gesture should ever cause.
    public func script(name: String? = nil, keywords: [String]? = nil) -> UserScript {
        UserScript(
            name: name ?? title,
            command: command,
            runMode: runMode,
            keywords: keywords ?? self.keywords
        )
    }

    /// The templates, in the order the **+** menu lists them: the two that act on any selection
    /// first, then the pair of image transforms, then the two that change files in place.
    public static let all: [UserScriptTemplate] = [
        UserScriptTemplate(
            id: "script.template.copyPaths",
            title: "Copy Paths",
            // The plainest possible demonstration of `"$@"`: one process, every selected path as its
            // own argument. `pbcopy` is also the answer to "the runner throws stdout away" — a
            // script that wants to *tell* the user something puts it on the pasteboard.
            command: #"printf '%s\n' "$@" | pbcopy"#,
            runMode: .combined,
            keywords: ["clipboard", "path", "copy", "pasteboard"]
        ),
        UserScriptTemplate(
            id: "script.template.archiveToOtherPanel",
            title: "Archive to Other Panel",
            // The `$DIRNEX_OTHER_DIR` lesson, and the reason its guard is load-bearing rather than
            // polite: with the variable unset (no second pane) the unguarded form expands to
            // `tar -czf /2026-07-26-120000.tgz`, which fails at the root of the disk with a message
            // naming a path the user never chose. The `echo` reaches the failure alert because the
            // runner surfaces stderr on a non-zero exit.
            command: """
            [ -n "$DIRNEX_OTHER_DIR" ] || { echo "No second panel to archive into." >&2; exit 1; }
            tar -czf "$DIRNEX_OTHER_DIR/$(date +%Y-%m-%d-%H%M%S).tgz" "$@"
            """,
            runMode: .combined,
            keywords: ["archive", "backup", "tar", "compress", "panel"]
        ),
        UserScriptTemplate(
            id: "script.template.imagesToJPEG",
            title: "Convert Images to JPEG",
            // The per-file transform PLAN.md §M6's exit criterion describes, with a tool every Mac
            // has instead of a Homebrew one. `${1%.*}` strips the extension, so `photo.heic` becomes
            // `photo.jpg` beside it and the original is left alone.
            //
            // On a *mixed* selection `sips` warns to stderr and exits **0** ("not a valid file -
            // skipping"), so a folder of images and notes converts the images and raises no alert.
            // That is the behavior we want, and it is `sips`'s choice rather than ours — worth
            // knowing before anyone "fixes" this into a loop that checks the type first.
            command: #"sips -s format jpeg "$1" --out "${1%.*}.jpg""#,
            runMode: .perFile,
            keywords: ["image", "photo", "convert", "jpeg", "jpg", "heic"]
        ),
        UserScriptTemplate(
            id: "script.template.resizeImages",
            title: "Resize Images to 1200 px",
            // Deliberately *not* in place. `sips -Z 1200 "$1"` overwrites the original, which is a
            // poor thing for a one-click example to do to someone's photographs; writing
            // `photo-1200.heic` beside it costs one more expansion (`${1##*.}` keeps the suffix) and
            // makes the template safe to try on real files.
            command: #"sips -Z 1200 "$1" --out "${1%.*}-1200.${1##*.}""#,
            runMode: .perFile,
            keywords: ["image", "photo", "resize", "scale", "thumbnail"]
        ),
        UserScriptTemplate(
            id: "script.template.removeQuarantine",
            title: "Remove Quarantine Flag",
            // `-dr` rather than `-d`, and not for the recursion: `xattr -d` exits **1** with "No such
            // xattr" on a file that was never quarantined, which would raise Dirnex's failure alert
            // for an ordinary selection. The recursive form exits 0 on the same input, which is what
            // makes this safe to run over a whole folder.
            command: #"xattr -dr com.apple.quarantine "$@""#,
            runMode: .combined,
            keywords: ["quarantine", "gatekeeper", "unblock", "download", "xattr"]
        )
    ]
}
