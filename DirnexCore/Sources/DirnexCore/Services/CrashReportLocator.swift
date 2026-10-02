import Foundation

/// A crash report on disk.
public struct CrashReportFile: Sendable, Hashable {
    public let url: URL
    public let modified: Date

    public init(url: URL, modified: Date) {
        self.url = url
        self.modified = modified
    }
}

/// Finds the crash report a bug report may carry (PLAN.md §M30): the newest Dirnex report from the
/// last 7 days.
///
/// macOS writes it to `~/Library/Logs/DiagnosticReports` as `Dirnex-2026-09-29-234458.ips`, and
/// later moves it to `Retired/` in the same folder: a two-day-old report was already there when
/// this was measured (2026-10-01). Both folders are looked in.
public enum CrashReportLocator {
    public static let maximumAge: TimeInterval = 7 * 24 * 60 * 60

    /// The most of a report that is read. ``CrashReportTrimmer`` keeps far less, and the start is
    /// the part worth keeping.
    public static let maximumReadBytes = 4 * BugReport.Limits.crashReportBytes

    public static func directories(home: URL) -> [URL] {
        let reports = home.appending(
            path: "Library/Logs/DiagnosticReports",
            directoryHint: .isDirectory
        )
        return [reports, reports.appending(path: "Retired", directoryHint: .isDirectory)]
    }

    /// Whether `name` is one of Dirnex's own reports: the process name, a dash, the date, `.ips`.
    /// Another process whose name starts with "Dirnex" doesn't match, and neither do the `.diag`
    /// and `.hang` files macOS writes beside crash reports.
    public static func isDirnexReport(named name: String) -> Bool {
        let prefix = "Dirnex-"
        guard name.hasPrefix(prefix), name.hasSuffix(".ips") else { return false }
        return name.dropFirst(prefix.count).first.map { $0.isASCII && $0.isNumber } ?? false
    }

    /// The newest of `files` modified in the last ``maximumAge`` before `now`. A report dated after
    /// `now` counts as new, since the clock may have moved back since it was written.
    public static func newest(of files: [CrashReportFile], now: Date) -> CrashReportFile? {
        files
            .filter { now.timeIntervalSince($0.modified) <= maximumAge }
            .max { $0.modified < $1.modified }
    }

    /// The newest Dirnex report from the last 7 days under `home`, or `nil`. A folder that is
    /// missing or can't be read just has no reports.
    public static func newestReport(
        home: URL,
        now: Date = Date(),
        fileManager: FileManager = .default
    ) -> CrashReportFile? {
        let files = directories(home: home).flatMap { directory -> [CrashReportFile] in
            let urls = (try? fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey]
            )) ?? []
            return urls.compactMap { url in
                guard isDirnexReport(named: url.lastPathComponent),
                      let values = try? url.resourceValues(
                          forKeys: [.contentModificationDateKey, .isRegularFileKey]
                      ),
                      values.isRegularFile == true,
                      let modified = values.contentModificationDate
                else {
                    return nil
                }
                return CrashReportFile(url: url, modified: modified)
            }
        }
        return newest(of: files, now: now)
    }

    /// The start of `file`'s text, at most ``maximumReadBytes``. A byte sequence that isn't UTF-8,
    /// or one cut in half at the end, becomes U+FFFD rather than losing the whole report.
    public static func text(of file: CrashReportFile) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: file.url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: maximumReadBytes), !data.isEmpty else {
            return nil
        }
        // Lossy on purpose: a report with one bad byte is still worth sending.
        // swiftlint:disable:next optional_data_string_conversion
        return String(decoding: data, as: UTF8.self)
    }
}
