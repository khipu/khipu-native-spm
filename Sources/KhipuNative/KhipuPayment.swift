import Foundation
import UIKit
import WebKit
import BridgeGenerated

/// Entry point of the khipu native payment SDK: `KhipuPayment().start(operationId:from:) { outcome in }`.
///
/// The SDK owns the web view and the payment UI. `start` presents a full-screen view controller, loads khipu's
/// payment page for the operation, and dismisses the controller before delivering a `KhipuPaymentOutcome`. The
/// payer can leave the payment only through the payment page: the controller cannot be dismissed with a swipe.
/// Both `start` overloads share one implementation.
///
/// `KhipuPayment` is `@MainActor`. An instance runs one payment at a time and can be reused for later payments.
@MainActor
public final class KhipuPayment {
    // Internal: the payment WebView is not reachable from the public surface, so no public path can load an
    // arbitrary URL into it.
    let host: KhipuWebViewHost
    private let dispatcher: BridgeDispatcher
    private let recorder = DiagnosticsRecorder()
    private let presenter: SheetPaymentPresenter
    let coordinator: KhipuPaymentInternal
    // The app-level lifecycle observers feeding the coordinator's resume protocol; removed in deinit.
    private var backgroundObserver: NSObjectProtocol?
    private var foregroundObserver: NSObjectProtocol?

    /// Creates an instance that always loads khipu's production payment page (`https://js.khipu.com/native/`).
    /// To test an integration, use a khipu developer account against production.
    public convenience init() {
        self.init(origin: .production, telemetry: NoopTelemetrySink(), onHandshakeMs: nil)
    }

    /// Test-only: creates an instance that loads the non-production origin named by `test` and wires its observation
    /// hooks. The origin is a fixed `KhipuTestOrigin`, never a URL. Available only through
    /// `@_spi(KhipuTesting) import KhipuNative`.
    @_spi(KhipuTesting) public convenience init(test: KhipuTestConfig) {
        let origin: PaymentOrigin
        switch test.origin {
        case .harness:
            // The SDK-authored harness page bundled by the integrating app. An app that bundles none must still get
            // a URL, never a crash, hence `?? about:blank`; the coordinator's start() guard then fails the payment
            // fast with INVALID_CONFIGURATION (iOS-only detection: about:blank loads successfully, so no load
            // failure would ever fire).
            let bundled = Bundle.main.url(forResource: "harness", withExtension: "html")
            origin = .harness(bundled ?? URL(string: "about:blank")!)
        case .staging:
            origin = .staging
        }
        self.init(origin: origin, telemetry: test.telemetry ?? NoopTelemetrySink(), onHandshakeMs: test.onHandshakeMs)
    }

