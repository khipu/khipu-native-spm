import Foundation
import CryptoKit

/// Shared lowercase-hex SHA-256 helper. The ONLY home for the 12-char id hashes that telemetry and diagnostics
/// carry (`correlation_id_hash = sha256(correlation_id).slice(0,12)`, and `operation_id_hash` the same way):
/// support correlates a ticket WITHOUT the SDK ever exposing a raw id (PII-adjacent).
///
/// Load-bearing invariant: **byte-for-byte Kotlin/Swift parity** — the same id MUST hash to the same prefix
/// on both platforms (`DiagnosticsTests` pins it with a fixed vector, like the `Base32` parity vectors).
/// No dependency: `CryptoKit.SHA256` is a system framework (iOS 13+, below the iOS 15 floor). Mirrors `Sha256.kt`.
enum Sha256 {
    /// Lowercase hex SHA-256 of `input` (UTF-8), truncated to the first `chars` chars (default 12).
    static func hex(_ input: String, chars: Int = 12) -> String {
        let digest = SHA256.hash(data: Data(input.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return String(hex.prefix(chars))
    }
}
