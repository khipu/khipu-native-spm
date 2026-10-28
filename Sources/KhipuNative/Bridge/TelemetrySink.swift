import Foundation

/// Receives the SDK's diagnostic events. Each event is one of the `TelemetryEvent` names plus a dictionary of
/// fields; many events include a `severity` field (`warn` or `error`). The payment outcome is never reported
/// here: it is delivered only through `start`.
///
/// Event names are grouped by prefix:
///  - `bridge.*`: the bridge between the payment page and the SDK — rejected, dropped or late messages,
///    undeliverable results, unavailable or disabled native capabilities, and untranslated error codes.
///  - `lifecycle.*`: the payment page's lifecycle — a failed liveness check after resuming, the termination of
///    the WebView's content process, and the payer's return from their bank or wallet app.
///  - `security.*`: a payment bundle that could not be verified, and blocked navigations.
///  - `reconciliation.*`: expiry of locally stored orphaned-payment records.
///  - `i18n.*`: error messages missing in the requested locale.
///
/// Events stay on the device: the SDK hands them to this sink in-process and never transmits them. No event
/// carries a raw correlation id or operation id; an event that refers to an operation carries a truncated SHA-256
/// hash instead (`correlation_id_hash`, `operation_id_hash`), which is enough to correlate events in a log
/// without exposing the id.
///
/// The public `KhipuPayment()` initializer installs `NoopTelemetrySink`, so a production integration receives no
/// events. To observe them, pass a sink through the test-only `KhipuTestConfig` (`@_spi(KhipuTesting)`).
///
/// An implementation must be thread-safe, fast, and must not throw; see `emit(event:fields:)`.
public protocol TelemetrySink: AnyObject {
    /// Receives one diagnostic `event` (a `TelemetryEvent` name) with its structured `fields`. Must not throw.
    ///
    /// **Threading: an implementation must be thread-safe.** The SDK calls this on whichever thread reached the
    /// emit point, and that is not always the same thread: emits come from the main queue, from the SDK's
    /// per-operation and timeout queues, and from the `URLSession` delegate queue that fetches the payment bundle.
    /// Two calls may therefore overlap. A sink that appends to a plain `Array` or writes a non-serialized file
    /// handle will corrupt under that, and the corruption shows up as lost diagnostics during exactly the incidents
    /// the diagnostics exist for. The SDK does not hop to the main queue for you: doing so would add latency to the
    /// payment path.
    ///
    /// A sink must also be fast and non-blocking: it runs inline on the emitting thread, so any I/O belongs on the
    /// implementation's own queue.
    func emit(event: String, fields: [String: Any])
}

/// The names of the diagnostic events the SDK reports through `TelemetrySink`.
public enum TelemetryEvent {
    /// A second result arrived for a bridge request that had already been answered (a capability result racing
    /// its timeout); the later one was dropped.
    public static let duplicateResultDropped = "bridge.duplicate_result_dropped"

    /// A result arrived for a bridge request the SDK no longer tracks: it was answered long enough ago to have
    /// expired, or it was abandoned when the page reloaded.
    public static let lateResponse = "bridge.late_response"

    /// A message from the payment page exceeded the size limit and was dropped without being parsed.
    public static let envelopeTooLarge = "bridge.envelope_too_large"

    /// A request from the payment page had an unsupported `message_type` and was rejected with an error.
    public static let invalidMessageType = "bridge.invalid_message_type"

    /// A message from the payment page was malformed (unparseable, a repeated top-level key, a missing or blank
    /// required field, or a payload that is not an object) and was rejected. `reason` says which.
    public static let malformedEnvelope = "bridge.malformed_envelope"

    /// A request from the payment page reused the id of a request that is in flight or was recently answered; it
    /// was dropped.
    public static let duplicateRequestDropped = "bridge.duplicate_request_dropped"

    /// A message from the payment page belonged to a different page session than the current one; it was
    /// discarded.
    public static let sessionMismatchDiscarded = "bridge.session_mismatch_discarded"

    /// A native capability is not available on this OS version. Emitted once, when the capability is registered;
    /// the payment page sees it as unavailable.
    public static let capabilityUnavailable = "bridge.capability_unavailable"

    /// A payment response from the page referred to an operation the SDK does not know or has already finished,
    /// and was discarded. `reason` says which.
    public static let orphanResponse = "bridge.orphan_response"

    /// An error code from the payment page had no public mapping, so the error was reported as `INTERNAL_ERROR`.
    public static let untranslatedError = "bridge.untranslated_error"

    /// A result could not be delivered back into the payment page: for example the script evaluation failed, the
    /// WebView was gone or had moved to another page, or the page never became ready. `reason` says which.
    public static let respondDeliveryFailed = "bridge.respond_delivery_failed"

    /// After the app returned to the foreground, the payment page failed the SDK's liveness check, so the SDK
    /// reloaded the page and continued the same payment. `reason` says how the check failed.
    public static let unrecoverableResume = "lifecycle.unrecoverable_resume"

    /// The WebView's content process terminated. If a payment was in progress, the SDK reloaded its page to
    /// continue it, or failed it with `INTERNAL_ERROR` when the WebView could not be recovered. `recovered` is true
    /// when the page was reloaded.
    public static let renderProcessGone = "lifecycle.render_process_gone"

    /// The payment bundle (`kws.js`) failed signature verification, so the SDK refused to run it and the active
    /// payment fails with `NETWORK_UNAVAILABLE`. `reason` says why.
    public static let bundleSignatureInvalid = "security.bundle_signature_invalid"

    /// The payment bundle (`kws.js`) could not be fetched, or could not be used safely, so the SDK refused to load
    /// it and the active payment fails with `NETWORK_UNAVAILABLE`. `reason` says why.
    public static let bundleUnavailable = "security.bundle_unavailable"

    /// The payment page tried to navigate its main frame to another origin or to a non-http(s) URL; the SDK
    /// cancelled that navigation. The payment continues.
    public static let navigationBlocked = "security.navigation_blocked"

    /// The payment page delivered a result after the SDK had already reported the payment as timed out, cancelled
    /// or closed. The late result is discarded and the reported outcome stands, so the payment's actual status
    /// needs to be reconciled. Emitted at most once per payment.
    public static let reconciliationRequired = "bridge.reconciliation_required"

    /// The SDK deleted locally stored orphaned-payment records that were older than 30 days.
    public static let metadataPurged = "reconciliation.metadata_purged"

    /// A native capability was left out of this build by its build flag. Emitted once, at SDK initialization.
    public static let capabilityDisabled = "bridge.capability_disabled"

    /// The app returned to the foreground after the SDK opened the payer's bank or wallet app for the active
    /// payment. Informational: it does not change the payment flow.
    public static let bankAppReturnDetected = "lifecycle.bank_app_return_detected"

    /// An error message was not available in the requested locale, so the SDK used its `es-CL` text. One event per
    /// missing message key.
    public static let i18nMissingTranslation = "i18n.missing_translation"
}

/// A sink that discards every event; the SDK's default when no sink is supplied.
public final class NoopTelemetrySink: TelemetrySink {
    public init() {}
    public func emit(event: String, fields: [String: Any]) {}
}
