import Foundation
import Testing

@testable import DirnexCore

@Suite("FinderTagColor")
struct FinderTagColorTests {
    /// The mapping is the whole point of the type and the easiest thing to get subtly wrong, so it
    /// is pinned outright. These indices are not a guess: each was read back off a real file after
    /// letting macOS assign the colour itself from the bare tag name.
    @Test("colour indices are the ones macOS actually assigns")
    func indices() {
        #expect(FinderTagColor.none.rawValue == 0)
        #expect(FinderTagColor.grey.rawValue == 1)
        #expect(FinderTagColor.green.rawValue == 2)
        #expect(FinderTagColor.purple.rawValue == 3)
        #expect(FinderTagColor.blue.rawValue == 4)
        #expect(FinderTagColor.yellow.rawValue == 5)
        #expect(FinderTagColor.red.rawValue == 6)
        #expect(FinderTagColor.orange.rawValue == 7)
    }

    /// Guards against "fixing" these indices into Finder's `FavoriteTagNames` display order, which
    /// runs Red, Orange, Yellow, Green, Blue, Purple, Grey and looks far more like a sensible
    /// enumeration than the real thing does.
    @Test("indices are not Finder's display order")
    func notDisplayOrder() {
        #expect(FinderTagColor.displayOrder.map(\.rawValue) != Array(1...7))
    }

    /// The order itself, pinned: it is what the sidebar and the tag menu list, and the whole reason
    /// it exists is that reaching for `allCases` instead is both easy and wrong.
    @Test("display order is Finder's rainbow, and covers every colour exactly once")
    func displayOrder() {
        #expect(
            FinderTagColor.displayOrder == [.red, .orange, .yellow, .green, .blue, .purple, .grey]
        )
        // Every real colour, none twice, and never `.none` — which is a stored value, not a choice.
        #expect(Set(FinderTagColor.displayOrder).count == FinderTagColor.displayOrder.count)
        #expect(
            Set(FinderTagColor.displayOrder) == Set(FinderTagColor.allCases).subtracting([.none])
        )
    }

    @Test("every colour but none names a stock system tag")
    func systemTagNames() {
        #expect(FinderTagColor.none.systemTagName == nil)
        #expect(FinderTagColor.red.systemTagName == "Red")
        #expect(FinderTagColor.grey.systemTagName == "Grey")
        for color in FinderTagColor.allCases where color != .none {
            #expect(color.systemTagName != nil)
        }
    }
}

@Suite("FinderTag")
struct FinderTagTests {
    // MARK: - The stock tags

