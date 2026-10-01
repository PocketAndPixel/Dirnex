// The Help category (PLAN.md §M30) lives in its own companion file, as the Application category
// does, so `CommandCatalogApplication.swift` stays about the App menu.
extension CommandCatalog {
    // MARK: - Help

    static let help: [Command] = [
        // Hidden in a build without a bug-report address (`bugReportCommandIDs`).
        Command(
            id: "help.reportBug",
            title: "Report a Bug…",
            category: .help,
            keywords: [
                "bug",
                "report",
                "problem",
                "issue",
                "crash",
                "feedback",
                "support",
                "contact"
            ]
        ),
        Command(
            id: "help.website",
            title: "Dirnex Website",
            category: .help,
            keywords: ["website", "web", "site", "home page", "homepage", "dirnex.app"]
        ),
        Command(
            id: "help.releaseNotes",
            title: "Release Notes",
            category: .help,
            keywords: ["release notes", "changes", "changelog", "what's new", "version", "history"]
        )
    ]
}
