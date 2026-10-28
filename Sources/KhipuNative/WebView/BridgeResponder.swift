import Foundation

/// The JS landing point for one gated delivery. `.respond` is the web→native response path (`khipuBridge._respond`);
/// `.request` is the reverse direction for `startPayment_v1`, the catalog's single native→web op, landing on
/// `khipuBridge._request` (the TS façade inlet). One discriminator, ONE gating brain: both directions share the
/// readiness/epoch/liveness machinery below instead of a duplicated queue. Mirrors Kotlin's `JsTarget`.
///
/// `.resume` and `.ping` are the lifecycle callbacks (`khipuBridge._resume`/`._ping`). They are NOT envelope
/// deliveries: they ride the NO-QUEUE `BridgeResponder.call` path (a deferred resume/ping is meaningless), never
/// `submit`'s readiness queue.
enum JsTarget {
    case respond, request, resume, ping
}

/// The injectable JS-delivery seam. A `BridgeResponder` calls this to push a terminal response envelope into the
/// page's `window.khipuBridge._respond(...)`, or an outbound native→web request envelope into
/// `window.khipuBridge._request(...)` (`JsTarget` selects the landing point). The real default (`KhipuWebViewHost`)
/// wraps `WKWebView.callAsyncJavaScript`; unit tests inject a fake so the readiness/liveness/teardown/delivery-error
/// paths are testable WITHOUT a real WKWebView.
///
/// `onResult` reports delivery success/failure: `(true, nil)` on success, `(false, reason)` on a JS execution
/// failure. **Asymmetric mechanism, identical outcome:** iOS's `callAsyncJavaScript` `Result.failure` IS a real
/// error channel (Android must synthesize one via a JS sentinel). Both feed the SAME `onResult` contract.
typealias JsDelivery = (_ envelopeJSON: String, _ target: JsTarget, _ onResult: @escaping (Bool, String?) -> Void) -> Void

/// What a readiness probe that found `window.khipuBridge` led to: the epoch became ready and flushed (`ready`), it is
/// still waiting for its own document's request for the bundle and the host should probe again (`pending`), or it
/// will never become ready from this probe (`closed`: a stale epoch, a torn-down host, or the gate blocked it).
enum ReadinessOutcome: Equatable {
    case ready, pending, closed
}

/// The WebView host's delivery brain: the readiness latch and bounded queue, the liveness/teardown guards, and the
/// structured delivery-error diagnostic. Deliberately holds NO `WKWebView` reference (all eval goes through the
/// injected `JsDelivery` seam), so this whole state machine is unit-testable without a real WebView.
/// `KhipuWebViewHost` owns one of these and wires the real WebView in. Mirrors `KhipuBridgeResponder.kt`.
///
/// **No cross-page leakage:** every page load is a new *epoch* (`pageGeneration`). Each request captures the epoch
/// it was accepted in; a response may only be delivered into the page of its own epoch (a response produced for a
/// previous page is dropped, never injected into a freshly-loaded one). **Fail-closed, never crash:** a
/// dead/destroyed WebView, a stale page, or a readiness-queue overflow are released with a structured
/// `bridge.respond_delivery_failed` diagnostic, never an exception, never a hang. A response for the CURRENT page that
/// arrives before readiness is QUEUED (bounded) and flushed on readiness. The one deliberate silent drop: when the
/// readiness gate blocks an epoch (ADR-221), its queue is cleared with no per-item diagnostic, because the
/// coordinator's `gate_blocked_bundle` terminal already records the failure.
final class BridgeResponder {
    private let jsDeliver: JsDelivery
    // Named `telemetry` on purpose: the telemetry-name gate finds emit callsites by the literal `telemetry.emit(`.
    private let telemetry: TelemetrySink
    private let maxQueued: Int

