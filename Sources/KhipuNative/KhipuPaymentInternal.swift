import Foundation
import BridgeGenerated

/// The presentation seam. The coordinator is deliberately VC/WebView-free so it stays unit-testable; the
/// SDK-managed open/close of the payment sheet goes through this protocol. The real implementation is the `UI/`
/// sheet shell, tests inject a fake. Mirrors Kotlin's `PaymentPresenter`.
protocol PaymentPresenting: AnyObject {
    /// Open the SDK-owned payment UI for `nativeOpId` (modal sheet). `isDark` is the RESOLVED theme, so the
    /// native chrome (status-bar style + view background) matches the payment page.
    func present(nativeOpId: String, isDark: Bool)

    /// Close the payment UI, then invoke `onClosed`. Idempotent: a UI that is already gone must still call
    /// `onClosed`, or the terminal delivery is lost and the merchant callback hangs.
    func close(nativeOpId: String, onClosed: @escaping () -> Void)
}

/// The single `start()` implementation behind every public surface: the Swift async + completion surfaces and
/// the Kotlin twins all delegate to this one coordinator. Mirrors `KhipuPaymentInternal.kt` behavior-for-behavior:
/// registry semantics, single-flight, terminal latch causes, timeout, cancel mapping, orphan fields, recorder
/// calls, teardown-then-deliver ordering, and the collect-under-lock/emit-after-release telemetry discipline. See
/// the Kotlin twin for the full design commentary.
final class KhipuPaymentInternal {
    private let presenter: PaymentPresenting
    private let loadPage: (URL) -> Void
    private let deliverRequest: (String) -> Void
    private let recorder: DiagnosticsRecorder
    // Named exactly `telemetry`: the telemetry-name gate (`bridge/codegen/src/telemetry-gate.ts`) finds the emit
    // callsites below by that receiver name.
    private let telemetry: TelemetrySink
    private let origin: PaymentOrigin
    /// The SELECTIVE per-domain cookie clear at terminal/close. Injected so the coordinator stays free of WebKit
    /// types and the tests can prove the SCOPE — the load-bearing part: `WKWebsiteDataStore.default()` is
    /// APP-GLOBAL, so a blanket clear would wipe the MERCHANT app's own cookies. Called with the payment host, ONCE
    /// per terminal, fail-soft. (Android's twin also has a flush seam; iOS needs none.)
    private let clearCookiesForHost: (String) -> Void
    private let paymentTimeoutMs: Double
    private let presentConfirmTimeoutMs: Double
    /// Ceiling for the INTERNAL delays (`presentConfirmTimeoutMs` 5s, `pingTimeoutMs` 2s, `pingProbeDelayMs`
    /// 1.5s), which have no schema `timeout` block to clamp against — unlike `paymentTimeoutMs`, which clamps to
    /// the op's own `[minMs, maxMs]`. 60s sits far above every default: generous for a slow simulator or a
    /// main-thread backlog, while still bounding an injected value instead of letting `Int(…)` trap on it.
    private static let internalBackstopCeilingMs: Int64 = 60_000
    private let mainQueue: DispatchQueue
    private let timeoutQueue = DispatchQueue(label: "com.khipu.payment.timeout", attributes: .concurrent)
    private let monotonicMs: () -> Double
    private let operationId: OperationId
    private let correlationId: () -> String
    private let sessionId: () -> String
    private let debugId: DebugId
    private let translator: PublicErrorTranslator
    private let maxEnvelopeBytes: Int
    private let terminalRecordCap: Int
    private let terminalRecordTtlMs: Double
    private let evalResume: (String) -> Void
    private let evalPing: (@escaping (Bool, String?) -> Void) -> Void
    private let pingTimeoutMs: Double
    private let pingProbeDelayMs: Double
    private let recoverWebView: () -> Bool
    private let systemIsDark: () -> Bool
    // The local orphan-metadata store — see the Kotlin twin for the full commentary.
    private let orphanStore: OrphanMetadataStore
    // The bank-app return-detection seam — see the Kotlin twin. Called from appReturnedToForeground for the ACTIVE
    // non-terminal payment with the hashed NATIVE op id; no-op default, the production closure (wired ONLY when
    // KHIPU_CAP_BANK_RETURN is defined) delegates to BankReturnDetector. OBSERVE + SIGNAL ONLY — never alters the
    // resume path, the latch, or finish().
    private let onBankAppReturn: (String) -> Void

    private let lock = NSLock()
    /// `backgrounded` is the resume protocol's CONSUMPTION TOKEN — set only by `appMovedToBackground()`, cleared
    /// (consumed) by the first `appReturnedToForeground()`; guarded by `lock`.
    private var backgrounded = false
    /// The ping-round SEQUENCE, coordinator state under `lock`. A new round supersedes the prior one (its deadline
    /// is cancelled and its late fail/deadline callbacks no-op via the seq guard), so a stale round-1 deadline can
    /// never reload a page round-2 just proved alive, and overlapping silent rounds cannot double-reload. Mirrors
    /// Kotlin.
    private var pingRoundSeq: UInt64 = 0
    private var pingDeadlineItem: DispatchWorkItem?
    /// The DEFERRED `_ping` probe of the current round, guarded by `lock` like `pingDeadlineItem` and cancelled at
    /// every one of the four sites that supersede a round. The cancel is hygiene, not correctness: every one of
    /// those sites also bumps `pingRoundSeq`, and the probe re-reads it under `lock` before evaluating anything, so
    /// a superseded probe is already INERT. The handle lets a supersession release the work item instead of leaving
    /// it booked on the main queue — with its `OperationRecord` and `PingRound` pinned — for the rest of the delay.
    private var pingProbeItem: DispatchWorkItem?
    /// The native operation registry: `khp_op_` → record + insertion order (terminal records RETAINED for the
    /// orphan guard's `reason:"terminal"`, bounded by cap + TTL).
    private var records: [String: OperationRecord] = [:]
    private var recordOrder: [String] = []
    /// Inbound matching index: the response envelope echoes `correlation_id`, not the native op id.
    private var byCorrelation: [String: String] = [:]
    /// Single-flight: one ACTIVE operation per instance (the instance owns ONE WebView/host).
    private var activeOpId: String?

    private final class OperationRecord {
        let nativeOpId: String
        // Byte-verbatim merchant id — never validated/normalized; distinct from nativeOpId.
        let merchantOperationId: String
        // Mutable: the controlled reload re-stamps BOTH under `lock` (fresh correlation + session on the SAME
        // record); finish()/recordError keep reading the current value.
        var correlationId: String
        var sessionId: String
        // The merchant options as they ride the wire: resolved ONCE at start() and IMMUTABLE (theme is fixed for
        // the payment session). `reStampForReload` re-stamps ONLY the correlation/session pair above, NEVER these
        // — a controlled reload re-sends the SAME resolved theme/style/bag verbatim (pinned by test).
        let resolvedTheme: String // "light"|"dark" — never "auto" on the wire
        let style: PaymentStyle? // nil = no styling field set → omitted from the payload
        // Top-level request booleans (not inside `style`): nil = omitted from the payload (the frozen "omitted,
        // never null" rule). Resolved ONCE at start() and IMMUTABLE — a reload re-sends them verbatim.
        let skipExitPage: Bool?
        let skipExitSuccessPage: Bool?
        let webOptions: [String: String] // empty = omitted from the payload (pass-through bag)
        // The merchant's BCP-47 locale for SDK-owned strings, IMMUTABLE like the options above. NATIVE-ONLY: never
        // serialized into buildStartRequest (the web owns its own localization, and the contract hash stays
        // frozen). nil = es-CL.
        let locale: String?
        let startedAtMonoMs: Double
        // Nulled after the one delivery: terminal records are RETAINED ≤cap/≤TTL for the orphan guard, which only
        // needs the ids — keeping the closure would pin whatever merchant UI it captured (a view controller,
        // typically) for up to an hour.
        var onResult: ((KhipuPaymentOutcome) -> Void)?
        /// Terminal latch: nil = ACTIVE; non-nil = WHY it went terminal. Claimed UNDER `lock` (the Swift
        /// dispatcher's PendingEntry pattern) — first-writer-wins, absorbing.
        var terminal: String?
        var terminalAtMonoMs: Double = 0
        var timeoutItem: DispatchWorkItem?
        // Present-confirmation state — the flag is `lock`-guarded (set by presentConfirmed(), re-checked by the
        // deadline before failing closed); the item handle mirrors timeoutItem. Mirrors Kotlin.
        var presentConfirmed = false
        var presentConfirmItem: DispatchWorkItem?
        // Set the first time a late web response triggers bridge.reconciliation_required for this op, so multiple
        // late responses emit it AT MOST ONCE. Guarded by `lock`.
        var reconciliationSignaled = false

        init(
            nativeOpId: String,
            merchantOperationId: String,
            correlationId: String,
            sessionId: String,
            resolvedTheme: String,
            style: PaymentStyle?,
            skipExitPage: Bool?,
            skipExitSuccessPage: Bool?,
            webOptions: [String: String],
            locale: String?,
            startedAtMonoMs: Double,
            onResult: @escaping (KhipuPaymentOutcome) -> Void
        ) {
            self.nativeOpId = nativeOpId
            self.merchantOperationId = merchantOperationId
            self.correlationId = correlationId
            self.sessionId = sessionId
            self.resolvedTheme = resolvedTheme
            self.style = style
            self.skipExitPage = skipExitPage
            self.skipExitSuccessPage = skipExitSuccessPage
            self.webOptions = webOptions
            self.locale = locale
            self.startedAtMonoMs = startedAtMonoMs
            self.onResult = onResult
        }
    }

