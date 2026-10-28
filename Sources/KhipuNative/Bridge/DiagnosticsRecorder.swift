import Foundation
import BridgeGenerated

/// Local, in-memory diagnostics state behind `dumpDiagnostics()`. Holds:
///  - `recent_errors`: a **FIFO ring buffer of ≤ recentErrorsCap** (default 5) — the most recent translated errors.
///  - `capability_latencies`: per-`op` p50/p95 over a **bounded sliding window** + a total `sample_count`.
///  - the debug-id map: a **bounded** `debug_id` → `correlation_id` map (cap 200, TTL 1h) so support can
///    correlate a ticket's `debug_id` back to internal logs WITHOUT exposing the raw `correlation_id`.
///
/// **Local-only:** records to memory + read by `dumpDiagnostics()`; sends NOTHING to khipu.
/// **Thread-safe:** every mutation/read takes `lock`. Callers invoke it only AFTER releasing their own locks (the
/// payment coordinator records from its terminal path, outside its lock), so this lock never nests inside another.
/// **Bounded growth:** every store is capped — the ring (5), the per-op window, the debug-id map (cap + TTL).
/// Fed by the payment coordinator's terminal path: every error → `recordError`, a success → `recordLatency`.
/// Mirrors DiagnosticsRecorder.kt.
final class DiagnosticsRecorder {
    private struct DebugIdEntry { let correlationId: String; let insertedAtMs: Double }

    private let lock = NSLock()
    private var recentRing: [RecentError] = [] // FIFO ring, ≤ recentErrorsCap
    private var latencySamples: [String: [Int64]] = [:] // per-op bounded window
    private var sampleCounts: [String: Int64] = [:] // per-op total observed (≥ window size)
    private var debugIds: [String: DebugIdEntry] = [:] // bounded by cap + TTL
    private var debugIdOrder: [String] = [] // insertion order for FIFO eviction

    private let clock: () -> Double
    private let recentErrorsCap: Int
    private let debugIdCap: Int
    private let debugIdTtlMs: Double
    private let latencyWindow: Int

    init(
        clock: @escaping () -> Double = { Date().timeIntervalSince1970 * 1000 },
        recentErrorsCap: Int = 5,
        debugIdCap: Int = 200,
        debugIdTtlMs: Double = 60 * 60 * 1000, // 1 hour
        latencyWindow: Int = 100
    ) {
        self.clock = clock
        self.recentErrorsCap = recentErrorsCap
        self.debugIdCap = debugIdCap
        self.debugIdTtlMs = debugIdTtlMs
        self.latencyWindow = latencyWindow
    }

    /// Record a translated `error` for `op` (correlated to `correlationId`, with `latencyMs` latency). Pushes a
    /// `RecentError` to the FIFO ring (dropping the oldest past the cap) and maps `error.debugId` ->
    /// `correlationId` in the bounded debug-id map. The raw `correlationId` lives ONLY in the internal debug-id
    /// map (never surfaced); `recent_errors` carries the `debug_id`, never the correlation_id.
    func recordError(op: String, correlationId: String, error: KhipuPaymentError, latencyMs: Int64) {
        // The single shared timestamp formatter (Diagnostics.iso8601): fixed-millis ISO-8601, byte-identical across
        // platforms. Computed BEFORE the lock, to keep the work under it minimal.
        let timestamp = Diagnostics.iso8601(clock())
        lock.lock(); defer { lock.unlock() }
        recentRing.append(RecentError(timestamp: timestamp, op: op, publicCode: error.code, debugId: error.debugId, latencyMs: latencyMs))
        while recentRing.count > recentErrorsCap { recentRing.removeFirst() }
        putDebugIdLocked(error.debugId, correlationId)
    }

    /// Record one capability-handle latency sample (ms) for `op` into the bounded per-op window.
    func recordLatency(op: String, ms: Int64) {
        lock.lock(); defer { lock.unlock() }
        var window = latencySamples[op] ?? []
        window.append(ms)
        while window.count > latencyWindow { window.removeFirst() }
        latencySamples[op] = window
        sampleCounts[op] = (sampleCounts[op] ?? 0) + 1
    }

    /// Defensive-copy of the FIFO ring (≤ recentErrorsCap); mutating it does not touch the recorder.
    func recentErrorsSnapshot() -> [RecentError] {
        lock.lock(); defer { lock.unlock() }
        return recentRing
    }

    /// Defensive-copy of the per-op p50/p95/sample_count (computed over the current bounded windows).
    func capabilityLatenciesSnapshot() -> [String: CapabilityLatency] {
        lock.lock(); defer { lock.unlock() }
        var out: [String: CapabilityLatency] = [:]
        for (op, window) in latencySamples {
            let sorted = window.sorted()
            out[op] = CapabilityLatency(
                p50Ms: Self.percentile(sorted, 50),
                p95Ms: Self.percentile(sorted, 95),
                sampleCount: sampleCounts[op] ?? 0
            )
        }
        return out
    }

    /// Support lookup: the `correlation_id` for a `debugId`, or nil if unknown/expired (purges expired first).
    func correlationId(forDebugId debugId: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        purgeExpiredLocked()
        return debugIds[debugId]?.correlationId
    }

    private func putDebugIdLocked(_ debugId: String, _ correlationId: String) {
        purgeExpiredLocked()
        if debugIds[debugId] != nil { debugIdOrder.removeAll { $0 == debugId } } // re-insert at the tail (recency on write)
        debugIds[debugId] = DebugIdEntry(correlationId: correlationId, insertedAtMs: clock())
        debugIdOrder.append(debugId)
        while debugIdOrder.count > debugIdCap {
            let eldest = debugIdOrder.removeFirst()
            debugIds.removeValue(forKey: eldest)
        }
    }

    private func purgeExpiredLocked() {
        let now = clock()
        let expired = debugIdOrder.filter { key in
            guard let entry = debugIds[key] else { return true }
            return now - entry.insertedAtMs >= debugIdTtlMs
        }
        for key in expired {
            debugIds.removeValue(forKey: key)
            debugIdOrder.removeAll { $0 == key }
        }
    }

    /// Nearest-rank percentile (index = ceil(p/100 · n) − 1), Kotlin/Swift-identical. Empty → 0.
    private static func percentile(_ sortedAsc: [Int64], _ p: Int) -> Int64 {
        if sortedAsc.isEmpty { return 0 }
        let rank = min(max(Int(ceil(Double(p) / 100.0 * Double(sortedAsc.count))), 1), sortedAsc.count)
        return sortedAsc[rank - 1]
    }
}
