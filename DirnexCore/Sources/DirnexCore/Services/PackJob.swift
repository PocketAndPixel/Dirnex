// MARK: - Job

/// What a queued pack operation is being asked to write (PLAN.md §M19 Slice 2).
///
/// Carried as the payload of `FileOperation.Kind.pack`, and it describes **only the encrypted
/// path**. Every other format still goes through `bsdtar` on the caller's own thread, because that
/// is the boundary §M19 drew around the libarchive exception: the reason to link libarchive at all
/// is that `bsdtar` has no way to take a passphrase that is not readable by any `ps`, and a plain
/// `.tar.gz` needs no passphrase. So the queue is not "where packing happens" — it is where
/// *encrypting* happens, which is the work that can run for minutes and the work a user needs to be
/// able to abandon.
///
/// The container is always zip and is therefore not a field. `EncryptedArchiveWriter.write` produces
/// a zip whatever else it is told (its `tar` container exists only as the inner wrapper
/// ``ArchiveNamePrivacy/hidden`` puts inside one), and zip is the only format that can be encrypted
/// at all — libarchive's 7-Zip writer refuses `encryption`, and tar has no notion of it. A `format`
/// field here would be a setting with one legal value and a way to ask for an illegal one.
public struct PackJob: Sendable {
    /// The directory ``names`` are relative to — the source pane's own directory, and what every
    /// entry's archive path is spelled against.
    public let sourceDirectory: VFSPath

    /// Bare names within ``sourceDirectory``. Bare rather than absolute because that is what the
    /// archive stores: a member called `docs/report.pdf` and not `/Users/…/docs/report.pdf`.
    public let names: [String]

    /// Where the finished archive lands. Written under a temporary name beside itself and renamed
    /// into place by the writer, so a canceled pack leaves nothing here.
    public let archive: VFSPath

    /// Which cipher, or none. `.none` is representable so the type does not need a second shape for
    /// the case a caller changed its mind, but the app only ever queues an encrypted job.
    public let encryption: ArchiveEncryption

    /// Whether the payload is wrapped in one inner tar to keep the file names out of the zip's
    /// permanently-plaintext central directory.
    public let namePrivacy: ArchiveNamePrivacy

    public let level: ArchivePacking.CompressionLevel

    /// Required when ``encryption`` is encrypted, and the one field that must never be logged,
    /// journalled or encoded. `FileOperation` is not `Codable` and ``UndoJournal`` returns `nil` for
    /// this kind, so there is no path from here to disk — but the reason it is an
    /// ``ArchivePassphrase`` rather than a `String` is that the guarantee should not rest on that
    /// remaining true.
    public let passphrase: ArchivePassphrase?

    /// Whether the walk may pull cloud placeholders down. `false` refuses the first `SF_DATALESS`
    /// item by name instead of silently downloading someone's whole Drive into an archive; the app
    /// sets it only after the user has agreed to the downloads.
    public let allowDataless: Bool

    public init(
        sourceDirectory: VFSPath,
        names: [String],
        archive: VFSPath,
        encryption: ArchiveEncryption,
        namePrivacy: ArchiveNamePrivacy = .visible,
        level: ArchivePacking.CompressionLevel = .normal,
        passphrase: ArchivePassphrase?,
        allowDataless: Bool = false
    ) {
        self.sourceDirectory = sourceDirectory
        self.names = names
        self.archive = archive
        self.encryption = encryption
        self.namePrivacy = namePrivacy
        self.level = level
        self.passphrase = passphrase
        self.allowDataless = allowDataless
    }
}

extension PackJob: Equatable {
    /// Written by hand because ``passphrase`` cannot be compared by value.
    ///
    /// `ArchivePassphrase` deliberately exposes no equality — the only comparison it offers is
    /// ``ArchivePassphrase/matches(_:)``, which exists for the "type it twice" confirmation and runs
    /// in constant time. Synthesising `Equatable` here would either need that method (turning an
    /// incidental `==` between two jobs into a passphrase comparison) or need the bytes out in the
    /// open. Identity is the honest answer for what this conformance is actually for: `FileOperation
    /// .Kind` is `Equatable`, so the queue can tell two jobs apart, and two jobs holding the *same*
    /// passphrase object are the same job.
    public static func == (lhs: PackJob, rhs: PackJob) -> Bool {
        lhs.sourceDirectory == rhs.sourceDirectory
            && lhs.names == rhs.names
            && lhs.archive == rhs.archive
            && lhs.encryption == rhs.encryption
            && lhs.namePrivacy == rhs.namePrivacy
            && lhs.level == rhs.level
            && lhs.passphrase === rhs.passphrase
            && lhs.allowDataless == rhs.allowDataless
    }
}

// MARK: - Outcome

/// What a finished pack job produced, carried home on `OperationReport/pack`.
///
/// Two cases for the same reason `ChecksumOutcome` has three: `OperationReport.failures` holds
/// `VFSError`s about a *path*, and everything that can go wrong here — an empty selection, a blank
/// passphrase, a cloud placeholder, libarchive refusing the write — is an ``EncryptedArchiveError``
/// about the job.
public enum PackOutcome: Sendable, Equatable {
    case created(PackSummary)
    /// The archive was not written. Nothing is left at the destination: the writer builds under a
    /// temporary name and only renames on success.
    case failed(EncryptedArchiveError)
}

/// What a successful pack wrote.
///
/// No per-entry list: the archive is the result, it is sitting in the destination pane, and the user
/// can open it. What is worth reporting is how many items went in — a number the user can compare
/// against what they marked — and whether it is encrypted, because that is the fact a status line
/// has to state plainly for a file whose protection is invisible from the outside.
public struct PackSummary: Sendable, Equatable {
    public let archive: VFSPath
    public let itemCount: Int
    /// The finished archive's own size on disk, or `0` if it could not be stat-ed.
    public let byteSize: Int64
    public let encryption: ArchiveEncryption
    /// Whether the names were wrapped away — what a "the recipient unpacks twice" note is gated on.
    public let namePrivacy: ArchiveNamePrivacy

    public init(
        archive: VFSPath,
        itemCount: Int,
        byteSize: Int64,
        encryption: ArchiveEncryption,
        namePrivacy: ArchiveNamePrivacy
    ) {
        self.archive = archive
        self.itemCount = itemCount
        self.byteSize = byteSize
        self.encryption = encryption
        self.namePrivacy = namePrivacy
    }
}