    private let lock = NSLock()
    private var ready = false
    private var alive = true
    // The WebView's render process died (webViewWebContentProcessDidTerminate). RECOVERABLE, distinct from `alive`'s
    // permanent teardown: the coordinator's render-gone recovery clears it after the host reloads.
    private var renderDead = false
    private var pageGeneration = 0
    private var probeMisses = 0 // bounded readiness re-poll budget for the current epoch
    private var probeExhausted = false // re-poll budget spent without khipuBridge appearing: fail-closed with diagnostics
    private var hostLoadPending = false // a host-initiated load() bumped the epoch; its own commit must NOT re-bump
    private let maxProbeAttempts: Int
    private struct Queued { let generation: Int; let responseJSON: String; let target: JsTarget }
    private var queue: [Queued] = []
    // The verify-before-deliver gate (ADR-221), all guarded by `lock`. `requireVerifiedBundle` is set per HOST load
    // (true unless a file:/about: harness) and CARRIES OVER a self-navigation bump; `verifiedGeneration` is the epoch
    // whose `/v1/kws.js` verified; `unverifiedGeneration` is the epoch the gate blocked at readiness (-1 = none).
    private var requireVerifiedBundle = false
    private var verifiedGeneration = -1
    private var unverifiedGeneration = -1
    // An epoch that required a verified bundle reached readiness without one, or without its own document's
    // request for it within the readiness budget (the readiness gate, ADR-221). Fired once per epoch, outside the
    // lock; the host forwards it to the coordinator, which resolves NETWORK_UNAVAILABLE.
    private let onUnverifiedReady: () -> Void

    // Bounded readiness re-poll: the host re-probes until khipuBridge appears, and the page's request for its bundle
    // with it, or the budget is spent, sized for a React bundle mount, not a hung page. 28 attempts are 4.8 s with the
    // host's schedule (four short retries, then every 200 ms). Mirrors Kotlin's DEFAULT_MAX_PROBE_ATTEMPTS.
    static let defaultMaxProbeAttempts = 28

    init(deliver: @escaping JsDelivery, telemetry: TelemetrySink = NoopTelemetrySink(), maxQueued: Int = 64,
         maxProbeAttempts: Int = BridgeResponder.defaultMaxProbeAttempts, onUnverifiedReady: @escaping () -> Void = {}) {
        self.jsDeliver = deliver
        self.telemetry = telemetry
        self.maxQueued = maxQueued
        self.maxProbeAttempts = maxProbeAttempts
        self.onUnverifiedReady = onUnverifiedReady
    }

    /// Current page epoch — captured per request (in the WKScriptMessageHandler) so a delivery can never cross into a later page.
    func generation() -> Int { lock.lock(); defer { lock.unlock() }; return pageGeneration }

    /// New page epoch for a HOST-initiated load: bump the epoch, drop readiness, reset the probe budget, abandon any
    /// queued responses from the previous page WITH a per-item `stale_page` diagnostic (the same dropped delivery as
    /// a respond-time stale drop, so the same observability). The load's own commit callback must then route through
    /// `onNavigationCommitted()`, which recognizes it and does NOT re-bump: deliveries queued between `load()` and
    /// the commit (the `startPayment_v1` request) belong to THIS page and must survive to readiness. A second,
    /// unconditional bump at commit would abandon the payment request. Mirrors Kotlin.
    func beginLoad(requireVerifiedBundle: Bool = false) {
        bumpEpoch(markHostLoad: true, requireVerifiedBundle: requireVerifiedBundle)
    }

    /// A main-frame navigation COMMITTED (`didCommit` / `onPageStarted`). The first commit after a host-initiated
    /// `beginLoad()` is that load's own navigation: the epoch was already bumped synchronously, so this is a no-op.
    /// Any other commit is a PAGE self-navigation (server redirect, JS location change) that never went through
    /// `load()`: full epoch bump (defense in depth: a previous page's response must never reach the new one).
    /// Mirrors Kotlin.
    func onNavigationCommitted() {
        lock.lock()
        let isHostLoadCommit = hostLoadPending
        hostLoadPending = false
        lock.unlock()
        if !isHostLoadCommit { bumpEpoch(markHostLoad: false, requireVerifiedBundle: nil) } // requirement carries over
    }

    private func bumpEpoch(markHostLoad: Bool, requireVerifiedBundle: Bool?) {
        lock.lock()
        pageGeneration += 1
        ready = false
        probeMisses = 0
        probeExhausted = false
        hostLoadPending = markHostLoad
        if let required = requireVerifiedBundle { self.requireVerifiedBundle = required }
        let dropped = queue.map { $0.responseJSON }
        queue.removeAll()
        lock.unlock()
        for json in dropped { emitFailure(json, "stale_page", "warn") } // outside the lock (deferred-telemetry)
    }

