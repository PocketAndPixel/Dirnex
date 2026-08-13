import AppKit
import DirnexCore

/// The S3 half of the Connect-to-Server form: a service picker over the fields one bucket needs —
/// region, bucket, access key id and secret — plus the endpoint and path-style rows an
/// S3-compatible server adds (PLAN.md §M21).
///
/// Its own object and its own file for the same reason the FTP and SMB sets are: `ConnectServerForm`
/// sits at SwiftLint's `type_body_length` with three protocols in it, and a fourth set of stored
/// controls does not fit.
///
/// **The bucket row is the only optional one, and leaving it blank means something** (§M21 Slice 9):
/// the connection is to the *account*, whose buckets become the pane's rows. That is a second root
/// and never the only one — a key scoped to one bucket cannot list an account at all, and for that
/// key nothing about this form has changed.
///
/// **The service picker is the design decision here.** Amazon and everything that merely speaks its
/// protocol need the same request and disagree on exactly two things — where the endpoint comes from
/// and how the bucket is spelled into the URL — so the two are one layout with two rows that appear.
/// For Amazon the host is *derived* from the region (`s3.<region>.amazonaws.com`), which is not a
/// convenience: addressing a bucket through the wrong host answers 301 rather than serving it, and
/// the legacy global `s3.amazonaws.com` is right only for `us-east-1`. A field the user could type
/// that into would be a field they could get wrong for no benefit.
///
/// **The region row is deliberately *not* one of the two, and the reason is worth stating because
/// hiding it for an S3-compatible server is the obvious-looking tidy-up.** The region is not merely
/// how Amazon's host is spelled — SigV4 derives its signing key through it (date → region →
/// service), so it rides in the `Credential` scope of every request to every server (measured
/// 2026-08-13 against a real S3-compatible endpoint). That leaves two server behaviors and only one
/// of them is safe to assume: a **lenient** server recomputes with whatever region the client
/// declared and accepts anything — the endpoint above did, verifying `us-east-1`, `lax`, `default`
/// and `us-west-1` alike — while a **strict** one pins its own and refuses a mismatch, which is why
/// regional providers put the region in the host (`s3.us-west-004.backblazeb2.com`,
/// `s3.eu-central-1.wasabisys.com`). Hidden, a strict server is simply unreachable: the failure is
/// `SignatureDoesNotMatch`, which reads as a *credentials* problem, so the user retypes a key that
/// was never wrong and has no field to correct the thing that is. It costs a lenient server's user
/// nothing to leave the row visible, since it is blank and optional (``defaultRegion``).
@MainActor
final class ConnectServerS3Fields {
    /// `Amazon S3` | `S3-Compatible` — which one decides whether the endpoint is derived or typed.
    let serviceControl = NSPopUpButton(frame: .zero, pullsDown: false)

    let endpoint = ConnectFormFactory.textField(placeholder: "minio.local:9000")
    let region = ConnectFormFactory.textField(placeholder: "us-east-1")
    let bucket = ConnectFormFactory.textField(placeholder: ConnectText.bucketHint)
    let accessKeyID = ConnectFormFactory.textField(placeholder: "AKIA…")
    let secretKey = ConnectFormFactory.secureField(placeholder: ConnectText.secretKeyHint)

    let pathStyleCheckbox = NSButton(
        checkboxWithTitle: ConnectText.pathStyle,
        target: nil,
        action: nil
    )

    /// Fills the bucket field in from the account, for the keys allowed to ask
    /// (``ConnectServerS3BucketPicker``). An assist beside the field, never a replacement for it.
    let bucketPicker = ConnectServerS3BucketPicker()

    /// The rows shown whenever S3 is the selected protocol.
    private var rows: [NSGridRow] = []
    /// Endpoint and path-style; shown only for an S3-compatible server, since Amazon derives one
    /// and requires the other.
    private var compatibleRows: [NSGridRow] = []
    /// Whether S3 is the currently selected protocol, so the conditional rows stay hidden for the
    /// other three even as the service picker changes.
    private var s3Selected = false

