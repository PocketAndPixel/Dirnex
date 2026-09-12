// Show in Finder and the cloud pair live in this companion file for the reason
// `CommandCatalogCategories.swift` does: `CommandCatalog.swift` sits at SwiftLint's `type_body_length`.
// They are File commands about where an item *lives* — on this disk, and whether its bytes are — so
// `all` composes them in straight after `file`, and the menu bar places them by its own layout.
extension CommandCatalog {
    // MARK: - File ▸ where an item lives

    static let fileLocation: [Command] = [
        Command(
            id: "file.showInFinder",
            title: "Show in Finder",
            category: .file,
            // Apple's own wording for the gesture — Xcode, Safari's downloads and Photos all say it —
            // and the way to everything Finder's menu offers that Dirnex cannot, such as a cloud
            // provider's own actions.
            keywords: ["reveal", "finder", "locate", "show", "open in finder"]
        ),
        Command(
            id: "file.downloadNow",
            title: "Download Now",
            category: .file,
            // Finder's title for the same act. The providers are named because a user who wants a
            // Dropbox file kept on this Mac types "dropbox", not "materialize".
            keywords: [
                "download", "offline", "keep", "cloud", "icloud", "dropbox", "onedrive", "box",
                "google drive", "placeholder", "materialize"
            ]
        ),
        Command(
            id: "file.removeDownload",
            title: "Remove Download",
            category: .file,
            // Finder's title; each provider calls the same thing something else ("Make Online-Only",
            // "Free Up Space", "Make Available Online Only"), so those phrasings are the keywords.
            keywords: [
                "evict", "online only", "online-only", "free up space", "offload", "cloud",
                "icloud",
                "dropbox", "onedrive", "box", "google drive", "local copy"
            ]
            // No shortcut for either: they are occasional, and the right-click is where they are
            // looked for — beside Open With, where Finder puts Remove Download.
        )
    ]
}
