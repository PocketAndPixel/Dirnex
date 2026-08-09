import Foundation

/// Reads `hdiutil -puppetstrings` progress lines.
///
/// With `-puppetstrings`, `hdiutil` replaces its drawn progress meter with machine-readable lines —
/// which is the whole reason creating a vault can show a real bar rather than a spinner. Captured
/// from a real 200 MB create:
///
///     PERCENT:-1.000000
///     PERCENT:-1.000000
///     PERCENT:0.000000
///     PERCENT:25.897619
///     PERCENT:49.376678
///     PERCENT:91.117226
///     PERCENT:-1.000000
///
/// Two things in that transcript decide the parser. **`-1` is a sentinel, not a percentage** — it
/// brackets the run at both ends and means "no measurable progress right now", so a caller that
/// takes it literally drives the bar to −1 % at the start and, worse, *back* to −1 % at the very
/// end, which reads as the operation failing at the moment it succeeded. And the values **repeat**
/// (91.117226 arrived three times in a row), so a bar driven straight from them must tolerate a
/// value that does not advance.
public enum DiskImageProgress {
    /// One line's meaning.
    public enum Line: Sendable, Equatable {
        /// A real fraction of the work, `0.0 ... 1.0`.
        case fraction(Double)
        /// `hdiutil` is working but cannot say how far along it is.
        case indeterminate
        /// Anything else `hdiutil` printed — kept as a case rather than dropped so a caller can log
        /// it, since this is also where an error message arrives.
        case other(String)
    }

    private static let prefix = "PERCENT:"

    /// Interprets one line of `hdiutil`'s output.
    public static func parse(_ line: String) -> Line {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix(prefix) else { return .other(trimmed) }

        let value = trimmed.dropFirst(prefix.count)
        guard let percent = Double(value) else { return .other(trimmed) }
        guard percent >= 0 else { return .indeterminate }
        // Clamped rather than trusted: a bar is a promise about a range, and there is no useful
        // behavior for 101 %.
        return .fraction(min(percent, 100) / 100)
    }

    /// Every fraction in a chunk of output, in order — the shape a caller draining a pipe wants.
    /// Indeterminate and non-progress lines are dropped, so a bar driven from this only ever moves
    /// on a real measurement.
    public static func fractions(in output: String) -> [Double] {
        output.split(whereSeparator: \.isNewline).compactMap { line in
            if case let .fraction(value) = parse(String(line)) { return value }
            return nil
        }
    }
}