    /// The field to focus when S3 is the selected protocol — the access key, which is the first row
    /// the user must fill in (the region above it is optional, resolving to ``defaultRegion`` when
    /// left blank) and the first of the three the bucket picker below waits on. Focusing the bucket
    /// instead would land the caret on the *last* row of the layout, above nothing but "Save as",
    /// and ask for the one value the rows above it exist to fetch.
    var firstResponder: NSView { accessKeyID }

    // MARK: - Building

    func buildRows(in grid: NSGridView) -> [NSView] {
        let bucketRow = bucketRow()
        rows = [
            grid.addRow(with: [ConnectFormFactory.label(ConnectText.service), serviceControl])
        ]
        compatibleRows = [
            grid.addRow(with: [ConnectFormFactory.label(ConnectText.endpoint), endpoint]),
            grid.addRow(with: [NSGridCell.emptyContentView, pathStyleCheckbox])
        ]
        // Bucket goes *below* the credentials, because that is the order the row can be filled in:
        // the picker beside it needs the region, the key id and the secret before it can ask for a
        // list, so a bucket row above them is a row whose own assist is not yet usable.
        rows += [
            grid.addRow(with: [ConnectFormFactory.label(ConnectText.region), region]),
            grid.addRow(with: [ConnectFormFactory.label(ConnectText.accessKeyID), accessKeyID]),
            grid.addRow(with: [ConnectFormFactory.label(ConnectText.secretKey), secretKey]),
            grid.addRow(with: [ConnectFormFactory.label(ConnectText.bucket), bucketRow])
        ]
        wireBucketPicker()

        serviceControl.addItems(withTitles: [ConnectText.amazonS3, ConnectText.s3Compatible])
        serviceControl.selectItem(at: Service.amazon.rawValue)
        serviceControl.target = self
        serviceControl.action = #selector(serviceChanged)

        // **The row, not the field.** `ConnectServerForm` pins every control it is handed to the
        // form's 364 pt column, so returning `bucket` here would size the *field* to 364 and leave
        // the stack 34 pt wider than its grid cell. The button then draws perfectly — `NSView` does
        // not clip — and is **unclickable**, because hit testing does respect bounds. Measured live:
        // the glyph was on screen, correctly placed, and no click on it ever reached the action.
        return [serviceControl, endpoint, region, accessKeyID, secretKey, bucketRow]
    }

    /// The bucket field with its picker button beside it. A stack rather than a third grid column,
    /// because the button belongs to this one row: a column would reserve its width in *every* row
    /// of the form, including the four the other three protocols draw.
    ///
    /// The button leads and the field follows, so it sits at the column's edge where the eye already
    /// is on the way down from the credentials above — the gesture that fills the field comes before
    /// the field it fills, rather than being something to find past the end of it.
    private func bucketRow() -> NSView {
        let row = NSStackView(views: [bucketPicker.view, bucket])
        row.orientation = .horizontal
        row.spacing = 6
        // The stack carries the form's width (see `buildRows`), so the field takes whatever the
        // button leaves rather than the two of them adding up past the column.
        bucket.setContentHuggingPriority(.defaultLow, for: .horizontal)
        bucket.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        bucketPicker.view.setContentHuggingPriority(.required, for: .horizontal)
        return row
    }

    private func wireBucketPicker() {
        bucketPicker.account = { [weak self] in self?.readAccount() }
        bucketPicker.didChoose = { [weak self] name, region in
            guard let self else { return }
            bucket.stringValue = name
            // Only when the server named one: a bucket list spans regions, and overwriting a region
            // the user typed with nothing would break the connect that was about to work.
            if let region, !region.isEmpty { self.region.stringValue = region }
        }
    }

    /// Every row this field set owns, for the form's show/hide and its size reservation.
    var allRows: [NSGridRow] { rows + compatibleRows }