    /// The host's OWN fetch of the page host's `/v1/kws.js` verified, for epoch `generation` (read by `load(url:)`
    /// before that fetch starts). It records that fetch only; whether the page asked for that bundle is checked at
    /// readiness (`onReady`'s `pageRequestedBundle`). A stamp for an epoch that is no longer current is ignored.
    /// Callable from the URLSession delegate queue.
    func markBundleVerified(generation: Int) {
        lock.lock(); defer { lock.unlock() }
        if generation == pageGeneration { verifiedGeneration = generation }
    }

    /// True between a host `beginLoad()` and that load's commit. A page-finish arriving in that window belongs to the
    /// previous document, so the host does not probe it under the new epoch.
    func isAwaitingHostLoadCommit() -> Bool { lock.lock(); defer { lock.unlock() }; return hostLoadPending }

    /// The page finished loading AND `window.khipuBridge` is defined: become ready and flush the current epoch's
    /// queue, in order. `probeGeneration` is the epoch captured when the probe was ISSUED: a stale probe callback (a
    /// load/navigation happened while it was in flight) must never mark the NEW page ready (the probe is
    /// epoch-authenticated, like every delivery). `pageRequestedBundle` is what the same probe read from the page's
    /// own document: it requested the page-origin `/v1/kws.js`.
    ///
    /// Before flushing, the readiness gate (ADR-221) withholds the request from an epoch that required a verified
    /// bundle. Without a verification for this epoch it blocks at once: `onUnverifiedReady` once, no flush. With
    /// one but no page request yet it answers `pending`, and each such probe spends one attempt of the readiness
    /// budget it shares with `onProbeMiss`; the probe that spends the last attempt blocks the epoch the same way. An
    /// epoch that is already ready stays ready, so a later probe cannot block a page that already received the
    /// request.
    @discardableResult
    func onReady(generation probeGeneration: Int, pageRequestedBundle: Bool = false) -> ReadinessOutcome {
        lock.lock()
        if !alive || probeGeneration != pageGeneration || unverifiedGeneration == pageGeneration { lock.unlock(); return .closed }
        if ready { lock.unlock(); return .ready }
        // The gate runs HERE: the first moment the page can receive the operationId.
        switch OriginGate.decide(requiresVerifiedBundle: requireVerifiedBundle, verifiedGeneration: verifiedGeneration,
                                 readyGeneration: pageGeneration, pageRequestedBundle: pageRequestedBundle) {
        case .allowed:
            ready = true
            let gen = pageGeneration
            let flush = queue.filter { $0.generation == gen }
            queue.removeAll()
            lock.unlock()
            for item in flush { evalDeliver(item.responseJSON, item.target) } // outside the lock: never eval while holding it
            return .ready
        case .awaitingPageRequest:
            probeMisses += 1
            if probeMisses < maxProbeAttempts { lock.unlock(); return .pending }
            return blockLocked()
        case .blocked:
            return blockLocked()
        }
    }

    /// Withhold the current epoch for good. Called with `lock` held; releases it before signalling.
    private func blockLocked() -> ReadinessOutcome {
        unverifiedGeneration = pageGeneration
        queue.removeAll() // no per-item emit: the coordinator's gate_blocked_bundle terminal is the record
        lock.unlock()
        onUnverifiedReady()
        return .closed
    }

    /// The readiness probe came back negative for epoch `probeGeneration`: kws.js is a React SPA, so
    /// `window.khipuBridge` appears when the bundle MOUNTS, possibly well after page-finish; a one-shot probe can
    /// genuinely miss it. Returns `true` while the host should re-schedule the bounded re-poll for this epoch. On
    /// exhaustion, fails closed: drains the queue with a per-item `readiness_timeout` diagnostic (the page will never
    /// receive them) and `respond` drops subsequent not-ready responses the same way instead of queueing into a black
    /// hole.
    func onProbeMiss(generation probeGeneration: Int) -> Bool {
        lock.lock()
        if !alive || probeGeneration != pageGeneration || ready || probeExhausted { lock.unlock(); return false }
        probeMisses += 1
        if probeMisses < maxProbeAttempts { lock.unlock(); return true }
        probeExhausted = true
        let drained = queue.map { $0.responseJSON }
        queue.removeAll()
        lock.unlock()
        for json in drained { emitFailure(json, "readiness_timeout", "error") } // outside the lock
        return false
    }

