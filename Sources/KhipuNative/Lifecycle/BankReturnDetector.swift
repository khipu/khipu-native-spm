#if KHIPU_CAP_BANK_RETURN
import Foundation

/// The bank-app RETURN DETECTOR. Build-flag-gated by the `KHIPU_CAP_BANK_RETURN` active-compilation-condition
/// (default ON — defined in Package.swift unless the environment disables it). When the flag is OFF this entire
/// source compiles to nothing (`scripts/ios-budget-check.sh` scans the flag-OFF and flag-ON binaries' symbols to
/// prove it).
///
/// Behavioral twin of the Kotlin `BankReturnDetector` (cross-platform parity): same launch marker, same
/// correlation window, same single-shot consume-on-return, same telemetry fields, same observe-and-signal-never-
/// finish shape. NOT a `BridgeCapability` — the bank return has no bridge op (it is a manual OS resume, ADR-005),
/// so the bridge contract and its hash stay untouched. It records a launch marker when `AppLauncher` launches an
/// external app for the active payment (`recordLaunch`), and when a payment returns to the foreground
/// (`onForegroundReturn`) it CORRELATES that resume with a recent launch and, if recent, emits the
/// `lifecycle.bank_app_return_detected` SIGNAL. It NEVER alters the resume path (that runs regardless), NEVER
/// calls `finish()`, and NEVER fabricates a verdict.
///
/// Thread-safe: `recordLaunch` runs on the bridge dispatch queue (from `AppLauncher.handle`) while
/// `onForegroundReturn` runs on main (the lifecycle callback) — the marker is guarded by `lock`. Telemetry is
/// emitted OUTSIDE the lock (the deferred-telemetry house rule); the sink contract is "MUST NOT throw".
final class BankReturnDetector {
    private let telemetry: TelemetrySink
    // MONOTONIC clock (CLOCK_MONOTONIC, matching the coordinator) — injected so tests drive both the within-window
    // and stale-marker branches deterministically.
    private let monotonicMs: () -> Double
    // A foreground return within this long after a launch counts as a bank return. Generous (a real authorization
    // round trip is seconds-to-minutes); only rejects a stale marker. Not load-bearing (consumed on each return).
    private let correlationWindowMs: Double
    private let lock = NSLock()
    /// The monotonic instant of the most recent external-app launch, or nil if none is pending (consumed on each
    /// foreground return). Guarded by `lock`.
    private var launchMarkerMonoMs: Double?

    init(
        telemetry: TelemetrySink,
        monotonicMs: @escaping () -> Double = { Double(clock_gettime_nsec_np(CLOCK_MONOTONIC)) / 1_000_000 },
        correlationWindowMs: Double = 10 * 60 * 1000 // 10 min — generous; mirrors Kotlin
    ) {
        self.telemetry = telemetry
        self.monotonicMs = monotonicMs
        self.correlationWindowMs = correlationWindowMs
    }

    /// `AppLauncher` launched an external app for the active payment — record the launch instant so the next
    /// foreground return can be recognized as a bank-app return. Runs on the bridge dispatch queue.
    func recordLaunch() {
        let now = monotonicMs()
        lock.lock(); defer { lock.unlock() }
        launchMarkerMonoMs = now
    }

    /// A payment returned to the foreground (called from the coordinator's `appReturnedToForeground()` for the
    /// ACTIVE non-terminal payment). If it correlates with a recent launch marker, emit
    /// `lifecycle.bank_app_return_detected` and return true; otherwise (no marker, or stale past the window) return
    /// false and emit nothing. The marker is CONSUMED on every return (single-shot). `operationIdHash` is the
    /// sha256.slice(0,12) of the NATIVE khp_op_ id (never the merchant id, which telemetry must not carry). SIGNAL
    /// ONLY: this never touches the resume path, the latch, or `finish()`.
    @discardableResult
    func onForegroundReturn(operationIdHash: String) -> Bool {
        lock.lock()
        let marker = launchMarkerMonoMs
        launchMarkerMonoMs = nil // consume — one return per launch (and clear a stale marker)
        lock.unlock()
        guard let launchMono = marker else { return false }
        let latencyMs = Int64(max(0, monotonicMs() - launchMono))
        if Double(latencyMs) > correlationWindowMs { return false } // a stale marker is not a bank-app return
        // Emit OUTSIDE the lock (deferred-telemetry discipline). Hashed NATIVE id only.
        telemetry.emit(
            event: TelemetryEvent.bankAppReturnDetected,
            fields: ["operation_id_hash": operationIdHash, "latency_ms": latencyMs]
        )
        return true
    }
}
#endif
