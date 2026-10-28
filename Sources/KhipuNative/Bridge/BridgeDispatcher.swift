import Foundation
import BridgeGenerated

/// Routes requests from the payment page to the registered `BridgeCapability` handlers. `KhipuPayment` creates its own
/// instance and keeps it private.
///
/// `handle(_:deliver:)` validates each inbound request envelope and runs the capability that matches its `op` off
/// the main queue. Requests for the same `op` run one at a time, in order; different `op`s run in parallel. A
/// request for a capability that is unavailable on this OS, or for an unknown `op`, is answered with an
/// `UNSUPPORTED_OP` error.
///
/// Each accepted request is answered exactly once, on the main queue, unless `close()` is called first; a request
/// still unanswered after the timeout (90 seconds by default) is answered with a `TIMEOUT` error. Dropped
/// envelopes, and capability results that arrive after their request was answered or abandoned, are reported
/// through the `TelemetrySink` passed to the initializer.
final class BridgeDispatcher {
    private enum Reason {
        case resolved, timeout
        var wire: String { self == .resolved ? "resolved" : "timeout" }
    }

    private final class PendingEntry {
        let op: String
        let sessionId: String // retained so resetSession() can echo it in the SESSION_RESET envelope
        let deliver: (String) -> Void
        var terminal = false
        // startedAtMs (WALL) powers pending_operations[].started_ago_ms (= clock() - startedAtMs);
        // startedAtMonoMs (MONOTONIC) powers latency_ms in bridge.late_response.
        var startedAtMs: Double = 0
        var startedAtMonoMs: Double = 0
        var completedAtMonoMs: Double = 0 // MONOTONIC — TTL purge
        var timeoutItem: DispatchWorkItem?
        init(op: String, sessionId: String, deliver: @escaping (String) -> Void) {
            self.op = op
            self.sessionId = sessionId
            self.deliver = deliver
        }
    }

    /// Bounded recent-meta record: op + the monotonic start + WHY it left the pending map
    /// (`purged` | `reset_abandoned`), kept just long enough to enrich a late signal.
    private struct MetaEntry { let op: String; let startedAtMonoMs: Double; let insertedAtMonoMs: Double; let origin: String }

    /// late_response `origin` discriminator: TTL-purged genuine late signal vs reset-abandoned.
    private static let originPurged = "purged"
    private static let originResetAbandoned = "reset_abandoned"

    private let stateLock = NSLock()
    /// Dispatch map: only OS-available capabilities, keyed by `op` (the dispatchable half of the
    /// declared-vs-dispatchable split). `handle()` op-lookup reads this, so a registered-but-unavailable op stays
    /// non-dispatchable (→ `UNSUPPORTED_OP`, never a crash).
    private var capabilities: [String: BridgeCapability] = [:]
    /// Every capability passed to `register`, in registration order, regardless of OS availability
    /// ("declared"). Discovery enumerates this so an unavailable capability surfaces as
    /// `available:false` instead of being omitted. Ordered + deterministic.
    private var declaredCaps: [BridgeCapability] = []
    private var currentSessionId: String?
    /// One serial queue per `op` — single-flight per `op`, parallel across `op`s.
    private var opQueues: [String: DispatchQueue] = [:]
    /// In-flight + recently-terminal operations keyed by `correlation_id`.
    private var pending: [String: PendingEntry] = [:]

    /// Teardown latch. Once close()d, handle() rejects (no entry, no enqueue) and pending handlers are released
    /// without delivering. Guarded by stateLock (read under the lock — Swift has no @Volatile).
    private var closed = false
    /// Bounded recently-terminal/abandoned metadata for late_response op/latency enrichment. Same discipline as
    /// DiagnosticsRecorder's debug-id map (dict + insertion-order array, purge-expired-on-write, evict eldest past
    /// the cap), so growth stays bounded under a flood of late signals. Guarded by stateLock.
    private var recentMeta: [String: MetaEntry] = [:]
    private var recentMetaOrder: [String] = []
    // Cap + TTL match DiagnosticsRecorder's debug-id map (200 / 1h), so growth stays bounded under a flood of
    // late signals.
    private static let recentMetaCap = 200
    private static let recentMetaTtlMs: Double = 60 * 60 * 1000 // 1 hour

