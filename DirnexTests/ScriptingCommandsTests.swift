import DirnexCore
import Foundation
import Testing

@testable import Dirnex

/// The AppleScript automation surface (PLAN.md §M6 "Automation: AppleScript/Shortcuts verbs"). The
/// *decisions* — how a path becomes a reveal target, how an operation name resolves to a command id
/// — are `DirnexCore.Automation`'s and are tested there. What is left here is the fragile app-side
/// contract that lives half in Swift and half in `Dirnex.sdef`: the sdef references each handler by
/// its Objective-C class name *as a string*, so a rename that compiles cleanly would silently break
/// scripting. These tests pin that string bridge, plus the two Info.plist keys that make the app a
/// scriptable target at all.
@Suite("Scripting commands")
struct ScriptingCommandsTests {
    /// The bundle the handlers (and the `Dirnex.sdef` resource) ship in.
    private var appBundle: Bundle { Bundle(for: DirnexRevealScriptCommand.self) }

    @Test("each verb's @objc handler class exists and is an NSScriptCommand")
    func commandClassesResolve() throws {
        let names = [
            "DirnexRevealScriptCommand",
            "DirnexCopySelectionScriptCommand",
            "DirnexRunOperationScriptCommand"
        ]
        for name in names {
            let cls = try #require(NSClassFromString(name), "missing scripting class \(name)")
            #expect(cls is NSScriptCommand.Type, "\(name) is not an NSScriptCommand subclass")
        }
    }

    @Test("Info.plist enables AppleScript and points at the sdef")
    func infoPlistScriptingKeys() {
        #expect(appBundle.object(forInfoDictionaryKey: "NSAppleScriptEnabled") as? Bool == true)
        #expect(
            appBundle.object(forInfoDictionaryKey: "OSAScriptingDefinition") as? String
                == "Dirnex.sdef"
        )
    }

    @Test("every sdef <cocoa class> resolves to a real NSScriptCommand subclass")
    func sdefClassesResolve() throws {
        let nodes = try sdefNodes(forXPath: "//command/cocoa/@class")
        #expect(!nodes.isEmpty, "the sdef declares no command classes")
        for node in nodes {
            let name = try #require(node.stringValue)
            let cls = try #require(NSClassFromString(name), "sdef names unknown class \(name)")
            #expect(cls is NSScriptCommand.Type, "sdef class \(name) is not an NSScriptCommand")
        }
    }

    @Test("the sdef's command names are exactly the AutomationVerb set")
    func sdefCommandNamesMatchVerbs() throws {
        let names = try sdefNodes(forXPath: "//command/@name").compactMap(\.stringValue)
        #expect(Set(names) == Set(AutomationVerb.allCases.map(\.commandName)))
    }

    /// Nodes matching `xpath` in the bundled `Dirnex.sdef`. External entities (the system sdef DTD)
    /// are never loaded, so the test needs nothing off the machine's own bundle.
    private func sdefNodes(forXPath xpath: String) throws -> [XMLNode] {
        let url = try #require(
            appBundle.url(forResource: "Dirnex", withExtension: "sdef"),
            "Dirnex.sdef is not in the app bundle"
        )
        let document = try XMLDocument(contentsOf: url, options: [.nodeLoadExternalEntitiesNever])
        return try document.nodes(forXPath: xpath)
    }
}
