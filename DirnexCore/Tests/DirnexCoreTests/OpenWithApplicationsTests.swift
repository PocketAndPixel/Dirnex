import Foundation
import Testing

@testable import DirnexCore

@Suite("OpenWithApplications")
struct OpenWithApplicationsTests {
    // MARK: - Fixtures

    private let textEdit = ApplicationRef(
        bundlePath: "/System/Applications/TextEdit.app",
        displayName: "TextEdit",
        bundleIdentifier: "com.apple.TextEdit"
    )
    private let preview = ApplicationRef(
        bundlePath: "/System/Applications/Preview.app",
        displayName: "Preview"
    )
    private let safari = ApplicationRef(
        bundlePath: "/Applications/Safari.app",
        displayName: "Safari"
    )
    private let chrome = ApplicationRef(
        bundlePath: "/Applications/Google Chrome.app",
        displayName: "Google Chrome"
    )

    /// A LaunchServices stand-in: which apps open which type, and each type's default.
    private struct Probe {
        var types: [String: String] = [:]
        var apps: [String: [ApplicationRef]] = [:]
        var defaults: [String: ApplicationRef] = [:]

        func candidates(for paths: [String]) -> OpenWithCandidates {
            OpenWithApplications.candidates(
                for: paths,
                typeOf: { types[$0] },
                applications: { apps[$0] ?? [] },
                defaultApplication: { defaults[$0] }
            )
        }
    }

    private func textAndImageProbe() -> Probe {
        Probe(
            types: [
                "/a.txt": "public.plain-text",
                "/b.txt": "public.plain-text",
                "/c.png": "public.png"
            ],
            apps: [
                "public.plain-text": [textEdit, safari, chrome],
                "public.png": [preview, safari, chrome]
            ],
            defaults: ["public.plain-text": textEdit, "public.png": preview]
        )
    }

    // MARK: - The list

    @Test("a single file offers its default first, then the rest by name")
    func singleFile() {
        let result = textAndImageProbe().candidates(for: ["/a.txt"])
        #expect(result.defaultApplication == textEdit)
        #expect(result.others == [chrome, safari])
        #expect(result.all.map(\.displayName) == ["TextEdit", "Google Chrome", "Safari"])
    }

    @Test("the default is never repeated among the others")
    func defaultNotDuplicated() {
        let result = textAndImageProbe().candidates(for: ["/a.txt"])
        #expect(!result.others.contains(textEdit))
    }

    @Test("a mixed selection offers only the apps that open every item")
    func mixedSelectionIntersects() {
        let result = textAndImageProbe().candidates(for: ["/a.txt", "/c.png"])
        // TextEdit can't open the png and Preview can't open the text, so neither is offered.
        #expect(result.all == [chrome, safari])
    }

    @Test("a mixed selection whose types disagree on the default promotes nothing")
    func mixedSelectionHasNoDefault() {
        let result = textAndImageProbe().candidates(for: ["/a.txt", "/c.png"])
        #expect(result.defaultApplication == nil)
    }

    @Test("files of one type keep that type's default")
    func homogeneousSelectionKeepsDefault() {
        let result = textAndImageProbe().candidates(for: ["/a.txt", "/b.txt"])
        #expect(result.defaultApplication == textEdit)
        #expect(result.others == [chrome, safari])
    }

    @Test("a unanimous default survives a mixed selection")
    func unanimousDefaultAcrossTypes() {
        var probe = textAndImageProbe()
        probe.defaults["public.png"] = textEdit
        probe.apps["public.png"] = [textEdit, safari, chrome]
        let result = probe.candidates(for: ["/a.txt", "/c.png"])
        #expect(result.defaultApplication == textEdit)
    }

    @Test("a default that no longer opens every item is not promoted")
    func defaultMustSurviveIntersection() {
        var probe = textAndImageProbe()
        // Both types name TextEdit the default, but it cannot open the png.
        probe.defaults["public.png"] = textEdit
        let result = probe.candidates(for: ["/a.txt", "/c.png"])
        #expect(result.defaultApplication == nil)
        #expect(result.all == [chrome, safari])
    }