    private let mainQueue: DispatchQueue
    private let timeoutQueue = DispatchQueue(label: "com.khipu.bridge.timeout", attributes: .concurrent)
    private let telemetry: TelemetrySink
    private let timeoutMs: Double
    private let ttlMs: Double
    /// WALL clock. Powers `pending_operations[].started_ago_ms`, a human-facing "how long ago" reading, so it stays
    /// on wall time on purpose; the ≥0 clamp in snapshotPendingOperations() is the defense against backward jumps.
    private let clock: () -> Double
    /// MONOTONIC clock. Powers TTL purge timing (`completedAtMonoMs`) + `latency_ms`, so a backward wall jump
    /// (NTP/manual) can never keep terminal entries un-purged. Default: CLOCK_MONOTONIC in ms (see the initializer).
    private let monotonic: () -> Double
    /// Inbound envelope size bound, 256 KB by default. Swift bounds on exact UTF-8 byte count (`utf8.count`),
    /// the same unit as Kotlin; comfortably exceeds the largest real op payload while staying configurable so
    /// tests can inject a tiny bound.
    private let maxEnvelopeBytes: Int
    /// For the OS-floor degradation diagnostic. Injected so tests can simulate floor−1 (an initializer param with
    /// a real default, like clock/timeoutMs/maxEnvelopeBytes). Used only to populate the diagnostic's `os_version`
    /// field; whether a capability is dispatchable is decided by `capability.availableOnOS`.
    private let osVersion: () -> Int

    convenience init() {
        self.init(mainQueue: .main, telemetry: NoopTelemetrySink())
    }

    init(
        mainQueue: DispatchQueue = .main,
        telemetry: TelemetrySink = NoopTelemetrySink(),
        timeoutMs: Double = 90_000,
        ttlMs: Double = 60_000,
        clock: @escaping () -> Double = { Date().timeIntervalSince1970 * 1000 },
        // CLOCK_MONOTONIC on Darwin keeps advancing while the device SLEEPS (unlike DispatchTime/mach_absolute_time,
        // which freeze) — matching Android's SystemClock.elapsedRealtime(), so a bank-app round-trip with a
        // sleeping device classifies the same late signal identically on both platforms.
        monotonic: @escaping () -> Double = { Double(clock_gettime_nsec_np(CLOCK_MONOTONIC)) / 1_000_000 },
        maxEnvelopeBytes: Int = 256 * 1024,
        osVersion: @escaping () -> Int = { ProcessInfo.processInfo.operatingSystemVersion.majorVersion }
    ) {
        self.mainQueue = mainQueue
        self.telemetry = telemetry
        self.timeoutMs = timeoutMs
        self.ttlMs = ttlMs
        self.clock = clock
        self.monotonic = monotonic
        self.maxEnvelopeBytes = maxEnvelopeBytes
        self.osVersion = osVersion
    }

    /// Registers `capability`. Whether it can be invoked is decided once, here, from its `availableOnOS`: one that
    /// is unavailable on this OS is still listed in `declared` but cannot be invoked, and is reported once through
    /// the `TelemetrySink`.
    func register(_ capability: BridgeCapability) {
        let available = capability.availableOnOS // computed once: stable decision for dispatch + diagnostic
        stateLock.lock()
        declaredCaps.append(capability)
        if available { capabilities[capability.id] = capability }
        stateLock.unlock()
        if !available {
            // OS-floor degradation: a declared-but-unavailable capability emits EXACTLY ONE structured diagnostic,
            // at registration, AFTER unlock (never emit while holding a lock). The op stays non-dispatchable.
            telemetry.emit(
                event: TelemetryEvent.capabilityUnavailable,
                // The per-platform unit marker travels with os_version so a consumer can interpret it unambiguously
                // (iOS operatingSystemVersion.majorVersion; Kotlin sends "android_api_level").
                fields: ["op": capability.id, "reason_code": "os_unsupported", "os_version": osVersion(), "os_version_unit": "ios_major_version"]
            )
        }
    }

    /// Every registered capability, in registration order, including those unavailable on this OS (the source
    /// for the page's capability discovery). Returns a copy.
    var declared: [BridgeCapability] {
        stateLock.lock(); defer { stateLock.unlock() }
        return declaredCaps
    }