    /// What a blank region field resolves to: AWS's own default, and what an S3-compatible server
    /// that has no regions is usually configured with.
    ///
    /// **The field is left empty and this is applied when it is read**, rather than prefilled. A
    /// region is genuinely optional for most of the servers this backend exists to reach — measured
    /// 2026-08-13 against a real S3-compatible endpoint, which verified the signature while ignoring
    /// the credential scope's region entirely, accepting `us-east-1`, `lax` and `default` alike — so
    /// a prefilled value states a fact about the user's server that the app does not know. The
    /// placeholder still shows it, which is the honest version of the same hint.
    ///
    /// It cannot be dropped altogether, in *either* direction. SigV4 always names a region, so the
    /// signature needs some string; and for the Amazon service the region additionally **derives the
    /// host** (`s3.<region>.amazonaws.com`), where an empty one would build `s3..amazonaws.com` —
    /// not a wrong region but a nonexistent server. Defaulting is safe there for a reason that is
    /// itself measured: a bucket in another region answers 301 naming the region that works, and
    /// `PanelViewController+ConnectS3` re-aims one attempt at it automatically, so a blank field
    /// costs an AWS user a redirect rather than a failure.
    static let defaultRegion = "us-east-1"

    /// The region to sign with: what was typed, or ``defaultRegion`` when the field is blank.
    ///
    /// One funnel for both readers. `readForm` and `readAccount` ask the same question, and a
    /// fallback applied in only one of them would leave the bucket picker refusing to ask — its
    /// guard rejects an empty region — on a form whose Connect button would have worked.
    private var regionValue: String {
        let typed = ConnectFormFactory.trimmed(region)
        return typed.isEmpty ? Self.defaultRegion : typed
    }

    // MARK: - State

    /// Which service the picker has selected. Named rather than compared by index, so re-ordering
    /// the dropdown cannot silently re-point the predicate (the same lesson `ConnectServerForm`'s
    /// own `Protocols` enum carries, and the reason `isSMB` once read `selectedSegment == 1`).
    private enum Service: Int {
        case amazon = 0
        case compatible = 1
    }

    private var service: Service {
        Service(rawValue: serviceControl.indexOfSelectedItem) ?? .amazon
    }

    private var isCompatible: Bool { service == .compatible }

    func setHidden(_ hidden: Bool) {
        s3Selected = !hidden
        for row in rows { row.isHidden = hidden }
        refreshConditionalRows()
    }

    private func refreshConditionalRows() {
        for row in compatibleRows { row.isHidden = !s3Selected || !isCompatible }
    }

    @objc private func serviceChanged() {
        refreshConditionalRows()
        onLayoutChanged?()
    }

    /// Called when a change alters the layout's height, so the sheet can re-fit.
    var onLayoutChanged: (() -> Void)?

    // MARK: - Prefill

    func apply(location: S3Location) {
        bucket.stringValue = location.bucket
        apply(location.account, secret: SecretKeychain.password(for: location) ?? "")
    }

    /// Prefill from a saved **account**: the same rows with the bucket left blank, which is exactly
    /// the state that saved it — so editing one and pressing Connect reconnects to the account
    /// rather than silently needing a bucket typed in.
    func apply(account: S3Account) {
        bucket.stringValue = ""
        apply(account, secret: SecretKeychain.password(for: account) ?? "")
    }

    /// The rows an account and a bucket share, which is all of them but one.
    ///
    /// One funnel rather than two prefills, because the *service* derivation below is the part that
    /// must not fork: it decides which rows are even visible, and two copies of it would disagree
    /// the first time either was corrected.
    private func apply(_ account: S3Account, secret: String) {
        region.stringValue = account.region
        accessKeyID.stringValue = account.accessKeyID
        secretKey.stringValue = secret
        // A saved connection is read back as *compatible* whenever its host is not the one Amazon's
        // region derives — including a bucket on AWS reached through a legacy or accelerated host.
        // Deciding it from the host rather than storing a service flag is what keeps the two from
        // disagreeing: the host is what the request is actually built from.
        let derived = S3Location.awsHost(region: account.region)
        let isAmazon = account.host == derived
            && account.addressing == .virtualHost
            && account.usesTLS
            && account.port == 443
        serviceControl.selectItem(at: (isAmazon ? Service.amazon : .compatible).rawValue)
        if !isAmazon {
            endpoint.stringValue = Self.endpointText(for: account)
            pathStyleCheckbox.state = account.addressing == .path ? .on : .off
        }
        refreshConditionalRows()
    }