    /// Teardown: no further eval may run; drain the queue WITH a per-item diagnostic (these deliveries are lost
    /// exactly like a respond-time dead-WebView drop). Idempotent.
    func shutdown() {
        lock.lock()
        alive = false
        ready = false
        let dropped = queue.map { $0.responseJSON }
        queue.removeAll()
        lock.unlock()
        for json in dropped { emitFailure(json, "webview_unavailable", "error") } // outside the lock
    }

    /// The WebView's render process died (`webViewWebContentProcessDidTerminate`). Gate every subsequent delivery to
    /// `webview_unavailable` (never eval against the defunct renderer) until the host reloads the WebView and calls
    /// `clearRenderDead()`. RECOVERABLE (unlike `shutdown()`'s `alive=false`); the coordinator's render-gone recovery
    /// clears it before the controlled reload's loadPage runs. No queue drain here: a render death does not abandon
    /// the page (the reload re-stamps and re-delivers the SAME record). Mirrors Kotlin.
    func markRenderDead() { lock.lock(); renderDead = true; lock.unlock() }

    /// The WebView is live again (post reload): re-open delivery. Called by the host inside `recoverWebView()` before
    /// the controlled reload's loadPage (which beginLoad()s a fresh epoch). Mirrors Kotlin.
    func clearRenderDead() { lock.lock(); renderDead = false; lock.unlock() }

    /// Deliver one terminal response produced for page epoch `generation`. Runs on the main queue (the dispatcher's
    /// single main-thread hop). Gates fail-closed: a dead WebView, a stale page or a queue overflow is dropped with a
    /// diagnostic; a not-yet-ready CURRENT page queues (bounded). The eval itself is outside the lock.
    func respond(_ responseJSON: String, generation: Int) {
        submit(responseJSON, generation: generation, target: .respond)
    }

    /// Deliver one outbound native→web REQUEST envelope (`startPayment_v1`, the catalog's single reversed-direction
    /// op) for page epoch `generation`, landing on `khipuBridge._request`. Rides the SAME readiness/epoch/liveness
    /// gating as `respond`: never evaluated before `khipuBridge` exists, never into a stale page, never against a dead
    /// WebView.
    func request(_ requestJSON: String, generation: Int) {
        submit(requestJSON, generation: generation, target: .request)
    }

    /// The NO-QUEUE call path for the lifecycle callbacks (`_resume`/`_ping`). Unlike `submit`, a call that cannot
    /// run NOW fails IMMEDIATELY through `onResult` with the gate reason: alive + current-epoch + ready → eval
    /// (outside the lock) and report the seam's result; `!alive` or a dead renderer → `webview_unavailable`; epoch
    /// mismatch → `stale_page`; `!ready` (including a spent probe budget, still `!ready`) → `page_not_ready`. The
    /// readiness queue exists so a *terminal result* survives a slow page mount; a resume delivered minutes later is
    /// meaningless, and a page that cannot answer `_ping` now is precisely the unrecoverable state the coordinator
    /// reloads.
    ///
    /// **Telemetry asymmetry vs `submit` (deliberate):** this path emits NO `bridge.respond_delivery_failed`. These
    /// are not envelope deliveries (no correlation_id to hash, nothing dropped); the failure travels through
    /// `onResult` and the COORDINATOR owns the lifecycle diagnostic (`lifecycle.unrecoverable_resume`).
    /// `payload` is the RAW value for the target (`_resume`'s merchant operationId; nil for `_ping`); the real
    /// delivery closure is responsible for JS-safe transport (AC-BRIDGE-006: structured arguments, never string
    /// concatenation into the eval). Mirrors `KhipuBridgeResponder.call` (Kotlin).
    func call(_ payload: String?, generation: Int, target: JsTarget, onResult: @escaping (Bool, String?) -> Void) {
        var gateReason: String?
        lock.lock()
        if !alive {
            gateReason = "webview_unavailable"
        } else if renderDead {
            // A post-render-death call must NOT touch the defunct renderer: degrade like a dead WebView until the
            // host reloads it (then clearRenderDead re-opens delivery).
            gateReason = "webview_unavailable"
        } else if generation != pageGeneration {
            gateReason = "stale_page"
        } else if !ready {
            gateReason = "page_not_ready"
        }
        lock.unlock()
        if let reason = gateReason {
            onResult(false, reason)
            return
        }
        jsDeliver(payload ?? "", target, onResult) // outside the lock: never eval while holding it
    }