    @Test("the stock tags are the seven system ones, in Finder's order, each in its own colour")
    func systemTags() {
        #expect(FinderTag.systemTags.map(\.name) == [
            "Red", "Orange", "Yellow", "Green", "Blue", "Purple", "Grey"
        ])
        #expect(FinderTag.systemTags.map(\.color) == FinderTagColor.displayOrder)
        // Each carries the colour it is named after — the property that lets the sidebar draw a
        // swatch from the tag alone.
        for tag in FinderTag.systemTags {
            #expect(tag.color.systemTagName == tag.name)
        }
    }

    /// The gate on Delete Tag: a custom tag can be deleted (strip it off its carriers and it is
    /// gone), a stock one cannot (`systemTags` is a constant — it would be back on the next
    /// rebuild). It rides on `==`, so it folds case and ignores colour like every other identity
    /// question here.
    @Test("the stock seven are system tags, by name, whatever their case or colour")
    func systemTagMembership() {
        for tag in FinderTag.systemTags {
            #expect(tag.isSystem)
        }
        #expect(FinderTag(name: "red").isSystem)
        #expect(FinderTag(name: "RED", color: .blue).isSystem)
        #expect(!FinderTag(name: "Urgent", color: .red).isSystem)
        #expect(!FinderTag(name: "Work").isSystem)
        // `Grey` is a stock name and `Gray` is not — the same spelling trap `systemTagName` carries.
        #expect(FinderTag(name: "Grey").isSystem)
        #expect(!FinderTag(name: "Gray").isSystem)
    }

    // MARK: - Identity

    /// macOS folds case to identify a tag while storing the user's spelling: writing `red` stores
    /// the name `red` but resolves it to Red's colour 6. So case-insensitive identity is the
    /// system's rule, not a convenience.
    @Test("identity is the name, case-insensitively")
    func caseInsensitiveIdentity() {
        #expect(FinderTag(name: "Work") == FinderTag(name: "work"))
        #expect(FinderTag(name: "Work").hashValue == FinderTag(name: "WORK").hashValue)
        #expect(FinderTag(name: "Work") != FinderTag(name: "Works"))
    }

    /// A file holding one name in two colours is malformed, not two tags — so the colour must stay
    /// out of identity, or a `Set` would keep both and the column would render the name twice.
    @Test("colour is not part of identity")
    func colorExcludedFromIdentity() {
        #expect(FinderTag(name: "Work", color: .red) == FinderTag(name: "Work", color: .blue))
        #expect(
            Set([FinderTag(name: "Work", color: .red), FinderTag(name: "work", color: .blue)]).count == 1
        )
    }

    // MARK: - Parsing

    @Test("the ordinary two-field form")
    func parsesNameAndColor() {
        let tag = FinderTag(storedString: "Red\n6")
        #expect(tag?.name == "Red")
        #expect(tag?.color == .red)
    }

    /// The system emits `Zebra\n0` for a colourless tag, but a bare name with no newline at all
    /// round-trips through its own reader, so both must parse.
    @Test("a colourless tag, spelled either way")
    func parsesColorless() {
        #expect(FinderTag(storedString: "Zebra\n0")?.color == FinderTagColor.none)
        #expect(FinderTag(storedString: "Zebra\n0")?.name == "Zebra")
        #expect(FinderTag(storedString: "Plainname")?.color == FinderTagColor.none)
        #expect(FinderTag(storedString: "Plainname")?.name == "Plainname")
    }

    /// The three-field shape is real: passing an already-suffixed `Red\n6` to the system's own
    /// setter makes it treat the whole string as a name and append its lookup, storing `Red\n6\n0`.
    /// The system reads that back as plain `Red`, so this must too.
    @Test("a stray third field is ignored, as the system ignores it")
    func parsesThreeFieldForm() {
        let tag = FinderTag(storedString: "Red\n6\n0")
        #expect(tag?.name == "Red")
        #expect(tag?.color == .red)
    }

    /// The name is what carries meaning; a nonsense colour byte should cost the colour, not the tag.
    @Test("a malformed colour degrades to none rather than dropping the tag")
    func malformedColorDegrades() {
        #expect(FinderTag(storedString: "Work\nrubbish")?.color == FinderTagColor.none)
        #expect(FinderTag(storedString: "Work\nrubbish")?.name == "Work")
        #expect(FinderTag(storedString: "Work\n99")?.color == FinderTagColor.none)
        #expect(FinderTag(storedString: "Work\n-1")?.color == FinderTagColor.none)
        #expect(FinderTag(storedString: "Work\n99")?.name == "Work")
    }

    @Test("an empty name is not a tag")
    func emptyNameRejected() {
        #expect(FinderTag(storedString: "") == nil)
        #expect(FinderTag(storedString: "\n6") == nil)
    }

    // MARK: - Serializing

    /// The colour field is always written, `\n0` included, because that is what the system emits.
    @Test("round-trips through the stored spelling")
    func roundTrips() {
        #expect(FinderTag(name: "Red", color: .red).storedString == "Red\n6")
        #expect(FinderTag(name: "Zebra").storedString == "Zebra\n0")
        for color in FinderTagColor.allCases {
            let tag = FinderTag(name: "Sample", color: color)
            let reparsed = FinderTag(storedString: tag.storedString)
            #expect(reparsed?.name == "Sample")
            #expect(reparsed?.color == color)
        }
    }

    /// Swift's `String` compares and hashes by canonical equivalence, so a decomposed name off the
    /// filesystem matches a precomposed one out of an attribute for free — the same property pass 1
    /// found load-bearing for Git paths, and worth pinning here for the same reason: it would need
    /// explicit normalization in any byte-keyed language.
    @Test("a decomposed name matches its precomposed spelling")
    func unicodeEquivalence() {
        let decomposed = "cafe\u{0301}"
        let precomposed = "café"
        #expect(decomposed.unicodeScalars.count != precomposed.unicodeScalars.count) // genuinely different bytes
        #expect(FinderTag(name: decomposed) == FinderTag(name: precomposed))
        #expect(FinderTag(storedString: "\(decomposed)\n6") == FinderTag(name: precomposed))
    }
}

