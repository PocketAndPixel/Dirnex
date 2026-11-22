import Foundation
import Testing

@testable import DirnexCore

/// The stock tags are the account's own: Finder's favorites, in the colors the system gives them
/// (PLAN.md §M40 Slice 6). The lists below are the ones read off real accounts that day: the CI
/// VM's US-English one (Gray), this Mac's (Grey), and one made under German.
@Suite("FinderStockTags")
struct FinderStockTagsTests {
    private static let germanFavorites = [
        "",
        "Rot",
        "Orange",
        "Gelb",
        "Grün",
        "Blau",
        "Lila",
        "Grau"
    ]

    /// What `NSURLTagNamesKey` answered for the German list, in the order it was asked.
    private static let germanColors: [FinderTag] = zip(
        germanFavorites.dropFirst(),
        FinderTagColor.displayOrder
    ).map { FinderTag(name: $0, color: $1) }

    private var german: FinderStockTags {
        FinderStockTags(favoriteNames: Self.germanFavorites, coloredAs: Self.germanColors)
    }

    // MARK: - From Finder's favorites

    @Test("Finder's favorites are the stock tags, in its order, the empty first entry skipped")
    func favoritesBecomeTheStockTags() {
        #expect(german.tags.map(\.name) == ["Rot", "Orange", "Gelb", "Grün", "Blau", "Lila", "Grau"])
        #expect(german.tags.map(\.color) == FinderTagColor.displayOrder)

        let usEnglish = FinderStockTags(
            favoriteNames: ["", "Red", "Orange", "Yellow", "Green", "Blue", "Purple", "Gray"],
            coloredAs: [FinderTag(name: "Gray", color: .gray), FinderTag(name: "Red", color: .red)]
        )
        #expect(usEnglish.tags.last == FinderTag(name: "Gray", color: .gray))
        #expect(usEnglish.contains(FinderTag(name: "gray")))
        #expect(!usEnglish.contains(FinderTag(name: "Grey")))
    }

    /// The probe's `Zebrafink`: a favorite the account's list has no color for draws hollow in
    /// Finder, and a name the lookup left out is no better known.
    @Test("a favorite the lookup did not color is colorless")
    func uncoloredFavorite() {
        let stock = FinderStockTags(
            favoriteNames: ["", "Rot", "Zebrafink", "Unasked"],
            coloredAs: [FinderTag(name: "Rot", color: .red), FinderTag(name: "Zebrafink")]
        )
        #expect(stock.tags.map(\.color) == [.red, .none, .none])
    }

    @Test("a repeated favorite is offered once, in its first spelling")
    func repeatedFavorite() {
        let stock = FinderStockTags(
            favoriteNames: ["Rot", "rot", "ROT"],
            coloredAs: [FinderTag(name: "Rot", color: .red)]
        )
        #expect(stock.tags == [FinderTag(name: "Rot")])
        #expect(stock.tags.first?.name == "Rot")
        #expect(stock.tags.first?.color == .red)
    }

    /// The preference and the attribute need not spell `Grün` with the same code points, and a
    /// lookup answer in other case is still the same tag.
    @Test("the colors match by name, whatever the case or the Unicode form")
    func matchingIgnoresCaseAndNormalization() {
        let stock = FinderStockTags(
            favoriteNames: ["Gr\u{00FC}n", "BLAU"],
            coloredAs: [
                FinderTag(name: "Gru\u{0308}n", color: .green),
                FinderTag(name: "blau", color: .blue)
            ]
        )
        #expect(stock.tags.map(\.color) == [.green, .blue])
        #expect(stock.tags.map(\.name) == ["Gr\u{00FC}n", "BLAU"])
    }

    @Test("an empty favorites list offers no stock tags")
    func emptyFavorites() {
        #expect(FinderStockTags(favoriteNames: [""], coloredAs: []).tags.isEmpty)
    }

    @Test("the fallback is the seven English names, and this process starts on it")
    func fallback() {
        #expect(FinderStockTags.fallback.tags.map(\.name) == [
            "Red", "Orange", "Yellow", "Green", "Blue", "Purple", "Grey"
        ])
        #expect(FinderStockTags.fallback.tags.map(\.color) == FinderTagColor.displayOrder)
        // Nothing in the core sets it; the app does, at launch.
        #expect(FinderStockTags.current == .fallback)
        #expect(FinderTag.systemTags == FinderStockTags.fallback.tags)
    }

    // MARK: - The index on another account's set

    @Test("an index seeded with a German set lists and protects the German names")
    func germanIndex() {
        var index = FinderTagIndex(stock: german)
        #expect(index.tags.map(\.name) == german.tags.map(\.name))

        // An iCloud file's `Rot\n1` says nothing about Rot.
        index.learn(FinderTag(name: "Rot", color: .gray))
        #expect(index.resolve(FinderTag(name: "Rot", color: .gray)).color == .red)

        // On this account English `Red` is a tag of its own, found on files and listed after.
        index.learn(FinderTag(name: "Red", color: .red))
        #expect(index.tags.map(\.name) == german.tags.map(\.name) + ["Red"])

        index.forget(FinderTag(name: "Rot"))
        #expect(index.tags.map(\.name).contains("Rot"))
        index.forget(FinderTag(name: "Red"))
        #expect(!index.names.contains("Red"))
    }

    // MARK: - The lookup, on this account

    /// Against the real system: the point of the lookup is what macOS answers, so a fake would only
    /// say back what this file assumes. Whatever language the account's list was made in, a list
    /// still in Finder's default shape is the seven colors in Finder's order.
    @Test("the lookup colors this account's favorites and leaves no file behind")
    func lookupOnThisAccount() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        guard let names = FinderStockTagLookup.favoriteNames() else { return }
        let colored = try FinderStockTagLookup.colors(of: names, in: tree.root)

        let asked = names.filter { !$0.isEmpty }
        #expect(colored.map(\.name) == asked)
        if Set(asked.map { $0.lowercased() }).count == 7 {
            #expect(colored.map(\.color) == FinderTagColor.displayOrder, "\(asked)")
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: tree.root.path).isEmpty)

        #expect(
            FinderStockTagLookup.forThisAccount(scratchDirectory: tree.root)
                == FinderStockTags(favoriteNames: names, coloredAs: colored)
        )
    }

    @Test("no names asks nothing, and a lookup that cannot write falls back")
    func lookupEdges() throws {
        let missing = URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)")
        #expect(try FinderStockTagLookup.colors(of: ["", ""], in: missing).isEmpty)
        #expect(throws: (any Error).self) {
            try FinderStockTagLookup.colors(of: ["Red"], in: missing)
        }
        #expect(FinderStockTagLookup.forThisAccount(scratchDirectory: missing) == .fallback)
    }
}
