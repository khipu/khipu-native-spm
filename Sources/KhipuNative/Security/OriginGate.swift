import Foundation

// The payment-page origin and the verify-before-deliver gate live side by side (one file, mirrored in Kotlin).
// The gate runs at the bridge responder's readiness flush, not at the coordinator's start(): a page must exist
// before its `/v1/kws.js` can be verified, so the decision is taken per page epoch once `khipuBridge` exists, and
// the operationId is withheld from any page whose bundle did not verify during that same load, or (iOS) whose own
// document did not request that bundle.
// Rationale and the accepted residuals: docs/adr/ADR-221-gate-at-readiness.md and the ADR it points to for the
// iOS page-request seal.

/// The payment-page origin. Every case carries a loadable URL. The public surface constructs `.production` only;
/// `.staging` and `.harness` are reachable solely through the `@_spi(KhipuTesting)` seam. `.harness` carries the
/// app-bundle URL resolved by `KhipuPayment.init(test:)` (`Bundle.main` `harness.html`, or `about:blank` when
/// absent, which `start()` fails fast on: an iOS-only check, because `about:blank` loads successfully where
/// Android's missing harness fails at load). Whether a page must verify its bundle is derived by the host from the
/// URL scheme, never stored here. Twin of Kotlin's `PaymentOrigin` (`OriginGate.kt`).
enum PaymentOrigin: Equatable {
    case production
    case staging
    case harness(URL)

    var url: URL {
        switch self {
        case .production: return URL(string: "https://\(KhipuSigningKeys.prodHost)/native/")!
        case .staging: return URL(string: "https://\(KhipuSigningKeys.stagingHost)/native/")!
        case .harness(let url): return url
        }
    }
}

/// The gate's verdict — a decision type, deliberately NOT a bare boolean: the verdict decides whether the
/// responder flushes or withholds the request, and a block must reach the terminal-latch cause
/// (`gate_blocked_bundle`, forensics), never collapse to one "OK" bit at the callsite. Kotlin's `GateDecision` has
/// no `awaitingPageRequest`: there the verification runs on the page's own request, so a verified bundle is always
/// one the page asked for.
enum GateDecision: Equatable {
    case allowed
    case blocked
    /// The page-origin bundle verified for this epoch, but the page's own document has not shown that it requested
    /// it. Not a verdict yet: WebKit reports the blocked request asynchronously, and on the pages measured it
    /// arrived after the page finished loading, when the bundle the SDK injects may already have defined
    /// `khipuBridge`. The responder re-checks within the readiness budget and blocks once it is spent.
    case awaitingPageRequest
}

/// The verify-before-deliver gate (ADR-221), evaluated by the bridge responder when a page epoch becomes READY.
enum OriginGate {
    /// `requiresVerifiedBundle` is true for every page but a file:/about: harness (fail-closed). Allowed iff no
    /// verification is required, or the bundle verified during THIS epoch (`verifiedGeneration ==
    /// readyGeneration`) AND the page's own document requested it (`pageRequestedBundle`). iOS verifies a fetch of
    /// its own, so the verification alone would also pass a page that runs some other bundle and never asked for
    /// this one. A previous page's verification never authorizes the current one. Pure, cannot throw. Kotlin's
    /// twin takes no `pageRequestedBundle`, because its verification stamp is taken on the page's own request.
    static func decide(requiresVerifiedBundle: Bool, verifiedGeneration: Int, readyGeneration: Int,
                       pageRequestedBundle: Bool) -> GateDecision {
        guard requiresVerifiedBundle else { return .allowed }
        guard verifiedGeneration == readyGeneration else { return .blocked }
        return pageRequestedBundle ? .allowed : .awaitingPageRequest
    }
}
