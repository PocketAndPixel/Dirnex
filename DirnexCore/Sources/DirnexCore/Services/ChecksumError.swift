import Foundation

/// Why a checksum could not be computed, or a checksum file could not be read.
///
/// A named vocabulary rather than a `String` payload, for the reason `VFSUnsupportedReason` and
/// `UndoActionLabel` are: these sentences reach the screen through a *return value*, not through an
/// assignment, so a bare literal here is invisible to Xcode's extractor and to every bare-literal
/// sweep alike — it would render English under a translated alert title, at the exact moment
/// something failed (docs/NOTES.md, "Localization").
///
/// The core ships no resources, so the English ``sentence`` is *data* and the fallback, keyed for
/// translation by the stable ``key`` (`LocalizationKey.checksumError(_:)`). The app joins the two;
/// until it does (Slice 2), the English renders and nothing is silently lost.
///
/// I/O failures are **not** here: a read that fails on permission or a vanished file throws
/// `VFSError` through `fromErrno`, exactly as `ByteComparator` does, so the app's existing error
/// text handles it unchanged.
public enum ChecksumError: Error, Sendable, Equatable {
    /// Hashing reads bytes through the local filesystem; a remote path must be downloaded first.
    /// Neither `sftp` nor `curl` can hash on the server, so there is no shortcut to offer.
    case needsLocalFile
    /// Directories, sockets and devices have no bytes to digest.
    case needsRegularFile
    /// The file's bytes are not on this disk (`SF_DATALESS`): reading one byte would make the cloud
    /// provider materialize the whole file and block until it lands. The caller has to say so and
    /// get an answer before starting, which is what `allowDataless` is for.
    case wouldDownloadPlaceholder(name: String)
    /// Nothing in the file looked like a checksum line — what `shasum -c` reports as "no properly
    /// formatted checksum lines found".
    case manifestUnreadable
    /// One file listed digests of two different widths. Verifying it would mean running two
    /// algorithms over the same tree and reporting one verdict, so it is refused with both named.
    case manifestMixesAlgorithms(first: ChecksumAlgorithm, second: ChecksumAlgorithm)

    /// The stable translation key token — the case name, spelled once, never derived.
    public var key: String {
        switch self {
        case .needsLocalFile: return "needsLocalFile"
        case .needsRegularFile: return "needsRegularFile"
        case .wouldDownloadPlaceholder: return "wouldDownloadPlaceholder"
        case .manifestUnreadable: return "manifestUnreadable"
        case .manifestMixesAlgorithms: return "manifestMixesAlgorithms"
        }
    }
}

public extension ChecksumError {
    /// The English sentence — the fallback the app shows when a translation is missing, and the
    /// only presentation a resource-free `swift test` ever sees.
    var sentence: String {
        let template = template
        guard !template.arguments.isEmpty else { return template.format }
        return String(format: template.format, arguments: template.arguments)
    }

    /// The English format, with `%@` placeholders in ``arguments`` order. What the catalog's English
    /// value must match, so a translator sees the same sentence the fallback renders.
    var englishFormat: String { template.format }

    /// The values to splice into ``englishFormat`` — or into its translation, which may reorder them
    /// with positional specifiers (`%1$@`).
    var arguments: [String] { template.arguments }

    /// Format and arguments together, so the two can never drift apart. Algorithm names stay in the
    /// English as the same technical vocabulary `SFTP` and `bsdtar` are.
    private var template: (format: String, arguments: [String]) {
        switch self {
        case .needsLocalFile:
            return ("Checksums can only be computed for local files.", [])
        case .needsRegularFile:
            return ("Only regular files have a checksum.", [])
        case let .wouldDownloadPlaceholder(name):
            return ("“%@” isn’t downloaded yet. Checksumming it would download it first.", [name])
        case .manifestUnreadable:
            return ("No checksum lines were found in this file.", [])
        case let .manifestMixesAlgorithms(first, second):
            return (
                "This checksum file mixes %@ and %@ digests, so it can’t be verified in one pass.",
                [first.displayName, second.displayName]
            )
        }
    }

    /// Every reason, with placeholder arguments where a case takes them — the coverage test's input.
    /// `CaseIterable` cannot be synthesized for an enum with associated values, and the ``key`` does
    /// not depend on them, so a representative value per case is exactly enough.
    static var allCases: [ChecksumError] {
        [
            .needsLocalFile,
            .needsRegularFile,
            .wouldDownloadPlaceholder(name: ""),
            .manifestUnreadable,
            .manifestMixesAlgorithms(first: .md5, second: .sha256)
        ]
    }
}