@Suite("FinderTagPayload")
struct FinderTagPayloadTests {
    private func payload(_ list: Any) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: list, format: .binary, options: 0)
    }

    /// The golden fixture: the exact bytes macOS wrote for a file tagged `Red` plus a custom
    /// colourless `Important`, captured off a real tagged file rather than constructed here. If the
    /// stored format is ever not what this pass measured, this is the test that says so.
    @Test("decodes the real bytes macOS writes")
    func decodesCapturedBytes() throws {
        // bplist00 array of ["Red\n6", "Important\n0"] — the literal bytes macOS 26 wrote for a file
        // tagged Red + Important through URLResourceValues.tagNames, read straight back out.
        let captured = Data(
            base64Encoded: "YnBsaXN0MDCiAQJVUmVkCjZbSW1wb3J0YW50CjAICxEAAAAAAAABAQAAAAAAAAADAAAAAAAAAAAAAAAAAAAAHQ=="
        )
        let tags = FinderTagPayload.decode(try #require(captured))
        #expect(tags == [FinderTag(name: "Red"), FinderTag(name: "Important")])
        #expect(tags.map(\.color) == [.red, FinderTagColor.none])
    }

    @Test("stored order is preserved")
    func preservesOrder() throws {
        let tags = FinderTagPayload.decode(try payload(["Zebra\n3", "Red\n6", "Apple\n2"]))
        #expect(tags.map(\.name) == ["Zebra", "Red", "Apple"])
    }

    /// The system does not dedupe on write — `tagNames = ["Red", "Red"]` genuinely stores Red
    /// twice — so a file can arrive holding a repeat, and a column rendering it twice looks broken.
    @Test("a repeated tag collapses, first spelling winning")
    func dedupesOnDecode() throws {
        let tags = FinderTagPayload.decode(try payload(["Red\n6", "red\n6", "Work\n0"]))
        #expect(tags.map(\.name) == ["Red", "Work"])
    }

    /// One unusable row must not blank the whole cell — the call `GitStatusParser` makes.
    @Test("a malformed entry is skipped, not thrown on")
    func skipsMalformedEntries() throws {
        let tags = FinderTagPayload.decode(try payload(["Red\n6", "", "Work\n0"]))
        #expect(tags.map(\.name) == ["Red", "Work"])
    }

    /// The attribute belonging to someone else is not an error to report, just nothing to show.
    @Test("a payload that isn't a string array yields nothing")
    func foreignPayloadYieldsNothing() throws {
        #expect(FinderTagPayload.decode(Data()).isEmpty)
        #expect(FinderTagPayload.decode(Data("not a plist".utf8)).isEmpty)
        let numbers = try payload([1, 2])
        #expect(FinderTagPayload.decode(numbers).isEmpty)
    }

    @Test("encode round-trips through decode")
    func encodeRoundTrips() throws {
        let tags = [FinderTag(name: "Red", color: .red), FinderTag(name: "my tag", color: .purple)]
        #expect(FinderTagPayload.decode(try FinderTagPayload.encode(tags)) == tags)
    }

    @Test("encode collapses duplicates the system would happily store")
    func encodeDedupes() throws {
        let data = try FinderTagPayload.encode([FinderTag(name: "Red"), FinderTag(name: "RED")])
        #expect(FinderTagPayload.decode(data).count == 1)
    }

    @Test("encode writes the binary plist the system reads")
    func encodeWritesBinaryPlist() throws {
        let data = try FinderTagPayload.encode([FinderTag(name: "Red", color: .red)])
        var format = PropertyListSerialization.PropertyListFormat.xml
        let list = try PropertyListSerialization.propertyList(from: data, format: &format)
        #expect(format == .binary)
        #expect(list as? [String] == ["Red\n6"])
    }

    // MARK: - The legacy label

    /// All four cases were read off real files. The rule is last-coloured-wins, and every plausible
    /// alternative — first, lowest — is wrong on at least one of them.
    @Test("the legacy label is the last coloured tag's index")
    func legacyLabelLastColorWins() {
        #expect(
            FinderTagPayload.legacyLabel(
                for: [FinderTag(name: "Green", color: .green), FinderTag(name: "Red", color: .red)]
            ) == 6
        )
        #expect(
            FinderTagPayload.legacyLabel(
                for: [FinderTag(name: "Red", color: .red), FinderTag(name: "Orange", color: .orange)]
            ) == 7
        )
        #expect(
            FinderTagPayload.legacyLabel(
                for: [FinderTag(name: "Orange", color: .orange), FinderTag(name: "Red", color: .red)]
            ) == 6
        )
    }

    /// A trailing colourless tag must not clear the label — the system skips past it.
    @Test("a colourless tag does not clear the label")
    func legacyLabelSkipsColorless() {
        #expect(
            FinderTagPayload.legacyLabel(
                for: [FinderTag(name: "Blue", color: .blue), FinderTag(name: "Zebra")]
            ) == 4
        )
        #expect(
            FinderTagPayload.legacyLabel(
                for: [FinderTag(name: "Zebra"), FinderTag(name: "Blue", color: .blue)]
            ) == 4
        )
    }

    @Test("no colours anywhere means no label")
    func legacyLabelNone() {
        #expect(FinderTagPayload.legacyLabel(for: []) == 0)
        #expect(
            FinderTagPayload.legacyLabel(for: [FinderTag(name: "Zebra"), FinderTag(name: "Work")]) == 0
        )
    }
}

