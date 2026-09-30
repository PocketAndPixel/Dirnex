import Foundation

/// Turning a subprocess's bytes into text, without letting one unrepresentable name discard the
/// whole answer.
///
/// **`String(bytes:encoding:.utf8)` is all-or-nothing**, and a *listing* is the worst possible place
/// for that: one file whose name is not valid UTF-8 makes the initializer return `nil` for the
/// entire stream, so the `?? ""` every call site carries turns a directory of a hundred files into
/// an empty one — or, where the caller checks, into "this archive cannot be read".
///
/// Measured 2026-09-09 on a zip written the way Windows tools wrote them for years (OEM code-page
/// names, UTF-8 flag clear — the fixture is a real one, built with `cp866` bytes and bit 11 CLEAR):
///
/// | `bsdtar -tvf` run under | output | Dirnex |
/// |---|---|---|
/// | `C` | every non-ASCII byte octal-escaped, so pure ASCII | lists, with `\217\240…` names |
/// | UTF-8 `LC_CTYPE` | *some* bytes escaped, others raw | **`archiveUnreadable`** |
///
/// That second row is a regression ``ChildProcessLocale`` introduced: pinning the locale is right
/// for every archive whose names *are* UTF-8, and for the ones that are not it moved the failure
/// from "ugly" to "cannot be opened at all". The honest fix is not to unpin the locale but to stop
/// decoding all-or-nothing — the ASCII columns of every other row are perfectly readable, and the
/// user is entitled to the ninety-nine files whose names are fine.
///
/// The same shape reaches SFTP and FTP: a Linux server or a code-page FTP server can hold a name
/// that is not valid UTF-8, and there the failure is *silent* — the listing decodes to `""` and the
/// pane draws an empty directory, which reads as "the folder is empty" rather than as an error.
///
/// What this cannot do is make such a name **addressable**: a `String` carrying U+FFFD no longer
/// names the file, so operating on that one row still fails. It is the difference between losing one
/// row and losing the directory.
public enum SubprocessText {
    /// `data` decoded as UTF-8, with anything invalid replaced rather than rejected.
    ///
    /// `String(decoding:as:)` is the non-failing spelling — it substitutes U+FFFD per ill-formed
    /// sequence and cannot return `nil`, so a caller needs no `?? ""` and gets no cliff.
    public static func lossyUTF8(_ data: Data) -> String {
        // SwiftLint prefers the failable `String(bytes:encoding:)` here, and that rule is right
        // everywhere but this one function: the failable initializer *is* the defect this
        // exists to remove, since it answers nil for the whole stream over one bad name.
        // swiftlint:disable:next optional_data_string_conversion
        String(decoding: data, as: UTF8.self)
    }
}
