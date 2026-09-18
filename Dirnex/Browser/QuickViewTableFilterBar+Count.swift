import AppKit
import DirnexCore

/// What the bar says where a count goes (2026-09-18): how many rows or values a filter left, which
/// match a find is on — and, when the text is a pattern that cannot be run, why there is no count at
/// all. Split out of `QuickViewTableFilterBar` when the class reached SwiftLint's
/// `type_body_length`, by concept: everything here is the one label's sentence.
extension QuickViewTableFilterBar {
    /// Put `text` on the count line — unless what is typed is a pattern that cannot be run, in which
    /// case the reason goes there instead. One funnel, so a surface cannot be the one that forgets.
    func showCountLine(_ text: @autoclosure () -> String) {
        countLabel.stringValue = patternProblem ?? text()
    }

    /// What the count line says instead of a count while the text is a pattern that cannot be run —
    /// `nil` whenever there is a count to show, which is every search that is not a pattern.
    ///
    /// Half-typed, a pattern is *usually* unusable (`(`, `[a-`), so this is a thing to say rather than
    /// a failure to report: an alert on every other keystroke would be unusable, and a bare "No
    /// matches" over an empty table would be true and unhelpful. It is the bar's own question because
    /// the bar is the one place that has both halves — the text and the options — and because the
    /// alternative is the same sentence plumbed through five surfaces.
    ///
    /// A back reference gets its own sentence: it is a pattern every other tool would take, refused
    /// here for a measured reason (``DirnexCore/PatternSearchError/backReference``), so "not valid"
    /// would be the app blaming the user for its own rule.
    var patternProblem: String? {
        guard options.contains(.pattern), !query.isEmpty else { return nil }
        switch FilterQuery(query, options: options).patternProblem {
        case .backReference:
            return String(
                localized: "No back references",
                comment: """
                Quick View find and filter: shown where the match count goes, when the pattern typed \
                uses a back reference (\\1), which this app does not run. Kept short: the bar is \
                narrow and this label truncates its tail.
                """
            )
        case .invalid:
            return String(
                localized: "Invalid pattern",
                comment: """
                Quick View find and filter: shown where the match count goes, when what is typed is \
                not a valid search pattern — which is the ordinary state of one half typed. Kept \
                short: the bar is narrow and this label truncates its tail.
                """
            )
        case nil:
            return nil
        }
    }

    /// "12 of 3000 values", or nothing while no text is typed — the tree's count, of the values that
    /// matched rather than the rows shown, since a matched container shows everything it holds.
    func showValueCount(matched: Int, of total: Int, filtering: Bool) {
        showCountLine(filtering ? String(
            localized: "\(matched) of \(total) values",
            comment: """
            Quick View JSON tree filter: how many values matched. %1$lld values matched, of %2$lld in \
            the file. Plural on the second.
            """
        ) : "")
    }

    /// "3 of 17 matches", "3 of 100 000+ matches" when the search stopped at its limit, "No matches",
    /// or nothing while no text is typed. `current` counts from 1.
    func showMatchCount(current: Int, of total: Int, isComplete: Bool, finding: Bool) {
        guard finding, total > 0 else {
            showCountLine(finding ? String(
                localized: "No matches",
                comment: "Quick View text find: the count when the text is found nowhere in the file."
            ) : "")
            return
        }
        showCountLine(isComplete ? String(
            localized: "\(current) of \(total) matches",
            comment: """
            Quick View text find: which match is the current one. %1$lld is the current match, of \
            %2$lld in the file. Plural on the second.
            """
        ) : String(
            localized: "\(current) of \(total)+ matches",
            comment: """
            Quick View text find: which match is the current one, when the search stopped at its limit \
            with more in the file. %1$lld is the current match, of more than %2$lld. Plural on the second.
            """
        ))
    }

    /// "12 of 3000 rows", or nothing while no text is typed.
    func showCount(shown: Int, of total: Int, filtering: Bool) {
        showCountLine(filtering ? String(
            localized: "\(shown) of \(total) rows",
            comment: """
            Quick View table filter: how many rows the filter left. %1$lld rows are shown, of %2$lld in \
            the file. Plural on the second.
            """
        ) : "")
    }
}
