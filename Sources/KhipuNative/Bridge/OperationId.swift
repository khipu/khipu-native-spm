import Foundation
import Security

/// Native **internal** operation-id generator. Produces `khp_op_<base32(8)>` — the `khp_op_` prefix + `Base32` of
/// 8 random bytes (64 bits → 13 base32 chars), matching `^khp_op_[a-z2-7]{13}$`, unique per process. The format is
/// frozen.
///
/// This id is **DISTINCT** from the merchant `operationId`: the merchant id is passed through the bridge
/// unvalidated; THIS is the internal handle the payment coordinator keys its operation records on, and the id
/// behind the `operation_id_hash` that `bridge.orphan_response` carries. Randomness is **injected** (like
/// `clock`/`timeoutMs`) so tests are deterministic; the default is `Security.SecRandomCopyBytes`. The generator is
/// pure given its RNG — no global singletons in the logic. Mirrors `OperationId.kt` exactly.
struct OperationId {
    static let prefix = "khp_op_"
    private static let byteLen = 8

    private let randomBytes: (Int) -> [UInt8]

    init(randomBytes: @escaping (Int) -> [UInt8] = OperationId.secureRandomBytes) {
        self.randomBytes = randomBytes
    }

    /// Generate a fresh `khp_op_<base32(8)>`.
    func generate() -> String {
        OperationId.prefix + Base32.encode(randomBytes(OperationId.byteLen))
    }

    private static func secureRandomBytes(_ n: Int) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: n)
        let status = SecRandomCopyBytes(kSecRandomDefault, n, &bytes)
        // A CSPRNG failure is catastrophic and astronomically rare; fail loudly rather than emit a
        // predictable id. Not on the dispatcher's hot path: the payment coordinator calls it once per payment.
        precondition(status == errSecSuccess, "SecRandomCopyBytes failed: \(status)")
        return bytes
    }
}
