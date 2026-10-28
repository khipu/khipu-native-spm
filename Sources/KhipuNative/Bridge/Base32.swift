import Foundation

/// RFC 4648 base32 encoder — lowercase alphabet (`a–z2–7`), NO padding. A shared, single-definition primitive:
/// the operation id (`OperationId`, `khp_op_…`) and the `debug_id` (`DebugId`, `khp_<base32(8)>`) both encode
/// 8 random bytes through THIS encoder. Keeping ONE encoder means two copies of the same transform cannot drift
/// apart.
///
/// The load-bearing invariant is **byte-for-byte Kotlin/Swift parity**: identical input bytes MUST encode
/// to identical strings on both platforms (`OperationIdTests` pins it with a fixed-vector test, including
/// the all-`0xFF` case whose trailing `'6'` proves the zero-pad of the final 4 bits). 8 bytes → 13 chars.
///
/// No dependency: plain arithmetic, only Foundation. Mirrors `Base32.kt` exactly.
enum Base32 {
    private static let alphabet = Array("abcdefghijklmnopqrstuvwxyz234567")

    /// Encode `bytes` as lowercase RFC-4648 base32 with no padding.
    static func encode(_ bytes: [UInt8]) -> String {
        var out = [Character]()
        out.reserveCapacity((bytes.count * 8 + 4) / 5)
        // `acc` holds only the not-yet-emitted low bits (< 5 carried + 8 added = < 13 bits → Int is ample);
        // we mask off already-emitted high bits each byte so the accumulator can never overflow.
        var acc = 0
        var bits = 0
        for b in bytes {
            acc = (acc << 8) | Int(b)
            bits += 8
            while bits >= 5 {
                bits -= 5
                out.append(alphabet[(acc >> bits) & 0x1F])
            }
            acc &= (1 << bits) - 1 // drop emitted bits; keep only the residual (< 5) bits
        }
        if bits > 0 {
            // Final partial group: left-align the residual bits in a 5-bit slot (zero-pad the low bits).
            out.append(alphabet[(acc << (5 - bits)) & 0x1F])
        }
        return String(out)
    }
}
