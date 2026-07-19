import Foundation

/// Shell-style wildcard matching for pattern selection (the `+`/`-` select-by-glob
/// feature, PLAN.md §M1 "pattern select").
///
/// Backed by POSIX `fnmatch`, so `*`, `?` and `[...]` character classes behave
/// exactly as users expect from the shell. Matching is case-insensitive — a file
/// manager's select-by-pattern should not care that a photo is `.JPG` not `.jpg`.
enum Glob {
    static func matches(_ pattern: String, _ name: String) -> Bool {
        // Lowercasing both sides gives case-insensitivity without depending on the
        // BSD-only FNM_CASEFOLD flag. Glob metacharacters are unaffected by case.
        pattern.lowercased().withCString { patternPtr in
            name.lowercased().withCString { namePtr in
                fnmatch(patternPtr, namePtr, 0) == 0
            }
        }
    }
}
