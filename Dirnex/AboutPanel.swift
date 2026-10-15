import AppKit
import DirnexCore

/// App menu ▸ About Dirnex: macOS's own About panel, given the lines it can't know by itself.
///
/// Under the version come the day this build was released, because a license covers versions by
/// their release day (PLAN.md §M29) and nothing else in the app says when this one came out; where
/// this build stands with the license; and links to dirnex.app and the acknowledgments. The
/// copyright line is `NSHumanReadableCopyright`, from the build settings.
///
/// The license line never names who the license is for. People paste About screenshots into bug
/// reports, the app's issues are public, and the name is often an email address. Settings ▸ License
/// shows it. A build that shows nothing about licenses (`LicensingSwitch.isOn`) has no license line.
///
/// The panel draws the credits small and shrinks its box to fit them, with no scroller while they are
/// this short (probed 2026-10-15). A link in it is opened through Launch Services, which is why the
/// acknowledgments are a `dirnex://` link (``AcknowledgmentsWindowController``).
@MainActor
enum AboutPanel {
    /// A run of text in a credits line, and the address it opens when it's a link.
    struct Piece: Equatable {
        let text: String
        var link: URL?
    }

    typealias Line = [Piece]

    /// Shows the panel, with the license as it stands right now.
    static func show() {
        let lines = lines(
            releaseDay: LicensingSwitch.buildReleaseDay,
            license: LicensingSwitch.isOn ? LicenseStore.shared.status : nil,
            today: LicenseDay(Date())
        )
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits(lines)])
    }

    /// The credits, line by line. `license` is `nil` in a build that shows nothing about licenses, and
    /// `today` is a UTC day, as a key's dates are.
    static func lines(releaseDay: LicenseDay?, license: LicenseStatus?, today: LicenseDay) -> [Line] {
        var lines: [Line] = []
        if let releaseDay {
            lines.append([Piece(text: String(
                localized: "Released \(dayText(releaseDay))",
                comment: "About panel, under the version: the day this version came out; %@ is a date."
            ))])
        }
        if let license {
            lines.append(licenseLine(license, today: today))
        }
        lines.append([
            Piece(text: "dirnex.app", link: HelpLinks.website),
            separator,
            Piece(
                text: AcknowledgmentsWindowController.title,
                link: AcknowledgmentsWindowController.link
            )
        ])
        return lines
    }

    /// A day as the user's language writes it in full, with no-break spaces, so a line that wraps
    /// never splits a date ("29 / сентября 2027 г." was seen in Russian).
    static func dayText(_ day: LicenseDay) -> String {
        day.displayText.replacingOccurrences(of: " ", with: "\u{00A0}")
    }

    /// The panel's credits: the lines centered, in the small system font, with each link's address
    /// on its text. The last line, the links, stands a little apart from the facts above it.
    static func credits(_ lines: [Line]) -> NSAttributedString {
        let credits = NSMutableAttributedString()
        for (index, line) in lines.enumerated() {
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center
            paragraph.paragraphSpacingBefore = index > 0 && index == lines.count - 1 ? 4 : 0
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: paragraph
            ]
            if index > 0 {
                credits.append(NSAttributedString(string: "\n", attributes: attributes))
            }
            for piece in line {
                var pieceAttributes = attributes
                pieceAttributes[.link] = piece.link
                credits.append(NSAttributedString(string: piece.text, attributes: pieceAttributes))
            }
        }
        return credits
    }

    private static let separator = Piece(text: " · ")

    /// Where this build stands with the license, without its name. A license that ended, whether
    /// or not it still covers this version, gets a quiet **Renew** link; no license gets **Buy a
    /// License**. Nothing more: the reminder is the place that asks.
    private static func licenseLine(_ status: LicenseStatus, today: LicenseDay) -> Line {
        switch status {
        case .unlicensed:
            [
                Piece(text: String(localized: "Not licensed")),
                separator,
                Piece(
                    text: String(
                        localized: "Buy a License",
                        comment: "About panel: link to the store, after “Not licensed”."
                    ),
                    link: LicenseLinks.buy
                )
            ]
        case let .licensed(key) where today <= key.until:
            [Piece(text: String(
                localized: "Licensed · updates until \(dayText(key.until))",
                comment: "About panel, with a license that covers this version; %@ is the last release day it covers."
            ))]
        case let .licensed(key):
            [
                Piece(text: String(
                    localized: "Licensed · updates ended \(dayText(key.until))",
                    comment: "About panel, with a license that covers this version but no later ones; %@ is a date."
                )),
                separator,
                renew(key)
            ]
        case let .lapsed(key):
            [
                Piece(text: String(
                    localized: "Your license doesn’t cover this version",
                    comment: "About panel, when the license ended before this version came out."
                )),
                separator,
                renew(key)
            ]
        }
    }

    private static func renew(_ key: LicenseKey) -> Piece {
        Piece(
            text: String(
                localized: "Renew",
                comment: "About panel: link that renews the license on dirnex.app."
            ),
            link: LicenseLinks.renew(key)
        )
    }
}