    // MARK: - Nothing to offer

    @Test("an empty selection offers nothing")
    func emptySelection() {
        #expect(textAndImageProbe().candidates(for: []).isEmpty)
    }

    @Test("a file macOS cannot type collapses the whole answer")
    func untypeableItemOffersNothing() {
        let probe = textAndImageProbe()
        // A vanished file, or one with an extension nothing claims.
        #expect(probe.candidates(for: ["/gone.zzz"]).isEmpty)
        #expect(probe.candidates(for: ["/a.txt", "/gone.zzz"]).isEmpty)
    }

    @Test("a type nothing opens offers nothing")
    func unopenableTypeOffersNothing() {
        var probe = textAndImageProbe()
        probe.types["/weird.zzzqqq"] = "dyn.unknown"
        #expect(probe.candidates(for: ["/weird.zzzqqq"]).isEmpty)
        #expect(probe.candidates(for: ["/a.txt", "/weird.zzzqqq"]).isEmpty)
    }

    @Test("a selection with no app in common offers nothing")
    func disjointSelectionOffersNothing() {
        var probe = textAndImageProbe()
        probe.apps["public.plain-text"] = [textEdit]
        probe.apps["public.png"] = [preview]
        #expect(probe.candidates(for: ["/a.txt", "/c.png"]).isEmpty)
    }

    // MARK: - Shape

    @Test("two copies of one app are both offered, ordered stably")
    func duplicateAppNamesAreBothKept() {
        let beta = ApplicationRef(bundlePath: "/Applications/Beta/Safari.app", displayName: "Safari")
        var probe = textAndImageProbe()
        probe.apps["public.plain-text"] = [textEdit, safari, beta]
        let result = probe.candidates(for: ["/a.txt"])
        // Same name, so the bundle path breaks the tie — and keeps the menu from reshuffling.
        #expect(result.others == [beta, safari])
    }

    @Test("the same app listed twice for a type appears once")
    func repeatedAppAppearsOnce() {
        var probe = textAndImageProbe()
        probe.apps["public.plain-text"] = [textEdit, safari, safari]
        let result = probe.candidates(for: ["/a.txt"])
        #expect(result.others == [safari])
    }

    // MARK: - Cost

    @Test("LaunchServices is asked once per distinct type, not once per file")
    func asksOncePerDistinctType() {
        // The lever the design rests on: a thousand marked photos must cost one question. Measured
        // live, asking what opens a file costs ~25x reading its type, so this is the whole budget.
        final class Counter: @unchecked Sendable {
            var appCalls: [String] = []
            var defaultCalls: [String] = []
        }
        let counter = Counter()
        let paths = (0..<500).map { "/photo\($0).png" } + ["/a.txt"]
        let result = OpenWithApplications.candidates(
            for: paths,
            typeOf: { $0.hasSuffix(".png") ? "public.png" : "public.plain-text" },
            applications: {
                counter.appCalls.append($0)
                return [safari, chrome]
            },
            defaultApplication: {
                counter.defaultCalls.append($0)
                return safari
            }
        )
        #expect(counter.appCalls == ["public.png", "public.plain-text"])
        #expect(counter.defaultCalls == ["public.png", "public.plain-text"])
        #expect(result.defaultApplication == safari)
        #expect(result.others == [chrome])
    }

    @Test("an empty intersection stops asking about later types")
    func stopsAskingOnceNothingIsLeft() {
        final class Counter: @unchecked Sendable {
            var calls: [String] = []
        }
        let counter = Counter()
        let apps: [String: [ApplicationRef]] = ["a": [textEdit], "b": [preview], "c": [safari]]
        _ = OpenWithApplications.candidates(
            for: ["/1", "/2", "/3"],
            typeOf: { ["/1": "a", "/2": "b", "/3": "c"][$0] },
            applications: {
                counter.calls.append($0)
                return apps[$0] ?? []
            },
            defaultApplication: { _ in nil }
        )
        // "a" and "b" already share nothing; "c" cannot change that, so it is never asked.
        #expect(counter.calls == ["a", "b"])
    }
}
