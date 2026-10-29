import Foundation
import BridgeGenerated

/// Output format of `KhipuPayment.dumpDiagnostics(format:)`: `.json` returns the typed `DiagnosticsDump`
/// object, `.text` a plain-text rendering of it.
public enum DiagnosticsFormat { case json, text }

/// Assembles the snake_case `DiagnosticsDump` from the live dispatcher snapshot + the `DiagnosticsRecorder`, plus
/// static SDK/contract metadata. The SHAPE is generated (parity-checked keys); THIS assembly is the hand-written
/// native glue. Local-only: reads in-memory state, sends nothing to khipu. Mirrors `Diagnostics.kt`.
enum Diagnostics {
    // sdkVersion is the version this source is published as: scripts/spm-mirror-assemble.sh stamps the release
    // version into the SPM mirror's copy, and the release verifies it. In-repo builds report 0.0.0-LOCAL.
    // contract_version is the envelope version in v1, resolved from the GENERATED ContractConstants.envelopeVersion
    // (one source, no hand-mirror to drift); bridge/codegen/src/governance-gate.ts cross-checks
    // CONTRACT_VERSION.ts == contract-version.json golden == ContractConstants.kt == .swift.
    static let sdkVersion = "1.0.2"
    static let contractVersion = ContractConstants.envelopeVersion

    static func build(
        dispatcher: BridgeDispatcher,
        recorder: DiagnosticsRecorder,
        webViewEngine: WebViewEngine,
        clock: () -> Double = { Date().timeIntervalSince1970 * 1000 },
        sdkVersion: String = Diagnostics.sdkVersion,
        contractVersion: String = Diagnostics.contractVersion
    ) -> DiagnosticsDump {
        DiagnosticsDump(
            timestamp: iso8601(clock()),
            sdkVersion: sdkVersion,
            contractVersion: contractVersion,
            webViewEngine: webViewEngine,
            pendingOperations: dispatcher.snapshotPendingOperations(),
            recentErrors: recorder.recentErrorsSnapshot(),
            capabilityLatencies: recorder.capabilityLatenciesSnapshot()
        )
    }

    /// Stable, grep-friendly multi-line text form (`format: .text`), meant to be pasted into a support chat or
    /// ticket without a JSON viewer. Deterministic: pending ops sorted by hashed id, latencies by op; recent_errors
    /// stay in ring (chronological) order. NO raw `correlation_id`.
    static func toText(_ dump: DiagnosticsDump) -> String {
        var lines: [String] = []
        lines.append("khipu-diagnostics")
        lines.append("timestamp=\(dump.timestamp)")
        lines.append("sdk_version=\(dump.sdkVersion)")
        lines.append("contract_version=\(dump.contractVersion)")
        lines.append("web_view_engine=\(dump.webViewEngine.name)/\(dump.webViewEngine.version)")
        lines.append("pending_operations=\(dump.pendingOperations.count)")
        for p in dump.pendingOperations.sorted(by: { $0.correlationIdHash < $1.correlationIdHash }) {
            lines.append("  op=\(p.op) correlation_id_hash=\(p.correlationIdHash) started_ago_ms=\(p.startedAgoMs) timeout_ms=\(p.timeoutMs)")
        }
        lines.append("recent_errors=\(dump.recentErrors.count)")
        for e in dump.recentErrors {
            lines.append("  timestamp=\(e.timestamp) op=\(e.op) public_code=\(e.publicCode.rawValue) debug_id=\(e.debugId) latency_ms=\(e.latencyMs)")
        }
        lines.append("capability_latencies=\(dump.capabilityLatencies.count)")
        for op in dump.capabilityLatencies.keys.sorted() {
            let l = dump.capabilityLatencies[op]!
            lines.append("  op=\(op) p50_ms=\(l.p50Ms) p95_ms=\(l.p95Ms) sample_count=\(l.sampleCount)")
        }
        return lines.joined(separator: "\n")
    }

    /// The pure .json/.text selection behind `KhipuPayment.dumpDiagnostics(format:)`, kept as its own seam:
    /// `KhipuPayment` needs a live WebView, so its `dumpDiagnostics` wrapper is not unit-testable — this selection
    /// IS unit-tested. Mirrors `Diagnostics.render` (Kotlin).
    static func render(_ dump: DiagnosticsDump, format: DiagnosticsFormat) -> Any {
        switch format {
        case .json: return dump
        case .text: return toText(dump)
        }
    }

    /// ISO-8601 UTC instant, FIXED 3-digit millisecond precision — the single timestamp formatter for diagnostics
    /// (the recorder calls this too). `.withFractionalSeconds` always emits `.SSS`; the Kotlin leg matches via a
    /// `…ss.SSS'Z'` pattern (not `Instant.toString()`, which drops `.000` for whole-second instants).
    static func iso8601(_ ms: Double) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date(timeIntervalSince1970: ms / 1000))
    }
}
