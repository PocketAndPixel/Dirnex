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
/// **The service picker is the design decision here.** Amazon and everything that merely speaks its
/// protocol need the same request and disagree on exactly two things — where the endpoint comes from
/// and how the bucket is spelled into the URL — so the two are one layout with two rows that appear.
/// For Amazon the host is *derived* from the region (`s3.<region>.amazonaws.com`), which is not a
/// convenience: addressing a bucket through the wrong host answers 301 rather than serving it, and
/// the legacy global `s3.amazonaws.com` is right only for `us-east-1`. A field the user could type
/// that into would be a field they could get wrong for no benefit.
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
    /// nothing has filled in already (the region carries a default) and the first of the three the
    /// bucket picker below waits on. Focusing the bucket instead would land the caret on the *last*
    /// row of the layout, above nothing but "Save as", and ask for the one value the rows above it
    /// exist to fetch.
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
        region.stringValue = Self.defaultRegion

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

    /// What AWS treats as the default and what an S3-compatible server that has no regions is
    /// usually configured with — so the field starts on the answer that is right most of the time
    /// and is still a field, because SigV4's credential scope always names one.
    static let defaultRegion = "us-east-1"

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
        region.stringValue = location.region
        bucket.stringValue = location.bucket
        accessKeyID.stringValue = location.accessKeyID
        secretKey.stringValue = SecretKeychain.password(for: location) ?? ""
        // A saved connection is read back as *compatible* whenever its host is not the one Amazon's
        // region derives — including a bucket on AWS reached through a legacy or accelerated host.
        // Deciding it from the host rather than storing a service flag is what keeps the two from
        // disagreeing: the host is what the request is actually built from.
        let derived = S3Location.awsHost(region: location.region)
        let isAmazon = location.host == derived
            && location.addressing == .virtualHost
            && location.usesTLS
            && location.port == 443
        serviceControl.selectItem(at: (isAmazon ? Service.amazon : .compatible).rawValue)
        if !isAmazon {
            endpoint.stringValue = Self.endpointText(for: location)
            pathStyleCheckbox.state = location.addressing == .path ? .on : .off
        }
        refreshConditionalRows()
    }

    /// The endpoint field's text for a saved location: the scheme only when it is the one the field
    /// does not assume, and the port only when it is not the scheme's default — so a round-trip
    /// through the form gives back what the user typed rather than a canonicalized spelling of it.
    private static func endpointText(for location: S3Location) -> String {
        let isDefaultPort = (location.usesTLS && location.port == 443)
            || (!location.usesTLS && location.port == 80)
        let authority = isDefaultPort ? location.host : "\(location.host):\(location.port)"
        return location.usesTLS ? authority : "http://\(authority)"
    }

    // MARK: - Reading

    /// The account the bucket picker asks, or `nil` when what is typed so far cannot make one.
    ///
    /// **It requires everything `readForm` does except the bucket**, which is the point: the picker
    /// exists to supply that one field, so demanding it would make the button useful only to
    /// somebody who no longer needs it.
    func readAccount() -> (account: S3Account, secretAccessKey: String)? {
        let regionValue = ConnectFormFactory.trimmed(region)
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
            usesTLS: resolved.usesTLS
        )
        return (account, secretKey.stringValue)
    }

    /// Where the request goes: typed for an S3-compatible server, derived from the region for
    /// Amazon — where a field the user could get wrong would buy them nothing, since a bucket
    /// addressed through the wrong host answers 301 rather than serving it.
    private func resolvedEndpoint(region regionValue: String) -> S3Endpoint? {
        guard isCompatible else { return S3Endpoint(host: S3Location.awsHost(region: regionValue)) }
        return S3Endpoint.parse(endpoint.stringValue)
    }

    /// The validated endpoint and secret, or `nil` when a required field is empty or unusable.
    func readForm(saveName: String?) -> ConnectServerPrompt.Form? {
        let bucketValue = ConnectFormFactory.trimmed(bucket)
        let regionValue = ConnectFormFactory.trimmed(region)
        let keyValue = ConnectFormFactory.trimmed(accessKeyID)
        guard ConnectFormFactory.isSafeArgument(bucketValue),
              ConnectFormFactory.isSafeArgument(regionValue),
              ConnectFormFactory.isSafeArgument(keyValue) else { return nil }
        // The secret isn't trimmed — it is 40 characters of base64 and every one of them counts —
        // but a blank one is certainly a mistake, so it is rejected rather than sent empty.
        guard !secretKey.stringValue.isEmpty else { return nil }

        guard let resolved = resolvedEndpoint(region: regionValue) else { return nil }
        let location = S3Location(
            host: resolved.host,
            port: resolved.port,
            bucket: bucketValue,
            region: regionValue,
            accessKeyID: keyValue,
            addressing: isCompatible && pathStyleCheckbox.state == .on ? .path : .virtualHost,
            usesTLS: resolved.usesTLS
        )
        return ConnectServerPrompt.Form(
            endpoint: .s3(location),
            password: secretKey.stringValue,
            saveName: saveName
        )
    }
}