    init(
        presenter: PaymentPresenting,
        loadPage: @escaping (URL) -> Void,
        deliverRequest: @escaping (String) -> Void,
        recorder: DiagnosticsRecorder,
        telemetry: TelemetrySink = NoopTelemetrySink(),
        // The page origin. Default production — the public surface's only origin.
        origin: PaymentOrigin = .production,
        // Default no-op so every existing callsite/test compiles unchanged; the public surface injects the real
        // WKHTTPCookieStore-backed clear.
        clearCookiesForHost: @escaping (String) -> Void = { _ in },
        // Schema timeout for startPayment_v1: default_ms from the GENERATED ContractConstants. Injectable so tests
        // pass an explicit value per case.
        paymentTimeoutMs: Double = Double(ContractConstants.startPaymentV1Timeout.defaultMs),
        // The positive present-confirmation deadline: how long after present() the sheet shell has to POSITIVELY
        // confirm the UI appeared (the present completion ran) before the operation fails closed. It closes the
        // silent UIKit-refusal window the best-effort pre-checks miss. Mirrors Kotlin.
        presentConfirmTimeoutMs: Double = 5_000,
        mainQueue: DispatchQueue = .main,
        // MONOTONIC: CLOCK_MONOTONIC keeps advancing through device sleep, matching Android's elapsedRealtime() —
        // same latency classification on both platforms.
        monotonicMs: @escaping () -> Double = { Double(clock_gettime_nsec_np(CLOCK_MONOTONIC)) / 1_000_000 },
        operationId: OperationId = OperationId(),
        correlationId: @escaping () -> String = { UUID().uuidString },
        // The coordinator GENERATES the session_id it stamps on its outbound request (it cannot reuse the
        // dispatcher's inbound pin — that pins the web→native direction); the response must ECHO it.
        sessionId: @escaping () -> String = { UUID().uuidString },
        debugId: DebugId = DebugId(),
        translator: PublicErrorTranslator? = nil,
        // Same inbound bound as the dispatcher (Swift bounds exact utf8 bytes).
        maxEnvelopeBytes: Int = 256 * 1024,
        // Terminal-record retention bounds — mirrors recentMeta/debugIdMap (cap 200 / 1h).
        terminalRecordCap: Int = 200,
        terminalRecordTtlMs: Double = 60 * 60 * 1000,
        // --- Lifecycle seams (house DI: real defaults, tests inject per case). The resume logic lives HERE — see
        // the Kotlin twin for why. NO flushCookies seam on iOS: WKHTTPCookieStore persists asynchronously with no
        // public flush API (backgrounding triggers the OS write-back); Android injects CookieManager.flush() here.
        /// Eval `window.khipuBridge._resume(merchantOperationId)` — fire-and-forget (`KhipuWebViewHost.resume`).
        evalResume: @escaping (String) -> Void = { _ in },
        /// Eval `window.khipuBridge._ping()` and report (pong, gateOrEvalReason) (`KhipuWebViewHost.ping`).
        evalPing: @escaping (@escaping (Bool, String?) -> Void) -> Void = { $0(false, nil) },
        /// The anti-zombie pong deadline, counted from the deferred probe (see `pingProbeDelayMs`).
        pingTimeoutMs: Double = 2_000,
        /// How long AFTER the `_resume` the single `_ping` probe waits before it evaluates (ADR-163; the defect it
        /// closes is described on `appReturnedToForeground`).
        ///
        /// Why 1500ms: the kws tick and the SPA heartbeat are both 1000ms, so `max(tick, beat) + 500ms jitter`;
        /// 1000ms would sit exactly on the edge. The heartbeat is emitted by an effect that runs after every React
        /// commit, so if React wedges the beat STOPS even though the JS thread is alive — that is what lets this
        /// probe detect a wedged SPA at all.
        ///
        /// Injectable (like `pingTimeoutMs`) so a web-side re-tune stays a change of a DEFAULT, not of the design.
        /// Mirrors Kotlin's `PING_PROBE_DELAY_MS`.
        pingProbeDelayMs: Double = 1_500,
        // Render-process-death recovery (house DI: real default, tests inject). iOS reloads the reusable WKWebView
        // (the content process re-spawns on the next load), so the seam clears the host's render-dead guard and
        // returns true when a payment is active; the default { false } is the fail-closed floor. Mirrors Kotlin's
        // recreateWebView. The reload itself rides reStampForReload/performReloadOnMain — there is NO second reload
        // path.
        recoverWebView: @escaping () -> Bool = { false },
        // --- Theming (house DI: the construction site injects the REAL trait read). The coordinator is VC/UI-free
        // BY DESIGN, so the OS dark-mode question arrives as a closure. Consulted ONLY for .auto, ONCE, at
        // start(): the resolved `light`|`dark` is what reaches the wire; the web NEVER sees "auto". The default
        // `{ false }` resolves an unwired coordinator's .auto to light — a visible, harmless floor. Mirrors
        // Kotlin. ---
        systemIsDark: @escaping () -> Bool = { false },
        // The local orphan-metadata store. Default is in-memory (harmless for tests that never exercise orphans);
        // the public surface wires the file-backed store (NoBackupFileOrphanStore). nil-coalesced (Swift defaults cannot reference
        // another parameter like Kotlin's `telemetry = telemetry`) so the default shares this coordinator's
        // `telemetry` sink. Mirrors Kotlin.
        orphanStore: OrphanMetadataStore? = nil,
        // The bank-app return seam (no-op default; the build-flag-ON wiring delegates to the detector).
        onBankAppReturn: @escaping (String) -> Void = { _ in }
    ) {
        self.presenter = presenter
        self.loadPage = loadPage
        self.deliverRequest = deliverRequest
        self.recorder = recorder
        self.telemetry = telemetry
        self.origin = origin
        self.clearCookiesForHost = clearCookiesForHost
        self.paymentTimeoutMs = paymentTimeoutMs
        self.presentConfirmTimeoutMs = presentConfirmTimeoutMs
        self.mainQueue = mainQueue
        self.monotonicMs = monotonicMs
        self.operationId = operationId
        self.correlationId = correlationId
        self.sessionId = sessionId
        self.debugId = debugId
        self.translator = translator ?? PublicErrorTranslator(telemetry: telemetry, debugId: debugId)
        self.maxEnvelopeBytes = maxEnvelopeBytes
        self.terminalRecordCap = terminalRecordCap
        self.terminalRecordTtlMs = terminalRecordTtlMs
        self.evalResume = evalResume
        self.evalPing = evalPing
        self.pingTimeoutMs = pingTimeoutMs
        self.pingProbeDelayMs = pingProbeDelayMs
        self.recoverWebView = recoverWebView
        self.systemIsDark = systemIsDark
        self.orphanStore = orphanStore ?? OrphanMetadataStore(store: InMemoryOrphanStore(), telemetry: telemetry)
        self.onBankAppReturn = onBankAppReturn
    }

    /// The ONE implementation: single-flight check → register → present UI → load the payment page → deliver the
    /// `startPayment_v1` request (readiness-gated by the responder) → arm the schema timeout. `options` is resolved
    /// HERE, once: theme `.auto` → the injected `systemIsDark` read; `.light`/`.dark` pass through WITHOUT
    /// consulting it (pinned by a counting test) — then stored immutably on the record. Mirrors Kotlin.
    func start(
        merchantOperationId: String,
        options: KhipuOptions = .default(),
        onResult: @escaping (KhipuPaymentOutcome) -> Void
    ) {
        // Theme resolution BEFORE the lock (an injected closure must never run under `lock`) and ONCE per start():
        // only .auto consults the OS. No try/catch mirror of the Kotlin guard: `() -> Bool` cannot throw
        // (type-system-guaranteed, not a behavior divergence).
        let resolvedTheme: String
        switch options.theme {
        case .light: resolvedTheme = Self.themeLight
        case .dark: resolvedTheme = Self.themeDark
        case .auto: resolvedTheme = systemIsDark() ? Self.themeDark : Self.themeLight
        }
        // Forwarded byte-verbatim, no validation. All-nil styling → nil (omitted from the wire — "omitted, never
        // sent as null"). The skip_exit_page / skip_exit_success_page booleans ride TOP-LEVEL on the request (not
        // inside `style`), so they NEVER force a `style` object.
        let style: PaymentStyle?
        if options.primaryColor != nil || options.fontFamily != nil {
            style = PaymentStyle(
                fontFamily: options.fontFamily,
                primaryColor: options.primaryColor
            )
        } else {
            style = nil
        }
        var record: OperationRecord?
        lock.lock()
        let active = activeOpId.flatMap { records[$0] }
        if active == nil || active?.terminal != nil {
            purgeTerminalRecordsLocked()
            let opId = operationId.generate() // khp_op_<base32(8)>
            let r = OperationRecord(
                nativeOpId: opId,
                merchantOperationId: merchantOperationId,
                correlationId: correlationId(),
                sessionId: sessionId(),
                resolvedTheme: resolvedTheme,
                style: style,
                skipExitPage: options.skipExitPage,
                skipExitSuccessPage: options.skipExitSuccessPage,
                webOptions: options.webOptions,
                locale: options.locale,
                startedAtMonoMs: monotonicMs(),
                onResult: onResult
            )
            records[opId] = r
            recordOrder.append(opId)
            byCorrelation[r.correlationId] = opId
            activeOpId = opId
            record = r
            // A stale PRE-payment background token must not resume THIS payment — the consumable transition has
            // to happen DURING the payment. Pinned by test on both platforms.
            backgrounded = false
        }
        lock.unlock()
        guard let r = record else {
            // A second start() while one is active resolves the NEW call immediately with INVALID_CONFIGURATION
            // and does NOT disturb the active payment. The recorder is deliberately NOT fed: no operation existed,
            // so there is nothing to attribute the error to. No custom "a payment is already active" hint: the
            // generated error table is FROZEN, and neither a hand-written error twin nor regenerating it is allowed.
            let error = publicError(.INVALID_CONFIGURATION, debugId: debugId.generate())
            mainQueue.async { onResult(.interrupted(error)) }
            return
        }
        // No origin gate here — it runs at READINESS in the bridge responder, per page epoch (ADR-221; see the
        // Kotlin twin).
        let pageUrl = origin.url
        if case .harness = origin, Self.isUnloadableOrigin(pageUrl) {
            // iOS-only: a missing bundled harness resolves to about:blank, which loads successfully, so detect it
            // here and fail fast (INVALID_CONFIGURATION, cause load_failed).
            loadFailed(r.nativeOpId)
            return
        }
        // UI + WebView work happens on main; ORDER matters: load() bumps the page epoch, and deliverRequest()
        // captures the CURRENT epoch — the request must bind to the payment page. Mirrors Kotlin. The presenter
        // detects a refused presentation and routes presentFailedRequested (fail-closed; the Kotlin twin wraps the
        // same block in try/catch).
        mainQueue.async {
            // Re-check the latch on the main hop BEFORE presenting: a close()/terminal that won the CAS between the
            // registration above and this queued block must NOT present a zombie sheet after the result was already
            // delivered (later start()s would then fail present_failed). Same discipline as performReloadOnMain.
            self.lock.lock()
            let terminated = r.terminal != nil
            self.lock.unlock()
            if terminated { return }
            // Open the SDK-owned UI; native chrome follows the resolved theme.
            self.presenter.present(nativeOpId: r.nativeOpId, isDark: r.resolvedTheme == Self.themeDark)
            self.loadPage(pageUrl)
            self.deliverRequest(self.buildStartRequest(r))
            // Arm the present-confirmation deadline HERE, after present(): the budget must time the present
            // ATTEMPT, not start()-call time, or a main-thread backlog longer than presentConfirmTimeoutMs consumes
            // it before present() ran → a spurious present_timeout. A silently-refused presentation (the UIKit
            // refusals the best-effort pre-checks miss; Android's twin is background-activity-launch suppression)
            // routes NO present completion, so silence past the deadline fails closed with its OWN cause. The
            // unloadable-harness and single-flight-rejected paths returned above, so no deadline is armed for them.
            let confirmItem = DispatchWorkItem { [weak self] in self?.presentConfirmDeadlineExpired(r.nativeOpId) }
            self.lock.lock()
            r.presentConfirmItem = confirmItem
            let alreadyTerminal = r.terminal != nil
            self.lock.unlock()
            self.timeoutQueue.asyncAfter(
                deadline: .now() + .milliseconds(khipuClampTimeoutMs(self.presentConfirmTimeoutMs, max: Self.internalBackstopCeilingMs, fallback: 5_000)), execute: confirmItem)
            if alreadyTerminal { confirmItem.cancel() } // post-arm race close
        }
        // The SDK's ONLY wait-side backstop: the `paymentTimeoutMs` `startPayment_v1` budget (default 10 min, max
        // 20 min, from ContractConstants). The SDK has NO bank-app-AUTHORIZATION timeout of its own (the openApp_v1
        // op timeout bounds only the launch round-trip); the web is the orchestrator, and khipu's backend rolling
        // timeout normally drives the web to a terminal ERROR first. On expiry this budget produces an HONEST
        // `.interrupted(PAYMENT_TIMEOUT)` ("the SDK stopped waiting") via expire()→finish() — NEVER a fabricated
        // success/failure. Do NOT add an authorization-wait timer and do NOT shorten this backstop; the only
        // re-arm is the deliberate one in `restartRequested`. Mirrors Kotlin.
        let timeoutItem = DispatchWorkItem { [weak self] in self?.expire(r.nativeOpId) }
        lock.lock()
        r.timeoutItem = timeoutItem
        let alreadyTerminal = r.terminal != nil
        lock.unlock()
        timeoutQueue.asyncAfter(deadline: .now() + .milliseconds(khipuClampTimeoutMs(paymentTimeoutMs, budget: ContractConstants.startPaymentV1Timeout)), execute: timeoutItem)
        // A terminal can win the race BEFORE the timeout work item was assigned — its finish() cancelled nothing,
        // leaving a live timer (absorbed by the latch). The present-confirm timer's post-arm close lives inside
        // the present block, where it is armed.
        if alreadyTerminal { timeoutItem.cancel() }
    }

