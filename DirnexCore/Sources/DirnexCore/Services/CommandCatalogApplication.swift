// The Application category (the App menu's commands) lives in its own companion file for the reason
// `CommandCatalogCategories.swift` does: the licensing pair (PLAN.md §M29) took that file past
// SwiftLint's `file_length`. `all`, in the main file, still composes it in last.
extension CommandCatalog {
    // MARK: - Application

    static let application: [Command] = [
        Command(
            id: "app.settings",
            title: "Settings…",
            category: .application,
            keywords: ["preferences", "options", "shortcuts", "config"],
            shortcut: CommandShortcut(key: ",", modifiers: .command)
        ),
        Command(
            id: "app.fullDiskAccess",
            title: "Full Disk Access…",
            category: .application,
            keywords: ["permission", "privacy", "security", "access", "disk", "grant", "onboarding"]
        ),
        Command(
            id: "app.showTour",
            title: "Welcome to Dirnex…",
            category: .application,
            keywords: ["tour", "welcome", "guide", "intro", "onboarding", "help", "getting started"]
        ),
        Command(
            id: "app.checkForUpdates",
            title: "Check for Updates…",
            category: .application,
            keywords: ["update", "upgrade", "sparkle", "version", "release", "new"]
        ),
        // The two licensing commands (PLAN.md §M29). They exist in every build's registry, and the
        // app hides them wherever this build shows nothing about licenses (`licensingCommandIDs`).
        Command(
            id: "app.license",
            title: "License…",
            category: .application,
            keywords: [
                "license", "licence", "key", "activate", "register", "registration", "serial",
                "unlock", "renew"
            ]
        ),
        Command(
            id: "app.buyLicense",
            title: "Buy a License…",
            category: .application,
            keywords: [
                "buy",
                "purchase",
                "order",
                "store",
                "shop",
                "price",
                "pay",
                "support",
                "licence"
            ]
        ),
        Command(
            id: "app.quit",
            title: "Quit Dirnex",
            category: .application,
            keywords: ["exit"],
            shortcut: CommandShortcut(key: "q", modifiers: .command)
        )
    ]
}