    /// Starts a new page session; called on each page load. Forgets the pinned session, so the next accepted request
    /// pins a new one, and answers every request still in flight with a `SESSION_RESET` error envelope, so none is
    /// left waiting. A capability result that arrives later for one of those requests is reported as
    /// `TelemetryEvent.lateResponse`.
    func resetSession() {
        var abandoned: [(String, (String) -> Void)] = []
        stateLock.lock()
        currentSessionId = nil
        for (id, entry) in pending {
            entry.timeoutItem?.cancel()
            // Remember metadata so a LATER late signal (the capability resolving after abandon) can still enrich
            // bridge.late_response with op/latency_ms — recorded for every cleared entry.
            // origin=reset_abandoned discriminates it from a TTL-purged genuine late signal.
            rememberMetaLocked(id, entry.op, entry.startedAtMonoMs, Self.originResetAbandoned)
            if !entry.terminal {
                entry.terminal = true // win the latch so a racing complete() does not double-deliver
                abandoned.append((Self.errorEnvelope(sessionId: entry.sessionId, correlationId: id, code: "SESSION_RESET", message: "request abandoned by session reset"), entry.deliver))
            }
        }
        pending.removeAll()
        stateLock.unlock()
        // Never deliver holding the lock: resolve each abandoned request after unlock.
        for (envelope, deliver) in abandoned { deliverOnMain(envelope, deliver) }
    }

    /// Shuts the dispatcher down. Idempotent. Afterwards `handle(_:deliver:)` ignores every call, and requests still
    /// in flight are released without a response: after teardown there is no page left to receive one. Pending
    /// timeouts are cancelled, and capability results that arrive later are dropped silently.
    func close() {
        stateLock.lock()
        closed = true
        currentSessionId = nil
        for (_, entry) in pending { entry.timeoutItem?.cancel() } // no deliver — release-without-deliver
        pending.removeAll()
        recentMeta.removeAll()
        recentMetaOrder.removeAll()
        stateLock.unlock()
    }

