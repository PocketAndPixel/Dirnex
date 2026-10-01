import DirnexCore
import Foundation

/// Every sentence the Report a Bug dialog shows, in one place.
extension BugReportController {
    static let introText = String(
        localized: """
        Describe what went wrong. Nothing is sent until you press Send, \
        and only what is ticked below goes with it.
        """,
        comment: "Report a Bug dialog: the line at the top."
    )
    static let whatHappenedLabel = String(
        localized: "What happened?",
        comment: "Report a Bug dialog: label above the required description field."
    )
    static let stepsLabel = String(
        localized: "Steps to reproduce (optional)",
        comment: "Report a Bug dialog: label above the field for how to make the bug happen again."
    )
    static let emailLabel = String(
        localized: "Email for a reply (optional)",
        comment: "Report a Bug dialog: label above the reply email field."
    )
    static let includeLabel = String(
        localized: "Send with the report:",
        comment: "Report a Bug dialog: label above the boxes that choose what else is sent."
    )
    static let previewTitle = String(
        localized: "Show What Will Be Sent…",
        comment: "Report a Bug dialog: button that shows the exact text that Send would send."
    )
    static let copyTitle = String(
        localized: "Copy Report",
        comment: "Report a Bug dialog: button that puts the report on the clipboard."
    )
    static let emailTitle = String(
        localized: "Email Instead",
        comment: "Report a Bug dialog: button that puts the report into a new email in the mail app."
    )
    static let sendTitle = String(
        localized: "Send",
        comment: "Report a Bug dialog: button that sends the report."
    )

    // MARK: - The boxes

    static func versionBoxTitle(_ value: String?) -> String {
        let value = value ?? unknownValue
        return String(
            localized: "Dirnex version: \(value)",
            comment: "Report a Bug dialog: box that sends the Dirnex version; %@ is the version and build."
        )
    }

    static func macOSBoxTitle(_ value: String?) -> String {
        let value = value ?? unknownValue
        return String(
            localized: "macOS version: \(value)",
            comment: "Report a Bug dialog: box that sends the macOS version; %@ is the version and build."
        )
    }

    static func modelBoxTitle(_ value: String?) -> String {
        let value = value ?? unknownValue
        return String(
            localized: "Mac model: \(value)",
            comment: "Report a Bug dialog: box that sends the Mac's model identifier, such as Mac16,5."
        )
    }

    static func languageBoxTitle(_ value: String?) -> String {
        let value = value ?? unknownValue
        return String(
            localized: "Language: \(value)",
            comment: "Report a Bug dialog: box that sends the app's language; %@ is its code, such as de."
        )
    }

    static func licenseBoxTitle(_ licensed: Bool) -> String {
        licensed
            ? String(
                localized: "Whether a license is present: yes",
                comment: "Report a Bug dialog: box that sends whether Dirnex has a license; it has one."
            )
            : String(
                localized: "Whether a license is present: no",
                comment: "Report a Bug dialog: box that sends whether Dirnex has a license; it has none."
            )
    }

    static func crashBoxTitle(_ fileName: String?) -> String {
        let fileName = fileName ?? unknownValue
        return String(
            localized: "Newest crash report: \(fileName)",
            comment: "Report a Bug dialog: box that sends Dirnex's newest crash report; %@ is its file name."
        )
    }

    static let noCrashReportTitle = String(
        localized: "No Dirnex crash report from the last 7 days",
        comment: "Report a Bug dialog: the crash report box, grayed out, when there is none to send."
    )

    static let unknownValue = String(
        localized: "unknown",
        comment: "Report a Bug dialog: stands for a fact about the Mac that couldn't be read."
    )

    // MARK: - The status line

    static let sendingMessage = String(
        localized: "Sending…",
        comment: "Report a Bug dialog: status while the report is on its way."
    )

    static func message(for problem: BugReportProblem) -> String? {
        switch problem {
        case .missingDescription:
            nil
        case .invalidEmail, .tooLong(.email):
            String(
                localized: "The email address doesn't look complete.",
                comment: "Report a Bug dialog: status when the reply email is not an address."
            )
        case .tooLong(.whatHappened):
            String(
                localized: "The description is too long to send.",
                comment: "Report a Bug dialog: status when the description is over the limit."
            )
        case .tooLong(.steps):
            String(
                localized: "The steps are too long to send.",
                comment: "Report a Bug dialog: status when the steps to reproduce are over the limit."
            )
        case .tooLong:
            // The facts and the crash report are cut to fit before they get here.
            nil
        }
    }

    static func message(for outcome: BugReportOutcome) -> String {
        switch outcome {
        case .sent:
            ""
        case .unreachable:
            String(
                localized: """
                Couldn't reach the server. Your report is still here: copy it, or send it by email.
                """,
                comment: "Report a Bug dialog: status when the report could not be sent."
            )
        case .rateLimited:
            String(
                localized: """
                Too many reports came from this network in the last hour. \
                Try again later, or send this one by email.
                """,
                comment: "Report a Bug dialog: status when the server refuses more reports for now."
            )
        case let .refused(reason):
            String(
                localized: """
                The server didn't accept the report (\(reason)). Copy it, or send it by email instead.
                """,
                comment: """
                Report a Bug dialog: status when the server refused the report; \
                %@ is the server's reason, in English.
                """
            )
        case let .serverProblem(status):
            String(
                localized: """
                The server had a problem (\(status)). \
                Your report is still here: copy it, or send it by email.
                """,
                comment: "Report a Bug dialog: status when the server failed; %lld is the HTTP status code."
            )
        }
    }

    static let copiedMessage = String(
        localized: "The report is on the clipboard.",
        comment: "Report a Bug dialog: status after Copy Report."
    )
    static let mailOpenedMessage = String(
        localized: "The report is in a new email in your mail app.",
        comment: "Report a Bug dialog: status after Email Instead."
    )
    static let noMailAppMessage = String(
        localized: "No mail app opened. Copy the report instead.",
        comment: "Report a Bug dialog: status when Email Instead found no mail app."
    )

    // MARK: - Email Instead

    static let mailSubject = String(
        localized: "Dirnex bug report",
        comment: "Subject of the email that Email Instead writes."
    )
    static let crashReportLeftOutOfMail = String(
        localized: """
        The crash report didn't fit in this email. The whole report is on the clipboard: paste it here.
        """,
        comment: "First line of the email Email Instead writes, when the crash report was too long for it."
    )
}