    /// The endpoint field's text for a saved connection: the scheme only when it is the one the
    /// field does not assume, and the port only when it is not the scheme's default — so a
    /// round-trip through the form gives back what the user typed rather than a canonicalized
    /// spelling of it.
    private static func endpointText(for account: S3Account) -> String {
        let isDefaultPort = (account.usesTLS && account.port == 443)
            || (!account.usesTLS && account.port == 80)
        let authority = isDefaultPort ? account.host : "\(account.host):\(account.port)"
        return account.usesTLS ? authority : "http://\(authority)"
    }

    // MARK: - Reading

    /// The account the bucket picker asks and the empty-bucket connect browses, or `nil` when what
    /// is typed so far cannot make one.
    ///
    /// **It requires everything `readForm` does except the bucket**, which is the point: the picker
    /// exists to supply that one field, so demanding it would make the button useful only to
    /// somebody who no longer needs it.
    ///
    /// The addressing mode rides along even though the one request this was originally built for —
    /// `ListAllMyBuckets` — has no bucket to spell into a URL and ignores it. It stopped being
    /// decorative the moment an account became a *place*: `CreateBucket`, `DeleteBucket` and
    /// `HeadBucket` all name a bucket, and so does every connection made by walking into one. An
    /// account built without it here and with it elsewhere would be the same question with two
    /// answers, which is this project's most repeated finding.
    func readAccount() -> (account: S3Account, secretAccessKey: String)? {
        let regionValue = regionValue
        let keyValue = ConnectFormFactory.trimmed(accessKeyID)
        guard ConnectFormFactory.isSafeArgument(regionValue),
              ConnectFormFactory.isSafeArgument(keyValue),
              !secretKey.stringValue.isEmpty,
              let resolved = resolvedEndpoint(region: regionValue) else { return nil }
        let account = S3Account(
            host: resolved.host,
            port: resolved.port,
            region: regionValue,
            accessKeyID: keyValue,
            addressing: addressing,
            usesTLS: resolved.usesTLS
        )
        return (account, secretKey.stringValue)
    }

    /// How a bucket reached from this form is spelled into the URL. Path-style is a *compatible*-only
    /// row, so ticking it and switching back to Amazon must not leave it behind.
    private var addressing: S3Addressing {
        isCompatible && pathStyleCheckbox.state == .on ? .path : .virtualHost
    }

    /// Where the request goes: typed for an S3-compatible server, derived from the region for
    /// Amazon — where a field the user could get wrong would buy them nothing, since a bucket
    /// addressed through the wrong host answers 301 rather than serving it.
    private func resolvedEndpoint(region regionValue: String) -> S3Endpoint? {
        guard isCompatible else { return S3Endpoint(host: S3Location.awsHost(region: regionValue)) }
        return S3Endpoint.parse(endpoint.stringValue)
    }

    /// The validated endpoint and secret, or `nil` when a required field is empty or unusable.
    ///
    /// **A blank bucket is an answer, not an omission** (PLAN.md §M21 Slice 9): it connects to the
    /// account and browses its buckets as rows. Every other field is still required — the endpoint
    /// this reaches, the key that signs for it and the region it signs in are exactly the same ones
    /// a bucket connection needs, which is why the two share `readAccount`.
    ///
    /// The blank field is safe to give a meaning to precisely because it had none: a bucket name
    /// cannot be empty (`S3BucketName.minimumLength` is 3), so nothing that used to connect now
    /// connects somewhere else. What it costs is a typo landing in the account pane instead of an
    /// error, and that is recoverable in one keystroke — the bucket the user meant is a row there.
    func readForm(saveName: String?) -> ConnectServerPrompt.Form? {
        // The secret isn't trimmed — it is 40 characters of base64 and every one of them counts —
        // but a blank one is certainly a mistake, and `readAccount` rejects it rather than signing
        // with nothing.
        guard let resolved = readAccount() else { return nil }
        let account = resolved.account
        let bucketValue = ConnectFormFactory.trimmed(bucket)
        guard !bucketValue.isEmpty else {
            return ConnectServerPrompt.Form(
                endpoint: .s3Account(account),
                password: resolved.secretAccessKey,
                saveName: saveName
            )
        }
        guard ConnectFormFactory.isSafeArgument(bucketValue) else { return nil }

        return ConnectServerPrompt.Form(
            endpoint: .s3(account.bucketLocation(named: bucketValue)),
            password: resolved.secretAccessKey,
            saveName: saveName
        )
    }
}