    /// Handles one request envelope from the payment page. Validation runs before any capability, cheapest check
    /// first: size, repeated top-level keys, JSON parse, required fields, `message_type`, payload shape, session,
    /// `op`, duplicate id. `deliver` receives at most one response envelope, as JSON, on the main queue: the
    /// capability's result or an error envelope. Some envelopes are dropped without calling `deliver`, for example
    /// oversized ones, ones from another page session, or duplicates of a request in flight; those are reported
    /// through the `TelemetrySink` instead. After `close()`, every call is ignored.
    func handle(_ requestJSON: String, deliver: @escaping (String) -> Void) {
        // 0. Teardown guard: reject post-close BEFORE any parse/insert/enqueue/early-delivery so a request
        //    arriving after close() leaves no pending entry, no queue.async, and no error-envelope delivery. Swift
        //    has no @Volatile, so read `closed` under a brief lock; the accept path re-checks under the lock to
        //    close the close()/accept race.
        stateLock.lock(); let isClosed = closed; stateLock.unlock()
        if isClosed { return }
        // 1. Size bound — check the RAW string BEFORE any parse so no attacker-controlled object graph is
        //    allocated. Swift bounds on exact UTF-8 byte count (`utf8.count`, O(n) with no extra allocation), the
        //    same unit as Kotlin, so identical bytes get the same verdict on both platforms. Oversize ⇒ drop with
        //    telemetry; there is no parsed correlation_id to respond to, so `deliver` is never called.
        guard requestJSON.utf8.count <= maxEnvelopeBytes else {
            telemetry.emit(
                event: TelemetryEvent.envelopeTooLarge,
                fields: ["size": requestJSON.utf8.count, "max": maxEnvelopeBytes, "severity": "warn"]
            )
            return
        }

        // 1b. Duplicate top-level keys: JSONSerialization keeps the FIRST occurrence and kotlinx the LAST, so an
        //     envelope declaring `op` twice runs a DIFFERENT capability per platform for identical bytes, and one
        //     declaring `correlation_id` twice dedups and session-pins under a different id. Refused on both
        //     platforms rather than silently meaning two things. TELEMETRY-ONLY, deliberately: the envelope is
        //     AMBIGUOUS, so there is no correlation_id we can honestly claim is "the" one to echo an error to —
        //     same posture as an unparseable envelope. The scanner fails OPEN (see its doc). Behaviorally
        //     identical to Kotlin.
        if Self.hasDuplicateTopLevelKeys(requestJSON) {
            telemetry.emit(
                event: TelemetryEvent.malformedEnvelope,
                fields: ["reason": "duplicate_key", "severity": "warn"]
            )
            return
        }

        // 2. Parse — malformed JSON gets a generic error envelope (there is no id to echo).
        guard
            let data = requestJSON.data(using: .utf8),
            let env = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else {
            deliverOnMain(Self.errorEnvelope(sessionId: "", correlationId: "", code: "INTERNAL_ERROR", message: "malformed envelope"), deliver)
            return
        }

        // 3. Field presence + non-blank + string-typed. `as? String` already rejects non-string JSON values
        //    (object/array/number/bool) as nil; bind via `guard let` so the accepted values are non-optional
        //    WITHOUT a force-unwrap (which would be fragile under any future reordering of this guard).
        let op = env["op"] as? String
        let correlationId = env["correlation_id"] as? String
        let sessionId = env["session_id"] as? String
        guard let opValue = op, !Self.isBlank(opValue),
              let correlationIdValue = correlationId, !Self.isBlank(correlationIdValue),
              let sessionIdValue = sessionId, !Self.isBlank(sessionIdValue) else {
            // Deliver an error envelope only when a usable correlation_id was parsed; else telemetry-only.
            // When a usable id was parsed (an error envelope IS delivered), include the HASHED id so the local log
            // can correlate — NEVER the raw id (PII).
            var fields: [String: Any] = ["reason": "blank_or_missing_field", "severity": "warn"]
            if let cid = correlationId, !Self.isBlank(cid) {
                deliverOnMain(Self.errorEnvelope(sessionId: sessionId ?? "", correlationId: cid, code: "INTERNAL_ERROR", message: "malformed envelope"), deliver)
                fields["correlation_id_hash"] = Sha256.hex(cid)
            }
            telemetry.emit(event: TelemetryEvent.malformedEnvelope, fields: fields)
            return
        }

        // 4. message_type — must decode to `request` via the GENERATED enum (never hardcode wire strings). Only
        //    inbound REQUESTs are handled here: the host routes the payment's inbound `response` to the payment
        //    coordinator, so a `response` that reaches the dispatcher — like `event`/`push`/unknown/missing — is
        //    rejected (the reserved message_type values stay dormant at runtime). A usable correlation_id exists
        //    here ⇒ deliver an error envelope.
        let messageType = (env["message_type"] as? String).flatMap { MessageType(rawValue: $0) }
        guard messageType == .request else {
            deliverOnMain(Self.errorEnvelope(sessionId: sessionIdValue, correlationId: correlationIdValue, code: "UNSUPPORTED_MESSAGE_TYPE", message: "unsupported message_type"), deliver)
            // Carries `op` so the field set matches the other events (session-mismatch/duplicate carry it too).
            telemetry.emit(event: TelemetryEvent.invalidMessageType, fields: ["op": opValue, "correlation_id_hash": Sha256.hex(correlationIdValue), "severity": "warn"])
            return
        }

        // 4c. `payload` SHAPE: a present-but-not-object payload (string / array / number / bool) is refused like
        //     any other malformed envelope, never coerced to `[:]`. Coercing would be silent corruption in the
        //     contract's data path: the caller believes it sent arguments, the capability sees none, and no
        //     diagnostic exists anywhere. A usable correlation_id exists here, so an error envelope IS delivered.
        //     ABSENT and explicit JSON `null` both mean `[:]` — several ops take no arguments, and `null` is how a
        //     web caller spells "nothing". JSONSerialization yields NSNull for an explicit null, which is why that
        //     case is spelled out rather than falling to the refusal. Behaviorally identical to Kotlin's JsonNull
        //     branch.
        let payloadValue = env["payload"]
        if let payloadValue, !(payloadValue is NSNull), !(payloadValue is [String: Any]) {
            deliverOnMain(Self.errorEnvelope(sessionId: sessionIdValue, correlationId: correlationIdValue, code: "INTERNAL_ERROR", message: "malformed envelope"), deliver)
            telemetry.emit(
                event: TelemetryEvent.malformedEnvelope,
                fields: [
                    "reason": "payload_not_object",
                    "severity": "warn",
                    // The HASHED id, never the raw one (same discipline as the blank-field branch).
                    "correlation_id_hash": Sha256.hex(correlationIdValue),
                ]
            )
            return
        }
        let payload = payloadValue as? [String: Any] ?? [:]

        // 5–7 under stateLock (session-mismatch → capability → purge → dedup → pin → insert →
        // timeout-arm), so a concurrent resetSession() cannot interleave. Telemetry for in-lock discards
        // is emitted AFTER unlock (never emit holding the lock).
        stateLock.lock()
        // 4b. Teardown guard under the lock: close() flips `closed` while holding stateLock, so
        //     re-checking here makes accept-vs-close atomic — no entry is inserted after close() won the lock.
        if closed { stateLock.unlock(); return }
        // 5. Session isolation: a mismatch against an ALREADY-pinned session ⇒ discard WITH telemetry and no
        //    response. The pin itself is deferred to the accept path below so an unknown-op / duplicate
        //    envelope cannot pin (and thereby lock out) a session it never used.
        let pinned = currentSessionId
        if let pinned = pinned, pinned != sessionIdValue {
            stateLock.unlock()
            telemetry.emit(
                event: TelemetryEvent.sessionMismatchDiscarded,
                fields: ["correlation_id_hash": Sha256.hex(correlationIdValue), "op": opValue, "severity": "warn"]
            )
            return // discard (do not deliver): session isolation
        }

        // 6. Capability lookup — unknown op ⇒ UNSUPPORTED_OP (delivered after unlock).
        guard let capability = capabilities[opValue] else {
            stateLock.unlock()
            deliverOnMain(Self.errorEnvelope(sessionId: sessionIdValue, correlationId: correlationIdValue, code: "UNSUPPORTED_OP", message: "no capability for \(opValue)"), deliver)
            return
        }

        // 7. Duplicate-by-id dedup. Purge past-TTL terminals FIRST so a stale id never falsely blocks a fresh
        //    request; any entry that REMAINS for this id is either in-flight (non-terminal) or a within-TTL
        //    terminal ⇒ duplicate request: drop WITHOUT overwriting the first entry or orphaning its timeout.
        //    Dedup is by id equality, not by envelope hash.
        purgeStaleLocked()
        if pending[correlationIdValue] != nil {
            stateLock.unlock()
            telemetry.emit(
                event: TelemetryEvent.duplicateRequestDropped,
                fields: ["correlation_id_hash": Sha256.hex(correlationIdValue), "op": opValue, "severity": "warn"]
            )
            return
        }

        // Accept: pin the session now (only a fully-accepted request pins), register the pending entry, arm
        // the timeout, enqueue.
        if pinned == nil { currentSessionId = sessionIdValue }
        let entry = PendingEntry(op: opValue, sessionId: sessionIdValue, deliver: deliver)
        entry.startedAtMs = clock() // WALL — started_ago_ms
        entry.startedAtMonoMs = monotonic() // MONOTONIC — latency_ms
        pending[correlationIdValue] = entry
        let queue = opQueueLocked(opValue)
        let timeoutItem = DispatchWorkItem { [weak self] in
            self?.complete(correlationIdValue, Self.errorEnvelope(sessionId: sessionIdValue, correlationId: correlationIdValue, code: "TIMEOUT", message: "operation timed out"), .timeout)
        }
        entry.timeoutItem = timeoutItem
        stateLock.unlock()

        timeoutQueue.asyncAfter(deadline: .now() + .milliseconds(Int(timeoutMs)), execute: timeoutItem)
        queue.async { [weak self] in // serial per op => single-flight
            guard let self = self else { return }
            let envelope: String
            do {
                let responsePayload = try capability.handle(payload: payload)
                envelope = Self.okEnvelope(sessionId: sessionIdValue, correlationId: correlationIdValue, payload: responsePayload)
            } catch {
                // Do not leak internal error text to the web layer (info disclosure).
                envelope = Self.errorEnvelope(sessionId: sessionIdValue, correlationId: correlationIdValue, code: "INTERNAL_ERROR", message: "capability error")
            }
            self.complete(correlationIdValue, envelope, .resolved)
        }
    }