    private init(origin: PaymentOrigin, telemetry: TelemetrySink, onHandshakeMs: ((Int) -> Void)?) {
        // This init is wiring only. It is not unit-tested beyond the origin mapping (KhipuTestingTests): the
        // behaviour behind each seam is unit-tested in the coordinator and host suites, and the quickstart sample's
        // UI tests drive the public wiring end to end.
        let dispatcher = BridgeDispatcher()
        // getCapabilities_v1 reports the live registry as generated Capability values.
        dispatcher.register(
            GetCapabilitiesCapability(registry: { [weak dispatcher] in
                (dispatcher?.declared ?? []).map { Capability(available: $0.availableOnOS, id: $0.id) }
            })
        )
        // openApp_v1: launch the payer's authorization app (bank or digital wallet). On return, the
        // willEnterForeground observer (wired below) feeds coordinator.appReturnedToForeground(), which re-checks
        // the outcome. Defaults to UIApplication.shared canOpenURL/open.
        //
        // The bank-app return detector is build-flag-gated by the KHIPU_CAP_BANK_RETURN active-compilation-condition
        // (default ON; Package.swift). When the flag is OFF the entire detector source compiles to nothing, so
        // bridge.capability_disabled is emitted EXACTLY ONCE here, from always-present code (CapabilityDiagnostics),
        // because the gated component cannot emit its own. The bank-return seam stays a `(String) -> Void` so no
        // detector type leaks past the #if. Both emit to the no-op sink, not the injected `telemetry` (there is no
        // integrator telemetry API); their emit-once and signal behaviour are unit-tested directly with recording
        // sinks.
        let bankReturnOnForeground: (String) -> Void
        #if KHIPU_CAP_BANK_RETURN
        let bankReturnDetector = BankReturnDetector(telemetry: NoopTelemetrySink())
        // onLaunched records the bank-app launch marker so the next foreground resume is recognizable.
        dispatcher.register(AppLauncher(onLaunched: { bankReturnDetector.recordLaunch() }))
        bankReturnOnForeground = { hash in bankReturnDetector.onForegroundReturn(operationIdHash: hash) }
        #else
        dispatcher.register(AppLauncher())
        bankReturnOnForeground = { _ in }
        CapabilityDiagnostics.emitCapabilityDisabled(
            NoopTelemetrySink(),
            capabilityId: CapabilityDiagnostics.capBankReturnDetector,
            osVersion: ProcessInfo.processInfo.operatingSystemVersion.majorVersion
        )
        #endif
        self.dispatcher = dispatcher
        let host = KhipuWebViewHost(dispatcher: dispatcher, telemetry: telemetry)
        self.host = host
        let presenter = SheetPaymentPresenter(webView: host.webView)
        self.presenter = presenter
        let coordinator = KhipuPaymentInternal(
            presenter: presenter,
            recorder: recorder,
            host: host,
            telemetry: telemetry,
            // One origin value for the coordinator AND host.navigationOrigin (set below), so they can never diverge.
            origin: origin,
            // The selective per-domain cookie clear at terminal/close. Scoped to the payment host by the coordinator
            // — NEVER a blanket wipe, because `WKWebsiteDataStore.default()` is shared with the merchant's own app.
            // Deleting per-cookie (rather than `removeData(ofTypes:)` for the whole record) keeps it surgical: only
            // cookies, only this payment's domain — localStorage and the rest of the merchant's website data are
            // untouched. Hops to MAIN because WKHTTPCookieStore is main-thread only, while a terminal can resolve on
            // any queue. This closure has no unit test; the SCOPE it depends on does (PaymentCookieScopeTests).
            clearCookiesForHost: { cookieHost in
                DispatchQueue.main.async {
                    let store = WKWebsiteDataStore.default().httpCookieStore
                    store.getAllCookies { cookies in
                        for cookie in cookies where PaymentCookieScope.belongs(cookieDomain: cookie.domain, paymentHost: cookieHost) {
                            store.delete(cookie)
                        }
                    }
                }
            },
            // The build-flag-gated bank-return seam (a no-op when KHIPU_CAP_BANK_RETURN is undefined).
            onBankAppReturn: bankReturnOnForeground
        )
        self.coordinator = coordinator
        // host↔coordinator wiring, WEAK in both directions: KhipuPayment is the owner of the whole graph — strong
        // closures here would form a host↔coordinator retain cycle that outlives it. While KhipuPayment lives, both
        // ends live. Every coordinator capture below is weak for the same reason.
        host.onResponseEnvelope = { [weak coordinator] envelope in coordinator?.completeFromWeb(envelope) }
        // A genuine main-frame load failure (a real unreachable origin) fails the payment fast, with a public code
        // that follows the origin, instead of a blank sheet for the whole payment timeout. The about:blank case is
        // caught synchronously in the coordinator's start() guard instead.
        host.onLoadFailed = { [weak coordinator] in coordinator?.webViewLoadFailed() }
        // Security invariant (AC-SEC-002/004): a verify-before-execute intercept failure (bad/absent signature, or
        // an unavailable bundle) resolves the active payment NETWORK_UNAVAILABLE, with no last-known-good
        // fallback. The host's intercept already emitted the security.bundle_* telemetry.
        host.onBundleVerificationFailed = { [weak coordinator] in coordinator?.bundleVerificationFailed() }
        // The responder blocked a page that reached readiness without a bundle verified for that load (ADR-221).
        host.onUnverifiedReady = { [weak coordinator] in coordinator?.bundleUnverifiedAtReadiness() }
        // AC-SEC-012b: the main-frame navigation policy gates against the SAME origin the coordinator loads (the one
        // `origin` parameter), so the two can never diverge.
        host.navigationOrigin = origin
        // The test seam's handshake observer (nil on the public surface).
        host.onHandshakeMs = onHandshakeMs
        // The presenter's teardown seam carries ONLY system-initiated teardown (sheetDidDisappear; the full-screen
        // non-swipeable sheet has no user-dismiss gesture). It feeds the coordinator's PAYMENT_ABORTED latch so a
        // system dismissal never leaves the callback hanging.
        presenter.onSystemTeardown = { [weak coordinator] nativeOpId in coordinator?.systemTeardownRequested(nativeOpId: nativeOpId) }
        // Fail-closed presentation: a refused present() resolves the operation with INTERNAL_ERROR instead of
        // running a headless payment until the payment timeout.
        presenter.onPresentFailed = { [weak coordinator] nativeOpId in
            coordinator?.presentFailedRequested(nativeOpId: nativeOpId)
        }
        // The positive present-confirmation: the sheet's present completion signals the UI actually appeared,
        // cancelling the coordinator's fail-closed deadline.
        presenter.onPresented = { [weak coordinator] nativeOpId in
            coordinator?.presentConfirmed(nativeOpId: nativeOpId)
        }
        // The content-process-termination signal drives the coordinator's tiered recovery (reload the reusable
        // WKWebView — the sheet keeps showing host.webView, so unlike Android there is no view swap). The
        // active-payment self-retention keeps the graph alive on a payment whose KhipuPayment the merchant dropped,
        // which is exactly the bank-app scenario here.
        host.onRenderProcessGone = { [weak coordinator] didCrash in coordinator?.webViewRenderGone(didCrash: didCrash) }
        // Stored (not computed) so the lifecycle matches Kotlin's `val __internals__ = Internals()` — a single
        // instance, not a fresh struct per access.
        self.__internals__ = Internals(dispatcher: dispatcher)
        // Lifecycle signals are APP-level on iOS: a modal sheet has no per-VC background notion, and both an app
        // background and a bank-app round trip background the APP. UIApplication notifications rather than
        // UIScene/applicationDidBecomeActive: they cover scene- and non-scene host apps at the iOS 15 floor and form
        // a consumable background→foreground pair (the coordinator's token does the exactly-once). ONE known
        // exception: in a MULTI-SCENE app (iPad multi-window), backgrounding only the payment scene posts no
        // app-level notification, so that case degrades to PAYMENT_TIMEOUT (callback still delivered — never lost);
        // UIScene-filtered observers would close it (known gap, dw:148). Android mirrors with the SDK-owned payment
        // Activity's onStop/onStart — same observable contract, sturdier sources. The active-payment self-retention
        // below keeps the graph alive on a payment whose KhipuPayment the merchant dropped, which is exactly the
        // bank-app scenario these observers exist for. `queue: .main`: merchant/test code may post these
        // notifications off-main — the resume path must reach the responder's main-thread eval precondition on
        // main, not on the poster's thread.
        backgroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
        ) { [weak coordinator] _ in coordinator?.appMovedToBackground() }
        foregroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main
        ) { [weak coordinator] _ in coordinator?.appReturnedToForeground() }
    }

    deinit {
        // Block-based observers are NOT auto-removed on deallocation — without this the center would keep
        // invoking the stale registrations forever (the closures only hold the coordinator weakly, but the
        // registration itself leaks).
        if let observer = backgroundObserver { NotificationCenter.default.removeObserver(observer) }
        if let observer = foregroundObserver { NotificationCenter.default.removeObserver(observer) }
        // deinit is iOS's ONLY instance-death signal, so it is the production trigger for the internal teardown
        // (host shutdown, which trips the responder's `alive` latch, and dispatcher close). deinit is nonisolated
        // (it runs on whatever thread drops the last reference) and cannot call the @MainActor `teardown()`
        // directly; this IS teardown's body with the host captured by value (capturing `self` in deinit is
        // illegal) hopped to main — shutdown touches the WKUserContentController, a main-thread API. Android
        // deliberately has NO mirror: the JVM has no deinit, so instance end-of-life is GC (see the Kotlin
        // KhipuPayment.teardown()).
        let host = self.host
        DispatchQueue.main.async { host.shutdown() }
    }

    /// Starts a payment and returns its outcome when it ends.
    ///
    /// Presents the SDK's payment UI from `anchor`, loads khipu's payment page for `operationId` (passed through
    /// unchanged) with `options`, and returns the outcome after dismissing the UI:
    /// - `.completed` when the payment page reached a verdict (`KhipuPaymentResult`: `ok`, `error`, `warning` or
    ///   `continue`). A payer cancellation is `.completed(.error(...))` with `failureReason == .USER_CANCELED`.
    /// - `.interrupted` when the SDK ended the flow without a verdict — for example `PAYMENT_ABORTED` after
    ///   `close()` or a dismissal the SDK did not initiate (such as your app dismissing the presenting
    ///   controller), `PAYMENT_TIMEOUT` when no verdict arrived within 10 minutes, or `INVALID_CONFIGURATION` when
    ///   this instance already has an active payment (the active payment is not affected).
    ///
    /// `anchor` is the view controller to present from. When `nil`, the SDK uses the top-most view controller of
    /// the key window (best effort); passing it is recommended. If it is already presenting another view
    /// controller, the payment is interrupted with `INTERNAL_ERROR`.
    ///
    /// Cancelling the calling task does not cancel the payment: the UI stays up and the payment runs to its end, but
    /// this call throws `CancellationError` right away and does not receive the outcome. That holds also when the
    /// task is already cancelled when it calls `start`: the payment still starts. `CancellationError` is the only
    /// error this method throws. To end a payment, call `close()`.
    // Deep links INTO and OUT of the payment both ride this public surface; the SDK adds NO deep-link code:
    //  • INTO: a merchant deep link (e.g. myapp://pay?operationId=…) is received by the MERCHANT's own
    //    UISceneDelegate (iOS) / Activity intent-filter (Android); they parse the operationId and call
    //    start(operationId:). The SDK does NOT — and must NOT — register the merchant's deep-link entry point
    //    (that is THEIR navigation surface). `operationId` passes through byte-verbatim, so the
    //    deep-link-supplied id reaches kws.js unchanged.
    //  • OUT: the typed outcome (the async return or the completion overload below) lets the merchant navigate
    //    anywhere on completion, including a deep link out. The ONLY SDK-initiated external-app launch is the
    //    allowlisted openApp_v1 (`AppLauncher`); the SDK never follows arbitrary web-supplied deep links out of the
    //    WebView — `NavigationPolicy` stays fail-closed, so the SDK cannot become an open redirect.
    // Tested in KhipuPaymentInternalTests (INTO) and NavigationPolicyTests (OUT). Not to be confused with ADR-005's
    // "no deep link, no callback", which governs ONLY the bank-app → SDK RETURN path (a manual app resume).
    public func start(
        operationId: String,
        options: KhipuOptions = .default(),
        from anchor: UIViewController? = nil
    ) async throws -> KhipuPaymentOutcome {
        // Through the completion overload, so the active-payment self-retention and the anchor are released at the
        // payment's terminal delivery: a cancelled caller stops waiting long before that, and releasing on its
        // return would let a dropped instance deallocate mid-payment. The wait is the coordinator's own
        // (`CancellableOutcome`, as in its async `start`).
        let outcome = CancellableOutcome()
        start(operationId: operationId, options: options, from: anchor, completion: outcome.deliver)
        return try await outcome.value()
    }

    /// Starts a payment and reports its outcome to `completion`. Behaves like the async `start`; `completion` is
    /// called exactly once, on the main queue, after the payment UI has been dismissed.
    public func start(
        operationId: String,
        options: KhipuOptions = .default(),
        from anchor: UIViewController? = nil,
        completion: @escaping (KhipuPaymentOutcome) -> Void
    ) {
        presenter.anchor = anchor
        retainWhileActive()
        coordinator.start(merchantOperationId: operationId, options: options) { outcome in
            // Delivered on the main queue; KhipuPayment is @MainActor, so this is the actor's thread.
            MainActor.assumeIsolated { self.releaseWhenDelivered() }
            completion(outcome)
        }
    }

    /// Active-payment self-retention, for parity with Android, whose static UI registry + timeout job keep its
    /// graph alive through an active payment even if the merchant drops the SDK reference. The iOS graph is weak
    /// everywhere, so without this, dropping `KhipuPayment` mid-payment would orphan the sheet, kill the timeout
    /// and silently lose the completion. The instance retains ITSELF from `start()` until the terminal delivery
    /// (counted — a second `start()` rejected because a payment is active must not release that payment's
    /// retention). The terminal also releases the merchant's `anchor` (a strong ref held past the payment would
    /// pin their view controller).
    private static var activePayments: [ObjectIdentifier: KhipuPayment] = [:]
    private var activeStarts = 0

    private func retainWhileActive() {
        activeStarts += 1
        Self.activePayments[ObjectIdentifier(self)] = self
    }

    private func releaseWhenDelivered() {
        activeStarts -= 1
        if activeStarts <= 0 {
            Self.activePayments.removeValue(forKey: ObjectIdentifier(self))
            presenter.anchor = nil
        }
    }

    /// Ends the active payment. Returns immediately; the payment UI is dismissed and the pending `start` then
    /// receives one `.interrupted` with `PAYMENT_ABORTED`. If the payment ends another way first (a verdict, the
    /// timeout), that outcome stands and this call has no effect; repeated calls are harmless. With no active
    /// payment this does nothing. The instance stays usable: you can call `start` again.
    public func close() {
        coordinator.closeRequested()
    }

    /// Reloads the payment page for the active payment, with the same `operationId` and options (including the
    /// theme resolved when the payment started). The payment UI stays on screen, no outcome is delivered for the
    /// reload — the original `start` still receives exactly one — and the payment timeout starts over. With no
    /// active payment this does nothing (call `start` instead); if the payment ends at the same moment, that
    /// outcome stands.
    public func restart() {
        coordinator.restartRequested()
    }

    /// Reports payments whose result may be unknown to your app, so you can reconcile them with your backend.
    ///
    /// A payment is recorded when its UI had been shown and it then ended by `close()`, a dismissal the SDK did
    /// not initiate, or the payment timeout — cases where the payer may still have completed it. Records are
    /// stored on the device and survive process restarts.
    ///
    /// Each call hands every stored record to `listener`, once per record and on the main queue, with your
    /// `operationId` and the `debugId` (`khp_…`) of the `KhipuPaymentError` that payment ended with, and then
    /// deletes it. The listener is not kept: records created later are reported by the next call, typically at
    /// the next app launch. Records older than 30 days are discarded without being reported. With no stored
    /// records the call does nothing.
    ///
    /// **Advisory only:** this never changes a payment's outcome, and the SDK does not query khipu for the payment's
    /// status. Check it with your backend; khipu's server-to-server notification is authoritative.
    public func onOrphanedPaymentDetected(_ listener: @escaping (_ operationId: String, _ debugId: String) -> Void) {
        coordinator.onOrphanedPaymentDetected(listener)
    }

    /// Internal teardown: shut the host down (no eval against a dead WebView) and close the dispatcher (reject
    /// post-close, release pending without delivering). Distinct from the public `close()`/`restart()`: close()
    /// ends a PAYMENT; this is the host/dispatcher END-OF-LIFE shutdown. Production trigger: `deinit`, iOS's only
    /// instance-death signal, which runs this same body (see there). Android's end-of-life is GC, with no
    /// deterministic signal, so its twin has no production caller.
    func teardown() {
        host.shutdown()
    }

    /// Returns a snapshot of the SDK's local diagnostics for troubleshooting; nothing is sent to khipu.
    /// `.json` (the default) returns a `DiagnosticsDump`; `.text` returns a line-oriented `String` for logs.
    /// Correlation ids appear only hashed (`correlation_id_hash`).
    public func dumpDiagnostics(format: DiagnosticsFormat = .json) -> Any {
        // The .json/.text selection is the pure, unit-tested Diagnostics.render seam.
        Diagnostics.render(Diagnostics.build(dispatcher: dispatcher, recorder: recorder, webViewEngine: Self.webViewEngine()), format: format)
    }

    // Best effort: WKWebView exposes no engine version, so it stays "unknown". Android reads the live provider
    // version where available.
    private static func webViewEngine() -> WebViewEngine {
        WebViewEngine(name: "WKWebView", version: "unknown")
    }

    /// Restricted diagnostics surface for SDK tests and advanced bug reports, not for regular integration code.
    /// For routine troubleshooting use `dumpDiagnostics(format:)`.
    public let __internals__: Internals

    public struct Internals {
        fileprivate let dispatcher: BridgeDispatcher
        /// The bridge contract version (`contract_version`) and every registered capability with its availability
        /// on this OS version (`supports`: capability id to `Bool`).
        public func getCapabilitiesRaw() -> [String: Any] {
            [
                "contract_version": Diagnostics.contractVersion,
                "supports": Dictionary(uniqueKeysWithValues: dispatcher.declared.map { ($0.id, $0.availableOnOS) }),
            ]
        }
    }
}

