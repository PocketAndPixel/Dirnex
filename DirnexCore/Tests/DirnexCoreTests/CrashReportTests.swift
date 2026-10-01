import Foundation
import Testing

@testable import DirnexCore

/// The crash report a bug report may carry (PLAN.md §M30): finding it, and making it fit to send.
///
/// The sample is shaped like a real Dirnex `.ips` measured on 2026-10-01 (a first line of JSON,
/// then a pretty-printed body whose strings escape every slash), with made-up identifiers and home.
@Suite("Crash report")
struct CrashReportTests {
    static let home = BugReportRedaction(homePath: "/Users/jane")

    static let header = [
        #""app_name":"Dirnex","timestamp":"2026-09-29 23:44:58.00 +0300","app_version":"1.4.0""#,
        #""build_version":"512","bundleID":"com.dirnex.Dirnex","os_version":"macOS 26.0.1 (25A362)""#,
        #""incident_id":"11111111-2222-3333-4444-555555555555""#
    ].joined(separator: ",")

    static let sample = "{\(header)}\n" + #"""
    {
      "uptime" : 560000,
      "modelCode" : "Mac16,5",
      "crashReporterKey" : "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE",
      "procPath" : "\/Users\/jane\/Applications\/Dirnex.app\/Contents\/MacOS\/Dirnex",
      "storeInfo" : {
        "deviceIdentifierForVendor" : "FFFFFFFF-0000-1111-2222-333333333333",
        "thirdParty" : true
      },
      "bootSessionUUID" : "44444444-5555-6666-7777-888888888888",
      "sleepWakeUUID" : "99999999-AAAA-BBBB-CCCC-DDDDDDDDDDDD",
      "exception" : {"codes":"0x0000000000000001","type":"EXC_BAD_ACCESS","signal":"SIGSEGV"},
      "termination" : {
        "reasons" : ["Library not loaded","tried: '\/Users\/jane\/Library\/Frameworks\/Sparkle.framework'"]
      },
      "neighbour" : "\/Users\/janet\/Library",
      "faultingThread" : 0
    }
    """#

    // MARK: - Redaction

    @Test("the home folder becomes ~ in both spellings, and only where its name ends")
    func redaction() {
        let home = Self.home
        #expect(home.redacted("/Users/jane") == "~")
        #expect(home.redacted("/Users/jane/Movies and /Users/jane.") == "~/Movies and ~.")
        #expect(home.redacted("/users/JANE/Movies") == "~/Movies")
        #expect(home.redacted(#"\/Users\/jane\/Movies"#) == #"~\/Movies"#)
        #expect(home.redacted("'/Users/jane'") == "'~'")
        for other in [
            "/Users/janet/x",
            "/Users/jane.doe/x",
            "/Users/jane-old",
            "/Users/jane_2",
            "/Users/jane\u{301}/x"
        ] {
            #expect(home.redacted(other) == other, "\(other)")
        }
    }

    @Test("a trailing slash on the home path is ignored, and / alone redacts nothing")
    func homePathShape() {
        #expect(BugReportRedaction(homePath: "/Users/jane/").redacted("/Users/jane/x") == "~/x")
        #expect(BugReportRedaction(homePath: "/").redacted("/Users/jane") == "/Users/jane")
        #expect(BugReportRedaction(homePath: "").redacted("/Users/jane") == "/Users/jane")
    }

    @Test("the current redaction is this Mac's home")
    func currentHome() {
        #expect(BugReportRedaction.current.redacted(NSHomeDirectory() + "/x") == "~/x")
    }

    // MARK: - Trimming

    @Test("a trimmed report keeps the crash and loses the home and the identifiers")
    func trimmedSample() {
        let trimmed = CrashReportTrimmer.trimmed(Self.sample, redaction: Self.home)
        #expect(!trimmed.contains(#"\/Users\/jane\/"#))
        #expect(
            trimmed.contains(#""procPath" : "~\/Applications\/Dirnex.app\/Contents\/MacOS\/Dirnex""#)
        )
        #expect(trimmed.contains(#"tried: '~\/Library\/Frameworks\/Sparkle.framework'"#))
        #expect(trimmed.contains(#""neighbour" : "\/Users\/janet\/Library""#))
        for identifier in ["AAAAAAAA", "FFFFFFFF", "44444444", "99999999"] {
            #expect(!trimmed.contains(identifier), "\(identifier)")
        }
        #expect(trimmed.contains(#""crashReporterKey" : "","#))
        #expect(trimmed.contains(#""deviceIdentifierForVendor" : "","#))
        // What the crash itself is about stays.
        #expect(trimmed.contains("EXC_BAD_ACCESS"))
        #expect(trimmed.contains(#""incident_id":"11111111-2222-3333-4444-555555555555""#))
        #expect(trimmed.utf8.count < Self.sample.utf8.count)
    }

    @Test("the pattern removes every identifying key, in either spacing")
    func everyIdentifyingKey() {
        for key in CrashReportTrimmer.identifyingKeys {
            let spaced = #""\#(key)" : "secret""#
            let tight = #"{"\#(key)":"secret"}"#
            #expect(CrashReportTrimmer.removingIdentifiers(from: spaced) == #""\#(key)" : """#)
            #expect(CrashReportTrimmer.removingIdentifiers(from: tight) == #"{"\#(key)":""}"#)
        }
    }

    @Test("a report over the limit keeps its start and says it was cut")
    func cut() {
        let text = String(repeating: "é", count: 1000)
        #expect(CrashReportTrimmer.cut(text, toBytes: 2000) == text)
        let cut = CrashReportTrimmer.cut(text, toBytes: 1001)
        #expect(cut.utf8.count <= 1001)
        #expect(cut.hasSuffix(CrashReportTrimmer.cutMarker))
        #expect(cut.hasPrefix("éé"))
        #expect(CrashReportTrimmer.cut(text, toBytes: 10).isEmpty)
    }

    @Test("a long report is trimmed to the contract's limit")
    func trimmedToLimit() {
        let long = Self.sample + String(repeating: "x", count: BugReport.Limits.crashReportBytes)
        let trimmed = CrashReportTrimmer.trimmed(long, redaction: Self.home)
        #expect(trimmed.utf8.count <= BugReport.Limits.crashReportBytes)
        #expect(trimmed.hasPrefix(#"{"app_name":"Dirnex""#))
        #expect(BugReport(whatHappened: "It crashed.", crashReport: trimmed).problem == nil)
    }

    // MARK: - Finding it

    private struct Fixture {
        let home: URL
        let reports: URL
        let retired: URL
        let now = Date(timeIntervalSince1970: 1_790_000_000)

        init() throws {
            home = FileManager.default.temporaryDirectory
                .appending(path: "dnx-m30-\(UUID().uuidString)", directoryHint: .isDirectory)
            let directories = CrashReportLocator.directories(home: home)
            reports = directories[0]
            retired = directories[1]
            try FileManager.default.createDirectory(at: retired, withIntermediateDirectories: true)
        }

        @discardableResult
        func file(_ name: String, in directory: URL, age: TimeInterval, text: String = "{}") throws -> URL {
            let url = directory.appending(path: name)
            try Data(text.utf8).write(to: url)
            try FileManager.default.setAttributes(
                [.modificationDate: now.addingTimeInterval(-age)],
                ofItemAtPath: url.path
            )
            return url
        }

        func remove() {
            try? FileManager.default.removeItem(at: home)
        }
    }

    @Test("only Dirnex's own .ips reports count")
    func names() {
        #expect(CrashReportLocator.isDirnexReport(named: "Dirnex-2026-09-29-234458.ips"))
        let others = [
            "Dirnex-2026-09-29-234458.hang",
            "DirnexHelper-2026-09-29-234458.ips",
            "Dirnex.cpu_resource-2026-09-29-234458.diag",
            "Dirnex-.ips",
            "dirnex-2026-09-29.ips",
            "Dirnex Helper-2026-09-29-234458.ips",
            "Finder-2026-09-29-234458.ips"
        ]
        for name in others {
            #expect(!CrashReportLocator.isDirnexReport(named: name), "\(name)")
        }
    }

    @Test("the newest report from the last 7 days is found, in either folder")
    func newest() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let day: TimeInterval = 24 * 60 * 60
        try fixture.file("Dirnex-2026-09-20-101010.ips", in: fixture.reports, age: 10 * day)
        try fixture.file("Dirnex-2026-09-27-101010.ips", in: fixture.retired, age: 3 * day)
        let expected = try fixture.file(
            "Dirnex-2026-09-29-101010.ips",
            in: fixture.reports,
            age: day
        )
        // Newer, but not Dirnex's or not a crash report.
        try fixture.file("Dirnex-2026-09-30-101010.hang", in: fixture.reports, age: 60)
        try fixture.file("DirnexHelper-2026-09-30-101010.ips", in: fixture.reports, age: 60)
        try FileManager.default.createDirectory(
            at: fixture.reports.appending(path: "Dirnex-2026-09-30-111111.ips"),
            withIntermediateDirectories: false
        )

        let found = CrashReportLocator.newestReport(home: fixture.home, now: fixture.now)
        #expect(found?.url.lastPathComponent == expected.lastPathComponent)

        let retired = try fixture.file(
            "Dirnex-2026-09-30-090909.ips",
            in: fixture.retired,
            age: 3600
        )
        let newer = CrashReportLocator.newestReport(home: fixture.home, now: fixture.now)
        #expect(newer?.url.lastPathComponent == retired.lastPathComponent)
    }

    @Test("nothing is found when every report is older than 7 days, or the folders are missing")
    func nothingFound() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.file(
            "Dirnex-2026-09-20-101010.ips",
            in: fixture.reports,
            age: 7 * 24 * 60 * 60 + 1
        )
        #expect(CrashReportLocator.newestReport(home: fixture.home, now: fixture.now) == nil)

        let missing = fixture.home.appending(path: "nobody")
        #expect(CrashReportLocator.newestReport(home: missing, now: fixture.now) == nil)
    }

    @Test("a report dated after now still counts")
    func clockMovedBack() {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let file = CrashReportFile(url: URL(filePath: "/x"), modified: now.addingTimeInterval(3600))
        #expect(CrashReportLocator.newest(of: [file], now: now) == file)
    }

    @Test("reading a report keeps its start, and a byte that isn't UTF-8 doesn't lose it")
    func reading() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let url = fixture.reports.appending(path: "Dirnex-2026-09-29-101010.ips")
        var bytes = Data("{\"a\":\"".utf8) + Data([0xFF]) + Data("\"}".utf8)
        try bytes.write(to: url)
        let file = CrashReportFile(url: url, modified: fixture.now)
        #expect(CrashReportLocator.text(of: file) == "{\"a\":\"\u{FFFD}\"}")

        bytes = Data(repeating: UInt8(ascii: "x"), count: CrashReportLocator.maximumReadBytes + 10)
        try bytes.write(to: url)
        #expect(CrashReportLocator.text(of: file)?.utf8.count == CrashReportLocator.maximumReadBytes)

        try Data().write(to: url)
        #expect(CrashReportLocator.text(of: file) == nil)
    }

    // MARK: - This Mac

    @Test("the macOS version is written as About This Mac writes it")
    func macOSVersion() {
        let version = { (patch: Int) in OperatingSystemVersion(
            majorVersion: 26,
            minorVersion: 0,
            patchVersion: patch
        ) }
        #expect(BugReportSystemInfo.macOSVersion(version(1), build: "25A362") == "26.0.1 (25A362)")
        #expect(BugReportSystemInfo.macOSVersion(version(0), build: "25A354") == "26.0 (25A354)")
        #expect(BugReportSystemInfo.macOSVersion(version(0), build: nil) == "26.0")
    }

    @Test("this Mac's facts are read")
    func currentSystem() throws {
        let system = BugReportSystemInfo.current()
        let macOS = try #require(system.macOS)
        let major = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
        #expect(macOS.hasPrefix("\(major)."))
        #expect(macOS.hasSuffix(")"))
        let model = try #require(system.macModel)
        #expect(!model.isEmpty)
        #expect(!model.contains("\0"))
    }

    @Test("a fact is cut to the short-field limit, and a blank one is dropped")
    func factsAreShort() {
        let system = BugReportSystemInfo(
            appVersion: String(repeating: "é", count: 80),
            appBuild: " "
        )
        #expect(system.appVersion?.utf8.count == BugReport.Limits.shortFieldBytes)
        #expect(system.appBuild == nil)
    }
}
