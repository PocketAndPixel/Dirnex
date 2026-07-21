import Foundation
import Testing

@testable import DirnexCore

@Suite("ICloudContainers")
struct ICloudContainersTests {
    // MARK: - Paths and identifiers

    @Test("the metadata cache sits under CloudDocs' session directory")
    func metadataDirectoryPath() {
        let directory = ICloudContainers.metadataDirectory(home: "/Users/test")
        #expect(
            directory.path == "/Users/test/Library/Application Support/CloudDocs/session/containers"
        )
    }

    @Test("a bundle identifier becomes a container directory name by dots → tildes")
    func containerIDMapping() {
        #expect(ICloudContainers.containerID(forBundleID: "com.apple.Pages") == "com~apple~Pages")
        #expect(ICloudContainers.containerID(forBundleID: "iCloud.is.workflow.my.workflows")
            == "iCloud~is~workflow~my~workflows")
        // A team-prefixed container keeps the prefix; the prefix's own dots convert too.
        #expect(ICloudContainers.containerID(forBundleID: "F3LWYJ7GM7.com.apple.garageband10")
            == "F3LWYJ7GM7~com~apple~garageband10")
    }

    // MARK: - Parsing

    @Test("a public container parses its name, scope and icons")
    func parsesPublicContainer() throws {
        let data = try metadataPlist([
            "BRContainerIcons": ["32x32_OSX", "256x256_OSX", "120x120_iOS"],
            "com.apple.iWork.Pages": [
                "BRContainerName": "Pages",
                "BRContainerIsDocumentScopePublic": true,
                "BRContainerLocalizedNames": ["de": "Pages", "uk": "Сторінки"]
            ]
        ])
        let metadata = try #require(
            ICloudContainers.parseMetadata(data, bundleID: "com.apple.Pages")
        )
        #expect(metadata.containerID == "com~apple~Pages")
        #expect(metadata.bundleID == "com.apple.Pages")
        #expect(metadata.name == "Pages")
        #expect(metadata.isDocumentScopePublic)
        #expect(metadata.iconNames == ["32x32_OSX", "256x256_OSX", "120x120_iOS"])
    }

    @Test("the public-scope flag is read as a number, because both 1 and true occur")
    func publicScopeAcceptsIntegerAndBoolean() throws {
        // Probed: one real plist carried `1` in one record and `true` in another. Matching
        // only the Bool would have hidden half the app libraries.
        let integerForm = try metadataPlist([
            "com.apple.Pages": ["BRContainerName": "Pages", "BRContainerIsDocumentScopePublic": 1]
        ])
        let booleanForm = try metadataPlist([
            "com.apple.Pages": ["BRContainerName": "Pages", "BRContainerIsDocumentScopePublic": true]
        ])
        #expect(ICloudContainers.parseMetadata(integerForm, bundleID: "com.apple.Pages")?
            .isDocumentScopePublic == true)
        #expect(ICloudContainers.parseMetadata(booleanForm, bundleID: "com.apple.Pages")?
            .isDocumentScopePublic == true)
    }

    @Test("one plist holding several app records is public if any record says so")
    func severalRecordsUnion() throws {
        // Pages ships two records in one file (`com.apple.Pages` and `com.apple.iWork.Pages`).
        let data = try metadataPlist([
            "com.apple.Pages": ["BRContainerIsDocumentScopePublic": false],
            "com.apple.iWork.Pages": [
                "BRContainerName": "Pages",
                "BRContainerIsDocumentScopePublic": true
            ]
        ])
        let metadata = try #require(
            ICloudContainers.parseMetadata(data, bundleID: "com.apple.Pages")
        )
        #expect(metadata.isDocumentScopePublic)
        #expect(metadata.name == "Pages")
    }

    @Test("a private container parses, and reports itself private")
    func parsesPrivateContainer() throws {
        // "Known and private" must be a value, not a parse failure — the caller filters on
        // the flag rather than on whether anything came back.
        let data = try metadataPlist([
            "com.apple.notes": [
                "BRContainerName": "Notes",
                "BRContainerIsDocumentScopePublic": false
            ]
        ])
        let metadata = try #require(
            ICloudContainers.parseMetadata(data, bundleID: "com.apple.notes")
        )
        #expect(!metadata.isDocumentScopePublic)
    }

    @Test("a nameless container falls back to its bundle id rather than a blank row")
    func namelessFallsBackToBundleID() throws {
        let data = try metadataPlist(["com.example.app": ["BRContainerIsDocumentScopePublic": true]])
        let metadata = try #require(
            ICloudContainers.parseMetadata(data, bundleID: "iCloud.com.example.app")
        )
        #expect(metadata.name == "iCloud.com.example.app")
    }

    @Test("bytes that are not a plist dictionary parse to nil")
    func rejectsNonDictionary() throws {
        #expect(ICloudContainers.parseMetadata(Data("not a plist".utf8), bundleID: "x") == nil)
        let array = try PropertyListSerialization.data(
            fromPropertyList: ["a"],
            format: .binary,
            options: 0
        )
        #expect(ICloudContainers.parseMetadata(array, bundleID: "x") == nil)
    }

    // MARK: - Localized names

    @Test("a localized name is used for the matching language, else the plain one")
    func localizedNameSelection() {
        let metadata = ICloudContainerMetadata(
            containerID: "com~apple~Pages",
            bundleID: "com.apple.Pages",
            name: "Pages",
            localizedNames: ["uk": "Сторінки"],
            isDocumentScopePublic: true
        )
        #expect(metadata.name(for: "uk") == "Сторінки")
        #expect(metadata.name(for: "de") == "Pages")
        #expect(metadata.name(for: nil) == "Pages")
    }

    // MARK: - Icons

    @Test("icon selection prefers macOS art and the smallest size that covers the request")
    func iconSelection() {
        let names = [
            "32x32_OSX",
            "256x256_OSX",
            "120x120_iOS",
            "16x16_OSX",
            "128x128_OSX",
            "64x64_OSX"
        ]
        // 16 pt at 2× wants 32 px: the 32 covers it exactly, so nothing larger is decoded.
        #expect(ICloudContainers.bestIconName(from: names, pointSize: 16, scale: 2) == "32x32_OSX")
        #expect(ICloudContainers.bestIconName(from: names, pointSize: 16, scale: 1) == "16x16_OSX")
        #expect(ICloudContainers.bestIconName(from: names, pointSize: 64, scale: 2) == "128x128_OSX")
    }

    @Test("nothing large enough falls back to the largest available")
    func iconFallsBackToLargest() {
        #expect(
            ICloudContainers.bestIconName(from: ["16x16_OSX", "32x32_OSX"], pointSize: 512) == "32x32_OSX"
        )
    }

    @Test("an iOS-only container still yields an icon")
    func iOSOnlyIcons() {
        // Half these apps never shipped for the Mac (probed: Truecaller caches only iOS art),
        // so refusing to fall back would leave real rows iconless.
        let names = ["120x120_iOS", "40x40_iOS", "80x80_iOS"]
        #expect(ICloudContainers.bestIconName(from: names, pointSize: 16, scale: 2) == "40x40_iOS")
    }

    @Test("a container that caches no icons yields nil")
    func noIcons() {
        // A real outcome, not a defensive one: several containers cache nothing at all.
        #expect(ICloudContainers.bestIconName(from: [], pointSize: 16) == nil)
        #expect(ICloudContainers.bestIconName(from: ["not-an-icon-name"], pointSize: 16) == nil)
    }

    // MARK: - Support

    private func metadataPlist(_ dictionary: [String: Any]) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: dictionary, format: .binary, options: 0)
    }
}
