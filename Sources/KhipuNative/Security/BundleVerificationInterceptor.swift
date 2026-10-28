import Foundation

/// Orchestrates the verify-before-execute check for the `/v1/kws.js` bundle load (ADR-003, AC-SEC-002: the WebView
/// executes only verified bytes). Twin of `BundleVerificationInterceptor.kt`: given the fetched bytes (or an
/// unavailability), select the baked key by request host, verify the embedded `//# khipu-sig:v1:` signature, and
/// either hand back the verified bytes to inject (`.serve`, no TOCTOU) or BLOCK the load (`.block` → the payment
/// resolves NETWORK_UNAVAILABLE, no last-known-good). Kotlin also checks the request host against the page's host;
/// iOS needs no such check because it builds the bundle URL from the page's own host (`bundleURL(forPage:)`).
/// That is host parity only. That the page itself requested the verified bundle is checked at readiness, from the
/// page's own document (`KhipuWebViewHost.readPageBundleRequest`).
///
/// Emits the `security.bundle_*` telemetry (through the `telemetry` sink) and signals a verification failure
/// via `onVerificationFailed` (→ NETWORK_UNAVAILABLE) or success via `onBundleVerified`. The gate does not read
/// that callback: on `.serve` the host stamps the page epoch, and the readiness gate checks the stamp (ADR-221).
///
/// The HTTP fetch is NOT here: the host performs it (`URLSession`) and hands the outcome to `decide`, keeping this
/// orchestration PURE and unit-tested, while the real fetch and WebView wiring (WKContentRuleList + inject) are not
/// unit-tested. `decide` NEVER throws.
final class BundleVerificationInterceptor {

    /// The fetch result handed to `decide`: either the raw bytes, or an unavailability with a reason.
    enum FetchOutcome {
        case ok(Data)
        case unavailable(reason: String, status: Int? = nil)
    }

    /// What the host must do with the intercepted request.
    enum Decision: Equatable {
        case serve(Data) // inject these (verified) bytes — the full bytes incl. the inert trailing comment
        case block       // block the load — the payment resolves NETWORK_UNAVAILABLE (failure was signalled)
    }

    private let verifier: BundleSignatureVerifier
    private let keysForHost: (String) -> [String]
    private let telemetry: TelemetrySink
    private let onVerificationFailed: () -> Void
    private let onBundleVerified: () -> Void

    init(
        verifier: BundleSignatureVerifier = BundleSignatureVerifier(),
        keysForHost: @escaping (String) -> [String] = KhipuSigningKeys.keysForHost,
        telemetry: TelemetrySink = NoopTelemetrySink(),
        onVerificationFailed: @escaping () -> Void = {},
        onBundleVerified: @escaping () -> Void = {}
    ) {
        self.verifier = verifier
        self.keysForHost = keysForHost
        self.telemetry = telemetry
        self.onVerificationFailed = onVerificationFailed
        self.onBundleVerified = onBundleVerified
    }

    /// Decide for an intercepted `/v1/kws.js` request served by `host`, given its `fetch` outcome. Emits the
    /// matching `security.bundle_*` telemetry and fires onVerificationFailed / onBundleVerified. The reasons are the
    /// `reason*` constants below; each is a value of its event's `reason` enum in events.schema.json.
    func decide(host: String, fetch: FetchOutcome) -> Decision {
        switch fetch {
        case .unavailable(let reason, let status):
            var fields: [String: Any] = ["host": host, "reason": reason, "severity": "error"]
            if let status = status { fields["status"] = status }
            telemetry.emit(event: TelemetryEvent.bundleUnavailable, fields: fields)
            onVerificationFailed()
            return .block
        case .ok(let bytes):
            // A host the SDK bakes no key for is a CONFIG/routing miss, not an attack, so it is decided here with
            // its own reason. Left to the verifier, the empty key list would come back .invalid and be reported as
            // `signature_mismatch`, a reason the schema documents as "a possible CDN compromise / MITM"; config
            // noise in the MITM channel is how a real MITM signal gets ignored.
            let keys = keysForHost(host)
            if keys.isEmpty {
                return blockSignatureInvalid(host: host, reason: Self.reasonUnknownHost)
            }
            switch verifier.verify(bundleBytes: bytes, spkiKeysBase64: keys) {
            case .valid:
                // serve exactly the bytes the SDK verified (no TOCTOU); the host stamps the page epoch on .serve.
                onBundleVerified()
                return .serve(bytes)
            case .invalid:
                // a present-but-invalid signature (tampered body / wrong key / malformed sig) — possible MITM.
                return blockSignatureInvalid(host: host, reason: Self.reasonSignatureMismatch)
            case .noMarker:
                // no `//# khipu-sig:v1:` trailer at all — an unsigned bundle is never trusted (AC-SEC-004).
                return blockSignatureInvalid(host: host, reason: Self.reasonNoMarker)
            }
        }
    }

    private func blockSignatureInvalid(host: String, reason: String) -> Decision {
        telemetry.emit(
            event: TelemetryEvent.bundleSignatureInvalid,
            fields: ["host": host, "reason": reason, "severity": "error"]
        )
        onVerificationFailed()
        return .block
    }

    // The fetch-unavailable reasons (events.schema.json bundle_unavailable.reason enum) — the host maps its
    // URLSession failure to one of these before calling decide(). Mirrors Kotlin's REASON_* constants.
    static let reasonDns = "dns"
    static let reasonTimeout = "timeout"
    static let reasonHttpError = "http_error"
    static let reasonEmpty = "empty"

    /// The body exceeded `BundleFetchPolicy.maxBundleBytes`: refused, never truncated-and-verified.
    static let reasonTooLarge = "too_large"

    /// The bytes were served by a host other than the one addressed (redirect / DNS surprise).
    static let reasonOriginMismatch = "origin_mismatch"

    // The signature-invalid reasons (events.schema.json bundle_signature_invalid.reason enum).
    static let reasonSignatureMismatch = "signature_mismatch"
    static let reasonNoMarker = "no_marker"

    /// The SDK bakes no key for this host: a config/routing miss, NOT a possible MITM.
    static let reasonUnknownHost = "unknown_host"

    /// The intercepted resource path, one route per environment. It is the ONLY path verified: every other request,
    /// the SPA bundle the iframe loads included, loads without verification (known gap, dw:520).
    static let bundlePath = "/v1/kws.js"
}