    /// The sheet shell POSITIVELY confirmed the presentation appeared: the `present(_:animated:completion:)`
    /// completion ran (Android's twin: the payment Activity bound in onCreate). Cancels the armed confirmation
    /// deadline; the flag is set under `lock` so a deadline already past its delay re-checks and no-ops. Unknown
    /// id / no deadline armed → safe no-op. Mirrors Kotlin.
    func presentConfirmed(nativeOpId: String) {
        lock.lock()
        let r = records[nativeOpId]
        r?.presentConfirmed = true
        let item = r?.presentConfirmItem
        lock.unlock()
        item?.cancel()
    }

    /// Claim the terminal for `nativeOpId` with `present_timeout` IFF still unconfirmed — the confirmed-flag check
    /// and the latch claim are ONE critical section: a confirmation that set presentConfirmed=true before this lock
    /// wins (claim skipped — NEVER a false fail-closed for a UI that DID appear); presentConfirmed() only sets the
    /// flag and does NOT claim the latch, so a read-then-claim would leave a window that kills a live sheet.
    /// Returns the record iff THIS caller won.
    private func claimPresentTimeout(_ nativeOpId: String) -> OperationRecord? {
        lock.lock(); defer { lock.unlock() }
        guard let r = records[nativeOpId], r.terminal == nil, !r.presentConfirmed else { return nil }
        r.terminal = Self.causePresentTimeout
        return r
    }

    /// The present-confirmation deadline expired with no positive confirmation and no terminal: fail closed with
    /// INTERNAL_ERROR through the ONE finish(), its own cause (`present_timeout` — forensics must never confuse a
    /// silent refusal with a detected one). The unconfirmed-flag check and the claim are atomic
    /// (`claimPresentTimeout`); the latch absorbs it if any terminal won first. Mirrors Kotlin's
    /// `finishPresentTimeout`.
    private func presentConfirmDeadlineExpired(_ nativeOpId: String) {
        guard let r = claimPresentTimeout(nativeOpId) else { return }
        let latencyMs = Int64(max(0, monotonicMs() - r.startedAtMonoMs))
        let error = publicError(.INTERNAL_ERROR, debugId: debugId.generate())
        finish(r, .failure(error), latencyMs: latencyMs, errorForRecorder: error)
    }

    /// Async form of the same single implementation — lives HERE (not in the public shell) so the both-surfaces
    /// test drives the REAL shared code without a WKWebView. RETURNS the typed `KhipuPaymentOutcome`: an
    /// interruption is `.interrupted(error)`, a value. The only error it throws is `CancellationError`.
    ///
    /// **The payment outlives the caller:** cancelling the calling Task does NOT cancel the payment (true cancel
    /// is the public `close()` → `closeRequested`). The wait ends at once with `CancellationError`; the operation
    /// runs to its terminal, which `finish()` records (and, for a payer-in-limbo cause, persists as an orphan)
    /// exactly as for any payment, and the outcome is dropped for this caller. A Task that is already cancelled
    /// when it calls this still starts the payment and throws at once. The Kotlin suspend twin has the same
    /// contract, from `suspendCancellableCoroutine`; `CancellableOutcome` is what gives it to Swift.
    func start(
        merchantOperationId: String,
        options: KhipuOptions = .default()
    ) async throws -> KhipuPaymentOutcome {
        // Started BEFORE the wait, through the callback form, so the payment never depends on the caller — the
        // same order as Kotlin, whose suspendCancellableCoroutine block runs even in a cancelled coroutine.
        let outcome = CancellableOutcome()
        start(merchantOperationId: merchantOperationId, options: options, onResult: outcome.deliver)
        return try await outcome.value()
    }

    /// The presenter refused the presentation (nil resolved host / host already presenting): fail closed with
    /// INTERNAL_ERROR through the one terminal path — never a headless payment running until the payment budget
    /// expires. The latch absorbs it if a racing terminal already won. Mirrors the Kotlin twin's try/catch around
    /// the present/load block.
    func presentFailedRequested(nativeOpId: String) {
        guard let r = claimTerminal(nativeOpId, cause: Self.causePresentFailed) else { return }
        let latencyMs = Int64(max(0, monotonicMs() - r.startedAtMonoMs))
        let error = publicError(.INTERNAL_ERROR, debugId: debugId.generate())
        finish(r, .failure(error), latencyMs: latencyMs, errorForRecorder: error)
    }

    /// Inbound `message_type:"response"` envelope, routed here by the host — never through the dispatcher.
    /// Validates with the dispatcher's inbound discipline (size bound → parse → blank checks), enforces the session
    /// echo, runs the orphan guard, then resolves the latch exactly once.
    func completeFromWeb(_ envelopeJSON: String) {
        // Size bound BEFORE parse (exact UTF-8 byte count on iOS).
        guard envelopeJSON.utf8.count <= maxEnvelopeBytes else {
            telemetry.emit(
                event: TelemetryEvent.envelopeTooLarge,
                fields: ["size": envelopeJSON.utf8.count, "max": maxEnvelopeBytes, "severity": "warn"]
            )
            return
        }
        guard let data = envelopeJSON.data(using: .utf8),
              let env = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            // No deliverable target (this IS the response side) — drop with the malformed diagnostic.
            telemetry.emit(
                event: TelemetryEvent.malformedEnvelope,
                fields: ["reason": "unparseable_envelope", "severity": "warn"]
            )
            return
        }
        let cid = env["correlation_id"] as? String
        let sid = env["session_id"] as? String
        guard let cidValue = cid, !Self.isBlank(cidValue), let sidValue = sid, !Self.isBlank(sidValue) else {
            var fields: [String: Any] = ["reason": "blank_or_missing_field", "severity": "warn"]
            if let c = cid, !Self.isBlank(c) { fields["correlation_id_hash"] = Sha256.hex(c) }
            telemetry.emit(event: TelemetryEvent.malformedEnvelope, fields: fields)
            return
        }

        // Lookup + classification + latch claim under the lock; ALL emission deferred to after release.
        var orphanFields: [String: Any]?
        var mismatchFields: [String: Any]?
        // Collected ALONGSIDE orphanFields in the already-terminal branch — emitted BESIDE bridge.orphan_response
        // (not instead of it) when the terminal cause ∈ {timeout, cancelled, closed}.
        var reconciliationFields: [String: Any]?
        var claimed: OperationRecord?
        lock.lock()
        let r = byCorrelation[cidValue].flatMap { records[$0] }
        if let r = r {
            if r.sessionId != sidValue {
                // The response must ECHO the session this start() stamped — a mismatch is discarded with the
                // existing discipline (same event + fields as the dispatcher's inbound pin).
                mismatchFields = ["op": Self.opStartPayment, "correlation_id_hash": Sha256.hex(cidValue), "severity": "warn"]
            } else if r.terminal != nil {
                // Known but already terminal — hash the NATIVE khp_op_ id (it is known here), and ADDITIONALLY
                // collect the reconciliation_required fields when the cause is payer-in-limbo. (Swift claims the
                // latch atomically under THIS lock — there is no CAS-loser branch like Kotlin's.)
                orphanFields = ["operation_id_hash": Sha256.hex(r.nativeOpId), "reason": "terminal"]
                reconciliationFields = reconciliationFieldsIfNeededLocked(r)
            } else {
                r.terminal = Self.causeWeb // first-writer-wins, claimed atomically with the lookup
                claimed = r
            }
        } else {
            // Unknown correlation — hash the RECEIVED id (no native khp_op_ is known), NEVER the raw value.
            orphanFields = ["operation_id_hash": Sha256.hex(cidValue), "reason": "unknown"]
        }
        lock.unlock()
        if let fields = orphanFields {
            telemetry.emit(event: TelemetryEvent.orphanResponse, fields: fields)
            // The late response is DISCARDED (no finish()/callback) — the already-delivered merchant outcome is
            // never overridden; it is only SIGNALED for reconciliation.
            if let recon = reconciliationFields { telemetry.emit(event: TelemetryEvent.reconciliationRequired, fields: recon) }
            return
        }
        if let fields = mismatchFields { telemetry.emit(event: TelemetryEvent.sessionMismatchDiscarded, fields: fields); return }
        guard let record = claimed else { return }

