import Foundation
import Testing

@testable import DirnexCore

@Suite("ExternalTextEditor")
struct ExternalTextEditorTests {
    /// A LaunchServices stand-in: bundle identifier → install path, for the apps "installed".
    private func locate(_ installed: [String: String]) -> (String) -> String? {
        { installed[$0] }
    }

    private let textEditPath = "/System/Applications/TextEdit.app"

    private func textEditRef() -> ApplicationRef {
        ApplicationRef(
            bundlePath: textEditPath,
            displayName: "TextEdit",
            bundleIdentifier: "com.apple.TextEdit"
        )
    }

    @Test("an editor resolves to the first of its bundle identifiers that is installed")
    func resolvesInPreferenceOrder() {
        let editor = ExternalTextEditor(
            identifier: "demo",
            displayName: "Demo",
            bundleIdentifiers: ["com.demo.Stable", "com.demo.Insiders"]
        )
        let onlyInsiders = editor.application(
            locateBundle: locate(["com.demo.Insiders": "/Applications/Demo Insiders.app"])
        )
        #expect(onlyInsiders?.bundlePath == "/Applications/Demo Insiders.app")
        #expect(onlyInsiders?.bundleIdentifier == "com.demo.Insiders")

        let both = editor.application(
            locateBundle: locate([
                "com.demo.Stable": "/Applications/Demo.app",
                "com.demo.Insiders": "/Applications/Demo Insiders.app"
            ])
        )
        #expect(both?.bundlePath == "/Applications/Demo.app")
    }

    @Test("an editor carries our display name, not the bundle's, whichever channel resolved")
    func displayNameIsOurs() {
        let insiders = ["com.microsoft.VSCodeInsiders": "/Applications/Code - Insiders.app"]
        let insidersOnly = ExternalTextEditor.visualStudioCode
            .application(locateBundle: locate(insiders))
        #expect(insidersOnly?.displayName == "Visual Studio Code")
    }

    @Test("an uninstalled editor resolves to nil")
    func uninstalledResolvesToNil() {
        #expect(ExternalTextEditor.bbEdit.application(locateBundle: locate([:])) == nil)
    }

    @Test("every known editor has a unique identifier and at least one bundle identifier")
    func knownEditorsAreWellFormed() {
        let identifiers = ExternalTextEditor.known.map(\.identifier)
        #expect(Set(identifiers).count == identifiers.count)
        for editor in ExternalTextEditor.known {
            #expect(!editor.displayName.isEmpty)
            #expect(!editor.bundleIdentifiers.isEmpty)
        }
    }

    @Test("installed lists only the known editors present, in preference order")
    func installedFiltersAndOrders() {
        let installed = ExternalTextEditor.installed(
            locateBundle: locate([
                "com.apple.TextEdit": textEditPath,
                "com.barebones.bbedit": "/Applications/BBEdit.app",
                "com.microsoft.VSCode": "/Applications/Visual Studio Code.app"
            ])
        )
        #expect(installed.map(\.identifier) == ["bbedit", "vscode", "textedit"])
    }

    // MARK: - Resolution

    @Test("automatic resolves to the system's plain-text handler, not to our preference order")
    func automaticPrefersTheSystemHandler() {
        // BBEdit is installed and heads `known`, but the user has never chosen it — what a
        // double-click on a `.txt` does is what F4 must do.
        let resolved = ExternalTextEditor.resolve(
            identifier: nil,
            locateBundle: locate(["com.barebones.bbedit": "/Applications/BBEdit.app"]),
            defaultPlainTextApplication: textEditRef
        )
        #expect(resolved?.bundlePath == textEditPath)
    }

    @Test("an empty preference means automatic, the same as none")
    func emptyIdentifierIsAutomatic() {
        let resolved = ExternalTextEditor.resolve(
            identifier: "",
            locateBundle: locate([:]),
            defaultPlainTextApplication: textEditRef
        )
        #expect(resolved?.bundlePath == textEditPath)
    }

    @Test("a chosen, installed editor wins over the system handler")
    func chosenEditorWins() {
        let resolved = ExternalTextEditor.resolve(
            identifier: "vscode",
            locateBundle: locate(["com.microsoft.VSCode": "/Applications/Visual Studio Code.app"]),
            defaultPlainTextApplication: textEditRef
        )
        #expect(resolved?.displayName == "Visual Studio Code")
    }

    @Test("a chosen editor that is no longer installed falls back to automatic")
    func uninstalledChoiceFallsBackToAutomatic() {
        let resolved = ExternalTextEditor.resolve(
            identifier: "zed",
            locateBundle: locate([:]),
            defaultPlainTextApplication: textEditRef
        )
        #expect(resolved?.bundlePath == textEditPath)
    }

    @Test("an unknown persisted identifier falls back to automatic rather than failing")
    func unknownIdentifierFallsBackToAutomatic() {
        let resolved = ExternalTextEditor.resolve(
            identifier: "emacs-from-a-future-version",
            locateBundle: locate([:]),
            defaultPlainTextApplication: textEditRef
        )
        #expect(resolved?.bundlePath == textEditPath)
    }

    @Test("with no system handler, the first installed known editor is used")
    func noSystemHandlerFallsBackToPreferenceOrder() {
        let resolved = ExternalTextEditor.resolve(
            identifier: nil,
            locateBundle: locate([
                "com.apple.dt.Xcode": "/Applications/Xcode.app",
                "com.coteditor.CotEditor": "/Applications/CotEditor.app"
            ]),
            defaultPlainTextApplication: { nil }
        )
        #expect(resolved?.displayName == "CotEditor")
    }

    @Test("nothing installed and no system handler resolves to nil")
    func nothingResolvesToNil() {
        let resolved = ExternalTextEditor.resolve(
            identifier: nil,
            locateBundle: locate([:]),
            defaultPlainTextApplication: { nil }
        )
        #expect(resolved == nil)
    }
}