    /// The blank-detection set shared by both platforms. Explicit scalars, NOT
    /// `.whitespacesAndNewlines` / `Char.isWhitespace()`, because those two disagree in BOTH directions:
    /// Swift's set INCLUDES the non-breaking spaces (U+00A0, U+2007, U+202F) that Java excludes, and EXCLUDES
    /// the C0 separators (U+001C–U+001F) that Java includes. With the platform defaults a single-NBSP `op` would
    /// be blank here and VALID on Android, and a single U+001F the reverse.
    ///
    /// This is their UNION — the stricter reading — the right side to err on for fields that are UUIDs and op
    /// names, where no whitespace of any kind is legitimate. U+200B ZERO WIDTH SPACE is deliberately ABSENT:
    /// Unicode does not classify it as whitespace and neither platform ever did.
    private static let blankScalars: Set<Unicode.Scalar> = [
        "\u{09}", "\u{0A}", "\u{0B}", "\u{0C}", "\u{0D}",           // tab, LF, VT, FF, CR
        "\u{1C}", "\u{1D}", "\u{1E}", "\u{1F}",                     // C0 separators (Java-only)
        "\u{20}", "\u{85}", "\u{A0}",                               // space, NEL, NBSP (NBSP: Swift-only)
        "\u{1680}",                                                 // ogham space mark
        "\u{2000}", "\u{2001}", "\u{2002}", "\u{2003}", "\u{2004}", "\u{2005}",
        "\u{2006}", "\u{2007}", "\u{2008}", "\u{2009}", "\u{200A}", // en/em/thin/hair (U+2007: Swift-only)
        "\u{2028}", "\u{2029}",                                     // line + paragraph separators
        "\u{202F}", "\u{205F}", "\u{3000}",                         // narrow NBSP, medium math, ideographic
    ]

