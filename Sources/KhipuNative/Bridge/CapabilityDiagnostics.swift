import Foundation

/// The build-flag DEGRADATION diagnostic emitter. ALWAYS-PRESENT code (never `#if`'d out): when a per-capability
/// build flag is OFF, the gated component itself is compiled out (`#if` on iOS, R8 on Android), so it cannot emit
/// its own "I am disabled" diagnostic — this stand-in, at the construction site, emits it instead.
///
/// Exactly symmetric to how the always-present `BridgeDispatcher` (not the unavailable capability) emits
/// `bridge.capability_unavailable` for the OS-floor case: that one is ENVIRONMENTAL, this one is a deliberate
/// BUILD-TIME choice. Same `TelemetrySink` seam (no-op by default; a recording sink in tests), same field shape.
/// Field naming uses `op`, never `capability_id` — a native-only lifecycle component has no `_v1` wire op.
/// Behavioral twin of the Kotlin `CapabilityDiagnostics`.
enum CapabilityDiagnostics {
    /// The bank-app return detector's capability id — the `op` value of its degradation diagnostic and the `<id>`
    /// of its build flag (`khipu.cap.bankReturnDetector.enabled`). NOT a `_v1` wire op.
    static let capBankReturnDetector = "bankReturnDetector"

    /// The frozen `reason_code` for a build-flag disable (distinct from capability_unavailable's "os_unsupported").
    static let reasonBuildFlagDisabled = "build_flag_disabled"

    /// Emit `bridge.capability_disabled` ONCE for a build-flag-disabled native `capabilityId`. The caller guards
    /// the call with the build flag (`#else`), so it fires exactly once at SDK init on the OFF path only. Mirrors
    /// the dispatcher's `capability_unavailable` fields verbatim (op / reason_code / os_version / os_version_unit).
    static func emitCapabilityDisabled(_ telemetry: TelemetrySink, capabilityId: String, osVersion: Int) {
        telemetry.emit(
            event: TelemetryEvent.capabilityDisabled,
            fields: [
                "op": capabilityId,
                "reason_code": reasonBuildFlagDisabled,
                "os_version": osVersion,
                "os_version_unit": "ios_major_version",
            ]
        )
    }
}
