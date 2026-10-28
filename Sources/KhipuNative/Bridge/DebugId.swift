import Foundation
import Security

/// Native **public-facing** debug-id generator (format: architecture.md:580).
/// Produces `khp_<base32(8)>` — the `khp_` prefix + `Base32` of 8 random bytes (64 bits → 13 base32 chars),
/// matching `^khp_[a-z2-7]{13}$`, unique per process.
///
/// `debug_id` is the OPAQUE handle that ties a `KhipuPaymentError` Sofía sees to internal logs WITHOUT ever
/// exposing the `correlation_id` (which is PII-adjacent): support looks it up via the recorder's bounded
/// `debugIdMap` (`debug_id` → `correlation_id`, cap 200 / TTL 1h, `DiagnosticsRecorder`). It is **DISTINCT**
/// from the `khp_op_<base32(8)>` internal operation id (`OperationId`): different prefix, different role.
///
/// Reuses the SINGLE shared `Base32` encoder — NO second encoder.
/// Randomness is **injected** (house DI pattern, like `clock`/`timeoutMs`/`OperationId.randomBytes`) so tests
/// are deterministic; the default is `Security.SecRandomCopyBytes`. Pure given its RNG. Mirrors `DebugId.kt`.
struct DebugId {
    static let prefix = "khp_"
    private static let byteLen = 8

    private let randomBytes: (Int) -> [UInt8]

    init(randomBytes: @escaping (Int) -> [UInt8] = DebugId.secureRandomBytes) {
        self.randomBytes = randomBytes
    }

    /// Generate a fresh `khp_<base32(8)>`.
    func generate() -> String {
        DebugId.prefix + Base32.encode(randomBytes(DebugId.byteLen))
    }

    private static func secureRandomBytes(_ n: Int) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: n)
        let status = SecRandomCopyBytes(kSecRandomDefault, n, &bytes)
        // A CSPRNG failure is catastrophic and astronomically rare; fail loudly rather than emit a
        // predictable id. Not on the handle() hot path (debug_id is generated at error-translation time).
        precondition(status == errSecSuccess, "SecRandomCopyBytes failed: \(status)")
        return bytes
    }
}