    /// True for nil/empty strings, or strings made ENTIRELY of `blankScalars`.
    /// Behaviorally identical to Kotlin's `isBlankParity`.
    static func isBlank(_ s: String?) -> Bool {
        guard let s = s, !s.isEmpty else { return true }
        return s.unicodeScalars.allSatisfy { blankScalars.contains($0) }
    }

    /// Whether the TOP-LEVEL JSON object in `json` declares the same key twice.
    ///
    /// `JSONSerialization` keeps the FIRST occurrence, kotlinx the LAST (measured, and pinned by
    /// `DuplicateJsonKeyTests`). Identical bytes therefore mean different things per platform — a duplicated
    /// `op` would run DIFFERENT capabilities, a duplicated `correlation_id` would dedup and session-pin under
    /// different ids — which is why such envelopes are refused rather than documented as accepted.
    ///
    /// **Fails OPEN by construction.** Anything it cannot confidently scan — not an object, truncated,
    /// malformed — returns `false` and is left to the real parser. This is a defense-in-depth check on the
    /// inbound path, and rejecting a valid payment would be a worse failure than missing an exotic one. Only
    /// depth 1 counts: a repeated key name inside `payload` is a different key. Mirrors Kotlin exactly.
    static func hasDuplicateTopLevelKeys(_ json: String) -> Bool {
        let chars = Array(json)
        var i = 0

        func skipWs() { while i < chars.count, chars[i].isWhitespace { i += 1 } }

        /// Read a JSON string starting at the opening quote; nil if malformed. Leaves `i` past the close.
        func readString() -> String? {
            guard i < chars.count, chars[i] == "\"" else { return nil }
            var out = ""
            i += 1
            while i < chars.count {
                let c = chars[i]
                if c == "\\" {
                    guard i + 1 < chars.count else { return nil }
                    out.append(c); out.append(chars[i + 1]) // keep escapes verbatim: only equality matters
                    i += 2
                } else if c == "\"" {
                    i += 1
                    return out
                } else {
                    out.append(c); i += 1
                }
            }
            return nil // unterminated
        }

        /// Skip one value (scalar, object or array), honoring nesting and strings. false if malformed.
        func skipValue() -> Bool {
            skipWs()
            guard i < chars.count else { return false }
            if chars[i] == "\"" { return readString() != nil }
            var depth = 0
            while i < chars.count {
                let c = chars[i]
                if c == "\"" {
                    if readString() == nil { return false }
                    continue
                } else if c == "{" || c == "[" {
                    depth += 1; i += 1
                } else if c == "}" || c == "]" {
                    if depth == 0 { return true } // belongs to the enclosing object
                    depth -= 1; i += 1
                    if depth == 0 { return true }
                } else if c == "," && depth == 0 {
                    return true
                } else {
                    i += 1
                }
            }
            return false
        }

        skipWs()
        guard i < chars.count, chars[i] == "{" else { return false } // not an object → parser's problem
        i += 1
        var seen = Set<String>()
        while true {
            skipWs()
            guard i < chars.count else { return false }   // truncated
            if chars[i] == "}" { return false }           // done, no duplicate found
            guard let key = readString() else { return false }
            if !seen.insert(key).inserted { return true } // DUPLICATE
            skipWs()
            guard i < chars.count, chars[i] == ":" else { return false }
            i += 1
            guard skipValue() else { return false }
            skipWs()
            if i < chars.count, chars[i] == "," { i += 1; continue }
            return false                                  // '}' or malformed: nothing more to check
        }
    }

