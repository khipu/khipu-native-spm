import Foundation

/// Test-only: the two non-production origins, available only through `@_spi(KhipuTesting) import KhipuNative`.
/// Fixed values, deliberately not a URL — the SDK maps each to its own internal origin, so no test can load an
/// arbitrary page into the payment web view.
/// - `harness`: the SDK's test page `harness.html`, bundled in the integrating app's main bundle (the offline
///   quickstart flow). If the app does not bundle it, the payment is interrupted with `INVALID_CONFIGURATION`.
/// - `staging`: khipu's staging origin, `https://js.khipu-st.com/native/` (its bundle is verified like
///   production's).
@_spi(KhipuTesting) public enum KhipuTestOrigin: CaseIterable {
    case harness
    case staging
}

/// Test-only: the configuration passed to `KhipuPayment.init(test:)`. A value, not global state, so two instances
/// never share configuration.
/// - `origin`: which non-production origin to load.
/// - `telemetry`: receives the SDK's telemetry events (the public `init()` discards them); see `TelemetrySink` for
///   its threading contract. `nil` discards them.
/// - `onHandshakeMs`: called at most once per page load the SDK starts (at start, on restart, and on its automatic
///   recovery reloads; navigation started by the page itself does not count), with the milliseconds from that load
///   to the first moment the page was ready and cleared to receive the payment (on staging, only after its bundle
///   verified). Called on the main thread.
@_spi(KhipuTesting) public struct KhipuTestConfig {
    public let origin: KhipuTestOrigin
    public let telemetry: TelemetrySink?
    public let onHandshakeMs: ((Int) -> Void)?

    public init(origin: KhipuTestOrigin, telemetry: TelemetrySink? = nil, onHandshakeMs: ((Int) -> Void)? = nil) {
        self.origin = origin
        self.telemetry = telemetry
        self.onHandshakeMs = onHandshakeMs
    }
}