@Suite("FinderTagIndex")
struct FinderTagIndexTests {
    /// The bug this type exists for, in one test: iCloud stores `Red\n1` on every tagged file in the
    /// drive — Finder's own UI does it too — and the dot must still come out red.
    @Test("a stock tag mangled by iCloud still resolves to its real colour")
    func resolvesStockTagNormalizedByICloud() {
        let index = FinderTagIndex()
        #expect(index.resolve(FinderTag(name: "Red", color: .grey)).color == .red)
        #expect(index.resolve(FinderTag(name: "Blue", color: .grey)).color == .blue)
        // Colour 1 is not special-cased: any wrong byte on a stock name loses to the name.
        #expect(index.resolve(FinderTag(name: "Green", color: .orange)).color == .green)
    }

    /// The system folds case to identify a tag, so a file spelling it `red` gets Red's colour — and
    /// keeps its own spelling, because that half belongs to the user.
    @Test("resolution is case-insensitive and preserves the file's spelling")
    func resolvePreservesSpelling() {
        let resolved = FinderTagIndex().resolve(FinderTag(name: "red", color: .grey))
        #expect(resolved.name == "red")
        #expect(resolved.color == .red)
    }

    /// A name nothing knows about keeps its stored colour: it is the only evidence there is, and off
    /// iCloud it is the right one.
    @Test("an unknown name keeps the colour the file carries")
    func resolveUnknownName() {
        #expect(FinderTagIndex().resolve(FinderTag(name: "Zebra", color: .purple)).color == .purple)
        #expect(FinderTagIndex().resolve(FinderTag(name: "Zebra")).color == .none)
    }