        let latencyMs = Int64(max(0, monotonicMs() - record.startedAtMonoMs))
        let outcome = decodeOutcome(env, locale: record.locale)
        finish(record, outcome.result, latencyMs: latencyMs, errorForRecorder: outcome.errorForRecorder)
    }

    /// The `bridge.reconciliation_required` fields for a late web response that targets an ALREADY-TERMINAL op whose
    /// cause is in the payer-in-limbo set {timeout, cancelled, closed} — the double-charge-invisible case (a would-be
    /// result for a payment the merchant was told failed/aborted). Returns nil when the cause is NOT in that set (a
    /// clean `web` verdict or an infra cause needs no reconciliation) OR it was already signaled. Sets
    /// `reconciliationSignaled` so multiple late responses emit it AT MOST ONCE. **Caller holds `lock`; emit the
    /// returned map AFTER releasing.** Hashes the `correlation_id`, never the raw value. Mirrors Kotlin.
    private func reconciliationFieldsIfNeededLocked(_ r: OperationRecord) -> [String: Any]? {
        guard let cause = r.terminal,
              cause == Self.causeTimeout || cause == Self.causeCancelled || cause == Self.causeClosed,
              !r.reconciliationSignaled else { return nil }
        r.reconciliationSignaled = true
        let latencyMs = Int64(max(0, monotonicMs() - r.startedAtMonoMs))
        return [
            "correlation_id_hash": Sha256.hex(r.correlationId),
            "op": Self.opStartPayment,
            "latency_ms": latencyMs,
            "last_known_client_state": cause,
            "severity": "warn",
        ]
    }

    // ============================================================================================================
    // The session-resume protocol. `_resume`/`_ping` are web callbacks: `_`-prefixed, un-versioned, invoked by
    // native via JS eval — NOT catalog ops, never envelopes, never through the dispatcher; zero schema/codegen
    // impact (the contract hash is unaffected). Mirrors the Kotlin twin.
    // ============================================================================================================

    /// First-writer-wins between pong / failure / deadline, per ping round.
    private final class PingRound {
        private let lock = NSLock()
        private var winner: String?
        func claim(_ cause: String) -> Bool {
            lock.lock(); defer { lock.unlock() }
            if winner != nil { return false }
            winner = cause
            return true
        }
    }

    /// The app moved to background (iOS signals are the app-level `didEnterBackground`/`willEnterForeground`
    /// notifications observed by `KhipuPayment` — a modal sheet has no per-VC background notion; Android's twin
    /// uses the SDK-owned Activity's `onStop`/`onStart`). Sets the consumption token REGARDLESS of payment state
    /// (the flag is about the TRANSITION). NO cookie flush on iOS: `WKHTTPCookieStore` persists asynchronously with
    /// no public flush API — backgrounding triggers the OS write-back; Android flushes here.
    func appMovedToBackground() {
        lock.lock()
        backgrounded = true
        lock.unlock()
    }

    /// Foreground after a CONSUMED background transition with an ACTIVE non-terminal payment: eval
    /// `_resume(merchantOperationId)` — EXACTLY once per transition, with the byte-verbatim MERCHANT id (the
    /// web/backend only know the merchant id; `khp_op_` never crosses the bridge) — then, `pingProbeDelayMs` LATER,
    /// probe `_ping()` and arm the `pingTimeoutMs` deadline FROM THAT PROBE, never from round start. First-writer-wins
    /// between pong / failure / deadline: pong → done, zero telemetry; failure → immediate `controlledReload` (a
    /// page that cannot answer NOW is the unrecoverable state, including a legitimately still-loading one:
    /// reloading is safe because the backend recognizes the same operationId); silence → the deadline reloads. No
    /// try/catch mirrors of the Kotlin eval guards: Swift closure types cannot throw (type-system-guaranteed, not a
    /// behavior divergence).
    ///
    /// **Why the single probe is DEFERRED** (ADR-163). `kws.js` judges SPA liveness by heartbeat freshness against
    /// `HEARTBEAT_STALE_MS = 2500`. Coming back from background the SPA's own timers were frozen too, so the beat is
    /// stale even for a HEALTHY page; kws therefore has a GRACE branch that answers `true` and stamps
    /// `lastKwsTick = now`, assuming a wedged SPA "fails the NEXT probe". Native emits only ONE probe per round, so
    /// an immediate probe hit the grace on exactly the return from the bank app and a WEDGED page answered healthy.
    /// The fix is NOT a second probe: merchant apps update slowly, so an old fleet will keep probing immediately and
    /// the grace must be assumed permanent. Deferring the one probe past the grace window means the grace is never
    /// what answers it. **The deadline is armed FROM the probe, not from round start** — at round start it would
    /// leave the probe 500ms of a 2000ms budget and reload slow-but-healthy pages. Mirrors the Kotlin twin.
    ///
    /// **The probe runs on `mainQueue`, NEVER on `timeoutQueue`.** `evalPing` reaches
    /// `WKWebView.callAsyncJavaScript` through the host, whose deliver closure asserts
    /// `dispatchPrecondition(condition: .onQueue(.main))` (`WebView/KhipuWebViewHost.swift`) — firing the probe
    /// from the worker queue would TRAP and take the merchant's app down. Unit tests cannot catch that: the harness
    /// injects a test queue and a fake `evalPing` that never touches WebKit. The deadline stays on `timeoutQueue`.
    /// Side effect: `appMovedToBackground()` is delivered on main too, so the probe's `backgrounded` re-read is
    /// SERIALIZED against it rather than merely best-effort.
    func appReturnedToForeground() {
        var record: OperationRecord?
        lock.lock()
        if !backgrounded { lock.unlock(); return } // no consumed transition: first start / double-foreground
        backgrounded = false // consume the transition — this IS "exactly once"
        if let id = activeOpId, let active = records[id], active.terminal == nil { record = active }
        lock.unlock()
        guard let r = record else { return } // a transition with no live payment needs no protocol
        // Notify the bank-app return detector BEFORE the resume protocol (no-op when the build flag is OFF).
        // OBSERVE + SIGNAL ONLY: the _resume/_ping/controlledReload re-check below runs UNCHANGED whether or not
        // this is a bank return. Hashed NATIVE id only. No try/catch mirror of the Kotlin guard: Swift's
        // `(String) -> Void` cannot throw.
        onBankAppReturn(Sha256.hex(r.nativeOpId))
        evalResume(r.merchantOperationId) // fire-and-forget; the web side of the resume protocol is khenshin-web's
        // Round supersession: arming a new round cancels the prior round's DEFERRED PROBE and its deadline AND
        // invalidates its late reload-bound callbacks. The seq bump is what makes a superseded probe inert; the
        // cancel is hygiene (see `pingProbeItem`). Same at the three other supersession sites.
        lock.lock()
        pingProbeItem?.cancel()
        pingDeadlineItem?.cancel()
        pingRoundSeq += 1
        let mySeq = pingRoundSeq
        lock.unlock()
        let round = PingRound() // first-writer-wins WITHIN the round: pong / fail / deadline
        // A reload-bound claim must be atomic with the round-vigency check (under `lock`) — fail/deadline from
        // a superseded round no-op; the pong path needs no guard (cancelling a dead deadline is harmless).
        let claimRound: (String) -> Bool = { [weak self] cause in
            guard let self = self else { return false }
            self.lock.lock(); defer { self.lock.unlock() }
            return self.pingRoundSeq == mySeq && round.claim(cause)
        }
        let probe = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            // Re-read the round token under `lock` before evaluating anything: the round may have been superseded,
            // or the app may have LEFT AGAIN during the delay. Abort WITHOUT claiming the round and WITHOUT
            // telemetry — a later return arms a fresh round. NOT optional: a suspended WKWebView may never complete
            // the `evaluateJavaScript`/`callAsyncJavaScript` callback, so the deadline would win by default and we
            // would drive `controlledReload` — a page load + request re-delivery — with the app in the BACKGROUND
            // (ADR-163).
            self.lock.lock()
            let vigent = self.pingRoundSeq == mySeq && !self.backgrounded
            self.lock.unlock()
            guard vigent else { return }
            let deadline = DispatchWorkItem { [weak self] in
                guard let self = self else { return }
                // Pass the CLAIMED round seq into the reload so reStampForReload can re-check it under `lock`:
                // claimRound validated mySeq then RELEASED `lock`, and a bumper can supersede the round in the gap
                // before the re-stamp re-acquires it (claim-then-recheck). Mirrors Kotlin.
                if claimRound(Self.reasonPingTimeout) { self.controlledReload(r, reason: Self.reasonPingTimeout, claimedRoundSeq: mySeq) }
            }
            self.lock.lock()
            if self.pingRoundSeq == mySeq { self.pingDeadlineItem = deadline } else { deadline.cancel() }
            self.lock.unlock()
            // Armed HERE — at the probe, not at round start (see the deferral note above): the page gets the full
            // `pingTimeoutMs` to answer THIS probe.
            self.timeoutQueue.asyncAfter(deadline: .now() + .milliseconds(khipuClampTimeoutMs(self.pingTimeoutMs, max: Self.internalBackstopCeilingMs, fallback: 2_000)), execute: deadline)
            self.evalPing { [weak self] pong, reason in
                guard let self = self else { return }
                if pong {
                    if round.claim(Self.pongWinner) { deadline.cancel() } // healthy: done, zero telemetry
                } else {
                    // Map the gate reason into the frozen reason enum: page_not_ready stays granular; every other
                    // immediate failure (stale page, dead WebView, eval error, no pong) collapses to ping_failed.
                    let mapped = reason == Self.reasonPageNotReady ? Self.reasonPageNotReady : Self.reasonPingFailed
                    if claimRound(mapped) {
                        deadline.cancel()
                        self.controlledReload(r, reason: mapped, claimedRoundSeq: mySeq) // carry the claimed seq for the re-check
                    }
                }
            }
        }
        // Register the probe as round state BEFORE scheduling it (the deadline's arm pattern), so the four
        // supersession sites can cancel it; a round already superseded in this gap cancels it right here.
        lock.lock()
        if pingRoundSeq == mySeq { pingProbeItem = probe } else { probe.cancel() }
        lock.unlock()
        // `mainQueue`, NEVER `timeoutQueue` — the host's deliver closure has a main-queue dispatchPrecondition and
        // would TRAP off-main (see the doc comment). This is the whole reason the probe is a `mainQueue` work item.
        mainQueue.asyncAfter(deadline: .now() + .milliseconds(khipuClampTimeoutMs(pingProbeDelayMs, max: Self.internalBackstopCeilingMs, fallback: 1_500)), execute: probe)
    }

    /// The controlled reload: SAME record, same `khp_op_`, same merchant id (the backend recognizes a
    /// paid/in-progress operationId, so reopening it is idempotent), same callback/latch/single-flight slot, same UI
    /// (present NOT re-invoked — the sheet is already up). Under `lock`: re-stamp a FRESH `correlation_id` +
    /// `session_id` and fix `byCorrelation` (old mapping REMOVED → an old-page response becomes
    /// `bridge.orphan_response {reason:"unknown"}`). Emit `lifecycle.unrecoverable_resume` AFTER release. The
    /// `paymentTimeoutMs` timer is NOT re-armed — ONE budget per `start()`; a reload does not extend the payment.
    private func controlledReload(_ r: OperationRecord, reason: String, claimedRoundSeq: UInt64) {
        // TEST SEAM (no-op in production): the deterministic interleaving point for the claim→re-stamp window.
        // claimRound has WON and released `lock`; reStampForReload below re-acquires it. A real cross-thread bumper
        // (double-return / render-gone / restart) can take `lock` in this exact gap — an interleaving the test
        // schedulers cannot otherwise reproduce. See `onReloadClaimWindowForTest`. Mirrors Kotlin.
        onReloadClaimWindowForTest()
        guard let operationIdHash = reStampForReload(r, claimedRoundSeq: claimedRoundSeq) else { return }
        // Emit after release. Hashed NATIVE id only — the merchant id is PII.
        telemetry.emit(
            event: TelemetryEvent.unrecoverableResume,
            fields: ["operation_id_hash": operationIdHash, "reason": reason, "severity": "warn"]
        )
        performReloadOnMain(r)
    }

    /// Re-stamp a FRESH `correlation_id` + `session_id` on the SAME record under `lock` and fix `byCorrelation` (old
    /// mapping REMOVED → an old-page response becomes `bridge.orphan_response {reason:"unknown"}`). Returns the
    /// hashed NATIVE id for the caller's emit-after-release, or nil if a racing terminal already absorbed the payment
    /// (no reload to perform). Every origin carries a loadable URL, so there is no per-origin guard. **Shared
    /// VERBATIM** by the `_ping` path (`controlledReload` → `lifecycle.unrecoverable_resume`), the render-gone
    /// recovery (`webViewRenderGone` → `lifecycle.render_process_gone`) and `restartRequested`: the events have
    /// disjoint field sets, so the mechanics are factored out instead of emitting from here, and there is NO second
    /// reload path. Mirrors Kotlin.
    private func reStampForReload(_ r: OperationRecord, claimedRoundSeq: UInt64? = nil) -> String? {
        lock.lock(); defer { lock.unlock() }
        if r.terminal != nil { return nil } // a racing terminal absorbed the payment (latch discipline)
        // Claim-then-recheck. A CLAIMED `_ping` reload (controlledReload passes the claimed seq) must ABORT if a
        // bumper (double-return foreground / render-gone / restart / close) superseded the round between
        // claimRound's `lock`-release and HERE — the claim-site seq guard does NOT cover this re-acquire gap. Without
        // it a stale claimed deadline re-stamps OVER the bumper's re-stamp, queues a SECOND reload and emits a
        // forensically-false `lifecycle.unrecoverable_resume`. The render-gone/restart bumpers pass nil (they bumped
        // the seq themselves — nothing to re-check). Mirrors Kotlin.
        if let claimed = claimedRoundSeq, claimed != pingRoundSeq { return nil }
        byCorrelation.removeValue(forKey: r.correlationId) // the old page's response is now an orphan (pinned by test)
        r.correlationId = correlationId()
        r.sessionId = sessionId()
        byCorrelation[r.correlationId] = r.nativeOpId
        return Sha256.hex(r.nativeOpId) // collect under the lock for the caller's deferred-telemetry emit
    }

    /// Re-deliver the request on a fresh page with the existing machinery UNCHANGED: loadPage = epoch bump +
    /// resetSession (host.load), deliverRequest = readiness-queued until the fresh page mounts; present NOT
    /// re-invoked; the timeout item is not touched here. No try/catch mirror of the Kotlin reload block: these
    /// closures cannot throw. Mirrors Kotlin.
    private func performReloadOnMain(_ r: OperationRecord) {
        let url = origin.url
        mainQueue.async {
            // Re-check the latch on the main hop: a terminal winning between the locked re-stamp and this block
            // must not see a post-terminal page load + re-delivered request (the latch absorbs the accounting
            // either way; this closes the observable window). Mirrors Kotlin.
            self.lock.lock()
            let alreadyTerminal = r.terminal != nil
            self.lock.unlock()
            if alreadyTerminal { return }
            self.loadPage(url)
            self.deliverRequest(self.buildStartRequest(r)) // snapshots the record's CURRENT (re-stamped) ids
        }
    }

    /// The WebView's RENDER process died (`webViewWebContentProcessDidTerminate`; Android's twin is
    /// `onRenderProcessGone`). Event-driven complement to the transition-driven `_ping`: the renderer can die at
    /// ANY instant, including in the background where `_ping` never runs. Render-process ≠ app-process: when the APP
    /// process dies the coordinator/latch/callback are GONE and nothing can honestly be restored; here the renderer
    /// CHILD died while they LIVE, so recovery is honest, not fabrication (`WKHTTPCookieStore` survives a
    /// render-gone — see the host's cookie note).
    ///
    /// With an ACTIVE non-terminal payment, RECOVER in place: `recoverWebView` reloads the reusable WKWebView (iOS
    /// does NOT re-create; the content process re-spawns on the next load), then reuse the reload mechanics
    /// VERBATIM (`reStampForReload` + `performReloadOnMain`). Recovery impossible (the seam returns false — a nil
    /// host) → fail closed (INTERNAL_ERROR through the ONE `finish`; the merchant can reopen with the same
    /// operationId). No active payment → telemetry only, never a fabricated terminal. No try/catch mirror of the
    /// Kotlin guards: `recoverWebView` is `() -> Bool` (type-guaranteed non-throwing); iOS does NOT crash the app on
    /// content-process death (the WebView blanks), so there is no return-true floor to protect — the handler exists
    /// for PARITY recovery. The fail-closed path uses `claimTerminal` + `finish` (Swift has no `failClosed`
    /// helper). No `reasonRenderProcessGone` constant: render-gone emits its OWN event (no `reason` field), not
    /// `unrecoverable_resume`, so a reload reason would be dead code.
    func webViewRenderGone(didCrash: Bool) {
        lock.lock()
        // Supersede any in-flight _ping round. A render-gone REPLACES the page, so a ping deadline ALREADY ARMED
        // (silent page) must NOT fire a second controlledReload on the page this recovery just reloaded. Mirror
        // appReturnedToForeground: cancel the probe and the armed deadline, and bump the round nonce so any late
        // reload-bound callback no-ops via claimRound.
        pingProbeItem?.cancel()
        pingDeadlineItem?.cancel()
        pingRoundSeq += 1
        let active: OperationRecord?
        if let id = activeOpId, let r = records[id], r.terminal == nil { active = r } else { active = nil }
        lock.unlock()
        // Recover the HOST regardless of payment state, so the instance stays reusable for the next start(). A
        // render-gone between payments must NOT strand the responder's renderDead guard — else the next start()
        // degrades every delivery to webview_unavailable, the web never gets startPayment_v1, and the payment hangs
        // for the whole budget (the tested sequential-start invariant). iOS clears the guard (the WKWebView is
        // reusable); Android re-creates the defunct WebView. Mirrors Kotlin.
        let hostRecovered = recoverWebView()
        guard let r = active else {
            // Nothing active to recover or fail — the host is sane again for the next start(). Telemetry only, no
            // operation_id_hash (no payment to attribute).
            emitRenderProcessGone(operationIdHash: nil, didCrash: didCrash, recovered: false)
            return
        }
        if !hostRecovered {
            // Recovery impossible (a nil host) → fail closed with INTERNAL_ERROR through the ONE finish().
            emitRenderProcessGone(operationIdHash: Sha256.hex(r.nativeOpId), didCrash: didCrash, recovered: false)
            guard let claimed = claimTerminal(r.nativeOpId, cause: Self.causeRenderGone) else { return }
            let latencyMs = Int64(max(0, monotonicMs() - claimed.startedAtMonoMs))
            let error = publicError(.INTERNAL_ERROR, debugId: debugId.generate())
            finish(claimed, .failure(error), latencyMs: latencyMs, errorForRecorder: error)
            return
        }
        // Live again — re-stamp + reload (NO second reload path). A nil re-stamp means a racing terminal absorbed
        // the payment between the active-check and the re-stamp: the latch already owns the outcome — do NOT fail
        // closed; recovered=false (no reload was performed). Hashed NATIVE id only.
        let operationIdHash = reStampForReload(r)
        emitRenderProcessGone(operationIdHash: Sha256.hex(r.nativeOpId), didCrash: didCrash, recovered: operationIdHash != nil)
        if operationIdHash != nil { performReloadOnMain(r) }
    }

    /// Emit `lifecycle.render_process_gone` (the hash was collected before this call — collect-under-lock,
    /// emit-after-release). `operation_id_hash` is present ONLY when an active payment existed. Hashed NATIVE id
    /// only, never the merchant id. `severity:"error"`: an unhandled render-gone crashes the merchant app, strictly
    /// more severe than a backgrounding. Mirrors Kotlin.
    private func emitRenderProcessGone(operationIdHash: String?, didCrash: Bool, recovered: Bool) {
        var fields: [String: Any] = ["did_crash": didCrash, "recovered": recovered, "severity": "error"]
        if let hash = operationIdHash { fields["operation_id_hash"] = hash }
        telemetry.emit(event: TelemetryEvent.renderProcessGone, fields: fields)
    }

    /// Is this harness origin one that can NEVER become a `khipuBridge` page? That is `about:blank` — what
    /// `KhipuPayment.init(test:)` resolves `.harness` to when the app bundles no `harness.html`. Pure + static so a
    /// unit test bites on the REAL predicate. Android has NO twin: its origin is always the `file://` constant, and
    /// a missing asset surfaces as a real main-frame navigation failure — the deliberate detection divergence.
    static func isUnloadableOrigin(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "about"
    }

    /// The host detected an unloadable REAL page origin (a main-frame `didFailProvisionalNavigation`/`didFail` —
    /// host unreachable / file unreadable). Fail the ACTIVE payment FAST with a typed `KhipuPaymentError` through
    /// the ONE `finish()` instead of a blank sheet for the full `paymentTimeoutMs` budget followed by a misleading
    /// `PAYMENT_TIMEOUT`. The public code follows the origin; see `loadFailed`. Idempotent via the terminal latch (a
    /// load failure racing a real terminal loses cleanly); no active non-terminal payment → safe no-op. The
    /// about:blank/missing-bundle case is caught synchronously in `start()` (see `isUnloadableOrigin`); this seam is
    /// the ASYNC twin of Android's `onReceivedError` → `webViewLoadFailed` (the deliberate detection divergence).
    /// Mirrors Kotlin's `webViewLoadFailed`.
    func webViewLoadFailed() {
        lock.lock()
        let active: OperationRecord?
        if let id = activeOpId, let r = records[id], r.terminal == nil { active = r } else { active = nil }
        lock.unlock()
        guard let r = active else { return } // no active non-terminal payment: safe no-op
        loadFailed(r.nativeOpId)
    }

    /// The unloadable-origin terminal: resolve through the ONE `finish()` with a public code that follows the
    /// `origin` — NETWORK_UNAVAILABLE for an https origin (`.production`/`.staging`), INVALID_CONFIGURATION for the
    /// bundled `.harness` — and its OWN cause (`causeLoadFailed`) for forensics on every origin. The latch absorbs it
    /// if a racing terminal already won (the `gateBlocked`/`presentFailedRequested` shape). Mirrors Kotlin's
    /// `loadFailed`.
    private func loadFailed(_ nativeOpId: String) {
        guard let r = claimTerminal(nativeOpId, cause: Self.causeLoadFailed) else { return }
        let latencyMs = Int64(max(0, monotonicMs() - r.startedAtMonoMs))
        // An https page that will not load is the payer's network (NETWORK_UNAVAILABLE); an unloadable harness is a
        // misconfigured integration (INVALID_CONFIGURATION). The cause stays load_failed.
        let code: KhipuPublicErrorCode
        if case .harness = origin { code = .INVALID_CONFIGURATION } else { code = .NETWORK_UNAVAILABLE }
        let error = publicError(code, debugId: debugId.generate())
        finish(r, .failure(error), latencyMs: latencyMs, errorForRecorder: error)
    }

    /// The verify-before-execute intercept BLOCKED the bundle load: the loaded `/v1/kws.js`'s embedded
    /// `//# khipu-sig:v1:` signature did not validate (tampered / wrong key / no marker), or the bundle endpoint was
    /// unavailable. The host's intercept (`BundleVerificationInterceptor`, which holds the bytes and the telemetry
    /// sink) already emitted the `security.bundle_*` diagnostic; the coordinator resolves the ACTIVE payment to
    /// NETWORK_UNAVAILABLE through the ONE `finish()`. Security invariant (AC-SEC-002/004, ADR-003): a failed
    /// verification BLOCKS the payment — never fall back to a last-known-good bundle, never leave the UI hanging.
    /// Idempotent via the terminal latch; no active non-terminal payment → safe no-op. Same public code as the gate
    /// block, its own forensic cause `causeBundleUnverified`. Mirrors Kotlin's `bundleVerificationFailed`.
    func bundleVerificationFailed() {
        lock.lock()
        let active: OperationRecord?
        if let id = activeOpId, let r = records[id], r.terminal == nil { active = r } else { active = nil }
        lock.unlock()
        guard let r = active else { return } // no active non-terminal payment: safe no-op
        guard let claimed = claimTerminal(r.nativeOpId, cause: Self.causeBundleUnverified) else { return }
        let latencyMs = Int64(max(0, monotonicMs() - claimed.startedAtMonoMs))
        let error = publicError(.NETWORK_UNAVAILABLE, debugId: debugId.generate())
        finish(claimed, .failure(error), latencyMs: latencyMs, errorForRecorder: error)
    }

    /// The active payment's page reached readiness without a bundle verified for that load (the responder withheld
    /// the request — ADR-221). NETWORK_UNAVAILABLE via `gateBlocked`, cause `causeGateBlockedBundle`. No active
    /// payment → no-op; latch absorbs races. Twin of Kotlin's `bundleUnverifiedAtReadiness`.
    func bundleUnverifiedAtReadiness() {
        lock.lock()
        let active: OperationRecord?
        if let id = activeOpId, let r = records[id], r.terminal == nil { active = r } else { active = nil }
        lock.unlock()
        guard let r = active else { return }
        gateBlocked(r.nativeOpId, cause: Self.causeGateBlockedBundle)
    }

    /// SYSTEM-INITIATED teardown of the payment sheet. There is NO native user-facing escape, so the ONLY caller is
    /// the OS-driven teardown guard (iOS `sheetDidDisappear`; Android `onDestroy`'s
    /// `isFinishing && !closedByCoordinator` on the twin) — the sheet is full-screen / `isModalInPresentation`, so
    /// swipe-to-dismiss is gone, and Android back is a no-op. Resolves PAYMENT_ABORTED after teardown completes
    /// (fault `integrator`: a non-attributable OS/programmatic close, never the payer; a user cancel is a WEB
    /// `error` verdict carrying `failure_reason == .USER_CANCELED`). The internal forensic cause stays `cancelled`,
    /// distinct from close()'s `closed`. Already-terminal operations are absorbed (the public `close()` shares this
    /// ONE latch path — `closeRequested`). The callback can NEVER be left hanging by a teardown.
    func systemTeardownRequested(nativeOpId: String) {
        guard let r = claimTerminal(nativeOpId, cause: Self.causeCancelled) else { return }
        let latencyMs = Int64(max(0, monotonicMs() - r.startedAtMonoMs))
        let error = publicError(.PAYMENT_ABORTED, debugId: debugId.generate())
        finish(r, .failure(error), latencyMs: latencyMs, errorForRecorder: error)
    }

    // ============================================================================================================
    // The public control surface. close() and restart() are pure native surface: NO web callback (khipu-web's own
    // close/restart drive its DOM modal; natively the SDK sheet IS the modal, and the backend timeout drives the
    // web to its own terminal). NO telemetry, NO schema/contract change. Mirrors the Kotlin twin.
    // ============================================================================================================

    /// Programmatic close (`KhipuPayment.close()` delegates here). A TERMINAL on the existing latch, NOT an
    /// instance teardown: claims `causeClosed`, then the ONE `finish` delivers PAYMENT_ABORTED (fault `integrator`,
    /// the same public code as system teardown) with a distinct internal cause (`closed`) for forensics. Idempotent
    /// via the latch (N calls / every race → one winner, one emission); no active payment → silent no-op; the
    /// instance stays REUSABLE — a later `start()` is legal. Returns immediately (delivery is always the posted
    /// main-queue hop); the result arrives teardown-then-deliver as `.interrupted(PAYMENT_ABORTED)`. Supersedes any
    /// armed `_ping` round. Mirrors Kotlin.
    func closeRequested() {
        lock.lock()
        let active = activeOpId.flatMap { records[$0] }
        // Supersede any in-flight _ping round: it is moot once the payment is being closed — a stale deadline must
        // not fire a reload-bound callback. ONLY when there is a payment to close: a no-op close must not perturb
        // round accounting.
        if active != nil {
            pingProbeItem?.cancel()
            pingDeadlineItem?.cancel()
            pingRoundSeq += 1
        }
        lock.unlock()
        guard let r = active else { return } // no active payment: safe no-op
        guard let claimed = claimTerminal(r.nativeOpId, cause: Self.causeClosed) else { return } // latch absorbs
        let latencyMs = Int64(max(0, monotonicMs() - claimed.startedAtMonoMs))
        let error = publicError(.PAYMENT_ABORTED, debugId: debugId.generate())
        finish(claimed, .failure(error), latencyMs: latencyMs, errorForRecorder: error)
    }

    /// Programmatic restart (`KhipuPayment.restart()` delegates here). The web-visible effect is "close() + a new
    /// start() with the same operationId"; the native realization is the controlled-reload mechanics on the ACTIVE
    /// payment with NO intermediate terminal — a literal close-then-start would deliver PAYMENT_ABORTED AND leave the
    /// second leg callback-less, breaking exactly-once. SAME record/`khp_op_`/merchant id/callback/options verbatim,
    /// FRESH correlation+session (`reStampForReload`), `present` NOT re-invoked (`performReloadOnMain`). The schema
    /// timer IS re-armed — the ONE deliberate divergence from "one budget per start()": that invariant governs
    /// AUTOMATIC recovery, while a public restart() is a deliberate merchant action and gets a fresh budget.
    /// Supersedes any armed `_ping` round. No active non-terminal payment → safe no-op. NO telemetry: a merchant
    /// action is not a degradation. Mirrors Kotlin.
    func restartRequested() {
        lock.lock()
        let active: OperationRecord?
        if let id = activeOpId, let r = records[id], r.terminal == nil { active = r } else { active = nil }
        // Supersede the _ping round under the same lock as the active lookup, and ONLY when there is an active
        // non-terminal payment to restart: a no-op restart must not perturb round accounting.
        if active != nil {
            pingProbeItem?.cancel()
            pingDeadlineItem?.cancel()
            pingRoundSeq += 1
        }
        lock.unlock()
        guard let r = active else { return } // no active non-terminal payment: safe no-op
        // A nil re-stamp = a racing terminal absorbed the payment (the latch owns the outcome): no reload to
        // perform, no-op.
        guard reStampForReload(r) != nil else { return }
        // Re-arm the schema timer: cancel the old budget, arm a fresh one (the start() arm pattern, including the
        // post-arm race close) — the deliberate divergence from "one budget per start()". The cancel + handle-swap
        // run UNDER `lock` (as in the Kotlin twin) so concurrent restarts cannot orphan a live timer that fires
        // expire() on a stale budget. startedAtMonoMs is deliberately NOT re-stamped: recorder latency measures the
        // whole attempt from the merchant's original start(), so a post-restart PAYMENT_TIMEOUT can report
        // latency > paymentTimeoutMs (accepted: rare manual action, forensic-only impact).
        let timeoutItem = DispatchWorkItem { [weak self] in self?.expire(r.nativeOpId) }
        lock.lock()
        r.timeoutItem?.cancel()
        r.timeoutItem = timeoutItem
        let alreadyTerminal = r.terminal != nil
        lock.unlock()
        timeoutQueue.asyncAfter(deadline: .now() + .milliseconds(khipuClampTimeoutMs(paymentTimeoutMs, budget: ContractConstants.startPaymentV1Timeout)), execute: timeoutItem)
        if alreadyTerminal { timeoutItem.cancel() } // post-arm race close
        performReloadOnMain(r) // re-load + re-deliver on main; the main-hop latch re-check stands
    }

    /// The origin gate blocked a page (reached from `bundleUnverifiedAtReadiness`): a REAL terminal — the record IS
    /// registered and the recorder IS fed (unlike the single-flight rejection, which feeds nothing), because a
    /// gate-block is a payment-path failure the merchant must see in `dumpDiagnostics()` `recent_errors` ("why does
    /// production say network unavailable?"). Resolves through the ONE terminal path — `finish()` owns the recorder
    /// feed, single-flight release, timeout cancel and callback release, and closes the sheet the start() block
    /// presented (teardown-then-deliver). Maps to NETWORK_UNAVAILABLE; no new telemetry name. The CAUSE
    /// (`causeGateBlockedBundle`) is internal forensics only, never the public code. Mirrors Kotlin.
    private func gateBlocked(_ nativeOpId: String, cause: String) {
        guard let r = claimTerminal(nativeOpId, cause: cause) else { return }
        let latencyMs = Int64(max(0, monotonicMs() - r.startedAtMonoMs))
        let error = publicError(.NETWORK_UNAVAILABLE, debugId: debugId.generate())
        finish(r, .failure(error), latencyMs: latencyMs, errorForRecorder: error)
    }

    /// The armed schema timeout fired: translate envelope TIMEOUT → PAYMENT_TIMEOUT via the generated table.
    private func expire(_ nativeOpId: String) {
        guard let r = claimTerminal(nativeOpId, cause: Self.causeTimeout) else { return }
        let latencyMs = Int64(max(0, monotonicMs() - r.startedAtMonoMs))
        // The locale rides the translator seam here too, so the timeout error localizes and miss-emits exactly like
        // an envelope error.
        let error = translator.translateError(envelopeCode: "TIMEOUT", locale: r.locale).error // PublicErrorTranslator-shaped
        finish(r, .failure(error), latencyMs: latencyMs, errorForRecorder: error)
    }

    /// Claim the terminal latch for `nativeOpId` under the lock (first-writer-wins, absorbing). Returns the record
    /// iff THIS caller won; an unknown id or an already-terminal record returns nil.
    private func claimTerminal(_ nativeOpId: String, cause: String) -> OperationRecord? {
        lock.lock(); defer { lock.unlock() }
        guard let r = records[nativeOpId], r.terminal == nil else { return nil }
        r.terminal = cause
        return r
    }

    /// The host whose cookies belong to this payment, or `nil` when there is nothing to scope a clear to. Each https
    /// origin reports the host it loads from (the same `KhipuSigningKeys` constant its URL is built from); the
    /// harness clears nothing — a `file://` page has NO cookie domain, and nothing is cleared rather than
    /// everything. Mirrors Kotlin.
    private func paymentCookieHost() -> String? {
        switch origin {
        case .production: return KhipuSigningKeys.prodHost
        case .staging: return KhipuSigningKeys.stagingHost
        case .harness: return nil
        }
    }

    /// One terminal path for every cause (the caller already WON the latch). Cancels the racing timers, releases
    /// the single-flight slot (the terminal record is RETAINED for the orphan guard, bounded by cap+TTL), feeds the
    /// recorder LIVE outside the lock, and closes the presentation BEFORE delivering on main
    /// (teardown-then-deliver).
    ///
    /// **S2S is the accounting source of truth.** This single `KhipuPaymentOutcome` callback is BEST-EFFORT UX, not
    /// the ledger: a `.completed` carries the web verdict and every other path is an honest `.interrupted` (never a
    /// fabricated payment result). The merchant's accounting MUST follow the authoritative S2S confirmation
    /// regardless of what — or whether — this callback delivered (a payer who closed the sheet before the web
    /// resolved is SURFACED via `onOrphanedPaymentDetected`). This SDK never reconciles server-side state.
    private func finish(
        _ r: OperationRecord,
        _ outcome: Result<KhipuPaymentResult, KhipuPaymentError>,
        latencyMs: Int64,
        errorForRecorder: KhipuPaymentError?
    ) {
        lock.lock()
        r.timeoutItem?.cancel()
        r.presentConfirmItem?.cancel() // a terminal absorbs the confirm deadline
        r.terminalAtMonoMs = monotonicMs()
        if activeOpId == r.nativeOpId { activeOpId = nil }
        let orphanToPersist = orphanToPersistLocked(r, errorForRecorder: errorForRecorder)
        lock.unlock()
        if let error = errorForRecorder {
            recorder.recordError(op: Self.opStartPayment, correlationId: r.correlationId, error: error, latencyMs: latencyMs)
        } else {
            recorder.recordLatency(op: Self.opStartPayment, ms: latencyMs)
        }
        // Persist the orphan record OUTSIDE the lock (best-effort, fail-soft — the store owns its own lock and
        // swallows storage errors). A timeout/cancelled/closed terminal of a LIVE payment may have an unknown
        // server-side outcome → surfaced via onOrphanedPaymentDetected on a later launch.
        if let orphan = orphanToPersist {
            orphanStore.put(operationId: orphan.operationId, debugId: orphan.debugId, lastKnownState: orphan.lastKnownState)
        }
        // The selective cookie clear lives HERE because finish() is the ONE terminal path, so the payment's cookies
        // are dropped exactly once per operation, whatever ended it; scoped to the payment host, never blanket (see
        // `clearCookiesForHost`). Cookie PERSISTENCE is unaffected: it serves the BACKGROUND round trip of a live
        // payment, and this runs after the payment ended. Mirrors Kotlin.
        if let cookieHost = paymentCookieHost() {
            clearCookiesForHost(cookieHost)
        }
        // Map the internal `Result` currency to the public `KhipuPaymentOutcome` at the ONE delivery boundary:
        // .success(verdict) → .completed (the web HAD its say, including a USER_CANCELED error verdict); every
        // .failure(error) → .interrupted (an SDK termination before any web verdict). A pure transform.
        let deliverable: KhipuPaymentOutcome
        switch outcome {
        case .success(let result): deliverable = .completed(result)
        case .failure(let error): deliverable = .interrupted(error)
        }
        // The whole close-then-deliver sequence runs on main: presenter.close touches the sheet, and the dismiss
        // completion keeps the callback on main. Strong self capture — a [weak self] here would evaporate the
        // delivery.
        mainQueue.async {
            self.presenter.close(nativeOpId: r.nativeOpId) {
                // Deliver once, then release the closure: the RETAINED terminal record must not pin the merchant UI
                // graph the callback captured. The latch guarantees one finish.
                let callback = r.onResult
                r.onResult = nil
                callback?(deliverable)
            }
        }
    }

    /// The orphan record to persist for THIS terminal, or nil. Persist iff the payment had become LIVE
    /// (present-confirmed — the UI appeared, so a server-side payment may exist) AND terminated toward the merchant
    /// with a payer-in-limbo cause {timeout, cancelled, closed}. A clean web verdict (causeWeb — the merchant has the
    /// real outcome) and every pre-payment/infra failure (load_failed / bundle_unverified / gate_* / present_failed /
    /// present_timeout) are EXCLUDED: no server-side payment could have been authorized. The debug_id is the SAME
    /// one the terminal `KhipuPaymentError` carries (the id the merchant can correlate). Caller holds `lock`.
    /// Mirrors Kotlin.
    private func orphanToPersistLocked(
        _ r: OperationRecord, errorForRecorder: KhipuPaymentError?
    ) -> (operationId: String, debugId: String, lastKnownState: String)? {
        guard r.presentConfirmed,
              let cause = r.terminal,
              cause == Self.causeTimeout || cause == Self.causeCancelled || cause == Self.causeClosed,
              let dbg = errorForRecorder?.debugId else { return nil }
        return (r.merchantOperationId, dbg, cause)
    }

    /// Register the opt-in orphan listener. **Registering it DRAINS any persisted orphan records** (they survive a
    /// process restart via the store — the in-memory `records` map is fresh per process) and delivers each via
    /// `listener` on the MAIN queue; the records are then removed (surface-then-remove: never re-fired on a later
    /// launch). No listener registered → records persist until the 30-day purge. The event is **ADVISORY ONLY**:
    /// the merchant MUST consult its own backend; the SDK never resolves the payment from this event and never
    /// overrides the authoritative S2S outcome. Mirrors Kotlin.
    func onOrphanedPaymentDetected(_ listener: @escaping (_ operationId: String, _ debugId: String) -> Void) {
        let drained = orphanStore.drainAll() // purges expired + returns the live records + removes them
        guard !drained.isEmpty else { return }
        // The listener closure is non-throwing, so a misbehaving merchant listener cannot throw mid-loop (only an
        // uncatchable trap could) — there is no per-record isolation analogue to Kotlin's `runCatching` to add here.
        // Documented language-justified divergence.
        mainQueue.async { for record in drained { listener(record.operationId, record.debugId) } }
    }

    /// Decode the envelope outcome fail-closed: `ok` → generated `StartPaymentResponse` (all four typed results
    /// resolve the callback as SUCCESS values — envelope-level `error`/`timeout` is the failure channel). `locale`
    /// is the record's resolved locale and rides ONLY the translator seam (which owns the `i18n.missing_translation`
    /// emission); the direct fail-closed publicError() calls below keep the es-CL default, so no translation miss
    /// goes unobserved outside the seam. Threading the locale to them is a known gap (dw:370). Mirrors Kotlin.
    private func decodeOutcome(
        _ env: [String: Any], locale: String?
    ) -> (result: Result<KhipuPaymentResult, KhipuPaymentError>, errorForRecorder: KhipuPaymentError?) {
        let envelopeResult = (env["result"] as? String).flatMap { EnvelopeResult(rawValue: $0) }
        switch envelopeResult {
        case .ok:
            if let payload = env["payload"] as? [String: Any],
               let data = try? JSONSerialization.data(withJSONObject: payload),
               let decoded = try? JSONDecoder().decode(StartPaymentResponse.self, from: data) {
                return (.success(decoded.result), nil)
            }
            // result:"ok" with an undecodable payload: fail closed, never crash, never hang.
            let error = publicError(.INTERNAL_ERROR, debugId: debugId.generate())
            return (.failure(error), error)
        case .error, .timeout:
            let errorObj = env["error"] as? [String: Any]
            let code = (errorObj?["code"] as? String)
                ?? (envelopeResult == .timeout ? "TIMEOUT" : "INTERNAL_ERROR")
            // SESSION_RESET disposition: the generated translation table is FROZEN and maps only
            // INTERNAL_ERROR/TIMEOUT/UNSUPPORTED_OP — SESSION_RESET deliberately is NOT in it (it flows
            // dispatcher→web, never web→native). If one ever arrives here anyway, the generated fallback IS the
            // design: INTERNAL_ERROR + untranslated=true + bridge.untranslated_error (emitted by the translator).
            // Pinned by test; do NOT touch the generated table.
            let translation = translator.translateError(envelopeCode: code, locale: locale)
            return (.failure(translation.error), translation.error)
        default:
            // Missing/undecodable envelope result: fail closed (never crash, never hang).
            let error = publicError(.INTERNAL_ERROR, debugId: debugId.generate())
            return (.failure(error), error)
        }
    }

    /// Build the outbound `startPayment_v1` REQUEST envelope from GENERATED types.
    private func buildStartRequest(_ r: OperationRecord) -> String {
        // Snapshot the pair ATOMICALLY under `lock`: a re-stamp concurrent with this read could yield a
        // mixed-generation envelope (old correlation + new session → orphan/mismatch → no response ever matches →
        // a silent hang until the payment budget expires); the locked read also orders it against the re-stamp
        // (Kotlin uses @Volatile, which has no Swift equivalent). Mirrors Kotlin.
        lock.lock()
        let cid = r.correlationId
        let sid = r.sessionId
        lock.unlock()
        // The merchant operationId byte-verbatim, plus the record's IMMUTABLE resolved options — theme always
        // (resolved, never "auto"), skip_exit_page/skip_exit_success_page (TOP-LEVEL on the request, not inside
        // `style`), style/web_options only when set (nil optionals are OMITTED by the synthesized Codable encode —
        // never null, the frozen envelope rule). A reload re-enters here with the SAME record → same values
        // verbatim.
        let payloadData = (try? JSONEncoder().encode(StartPaymentRequest(
            operationId: r.merchantOperationId,
            skipExitPage: r.skipExitPage,
            skipExitSuccessPage: r.skipExitSuccessPage,
            style: r.style,
            theme: r.resolvedTheme,
            webOptions: r.webOptions.isEmpty ? nil : r.webOptions
        ))) ?? Data("{}".utf8)
        let payload = ((try? JSONSerialization.jsonObject(with: payloadData)) as? [String: Any]) ?? [:]
        let envelope: [String: Any] = [
            // envelope.json `Request` requires envelope_version; == contract_version for v1.
            "envelope_version": Diagnostics.contractVersion,
            "message_type": MessageType.request.rawValue,
            "session_id": sid,
            "op": Self.opStartPayment,
            "correlation_id": cid,
            "payload": payload,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: envelope),
              let json = String(data: data, encoding: .utf8) else { return "{}" }
        return json
    }

    /// Purge-on-insert for RETAINED terminal records (cap + TTL bounded growth, the dispatcher's recentMeta
    /// discipline). Caller holds `lock`. ACTIVE records are never purged.
    private func purgeTerminalRecordsLocked() {
        let now = monotonicMs()
        let expired = recordOrder.filter { id in
            guard let r = records[id] else { return true }
            return r.terminal != nil && now - r.terminalAtMonoMs >= terminalRecordTtlMs
        }
        for id in expired { removeRecordLocked(id) }
        while recordOrder.filter({ records[$0]?.terminal != nil }).count > terminalRecordCap {
            guard let eldest = recordOrder.first(where: { records[$0]?.terminal != nil }) else { break }
            removeRecordLocked(eldest)
        }
    }

    private func removeRecordLocked(_ nativeOpId: String) {
        if let r = records[nativeOpId] { byCorrelation.removeValue(forKey: r.correlationId) }
        records.removeValue(forKey: nativeOpId)
        recordOrder.removeAll { $0 == nativeOpId }
    }

    /// True for empty/whitespace-only strings (mirrors the dispatcher's isBlank).
    private static func isBlank(_ s: String) -> Bool {
        s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // --- test seams (@testable visibility; mirror the dispatcher's pendingSize/purgeNow pattern) ---
    // The claim→re-stamp WINDOW seam — NOT a production environment input, so it lives here with the test seams,
    // not in the init. Fired by `controlledReload` AFTER claimRound won + released `lock` and BEFORE
    // `reStampForReload` re-acquires it. Production leaves the no-op default; a test injects a supersession bumper
    // here to reproduce the cross-thread interleaving the test schedulers collapse. Mirrors Kotlin's
    // onReloadClaimWindowForTest. Visibility (the Swift counterpart of Kotlin's `@Volatile`): the test assigns this
    // closure BEFORE `appReturnedToForeground` enqueues the probe, which in turn enqueues the deadline on
    // `timeoutQueue`; those GCD enqueues are happens-before edges, so the deadline body reads the test's write
    // without an explicit barrier.
    var onReloadClaimWindowForTest: () -> Void = {}
    func recordCount() -> Int { lock.lock(); defer { lock.unlock() }; return records.count }
    func purgeNow() { lock.lock(); defer { lock.unlock() }; purgeTerminalRecordsLocked() }
    func activeNativeOpId() -> String? { lock.lock(); defer { lock.unlock() }; return activeOpId }
    // The terminal CAUSE string — tests assert "closed"≠"cancelled" and "present_timeout"≠"present_failed"
    // directly on the record (the cause IS the forensic contract). Mirrors Kotlin.
    func terminalCause(nativeOpId: String) -> String? { lock.lock(); defer { lock.unlock() }; return records[nativeOpId]?.terminal }

    /// Test seam: is ANY present-confirmation deadline armed? Lets the no-present tests assert "NO deadline armed"
    /// DIRECTLY — not just "exactly one emission" (which the latch guarantees regardless of arming). Bites if the
    /// arm ever moves from the present block back to start()-call time.
    func anyPresentConfirmArmed() -> Bool { lock.lock(); defer { lock.unlock() }; return records.values.contains { $0.presentConfirmItem != nil } }

    static let opStartPayment = ContractConstants.opStartPaymentV1
    // Terminal-latch causes: WHY the operation went terminal, for race-loser routing.
    static let causeWeb = "web"
    static let causeTimeout = "timeout"
    // The SYSTEM-TEARDOWN forensic cause, kept distinct from causeClosed. Its sole emitter is
    // `systemTeardownRequested` (OS-driven teardown); the public code is PAYMENT_ABORTED. No user gesture reaches it.
    static let causeCancelled = "cancelled"
    // The programmatic close() terminal — same PUBLIC code as causeCancelled (PAYMENT_ABORTED), distinct cause so
    // forensics tell a programmatic close from a system teardown. (Kotlin's BridgeDispatcher has its OWN
    // dispatcher-layer CAUSE_CLOSED — the Swift dispatcher never needed one; different layer, deliberately not
    // shared.)
    static let causeClosed = "closed"
    static let causePresentFailed = "present_failed" // the present/load block failed
    // The present-confirmation deadline expired — the UI never positively appeared (the silent UIKit refusal /
    // Android background-activity-launch suppression). Its OWN cause: forensics must never confuse a suppressed
    // launch with a detected refusal.
    static let causePresentTimeout = "present_timeout"
    // The render-gone fail-closed terminal cause (recovery impossible — recoverWebView returned false, a nil host).
    // Its OWN cause so forensics never confuse a render-process death with a present/reload failure.
    static let causeRenderGone = "render_gone"
    // The page origin could not load (iOS: an about:blank-origin guard in start() OR a didFail* on a real
    // unreachable origin; Android: a main-frame onReceivedError). The public code follows the origin —
    // NETWORK_UNAVAILABLE for https (production/staging), INVALID_CONFIGURATION for the harness — but this cause is
    // the same on every origin, so forensics never confuse an unloadable origin with a PAYMENT_TIMEOUT (the
    // blank-then-timeout trap this fail-fast replaces) or a present/reload failure. Mirrors Kotlin's
    // CAUSE_LOAD_FAILED.
    static let causeLoadFailed = "load_failed"
    // The verify-before-execute intercept blocked the `/v1/kws.js` load (bad/absent signature, or unavailable).
    // Maps to NETWORK_UNAVAILABLE — its OWN forensic cause, distinct from causeLoadFailed (an unloadable origin,
    // whatever its public code). Mirrors Kotlin's CAUSE_BUNDLE_UNVERIFIED.
    static let causeBundleUnverified = "bundle_unverified"
    // Kotlin adds CAUSE_RELOAD_FAILED: its reload block can throw on the JVM; the Swift reload closures cannot
    // throw, so that state is unrepresentable here.
    // The gate cause: internal forensics, never the public error code. Set at READINESS — the bridge responder
    // withheld the request from a page whose /v1/kws.js did not verify during that load
    // (`bundleUnverifiedAtReadiness`). See ADR-221. Mirrors Kotlin's CAUSE_GATE_BLOCKED_BUNDLE.
    static let causeGateBlockedBundle = "gate_blocked_bundle"
    // The frozen `lifecycle.unrecoverable_resume` reason enum (events.schema.json) + the round-winner marker for a
    // healthy pong (never emitted — zero success-path telemetry).
    static let reasonPingTimeout = "ping_timeout"
    static let reasonPingFailed = "ping_failed"
    static let reasonPageNotReady = "page_not_ready"
    static let pongWinner = "pong"
    // The RESOLVED wire theme values — bare strings because the codegen parser does not emit string-enum $defs;
    // "auto" never has a wire constant.
    static let themeLight = "light"
    static let themeDark = "dark"
}