extension KhipuPaymentInternal {
    /// Production wiring convenience: bind the coordinator's load/deliver seams to a live host. WEAK host —
    /// the coordinator must not retain the host strongly (see the retain-cycle note in `KhipuPayment.init`).
    /// `origin` mirrors the designated init's default: production, the public surface's only origin.
    ///
    /// The lifecycle seams ride the same weak-host pattern — `_resume` fire-and-forget, `_ping` reporting (pong,
    /// gateOrEvalReason); a dead host answers the ping with `webview_unavailable` so the coordinator still reloads
    /// instead of waiting the full deadline. NO flushCookies seam: WKHTTPCookieStore persists asynchronously,
    /// while Android injects CookieManager.flush(). This wiring has no unit test of its own; the seams themselves
    /// are tested through the coordinator and host/responder suites.
    convenience init(
        presenter: PaymentPresenting,
        recorder: DiagnosticsRecorder,
        host: KhipuWebViewHost,
        // The public surface passes the no-op sink; the test seam may inject one (KhipuTestConfig).
        telemetry: TelemetrySink = NoopTelemetrySink(),
        origin: PaymentOrigin = .production,
        // The selective per-domain cookie clear at terminal/close (no-op default; KhipuPayment.init wires the real
        // WKHTTPCookieStore-backed clear).
        clearCookiesForHost: @escaping (String) -> Void = { _ in },
        // The build-flag-gated bank-return seam (no-op default; KhipuPayment.init wires the detector).
        onBankAppReturn: @escaping (String) -> Void = { _ in }
    ) {
        self.init(
            presenter: presenter,
            loadPage: { [weak host] url in host?.load(url: url) },
            deliverRequest: { [weak host] request in host?.deliverRequest(request) },
            recorder: recorder,
            telemetry: telemetry,
            origin: origin,
            clearCookiesForHost: clearCookiesForHost,
            evalResume: { [weak host] operationId in host?.resume(operationId: operationId) },
            evalPing: { [weak host] onResult in
                guard let host = host else { onResult(false, "webview_unavailable"); return }
                host.ping(onResult: onResult)
            },
            // Recover from a content-process termination by reloading the reusable WKWebView (no re-creation). A
            // nil host (deallocated) returns false → fail-closed.
            recoverWebView: { [weak host] in host?.recoverWebView() ?? false },
            // The REAL OS dark-mode read for Theme.auto. Reads the SYSTEM interface style from the connected
            // scene's KEY WINDOW — the same source Android reads (Configuration.uiMode), so .auto resolves
            // identically on both platforms (same key-window lookup as
            // SheetPaymentPresenter.topMostViewController). NOT the host WebView's traitCollection: at start() the
            // SDK WebView is still frame:.zero / OFF-WINDOW (it joins the hierarchy only in present()→viewDidLoad,
            // which runs AFTER theme resolution), and a detached view's userInterfaceStyle does NOT reliably
            // reflect the device — a dark device could resolve to "light". `UITraitCollection.current` is reliable
            // only inside UIKit callbacks, never from the coordinator. No key window (style nil) floors .auto to
            // light, mirroring the coordinator's own default.
            systemIsDark: {
                UIApplication.shared.connectedScenes
                    .compactMap { $0 as? UIWindowScene }
                    .flatMap { $0.windows }
                    .first { $0.isKeyWindow }?
                    .traitCollection.userInterfaceStyle == .dark
            },
            // Persists payer-in-limbo terminals so onOrphanedPaymentDetected can surface them across a process
            // restart; records expire after 30 days. A plain file in a directory excluded from backup, Foundation
            // only (NoBackupFileOrphanStore explains why not UserDefaults, and why not the Keychain, which would
            // leak operationIds across installs). Mirrors the Android wiring.
            orphanStore: OrphanMetadataStore(store: NoBackupFileOrphanStore()),
            // Forward the build-flag-gated bank-return seam to the designated init.
            onBankAppReturn: onBankAppReturn
        )
    }
}