    /// Red is 6 because `systemTags` says so. A file claiming otherwise is describing iCloud.
    @Test("a sighting never overwrites a stock tag")
    func learnRefusesStockTags() {
        var index = FinderTagIndex()
        index.learn(FinderTag(name: "Red", color: .grey))
        index.learn(FinderTag(name: "red", color: .none))
        #expect(index.resolve(FinderTag(name: "Red", color: .grey)).color == .red)
        #expect(index.tags.count == FinderTag.systemTags.count)
    }

    @Test("a custom name is learned from a sighting")
    func learnCustomTag() {
        var index = FinderTagIndex()
        index.learn(FinderTag(name: "Zebra", color: .purple))
        #expect(index.resolve(FinderTag(name: "Zebra", color: .grey)).color == .purple)
    }

    /// The regression this guard exists to prevent: `Zebra` is purple on the Desktop and grey in
    /// iCloud Drive. Whichever folder is browsed last must not decide — the Desktop's dot is correct
    /// today and has to stay correct.
    @Test("a grey sighting does not displace a colour already known")
    func greySightingDoesNotDowngrade() {
        var index = FinderTagIndex()
        index.learn(FinderTag(name: "Zebra", color: .purple))
        index.learn(FinderTag(name: "Zebra", color: .grey))
        #expect(index.resolve(FinderTag(name: "Zebra", color: .grey)).color == .purple)
    }

    /// The guard is only about grey, and only in that direction: a real recolour to any other colour
    /// is still the newest evidence and wins.
    @Test("a non-grey sighting still wins, and grey is learned when nothing is known")
    func learnStillTracksRealRecolours() {
        var index = FinderTagIndex()
        index.learn(FinderTag(name: "Zebra", color: .purple))
        index.learn(FinderTag(name: "Zebra", color: .blue))
        #expect(index.resolve(FinderTag(name: "Zebra")).color == .blue)

        // A genuinely grey tag, never seen in any other colour, is grey.
        var fresh = FinderTagIndex()
        fresh.learn(FinderTag(name: "Work", color: .grey))
        #expect(fresh.resolve(FinderTag(name: "Work")).color == .grey)
        // …and a colourless sighting is not a colour, so it does not lock grey out either.
        fresh.learn(FinderTag(name: "Work", color: .green))
        #expect(fresh.resolve(FinderTag(name: "Work")).color == .green)
    }

    @Test("resolving a list resolves every tag in order")
    func resolveList() {
        var index = FinderTagIndex()
        index.learn(FinderTag(name: "Zebra", color: .purple))
        let resolved = index.resolve([
            FinderTag(name: "Red", color: .grey),
            FinderTag(name: "Zebra", color: .grey),
            FinderTag(name: "Unseen", color: .yellow)
        ])
        #expect(resolved.map(\.name) == ["Red", "Zebra", "Unseen"])
        #expect(resolved.map(\.color) == [.red, .purple, .yellow])
    }

    @Test("known tags list the stock seven in Finder's order, then custom names sorted")
    func tagsOrdering() {
        var index = FinderTagIndex()
        index.learn(FinderTag(name: "Zebra", color: .purple))
        index.learn(FinderTag(name: "Alpha", color: .blue))
        #expect(index.tags.map(\.name) == FinderTag.systemTags.map(\.name) + ["Alpha", "Zebra"])
        #expect(index.names.contains("Zebra"))
    }

    @Test("a custom name can be forgotten, a stock one cannot")
    func forget() {
        var index = FinderTagIndex()
        index.learn(FinderTag(name: "Zebra", color: .purple))
        index.forget(FinderTag(name: "Zebra"))
        #expect(!index.names.contains("Zebra"))
        // Forgotten means unknown, so the file's own colour is all that is left.
        #expect(index.resolve(FinderTag(name: "Zebra", color: .grey)).color == .grey)

        index.forget(FinderTag(name: "Red"))
        #expect(index.resolve(FinderTag(name: "Red", color: .grey)).color == .red)
    }
}