    private func submit(_ envelopeJSON: String, generation: Int, target: JsTarget) {
        var dropReason: String?
        var dropSeverity = "warn"
        var doEval = false
        var gateDrop = false
        var evictedJSON: String? = nil // a RESPOND pushed out to make room for the payment REQUEST
        lock.lock()
        if !alive {
            dropReason = "webview_unavailable"; dropSeverity = "error" // no eval against a dead WebView
        } else if renderDead {
            // The renderer died: drop with a diagnostic, never eval against the defunct WebView, until the host
            // reloads it (clearRenderDead). A queued response would target a dead page.
            dropReason = "webview_unavailable"; dropSeverity = "error"
        } else if generation != pageGeneration {
            dropReason = "stale_page" // a previous page's delivery: never inject into the new one
        } else if generation == unverifiedGeneration {
            gateDrop = true // the gate blocked this epoch: never deliver; no emit
        } else if !ready {
            if probeExhausted {
                // Probe budget spent without khipuBridge appearing: the queue is a black hole, drop now.
                dropReason = "readiness_timeout"; dropSeverity = "error"
            } else if queue.count >= maxQueued {
                // A full queue is DIRECTION-AWARE. The two directions are not equally valuable: the ONE outbound
                // REQUEST (`startPayment_v1`) drives the whole payment, so losing it to a burst of pre-readiness
                // RESPOND deliveries leaves the payment waiting out its timeout, while losing a response costs one
                // delivery. So a REQUEST evicts the oldest non-REQUEST instead of being dropped; the victim gets the
                // same diagnostic it would have gotten as an overflow, so nothing disappears silently. Reserving
                // fixed headroom for the request would be worse: it shrinks the usable queue for responses even
                // when no request ever arrives. Behaviorally identical to Kotlin.
                if target == .request, let victimIndex = queue.firstIndex(where: { $0.target != .request }) {
                    evictedJSON = queue.remove(at: victimIndex).responseJSON
                    queue.append(Queued(generation: generation, responseJSON: envelopeJSON, target: target))
                } else {
                    dropReason = "readiness_queue_overflow" // bounded; fail-closed
                }
            } else {
                queue.append(Queued(generation: generation, responseJSON: envelopeJSON, target: target)) // queue until ready
            }
        } else {
            doEval = true
        }
        lock.unlock()
        // Outside the lock (deferred-telemetry discipline): the evicted response is reported with the SAME reason it
        // would have carried had it been the one dropped at the door.
        if let evictedJSON { emitFailure(evictedJSON, "readiness_queue_overflow", "warn") }
        if gateDrop { return }
        if doEval {
            evalDeliver(envelopeJSON, target)
        } else if let reason = dropReason {
            emitFailure(envelopeJSON, reason, dropSeverity)
        }
    }

    private func evalDeliver(_ envelopeJSON: String, _ target: JsTarget) {
        jsDeliver(envelopeJSON, target) { [weak self] ok, reason in
            if !ok { self?.emitFailure(envelopeJSON, reason ?? "eval_failed", "error") } // a delivery error is reported, never swallowed
        }
    }

    /// Structured `bridge.respond_delivery_failed`. Fields { op?, correlation_id_hash, reason, severity }: the
    /// `correlation_id` is hashed (PII, never raw). A RESPONSE envelope carries no `op` (omitted); an outbound REQUEST
    /// envelope does carry it, included per the field's registered "callers that know the op".
    private func emitFailure(_ envelopeJSON: String, _ reason: String, _ severity: String) {
        var fields: [String: Any] = ["reason": reason, "severity": severity]
        let parsed = Self.envelopeFields(of: envelopeJSON)
        if let cid = parsed.correlationId { fields["correlation_id_hash"] = Sha256.hex(cid) }
        if let op = parsed.op { fields["op"] = op }
        telemetry.emit(event: TelemetryEvent.respondDeliveryFailed, fields: fields)
    }

    private static func envelopeFields(of envelopeJSON: String) -> (correlationId: String?, op: String?) {
        guard let data = envelopeJSON.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return (nil, nil) }
        return (obj["correlation_id"] as? String, obj["op"] as? String)
    }
}