    /// Terminal-absorbing first-writer-wins latch. The first of {resolve, timeout} wins
    /// and delivers on main; a later signal for a still-tracked id is dropped + emits
    /// `bridge.duplicate_result_dropped`; a signal for an untracked id emits `bridge.late_response`.
    private func complete(_ correlationId: String, _ envelope: String, _ reason: Reason) {
        stateLock.lock()
        // Post-close policy: teardown is a deliberate terminal state — a capability resolving after close() is
        // dropped in FULL silence (no delivery, no mislabeled late_response through a sink whose host is already
        // gone). Deliberately final: there is no telemetry event for use-after-close, since on iOS this only ever
        // happens after the deinit teardown.
        if closed { stateLock.unlock(); return }
        guard let entry = pending[correlationId] else {
            // Untracked id => a late signal for an already-purged/abandoned entry, enriched with `op` +
            // `latency_ms` + `origin` from the bounded recentMeta store (best-effort — absent if evicted/expired
            // under a flood). Read the meta UNDER the lock, then emit AFTER releasing it. The id is HASHED, never
            // raw (PII).
            let meta = recentMeta[correlationId]
            stateLock.unlock()
            let nowMono = monotonic()
            var fields: [String: Any] = ["correlation_id_hash": Sha256.hex(correlationId), "reason": reason.wire]
            if let meta = meta {
                fields["op"] = meta.op
                fields["latency_ms"] = Int64(max(0, nowMono - meta.startedAtMonoMs))
                fields["origin"] = meta.origin // purged vs reset_abandoned
            }
            telemetry.emit(event: TelemetryEvent.lateResponse, fields: fields)
            return
        }
        if !entry.terminal {
            entry.terminal = true
            entry.timeoutItem?.cancel() // winner: stop the racing timeout
            entry.completedAtMonoMs = monotonic() // MONOTONIC: TTL purge can't be defeated by a backward wall jump
            let deliver = entry.deliver
            stateLock.unlock()
            deliverOnMain(envelope, deliver)
        } else {
            let op = entry.op
            stateLock.unlock()
            telemetry.emit(
                event: TelemetryEvent.duplicateResultDropped,
                fields: ["op": op, "correlation_id_hash": Sha256.hex(correlationId), "reason": reason.wire, "severity": "warn"]
            )
        }
    }

    /// The single main-thread delivery hop. The explicit `closed` gate stops the early-validation error envelopes —
    /// produced OUTSIDE the lock with no closed re-check — from being delivered after close(); without it an
    /// unconditional `mainQueue.async` would deliver them, breaking "nothing is delivered after close()", which
    /// Kotlin keeps with the same gate.
    private func deliverOnMain(_ envelope: String, _ deliver: @escaping (String) -> Void) {
        stateLock.lock(); let isClosed = closed; stateLock.unlock()
        if isClosed { return }
        mainQueue.async { deliver(envelope) }
    }

    /// Lazily create the serial consumer queue for `op` (single-flight per `op`). Caller holds the lock.
    private func opQueueLocked(_ op: String) -> DispatchQueue {
        if let queue = opQueues[op] { return queue }
        let queue = DispatchQueue(label: "com.khipu.bridge.op.\(op)")
        opQueues[op] = queue
        return queue
    }

    /// Purge-on-insert: drop terminal entries older than `ttlMs` (MONOTONIC timing) so the pending map cannot
    /// grow unbounded. Caller holds the lock. Snapshots the stale set first (filter) so the
    /// `pending` mutation never races its own iteration.
    private func purgeStaleLocked() {
        let nowMono = monotonic()
        let stale = pending.filter { $0.value.terminal && nowMono - $0.value.completedAtMonoMs >= ttlMs }
        for (id, entry) in stale {
            // Remember op/startedAtMono before dropping: a slow capability resolving AFTER the timeout won and the
            // entry was purged is the canonical bridge.late_response case — this lets it carry op/latency_ms
            // with origin=purged (the genuine late signal, vs reset_abandoned).
            rememberMetaLocked(id, entry.op, entry.startedAtMonoMs, Self.originPurged)
            pending.removeValue(forKey: id)
        }
    }

