import DirnexCore
import Foundation
import Testing

@testable import Dirnex

/// Coverage for the two *error vocabularies* the core hands over as data — `VFSUnsupportedReason`
/// and `ChecksumError` (PLAN.md §M12 Slice 11, §M14 Slice 2).
///
/// Split out of `LocalizationCoverageTests`, which had reached SwiftLint's type-body ceiling, along
/// a seam that is a real one: these two are the entries that carry **arguments**, so they need a
/// check the registry entries do not — that a translation may reorder a placeholder but must never
/// drop one. Both reach the screen through a *return value* rather than an assignment, which is
/// precisely why neither is visible to Xcode's extractor or to any bare-literal sweep, and why a
/// missing translation here renders English under a translated alert title at the exact moment
/// something has failed.
@Suite("Localization coverage — error vocabularies")
struct LocalizationErrorCoverageTests {
    private var translatedLanguages: [AppLanguage] {
        AppLanguages.all.filter { $0 != AppLanguages.english }
    }

    private func bundle(for language: AppLanguage) throws -> Bundle {
        let path = try #require(
            Bundle.main.path(forResource: language.code, ofType: "lproj"),
            "the built app has no \(language.code).lproj — is \(language.code) in knownRegions?"
        )
        return try #require(Bundle(path: path))
    }

    private func translation(_ key: String, in bundle: Bundle) -> String? {
        let sentinel = "\u{0}missing"
        let value = bundle.localizedString(forKey: key, value: sentinel, table: nil)
        return value == sentinel ? nil : value
    }

    @Test("every unsupported-operation reason is translated in every shipped language")
    func everyUnsupportedReasonIsTranslated() throws {
        for language in translatedLanguages {
            let bundle = try bundle(for: language)
            for reason in VFSUnsupportedReason.allCases {
                let key = LocalizationKey.vfsUnsupported(reason)
                let value = translation(key, in: bundle)
                #expect(value != nil, "\(language.code): no \(key)")
                guard let value else { continue }
                #expect(
                    value != reason.englishFormat,
                    "\(language.code): \(key) is still English"
                )
                // A translation may reorder the arguments positionally, but it cannot *drop* one:
                // a lost `%@` silently swallows the file name the sentence was naming, and
                // `String(format:)` would then read past the arguments it was given.
                let found = placeholderCount(value)
                let wanted = reason.arguments.count
                #expect(
                    found == wanted,
                    """
                    \(language.code): \(key) takes \(wanted) arguments, its translation has \(found)
                    """
                )
            }
        }
    }

    @Test("every checksum failure reason is translated in every shipped language")
    func everyChecksumErrorIsTranslated() throws {
        for language in translatedLanguages {
            let bundle = try bundle(for: language)
            for error in ChecksumError.allCases {
                let key = LocalizationKey.checksumError(error)
                let value = translation(key, in: bundle)
                #expect(value != nil, "\(language.code): no \(key)")
                guard let value else { continue }
                #expect(
                    value != error.englishFormat,
                    "\(language.code): \(key) is still English"
                )
                // A translation may reorder the arguments positionally, but it cannot *drop* one:
                // a lost `%@` swallows the file name — or the algorithm — the sentence was naming,
                // and `String(format:)` would then read past the arguments it was given.
                let found = placeholderCount(value)
                let wanted = error.arguments.count
                #expect(
                    found == wanted,
                    """
                    \(language.code): \(key) takes \(wanted) arguments, its translation has \(found)
                    """
                )
            }
        }
    }

    /// How many arguments a format string consumes — `%@`/`%d` counted once each, `%1$@` counted by
    /// the highest position named, and `%%` (a literal percent) not counted at all.
    private func placeholderCount(_ format: String) -> Int {
        var positional = 0
        var sequential = 0
        var index = format.startIndex
        while let percent = format[index...].firstIndex(of: "%") {
            let after = format.index(after: percent)
            guard after < format.endIndex else { break }
            if format[after] == "%" {
                index = format.index(after: after)
                continue
            }
            let digits = format[after...].prefix(while: \.isNumber)
            if !digits.isEmpty, format[format.index(after, offsetBy: digits.count)] == "$" {
                positional = max(positional, Int(digits) ?? 0)
            } else {
                sequential += 1
            }
            index = after
        }
        return max(positional, sequential)
    }
}
