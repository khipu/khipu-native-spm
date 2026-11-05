import Foundation
import WebKit
import CryptoKit
import BridgeGenerated

/// Configures the payment WebView and connects it to the bridge. `KhipuPayment` creates and owns the host for its
/// payment page.
///
/// The host applies the SDK's hardened WebView settings and a mobile layout, exposes `window.khipuNative.send(json)`
/// to the page, and routes the page's messages to the SDK. It delivers results back into the page only once the page
/// has loaded and defined `window.khipuBridge`, and never into a page other than the one they belong to; a delivery
/// that cannot be made is reported through the `TelemetrySink` instead. It verifies the signature of the payment
/// bundle (`/v1/kws.js`) before the WebView may run it, hands the payment request only to a page that requested that
/// bundle itself and, in the SDK's own payment flow, blocks main-frame navigations away from the payment origin.
final class KhipuWebViewHost: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    /// The WebView this host drives. The same instance is kept even after its content process terminates; WebKit
    /// starts a new content process on the next load.
    let webView: WKWebView
    private let dispatcher: BridgeDispatcher
    private let responder: BridgeResponder
    private let telemetry: TelemetrySink
    private static let messageName = "khipuNative"
    // Same inbound bound as the dispatcher and the coordinator (256KB, exact UTF-8 bytes), applied BEFORE the
    // router parses.
    private static let maxRoutedEnvelopeBytes = 256 * 1024
    // True once the page finished its initial main-frame load (`didFinish`, when the tracker says the page-finish is
    // the page's). Gates `reportLoadFailure` so a main-frame failure AFTER a successful load (a kws.js SPA navigation)
    // does not resolve a load-failure terminal over a running payment; twin of Android's `onReceivedError` gate. Reset
    // on each `load(url:)`. Main-thread only (the WKNavigationDelegate callbacks and load() run on main).
    private var hasFinishedInitialLoad = false

    /// The verified bundle JS waiting to be injected, when it arrived BEFORE `didFinish`. The two asynchronies (page
    /// load, URLSession fetch+verify) can complete in either order, so whichever finishes last performs the
    /// injection. Injecting into a page that has not committed yet silently does nothing.
    private var verifiedBundleJS: String?

    /// The URL the SDK fetches and verifies for the page `load(url:)` loads, `https://<page host>/v1/kws.js`; nil for
    /// a page with no bundle (the harness). Readiness accepts the page's own request for exactly this URL.
    /// Main-thread only.
    private var expectedBundleURL: URL?

    /// Tests only. When set, `load(url:)` calls it once the block rule is installed, in place of the network page
    /// load and bundle fetch, with the page URL and that load's epoch, and takes the navigation it returns as the
    /// page's. A test serves a page from memory under the real https origin and hands over its bundle through
    /// `acceptVerifiedBundle`. The SDK never sets it.
    var loadWithoutNetworkForTesting: ((_ url: URL, _ epoch: Int) -> WKNavigation?)?

    /// Tests only. When set, the host hands it the issue of the page's load with that load's epoch, instead of
    /// issuing it at once; the page is issued when the test calls `issue`. The SDK never sets it.
    var holdPageLoadForTesting: ((_ epoch: Int, _ issue: @escaping () -> Void) -> Void)?

    // Which navigation callbacks belong to the host's own page load (see `HostLoadTracker`). Main-thread only.
    private let hostLoadTracker = HostLoadTracker()
    // The page and epoch of the current host load, kept to issue the page again when another document took its place.
    private var hostLoad: (url: URL, epoch: Int)?

    /// The steady delay between readiness probes, and the cap of the short first ones (`probeRampMs`). The responder
    /// grants `BridgeResponder.defaultMaxProbeAttempts` of them, about 5 s for the bundle to mount. Tests shorten it
    /// to reach a spent budget quickly.
    var probeRetryDelayMs = 200
    /// The first retries after a missed probe. The bundle injected at page-finish usually defines `khipuBridge` a few
    /// tens of milliseconds after the first probe (7–77 ms on real devices), and a flat interval made each of those
    /// loads wait the full 200 ms.
    static let probeRampMs = [25, 25, 50, 100]
    private var probeRetryGeneration = -1
    private var probeRetries = 0

    /// The delay before retry `retry` (1-based) of one page's readiness probe.
    static func probeRetryDelay(retry: Int, steadyMs: Int) -> Int {
        retry >= 1 && retry <= probeRampMs.count ? min(probeRampMs[retry - 1], steadyMs) : steadyMs
    }
    /// Attempts to install the block rule before giving up. The failure mode is transient (WebKit store/resource
    /// state), not a bad rule (the JSON is a literal), so a bounded retry removes almost every occurrence before the
    /// fail-closed decision has to be taken.
    static let blockRuleAttempts = 3
    /// The block rule. `([?#].*)?$` so a cache-bust query or fragment (`/v1/kws.js?v=…`) is ALSO blocked and only
    /// injected after verification (a bare `…\.js$` anchor would let a query'd URL load unverified). Android's
    /// `url.path` match already ignores the query, so both platforms block the same loads.
    static let bundleBlockRule = #"[{"trigger":{"url-filter":".*/v1/kws\\.js([?#].*)?$"},"action":{"type":"block"}}]"#

    /// Store identifier DERIVED from the rule's content, so editing the rule invalidates the on-disk compiled copy
    /// automatically (see the note in `installBundleBlockRule`).
    static let bundleBlockRuleIdentifier: String = {
        let digest = SHA256.hash(data: Data(bundleBlockRule.utf8))
        return "khipu-block-kws-" + digest.compactMap { String(format: "%02x", $0) }.joined().prefix(8)
    }()

    /// `security.bundle_unavailable` reason for "the block rule could not be installed, so we refused to load
    /// rather than execute an unverified bundle". Matches the enum in events.schema.json.
    static let reasonBlockRuleUnavailable = "block_rule_unavailable"

    /// Where an inbound `message_type:"response"` envelope goes: the payment coordinator's `completeFromWeb`. The
    /// dispatcher handles requests only; its reject path is for malformed traffic, not for the `startPayment_v1`
    /// response. Nil (no coordinator wired, as in the harness tests) sends everything to the dispatcher. Settable
    /// after init because `KhipuPayment` constructs the host first, then the coordinator.
    var onResponseEnvelope: ((String) -> Void)?

    /// Signalled when the content process terminates (`webViewWebContentProcessDidTerminate`), so the coordinator
    /// runs its tiered recovery (`webViewRenderGone`). `didCrash` is always true: the iOS API carries no cause.
    /// Settable after construction, like `onResponseEnvelope`; `KhipuPayment` wires it weakly. iOS does NOT crash the
    /// app on content-process death (the WebView blanks), so this is recovery for parity, not crash prevention
    /// (Android's twin must return true to survive). Mirrors Kotlin's `onRenderProcessGone`.
    var onRenderProcessGone: ((Bool) -> Void)?

    /// Signalled when the page's load cannot produce the page: a MAIN-FRAME navigation of that load, or of its
    /// document before its first page-finish, GENUINELY fails (host unreachable, file unreadable), or another document
    /// took the place of the page's load twice. The coordinator then fails the payment fast (`webViewLoadFailed`: NETWORK_UNAVAILABLE for an https origin, INVALID_CONFIGURATION for
    /// the harness) instead of a blank sheet for the whole payment budget and then a misleading PAYMENT_TIMEOUT.
    /// Settable after construction, like `onResponseEnvelope`; `KhipuPayment` wires it weakly. Detection differs from
    /// Android: a missing bundled harness resolves to about:blank, which loads SUCCESSFULLY and never reaches here, so
    /// the coordinator's `start()` guard (`isUnloadableOrigin`) owns that case. Nil is safe.
    var onLoadFailed: (() -> Void)?

    /// Signalled when verify-before-execute BLOCKED the `/v1/kws.js` load (bad or absent embedded signature, or the
    /// bundle was unavailable), so the coordinator resolves the payment NETWORK_UNAVAILABLE
    /// (`bundleVerificationFailed`). Settable after init; `KhipuPayment` wires it weakly. Mirrors Kotlin's
    /// `onBundleVerificationFailed`.
    var onBundleVerificationFailed: (() -> Void)?

    /// The bundle verified and STAMPED the page epoch. An observation hook for tests: the readiness gate reads the
    /// responder's stamp, not this callback. Fires AFTER the stamp. Mirrors Kotlin's `onBundleVerified`.
    var onBundleVerified: (() -> Void)?

    /// A page that needed a verified bundle reached readiness without one for its epoch, or without having requested
    /// it within the readiness budget (the readiness gate, ADR-221). `KhipuPayment` wires it to
    /// `coordinator.bundleUnverifiedAtReadiness()`. Twin of Kotlin's `onUnverifiedReady`.
    var onUnverifiedReady: (() -> Void)?

    /// Milliseconds from a host `load(url:)` to the first gate-passing readiness after it, reported at most once per
    /// host `load(url:)` (a page's own self-navigation does not re-arm it). Test-only observation, wired only through
    /// `KhipuTestConfig.onHandshakeMs`. Main-thread only. Twin of Kotlin's `onHandshakeMs`.
    var onHandshakeMs: ((Int) -> Void)?
    private var handshakeT0Nanos: UInt64 = 0
    private var handshakeReported = true

    /// The SDK's trusted `PaymentOrigin`, read by `decidePolicyFor` to classify main-frame navigations through the
    /// pure `NavigationPolicy`. Settable after construction, like `onResponseEnvelope`; `KhipuPayment` always wires it
    /// to the origin the coordinator loads. Nil (unwired) means navigations are not policed. Mirrors Kotlin's
    /// `navigationOrigin`.
    var navigationOrigin: PaymentOrigin?

    /// `security.bundle_unavailable` reason for a body whose signature VERIFIED but which is not UTF-8, so it cannot
    /// be injected. Matches the enum in `events.schema.json`.
    static let reasonUndecodable = "undecodable"

    /// The verify-before-execute decision: selects the baked key by request host, runs `BundleSignatureVerifier`,
    /// emits `security.bundle_*` through this host's `telemetry`, and decides between injecting the verified bytes and
    /// blocking. The decision is unit-tested; the `URLSession` fetch and the `WKContentRuleList`/inject wiring below
    /// are not.
    private lazy var bundleInterceptor = BundleVerificationInterceptor(
        telemetry: telemetry,
        onVerificationFailed: { [weak self] in self?.onBundleVerificationFailed?() }
    )

    init(dispatcher: BridgeDispatcher, telemetry: TelemetrySink = NoopTelemetrySink()) {
        self.dispatcher = dispatcher
        self.telemetry = telemetry

        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default() // persist cookies across the bank-app round trip
        // Force the mobile content mode so the page is never laid out at desktop width. The `width=device-width` meta
        // is web-owned (kws.js); the native job is the UA + the content-mode switch. (Android mirrors this with
        // WebSettings.useWideViewPort=false / loadWithOverviewMode=false.)
        config.defaultWebpagePreferences.preferredContentMode = .mobile
        // CSP-relevant hardening: the SDK's slice of the 3-layer CSP responsibility split (security/CSP-RACI.md), the
        // twin of Android's WebSettings block. No auto-opened windows: window.open()/target=_blank is the SDK's
        // external-navigation seam (NavigationPolicy.externalSeam), so the page may not spawn windows behind the
        // SDK's back.
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        // Keep the platform's fraudulent-website (Safe Browsing) warning ON — default true; asserted/documented here.
        config.preferences.isFraudulentWebsiteWarningEnabled = true
        // Not a parity gap: WKWebView has NO mixedContentMode / allowFileAccess / allowUniversalAccessFromFileURLs
        // equivalents because it BLOCKS mixed content and cross-file-origin access BY DEFAULT; Android must opt out
        // explicitly (its WebSettings block). Geolocation, as on Android, is NOT disabled (the payment flow can
        // require it); making it work needs CoreLocation + NSLocationWhenInUseUsageDescription (known gap, dw:251).
        // OTP autofill is WEB-OWNED: kws.js marks its OTP <input> with autocomplete="one-time-code", and WebKit's
        // Security Code AutoFill offers the incoming SMS code in the QuickType bar INSIDE this WKWebView, with no
        // native code involved. This default configuration PERMITS it: do NOT add any setting that suppresses
        // QuickType/AutoFill for web content. The fallback is manual entry into the same web field; the payment
        // never blocks on the OTP step.
        let contentController = config.userContentController
        // Expose the web->native send() at document start (the bridge seam).
        let bootstrap = "window.khipuNative = { send: function(json) { window.webkit.messageHandlers.khipuNative.postMessage(json); } };"
        contentController.addUserScript(
            WKUserScript(source: bootstrap, injectionTime: .atDocumentStart, forMainFrameOnly: true)
        )
        // The page-request seal: records, in a world the page cannot reach, which script loads of the main document
        // failed, so readiness can tell whether the document requested `/v1/kws.js` itself.
        contentController.addUserScript(
            WKUserScript(source: Self.sealScript, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: Self.sealWorld)
        )

        let webView = WKWebView(frame: .zero, configuration: config)
        self.webView = webView
        // The responder is built before `super.init`, so its block signal cannot capture `self`; it reaches the host
        // through this weak local instead, filled the moment `self` exists (no callback can fire earlier: readiness
        // needs a load, and a load needs a constructed host).
        weak var hostRef: KhipuWebViewHost?
        // Delivery uses `callAsyncJavaScript` with structured arguments (AC-BRIDGE-006: never string-concatenate into
        // JS) and surfaces a real `Result.failure` to the responder, which emits bridge.respond_delivery_failed. The
        // iOS floor is 15 because this API's WebKit Swift overlay crashes on real iOS 14 devices, so no
        // `evaluateJavaScript` fallback is needed.
        self.responder = BridgeResponder(
            deliver: { [weak webView] payload, target, token, onResult in
                // Deliver on the main queue: the dispatcher already hops to main; assert it so the WebView is only
                // ever touched on the main thread.
                dispatchPrecondition(condition: .onQueue(.main))
                guard let webView = webView else { onResult(false, "webview_unavailable"); return }
                // The payload travels as a STRUCTURED argument; only the SDK-built script is code.
                var arguments: [String: Any] = ["t": token]
                switch target {
                case .respond, .request: arguments["r"] = payload
                case .resume: arguments["id"] = payload
                case .ping: break
                }
                webView.callAsyncJavaScript(BridgeScripts.delivery(target), arguments: arguments, in: nil, in: .page) { result in
                    let (ok, reason) = KhipuWebViewHost.deliveryOutcome(target, result)
                    onResult(ok, reason)
                }
            },
            telemetry: telemetry,
            onUnverifiedReady: { hostRef?.onUnverifiedReady?() }
        )

        super.init()
        hostRef = self
        contentController.add(self, name: Self.messageName)
        // Readiness: the page is only deliverable once it finished loading AND window.khipuBridge (defined by kws.js)
        // exists, so native never evals a _respond before the bridge is defined.
        webView.navigationDelegate = self
        // Force a mobile user-agent so kws.js never falls back to a desktop layout.
        webView.customUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 16_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148 KhipuNative/1.0"
    }

    // Internal: the payment WebView is not reachable from the public surface, so no public path can load an
    // arbitrary URL into it; the coordinator loads only the SDK's fixed origins.
    func load(url: URL) {
        // Derived from the URL HERE, so no caller can load a page that skips verification (ADR-221).
        responder.beginLoad(requireVerifiedBundle: Self.requiresVerifiedBundle(url))
        hostLoadTracker.load()
        let epoch = responder.generation() // the page the bundle fetch below belongs to
        hostLoad = (url, epoch)
        dispatcher.resetSession() // new page load => new session binding; resolves abandoned requests
        hasFinishedInitialLoad = false // a fresh page is back in the initial-load phase
        verifiedBundleJS = nil // a new page epoch invalidates any bundle verified for the previous one
        // The handshake clock starts at the host load, re-armed per load (a restart/reload is a new handshake).
        handshakeT0Nanos = DispatchTime.now().uptimeNanoseconds
        handshakeReported = false

        // VERIFY-BEFORE-EXECUTE WIRING. Only a REMOTE page fetches `/v1/kws.js`; the bundled `file://` harness
        // carries its own façade and has no bundle to verify, so it loads unchanged. Any other non-https page still
        // requires verification (above); with nothing fetched for it, it can never pass readiness.
        let isHttps = url.scheme?.lowercased() == "https"
        expectedBundleURL = isHttps ? Self.bundleURL(forPage: url) : nil
        guard isHttps, let bundleURL = expectedBundleURL else {
            issuePageLoad(url, epoch: epoch)
            return
        }
        // The block rule must be installed BEFORE the page can request the bundle, or WebKit loads and executes it
        // unverified. So the load is CHAINED to the install completion, never parallel.
        installBundleBlockRule(attemptsLeft: Self.blockRuleAttempts) { [weak self] installed in
            guard let self = self else { return }
            // A newer load began while this rule was installing: this load issues, fetches and signals nothing, since a
            // failure it signalled would end the newer load's payment.
            guard epoch == self.responder.generation() else { return }
            guard installed else {
                // FAIL-CLOSED: without the rule the page would execute an unverified bundle, which is exactly what
                // ADR-003 forbids. Refusing to load costs a payment in a rare transient case; loading anyway would
                // make "iOS verifies" an assertion with an asterisk forever. The coordinator turns this into
                // NETWORK_UNAVAILABLE, never a silent hang.
                self.telemetry.emit(
                    event: TelemetryEvent.bundleUnavailable,
                    fields: ["host": bundleURL.host ?? "", "reason": Self.reasonBlockRuleUnavailable, "severity": "error"]
                )
                self.onBundleVerificationFailed?()
                return
            }
            self.issuePageLoad(url, epoch: epoch)
            if self.loadWithoutNetworkForTesting == nil { self.fetchVerifyAndInjectBundle(from: bundleURL, epoch: epoch) }
        }
    }

    /// Issue the page's load, or hand it to `holdPageLoadForTesting`, and tell the tracker its navigation. A load whose
    /// epoch is no longer current (a newer `load(url:)` began meanwhile) issues nothing.
    private func issuePageLoad(_ url: URL, epoch: Int) {
        let issue = { [weak self] in
            guard let self = self else { return }
            guard epoch == self.responder.generation() else { return }
            let navigation: WKNavigation?
            if let loadWithoutNetwork = self.loadWithoutNetworkForTesting {
                navigation = loadWithoutNetwork(url, epoch)
            } else {
                navigation = self.webView.load(URLRequest(url: url))
            }
            self.hostLoadTracker.issued(navigation)
        }
        if let hold = holdPageLoadForTesting { hold(epoch, issue) } else { issue() }
    }

    /// The bundle URL for a payment page: same origin, `/v1/kws.js` (the path the interceptor and the block rule both
    /// key on). Returns nil when the page carries no host (a `file://` harness).
    static func bundleURL(forPage page: URL) -> URL? {
        guard let host = page.host, !host.isEmpty else { return nil }
        var c = URLComponents()
        c.scheme = "https"
        c.host = host
        c.port = page.port
        c.path = BundleVerificationInterceptor.bundlePath
        return c.url
    }

    /// Verify-before-execute (ADR-003, AC-SEC-002), the iOS twin of Android's `shouldInterceptRequest`.
    ///
    /// `WKURLSchemeHandler` does NOT intercept `https://`, so iOS cannot transparently intercept a sub-resource the
    /// way Android's synchronous `shouldInterceptRequest` does. Instead a `WKContentRuleList`
    /// (`installBundleBlockRule`) BLOCKS the WebView's own load of `/v1/kws.js`, and the SDK fetches it with
    /// `URLSession`, verifies it, and INJECTS the verified body here. That keeps the real https origin (cookies and
    /// CORS unchanged): parity of behavior with Android, not of mechanism. A failed verification injects nothing AND
    /// signals the coordinator (→ NETWORK_UNAVAILABLE). Started by every https load with that load's epoch; a VALID
    /// bundle stamps the epoch, which the readiness gate requires (ADR-221). The stamp proves only that the SDK's
    /// own fetch verified; readiness also requires the page's own document to have requested that URL
    /// (`readPageBundleRequest`), which Android gets by verifying the page's request itself. The harness never
    /// requests it. `BundleVerificationInterceptor.decide` and `BundleSignatureVerifier` are unit-tested.
    func fetchVerifyAndInjectBundle(from bundleURL: URL, epoch: Int) {
        let host = bundleURL.host ?? ""
        var request = URLRequest(url: bundleURL)
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData // no-cache: verify fresh bytes, never the cache
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        // The byte ceiling and the origin pin need the body refused WHILE it arrives, which the convenience
        // `dataTask(with:completionHandler:)` cannot do (it hands over an already-buffered body).
        // `BundleFetchDelegate` applies both through the data-delegate callbacks and reports a FetchOutcome; the
        // mapping lives in the unit-tested `BundleFetchPolicy.outcome`, the twin of Android's `readResponse`.
        let delegate = BundleFetchDelegate(requestHost: host) { [weak self] outcome in
            guard let self = self else { return }
            // A body we cannot decode as UTF-8 can never be injected, so refuse it BEFORE asking for a decision: a
            // `.serve` decision stamps the epoch verified and fires `onBundleVerified`, so deciding first would signal
            // "verified" for a bundle that never runs. And it must fail closed with a reason: a silent return here
            // would inject nothing, signal nothing, and hang the payment to the clamp.
            if case .ok(let bytes) = outcome, String(data: bytes, encoding: .utf8) == nil {
                self.telemetry.emit(
                    event: TelemetryEvent.bundleUnavailable,
                    fields: ["host": host, "reason": Self.reasonUndecodable, "severity": "error"]
                )
                self.onBundleVerificationFailed?()
                return
            }
            // .block → the interceptor already signalled onVerificationFailed (→ NETWORK_UNAVAILABLE); inject nothing.
            guard case .serve(let body) = self.bundleInterceptor.decide(host: host, fetch: outcome),
                  let js = String(data: body, encoding: .utf8) else { return } // the decode is already guaranteed above
            self.acceptVerifiedBundle(js, epoch: epoch)
        }
        // A delegate session retains its delegate until invalidated; `finishTasksAndInvalidate` lets the task
        // run to completion and then releases both (the shared session cannot be used — it takes no delegate).
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        session.dataTask(with: request).resume()
        session.finishTasksAndInvalidate()
    }

    /// The bundle for epoch `epoch` verified: stamp the epoch, then inject the body once the page has finished
    /// loading. Callable from any queue (the URLSession delegate queue in production).
    func acceptVerifiedBundle(_ js: String, epoch: Int) {
        responder.markBundleVerified(generation: epoch) // stamp BEFORE the inject is dispatched → ready ⇒ verified
        onBundleVerified?()
        // The page load and this fetch race. Injecting into a page that has not finished loading silently does
        // nothing, so whichever completes LAST performs the injection: if the page is already finished, inject
        // now; otherwise park the JS and let `didFinish` inject it.
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            // A superseded load's fetch must not inject into (or park for) the newer page: its stamp was already
            // ignored, so its bytes would hand that page a khipuBridge the gate then blocks.
            guard epoch == self.responder.generation() else { return }
            if self.hasFinishedInitialLoad {
                self.webView.evaluateJavaScript(js, completionHandler: nil)
            } else {
                self.verifiedBundleJS = js
            }
        }
    }

    /// Install a `WKContentRuleList` that blocks the WebView's DIRECT load of `/v1/kws.js`, so the page runs only the
    /// verified body injected by `fetchVerifyAndInjectBundle`. Async (WebKit compiles rule lists off-main). Invoked by
    /// every https load; the harness never loads `/v1/kws.js`, so this is inert there.
    func installBundleBlockRule(attemptsLeft: Int = 1, completion: @escaping (Bool) -> Void) {
        let rule = Self.bundleBlockRule
        // Look up the compiled list first and compile only when the store lacks it: compiling costs about 15 ms even
        // when repeated and a lookup about 5 ms (simulator), and this sits on the critical path because `load()`
        // waits for the install before loading the page.
        //
        // The identifier is DERIVED from the rule's content (`bundleBlockRuleIdentifier`), and that is load-bearing:
        // the compiled list PERSISTS on disk across launches, so with a fixed id a future edit of the `url-filter`
        // would keep serving the OLD rule to every existing user and the edit would have no effect. With the derived
        // id, any edit to the rule invalidates the cache by construction.
        //
        // Bounded RETRY. The failure mode here is transient WebKit store/resource state, not a bad rule (the JSON is
        // a literal), so one hiccup should not cost a payment; the retries are bounded so a genuinely broken store
        // still reaches the fail-closed decision instead of looping.
        func retryOrFail() {
            guard attemptsLeft > 1 else { completion(false); return }
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(120)) { [weak self] in
                self?.installBundleBlockRule(attemptsLeft: attemptsLeft - 1, completion: completion)
            }
        }
        guard let store = WKContentRuleListStore.default() else { retryOrFail(); return }
        let identifier = Self.bundleBlockRuleIdentifier
        store.lookUpContentRuleList(forIdentifier: identifier) { [weak self] cached, _ in
            guard let self = self else { return }
            if let cached = cached { // compiled by an earlier launch: the hot path
                self.webView.configuration.userContentController.add(cached)
                completion(true)
                return
            }
            // Absent (first use, store cleared, or the rule changed → new id): compile; it stays cached.
            store.compileContentRuleList(forIdentifier: identifier, encodedContentRuleList: rule) { [weak self] list, error in
                guard let self = self, let list = list, error == nil else { retryOrFail(); return }
                self.webView.configuration.userContentController.add(list)
                completion(true)
            }
        }
    }

    /// Internal teardown plumbing: stop the host from ever evaluating against a dead WebView and release the
    /// dispatcher's pending handlers without delivering. NOT the public `close()`/`restart()` control surface, only
    /// the internal shutdown the host and dispatcher need.
    func shutdown() {
        // Detach the JS→native inlet AND break the classic WKUserContentController→handler retain cycle:
        // `contentController.add(self, …)` retains the host strongly, so without this remove the whole
        // host+WebView+responder graph leaks after teardown (and the deliver closure's `[weak webView]` guard could
        // never fire). Android mirrors with removeJavascriptInterface.
        webView.configuration.userContentController.removeScriptMessageHandler(forName: Self.messageName)
        responder.shutdown()
        dispatcher.close()
    }

    /// Deliver an outbound native→web REQUEST envelope (`startPayment_v1`). Captures the CURRENT page epoch (the
    /// coordinator calls this after `load()`, so the request is bound to the payment page) and goes through the
    /// responder's gating: queued until `khipuBridge` readiness, epoch-authenticated, liveness-gated. A failed
    /// delivery emits `bridge.respond_delivery_failed`.
    func deliverRequest(_ requestJSON: String) {
        responder.request(requestJSON, generation: responder.generation())
    }

    /// Recover after a content-process termination. The WKWebView is REUSABLE (WebKit re-spawns the content process
    /// on the next load), so recovery is just clearing the responder's render-dead guard; the coordinator's
    /// controlledReload (`loadPage` → `webView.load`) then re-spawns the content process on the SAME WebView, with
    /// no re-creation, unlike Android's destroy+rebuild. Returns true: a reusable WebView is always recoverable on
    /// iOS. `KhipuPayment` wires the coordinator's `recoverWebView` seam to this.
    func recoverWebView() -> Bool {
        responder.clearRenderDead()
        return true
    }

    /// Invoke the page's `window.khipuBridge._resume(operationId)` when the app returns to the foreground mid-payment.
    /// Fire-and-forget at the CURRENT page epoch through the responder's NO-QUEUE call path: if the page cannot take
    /// it now, the coordinator's `_ping` deadline owns recovery. Mirrors Kotlin's `KhipuWebViewHost.resume`.
    func resume(operationId: String) {
        responder.call(operationId, generation: responder.generation(), target: .resume) { _, _ in }
    }

    /// Probe the page's `window.khipuBridge._ping()`, the check that a live page is not wedged. Reports `(true, nil)`
    /// on a pong, `(false, gateOrEvalReason)` otherwise. The coordinator maps the reason into the
    /// `lifecycle.unrecoverable_resume` enum and owns the deadline (the responder never arms timers). Mirrors Kotlin's
    /// `KhipuWebViewHost.ping`.
    func ping(onResult: @escaping (Bool, String?) -> Void) {
        responder.call(nil, generation: responder.generation(), target: .ping, onResult: onResult)
    }

    // iOS deliberately has NO `flushCookies` mirror: `WKHTTPCookieStore` (under the `.default()` data store configured
    // in init) persists asynchronously with no public flush API, and backgrounding triggers the OS write-back.
    // Android calls `CookieManager.flush()` on background (RAM→disk, so cookies survive a process death during the
    // bank-app trip). Same observable contract MODULO the OS persistence timing: an OS kill racing the asynchronous
    // write-back can lose not-yet-persisted cookies. There is no API to close that window on iOS, so it is an
    // accepted residual, not parity to fix.

    /// Pure inbound-envelope router predicate, static so unit tests can drive it without a real WKWebView.
    /// `message_type` is decoded via the GENERATED `MessageType` enum (never a hardcoded wire string); anything
    /// unparseable, absent or non-response answers `false`, so the dispatcher's inbound hardening keeps owning
    /// malformed traffic. Mirrors Kotlin's `EnvelopeRouter`.
    static func isResponseEnvelope(_ envelopeJSON: String) -> Bool {
        guard let data = envelopeJSON.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let raw = obj["message_type"] as? String else { return false }
        return MessageType(rawValue: raw) == .response
    }

    // MARK: WKScriptMessageHandler

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == Self.messageName, let json = message.body as? String else { return }
        // AC-SEC-013: a cross-origin SUB-frame must not reach the native bridge. A WKScriptMessageHandler registered
        // via `contentController.add(self, name:)` is callable from EVERY frame (the bootstrap `window.khipuNative`
        // user script is `forMainFrameOnly:true`, but a sub-frame can still call
        // `window.webkit.messageHandlers.khipuNative.postMessage(...)` directly), so this receive-side guard is the
        // real protection: drop any message whose `frameInfo` is NOT the main frame BEFORE it reaches the router or
        // dispatcher. The main frame is trusted because NavigationPolicy keeps it on the payment origin. Not
        // unit-tested: `WKFrameInfo` is not constructible in unit tests. (Android cannot filter by frame; see the
        // addJavascriptInterface note in its host.)
        guard message.frameInfo.isMainFrame else { return }
        // Route by the wire `message_type` BEFORE the dispatcher: an inbound RESPONSE envelope is the startPayment_v1
        // outcome and belongs to the coordinator, not to the dispatcher's request validation (which rejects
        // non-request types with UNSUPPORTED_MESSAGE_TYPE, correct only for web→native traffic).
        // Size bound BEFORE the router's parse: isResponseEnvelope parses the full JSON, which would let a hostile
        // page force an unbounded parse ahead of every gate. An oversize envelope skips the router and falls through
        // to the dispatcher, whose size gate rejects it BEFORE parsing (same bound, same envelope_too_large
        // diagnostic).
        if let sink = onResponseEnvelope, json.utf8.count <= Self.maxRoutedEnvelopeBytes, Self.isResponseEnvelope(json) {
            sink(json)
            return
        }
        // Capture the page epoch NOW so the eventual delivery can never cross into a later page; the dispatcher runs
        // off-main and performs the single main-queue delivery hop exactly once, where respond() gates
        // (liveness/readiness/stale) and evals; a discarded envelope never invokes this callback.
        let generation = responder.generation()
        // Capture the (WebView-free) responder STRONGLY: with `[weak self]`, a host deallocated mid-flight would make
        // the delivery evaporate with no diagnostic, while Android's strong capture reaches the `alive` gate and
        // emits it. The responder's own deliver closure holds the WebView weakly, so this retains no WebView.
        let responder = self.responder
        // Until the host load commits, the message may come from the document that load replaces, so it must not pin
        // the bridge session.
        dispatcher.handle(json, mayPinSession: { !responder.isAwaitingHostLoadCommit() }) { responseJSON in
            responder.respond(responseJSON, generation: generation)
        }
    }

    // MARK: WKNavigationDelegate

    /// WebKit navigation-policy callback. In the SDK's own payment flow it cancels a main-frame navigation, or a
    /// new-window request, that leaves the payment origin, and reports it as `TelemetryEvent.navigationBlocked`.
    /// Sub-frame navigations are always allowed.
    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        guard let origin = navigationOrigin else { decisionHandler(.allow); return }
        // A present, non-main targetFrame is a sub-frame nav → allow (RACI layer 1). nil = new-window/_blank → gate.
        if let frame = navigationAction.targetFrame, !frame.isMainFrame { decisionHandler(.allow); return }
        let url = navigationAction.request.url
        switch NavigationPolicy.decide(destinationScheme: url?.scheme, destinationHost: url?.host, origin: origin) {
        case .allow:
            decisionHandler(.allow)
        case .blockUnexpected:
            emitNavigationBlocked(scheme: url?.scheme, host: url?.host, reason: "unexpected_origin")
            decisionHandler(.cancel)
        case .externalSeam:
            emitNavigationBlocked(scheme: url?.scheme, host: url?.host, reason: "external_scheme")
            decisionHandler(.cancel)
        }
    }

    /// Emit `security.navigation_blocked` through the `telemetry` seam: the destination host/scheme and reason, NEVER
    /// the merchant operationId (PII), like the `security.bundle_*` events. Mirrors Kotlin's `emitNavigationBlocked`.
    private func emitNavigationBlocked(scheme: String?, host: String?, reason: String) {
        var fields: [String: Any] = ["scheme": scheme ?? "", "reason": reason, "severity": "warn"]
        if let host = host { fields["host"] = host }
        telemetry.emit(event: TelemetryEvent.navigationBlocked, fields: fields)
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        switch hostLoadTracker.committed(navigation) {
        case .page:
            responder.onHostLoadCommitted()
        case .other:
            // While the host load is pending this is a document the load will replace, and the responder keeps the
            // epoch; after the page committed it is a self-navigation (server redirect, JS location change), and the
            // epoch moves on. Commit, not didStartProvisionalNavigation, so a CANCELLED provisional navigation (e.g. a
            // bank-app universal link) never invalidates the live page's epoch.
            responder.onNavigationCommitted()
        case .otherReissue:
            // Another document committed after the page's load was issued, and may have cancelled it without a
            // callback: the page is issued again.
            responder.onNavigationCommitted()
            if let load = hostLoad { issuePageLoad(load.url, epoch: load.epoch) }
        case .otherFailLoad:
            responder.onNavigationCommitted()
            onLoadFailed?()
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // A page-finish before the page's own load committed belongs to the previous document or to one that load will
        // replace. Probing it under the new epoch would test that page's khipuBridge and its record of the bundle
        // request, and injecting would hand it the new load's bundle.
        guard hostLoadTracker.finished() == .probe, !responder.isAwaitingHostLoadCommit() else { return }
        // The initial main-frame load completed: a LATER main-frame failure is a kws.js SPA navigation, NOT an
        // unloadable origin, so it must not fail the running payment (gated in reportLoadFailure below).
        hasFinishedInitialLoad = true
        // The other side of the race: the verified bundle arrived before the page finished, so inject it now. Cleared
        // after injecting so a later navigation cannot re-inject a bundle verified for the old page.
        if let js = verifiedBundleJS {
            verifiedBundleJS = nil
            webView.evaluateJavaScript(js, completionHandler: nil)
        }
        // kws.js defines window.khipuBridge when its React bundle MOUNTS, possibly after page-finish, so the probe
        // re-polls (bounded) instead of latching never-ready on a one-shot miss. evaluateJavaScript is pure ObjC (no
        // WebKit Swift overlay), so this readiness check is safe on the iOS 15 floor.
        probeReadiness(generation: responder.generation())
    }

    /// WebKit callback for a terminated content process (for example under memory pressure). The page goes blank but
    /// the app does not crash. The host stops delivering into the blank page, and the SDK reloads the page of a
    /// payment in progress, or fails that payment with `INTERNAL_ERROR` when the WebView cannot be recovered.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        responder.markRenderDead()
        onRenderProcessGone?(true) // iOS carries no didCrash detail — always true
    }

    /// WebKit callback: a main-frame load failed before it was committed. If it is the page's load, or a navigation
    /// of the page's document before that document finished loading, and the load was not merely cancelled, the
    /// payment fails right away instead of waiting for its timeout.
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        reportLoadFailure(navigation, error)
    }

    /// WebKit callback: a committed load failed. Handled like a provisional failure.
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        reportLoadFailure(navigation, error)
    }

    /// Route a navigation failure to the fail-fast seam. Two filters keep a running payment alive:
    /// - a benign cancellation (`NSURLErrorCancelled`: a bank-app universal link, or a load superseded by the next
    ///   one) is not an unloadable origin;
    /// - a failure counts only for the host's own page load, or for that page's document before its first
    ///   page-finish (`HostLoadTracker.failed`); later it belongs to a kws.js SPA navigation.
    ///
    /// Android applies the same two filters in `onReceivedError`. The classifier and the tracker are unit-tested;
    /// this wiring is structural.
    private func reportLoadFailure(_ navigation: WKNavigation?, _ error: Error) {
        guard Self.isGenuineLoadFailure(error) else { return }
        switch hostLoadTracker.failed(navigation) {
        case .hostLoad: onLoadFailed?()
        case .page: if !hasFinishedInitialLoad { onLoadFailed?() }
        case .ignore: break
        }
    }

    /// Pure classifier (static so unit tests can drive it without a WKWebView, like `isResponseEnvelope` /
    /// `probeIndicatesReady`): a cancelled navigation (`NSURLErrorCancelled`: a bank-app universal link, or a load
    /// superseded by the next one) is NOT an unloadable origin; everything else is a genuine load failure.
    static func isGenuineLoadFailure(_ error: Error) -> Bool {
        let nsError = error as NSError
        return !(nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled)
    }

    /// Whether the page at `url` must verify its `/v1/kws.js` before it can receive the operationId (ADR-221).
    /// Fail-closed: only the harness schemes (`file:`, `about:`), which carry their own façade, are exempt. Every other
    /// scheme, including a missing or unknown one, requires it, so a page the SDK cannot verify is blocked at readiness
    /// instead of trusted. Twin of Kotlin's `KhipuWebViewHost.requiresVerifiedBundle`.
    static func requiresVerifiedBundle(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return true }
        return scheme != "file" && scheme != "about"
    }

    /// Issue one readiness probe for page epoch `generation`; the responder decides whether to re-poll (bounded).
    /// The epoch is captured at ISSUE time so a stale callback can never mark a newer page ready. Once khipuBridge is
    /// there, the same probe reads the document's record of its bundle request, so both facts come from the same
    /// document.
    private func probeReadiness(generation: Int) {
        // The token of the epoch this probe judges; a probe for an epoch that is no longer current judges nothing.
        guard let token = responder.documentToken(for: generation) else { return }
        webView.evaluateJavaScript(BridgeScripts.probe(token: token)) { [weak self] result, _ in
            guard let self = self else { return }
            guard Self.probeIndicatesReady(result) else {
                if self.responder.onProbeMiss(generation: generation) { self.scheduleProbe(generation: generation) }
                return
            }
            self.readPageBundleRequest { requested in
                switch self.responder.onReady(generation: generation, pageRequestedBundle: requested) {
                case .ready:
                    if !self.handshakeReported {
                        self.handshakeReported = true
                        self.onHandshakeMs?(Int((DispatchTime.now().uptimeNanoseconds - self.handshakeT0Nanos) / 1_000_000))
                    }
                case .pending:
                    self.scheduleProbe(generation: generation)
                case .closed:
                    break
                }
            }
        }
    }

    private func scheduleProbe(generation: Int) {
        if generation != probeRetryGeneration {
            probeRetryGeneration = generation
            probeRetries = 0
        }
        probeRetries += 1
        let delayMs = Self.probeRetryDelay(retry: probeRetries, steadyMs: probeRetryDelayMs)
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(delayMs)) { [weak self] in
            self?.probeReadiness(generation: generation)
        }
    }

    /// Whether the current main-frame document requested `expectedBundleURL` itself, read from the seal world.
    /// Reports false when it cannot tell (no bundle for this page, an evaluation failure), so the gate never passes
    /// on missing evidence.
    private func readPageBundleRequest(_ completion: @escaping (Bool) -> Void) {
        guard let bundleURL = expectedBundleURL else { completion(false); return }
        webView.callAsyncJavaScript(Self.failedScriptsQuery, arguments: [:], in: nil, in: Self.sealWorld) { result in
            guard case .success(let value) = result, let sources = value as? [Any] else { completion(false); return }
            completion(sources.contains { ($0 as? String).map { Self.isPageBundleRequest($0, bundleURL: bundleURL) } ?? false })
        }
    }

    /// Pure parser for the readiness-probe result, extracted so unit tests can drive it without a real WKWebView.
    /// Mirrors Android's `JsResultParser`.
    static func probeIndicatesReady(_ result: Any?) -> Bool { (result as? Bool) == true }

    /// A delivery's result: delivered, refused by a document the probe did not mark (reported as `stale_page`,
    /// like any delivery whose page went stale), or failed. `_ping` counts only a strict `true` as delivered.
    /// Mirrors Android's `JsResultParser.deliveryOutcome`. A raw error description never leaves: it could carry
    /// page-derived text into telemetry.
    static func deliveryOutcome(_ target: JsTarget, _ result: Result<Any, Error>) -> (Bool, String?) {
        guard case .success(let value) = result else { return (false, "eval_failed") }
        if (value as? String) == BridgeScripts.staleDocument { return (false, "stale_page") }
        if target == .ping { return (value as? Bool) == true ? (true, nil) : (false, "eval_failed") }
        return (true, nil)
    }

    // MARK: The page-request seal

    /// The content world of the page-request seal. Page scripts cannot read, replace or call into what runs there,
    /// and WebKit does not apply the page's Content-Security-Policy to it.
    static let sealWorld = WKContentWorld.world(name: "khipu-bundle-seal")

    /// Runs at document start in the main frame only and records the source of every script element whose load
    /// failed, from the trusted `error` event. The block rule fails every `/v1/kws.js` load, so a document that
    /// requested its bundle always leaves that URL here. Listening at window capture, registered before any page
    /// script runs, keeps the page from stopping the event before it is recorded. It writes nothing to the DOM and
    /// injects no script into the page, so a strict CSP on the page has nothing to block. The list is capped so a
    /// page cannot make it grow without bound.
    static let sealScript = """
        (function () {
          var failed = [];
          addEventListener('error', function (event) {
            var script = event.target;
            if (event.isTrusted && script instanceof HTMLScriptElement && failed.length < 64) {
              failed.push(String(script.src));
            }
          }, true);
          Object.defineProperty(window, 'khipuFailedScripts', { value: function () { return failed.slice(); } });
        })();
        """

    /// Evaluated in `sealWorld`: the sources the seal script recorded for the current document, or none if it did not
    /// run there.
    static let failedScriptsQuery = "return typeof khipuFailedScripts === 'function' ? khipuFailedScripts() : [];"

    /// Whether a script source the seal recorded is the page's own bundle: the exact `https` URL the SDK fetched and
    /// verified (same host and port, path `/v1/kws.js`, no credentials). A query or fragment is accepted because the
    /// block rule blocks those too. Any other source, another host's `/v1/kws.js` included, is not this page's
    /// request for its verified bundle. Pure, so the matching rule is unit-tested.
    static func isPageBundleRequest(_ source: String, bundleURL: URL) -> Bool {
        guard source.utf8.count <= 2048,
              let request = URLComponents(string: source),
              let expected = URLComponents(url: bundleURL, resolvingAgainstBaseURL: false),
              request.scheme?.lowercased() == "https",
              request.user == nil, request.password == nil,
              let host = request.host?.lowercased(), host == expected.host?.lowercased(),
              (request.port ?? 443) == (expected.port ?? 443) else { return false }
        return request.percentEncodedPath == BundleVerificationInterceptor.bundlePath
    }
}
