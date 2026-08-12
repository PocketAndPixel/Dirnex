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

    /// The rows shown whenever S3 is the selected protocol.
    private var rows: [NSGridRow] = []
    /// Endpoint and path-style; shown only for an S3-compatible server, since Amazon derives one
    /// and requires the other.
    private var compatibleRows: [NSGridRow] = []
    /// Whether S3 is the currently selected protocol, so the conditional rows stay hidden for the
    /// other three even as the service picker changes.
    private var s3Selected = false

    /// The field to focus when S3 is the selected protocol — the bucket, which is the one field
    /// nothing else can supply and the thing the user came here to name.
    var firstResponder: NSView { bucket }

    // MARK: - Building

    func buildRows(in grid: NSGridView) -> [NSView] {
        rows = [
            grid.addRow(with: [ConnectFormFactory.label(ConnectText.service), serviceControl])
        ]
        compatibleRows = [
            grid.addRow(with: [ConnectFormFactory.label(ConnectText.endpoint), endpoint]),
            grid.addRow(with: [NSGridCell.emptyContentView, pathStyleCheckbox])
        ]
        rows += [
            grid.addRow(with: [ConnectFormFactory.label(ConnectText.region), region]),
            grid.addRow(with: [ConnectFormFactory.label(ConnectText.bucket), bucket]),
            grid.addRow(with: [ConnectFormFactory.label(ConnectText.accessKeyID), accessKeyID]),
            grid.addRow(with: [ConnectFormFactory.label(ConnectText.secretKey), secretKey])
        ]

        serviceControl.addItems(withTitles: [ConnectText.amazonS3, ConnectText.s3Compatible])
        serviceControl.selectItem(at: Service.amazon.rawValue)
        serviceControl.target = self
        serviceControl.action = #selector(serviceChanged)
        region.stringValue = Self.defaultRegion

        return [serviceControl, endpoint, region, bucket, accessKeyID, secretKey]
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

        let resolved: S3Endpoint
        if isCompatible {
            guard let parsed = S3Endpoint.parse(endpoint.stringValue) else { return nil }
            resolved = parsed
        } else {
            resolved = S3Endpoint(host: S3Location.awsHost(region: regionValue))
        }
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