    /// Record recently-terminal/abandoned metadata for late-response enrichment. Caller holds the lock. Mirrors
    /// DiagnosticsRecorder.putDebugIdLocked: purge-expired, re-insert at the tail (recency), evict eldest past the cap.
    private func rememberMetaLocked(_ correlationId: String, _ op: String, _ startedAtMonoMs: Double, _ origin: String) {
        purgeMetaLocked()
        if recentMeta[correlationId] != nil { recentMetaOrder.removeAll { $0 == correlationId } }
        recentMeta[correlationId] = MetaEntry(op: op, startedAtMonoMs: startedAtMonoMs, insertedAtMonoMs: monotonic(), origin: origin)
        recentMetaOrder.append(correlationId)
        while recentMetaOrder.count > Self.recentMetaCap {
            let eldest = recentMetaOrder.removeFirst()
            recentMeta.removeValue(forKey: eldest)
        }
    }

    private func purgeMetaLocked() {
        let nowMono = monotonic()
        let expired = recentMetaOrder.filter { key in
            guard let entry = recentMeta[key] else { return true }
            return nowMono - entry.insertedAtMonoMs >= Self.recentMetaTtlMs
        }
        for key in expired {
            recentMeta.removeValue(forKey: key)
            recentMetaOrder.removeAll { $0 == key }
        }
    }

    // --- test/diagnostic seams (@testable visibility) ---
    func pendingSize() -> Int {
        stateLock.lock(); defer { stateLock.unlock() }
        return pending.count
    }

    func purgeNow() {
        stateLock.lock(); defer { stateLock.unlock() }
        purgeStaleLocked()
    }

    /// Bounded recent-meta store size: a test asserts it stays ≤ cap under a flood of late signals.
    func recentMetaSize() -> Int {
        stateLock.lock(); defer { stateLock.unlock() }
        return recentMeta.count
    }

    /// Defensive-copy snapshot of the IN-FLIGHT operations, for `dumpDiagnostics()`. Returns a FRESH array of
    /// generated `PendingOperation`; mutating it never touches the live `pending` map. Only NON-terminal entries
    /// appear — a recently-terminal (within-TTL, dedup-lingering) entry is no longer a pending operation.
    /// `correlation_id` is HASHED (Sha256.hex, 12-char), NEVER raw (PII); `started_ago_ms` = now − startedAtMs;
    /// `timeout_ms` = the entry's bound. Reuses the existing pending-map lifecycle — no new store to bound.
    func snapshotPendingOperations() -> [PendingOperation] {
        stateLock.lock(); defer { stateLock.unlock() }
        let now = clock()
        return pending.compactMap { id, entry in
            guard !entry.terminal else { return nil }
            return PendingOperation(
                op: entry.op,
                correlationIdHash: Sha256.hex(id),
                // Clamp ≥0: clock() is wall-clock; a backward NTP/manual jump between startedAtMs and now would
                // otherwise surface a negative started_ago_ms.
                startedAgoMs: Int64(max(0, now - entry.startedAtMs)),
                timeoutMs: Int64(timeoutMs)
            )
        }
    }

    private static func okEnvelope(sessionId: String, correlationId: String, payload: [String: Any]) -> String {
        toJSON([
            "message_type": MessageType.response.rawValue,
            "session_id": sessionId,
            "correlation_id": correlationId,
            "result": EnvelopeResult.ok.rawValue,
            "payload": payload,
        ])
    }

    private static func errorEnvelope(sessionId: String, correlationId: String, code: String, message: String) -> String {
        toJSON([
            "message_type": MessageType.response.rawValue,
            "session_id": sessionId,
            "correlation_id": correlationId,
            "result": EnvelopeResult.error.rawValue,
            "payload": [:],
            "error": ["code": code, "message": message],
        ])
    }

    private static func toJSON(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let string = String(data: data, encoding: .utf8) else {
            return "{\"result\":\"error\"}"
        }
        return string
    }
}
