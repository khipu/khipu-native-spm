import Foundation
import CryptoKit

/// Verifies the embedded self-signature of a `kws.js` bundle (ADR-003: the signature rides inside the bundle; there
/// is no separate manifest). The format below is byte-exact, as an openssl sign→verify round-trip produces it.
/// Behaviorally identical to `BundleSignatureVerifier.kt`.
///
/// **Wire format.** The served bytes are `<body>` + `"\n//# khipu-sig:v1:"` + `<sig-base64url-no-pad>` +
/// `"\n"`, where `<sig>` is the **ECDSA P-256 / SHA-256** signature of `<body>`, **DER**-encoded
/// (~70–72 bytes). `v1` = ECDSA P-256/SHA-256/DER. The marker is an inert JS line comment.
///
/// **Verification (AC-SEC-001).** Find the LAST `\n//# khipu-sig:v1:` separator; `body = bytes[:idx]`;
/// the trailer up to the next `\n` is the signature, base64url-decoded (re-padded) → DER sig; verify
/// ECDSA P-256 over SHA-256(body) against the baked SPKI key(s) (CURRENT, then NEXT). A valid signature
/// passes, a tampered body fails, a wrong key fails, a missing marker is `.noMarker`.
///
/// **CryptoKit, iOS 15+, zero dependency.** `verify` NEVER throws: a malformed key, signature, or marker is a
/// fail-closed decision, not an error. `isValidSignature(_:for:)` hashes the body with SHA-256 internally,
/// matching Android's explicit `SHA256withECDSA`.
final class BundleSignatureVerifier {

    /// The verifier's decision. `.invalid` and `.noMarker` BOTH block the load (AC-SEC-004: "does not validate …
    /// OR carries no signature marker"); kept distinct for diagnostics only. Twin of Kotlin
    /// `BundleSignatureVerifier.Result`.
    enum Result { case valid, invalid, noMarker }

    /// Verify `bundleBytes` against any of `spkiKeysBase64` (SPKI DER, base64): `.valid` iff the embedded
    /// signature validates against at least one key (CURRENT, plus NEXT during a rotation); `.invalid`
    /// if a marker is present but no key validates (tampered body / wrong key / malformed sig / empty list);
    /// `.noMarker` if there is no `//# khipu-sig:v1:` trailer at all.
    func verify(bundleBytes: Data, spkiKeysBase64: [String]) -> Result {
        guard let sepRange = Self.lastRange(of: Self.separator, in: bundleBytes) else { return .noMarker }
        let body = bundleBytes.subdata(in: bundleBytes.startIndex ..< sepRange.lowerBound)
        // The signature is the trailer bytes from after the separator up to the next LF (the format always
        // appends a trailing "\n"; a no-LF trailer is tolerated — take the whole remainder).
        let afterSep = bundleBytes.subdata(in: sepRange.upperBound ..< bundleBytes.endIndex)
        let sigBytes: Data
        if let lf = afterSep.firstIndex(of: 0x0A) {
            sigBytes = afterSep.subdata(in: afterSep.startIndex ..< lf)
        } else {
            sigBytes = afterSep
        }
        guard let sigASCII = String(data: sigBytes, encoding: .ascii),
              let derSig = Base64Url.decode(sigASCII), !derSig.isEmpty else { return .invalid }
        // Canonical-DER pre-check, mirroring Kotlin. CryptoKit already rejects every case this catches, so on
        // iOS it changes no verdict today; it is here because behavioral parity is the invariant, not an accident
        // of two libraries happening to agree. Android needs the check for real: its provider accepts
        // non-canonical DER on API 21 while rejecting it on 25+. Keeping the twin means the decision lives in OUR
        // code on both platforms, and that a future CryptoKit relaxation cannot silently reintroduce the
        // divergence; the `security/der-parity/` corpus pins the same verdict on every engine.
        guard Self.isCanonicalEcdsaDer(derSig) else { return .invalid }
        for keyB64 in spkiKeysBase64 where Self.verifyOne(body: body, derSig: derSig, spkiBase64: keyB64) {
            return .valid
        }
        return .invalid
    }

    private static func verifyOne(body: Data, derSig: Data, spkiBase64: String) -> Bool {
        guard let spki = Base64Url.decode(spkiBase64),
              let pub = try? P256.Signing.PublicKey(derRepresentation: spki),
              let sig = try? P256.Signing.ECDSASignature(derRepresentation: derSig) else {
            // A bad SPKI key or a non-DER signature is a fail-closed `false`, never thrown out of the verifier.
            return false
        }
        return pub.isValidSignature(sig, for: body)
    }

    /// True iff `der` is a strictly canonical ECDSA signature: `SEQUENCE { INTEGER r, INTEGER s }`, the
    /// SEQUENCE length covering exactly the buffer, each INTEGER minimally encoded and non-negative.
    ///
    /// Rejects a redundant leading `0x00` (the API-21 divergence on Android), trailing bytes after the
    /// SEQUENCE, and a declared length that disagrees with the content. Twin of Kotlin
    /// `BundleSignatureVerifier.isCanonicalEcdsaDer` — the two must change together.
    ///
    /// Encoding-only: it says nothing about the VALUES of r/s, so high-S stays acceptable (all three engines
    /// accept it; rejecting it would change behaviour rather than align it). Single-byte lengths only — a
    /// P-256 signature is ~70-72 bytes, so a DER long-form length here is malformed by construction.
    static func isCanonicalEcdsaDer(_ der: Data) -> Bool {
        let b = [UInt8](der)
        guard b.count >= minDerSize, b[0] == derSequence else { return false }
        guard Int(b[1]) == b.count - 2 else { return false } // trailing bytes AND wrong declared length
        var pos = 2
        for _ in 0 ..< 2 { // exactly two INTEGERs, r then s
            guard pos + 2 <= b.count, b[pos] == derInteger else { return false }
            let len = Int(b[pos + 1])
            let valueStart = pos + 2
            guard len > 0, valueStart + len <= b.count else { return false }
            let first = b[valueStart]
            guard first & 0x80 == 0 else { return false } // negative: these INTEGERs are unsigned values
            if first == 0x00 {
                // A leading zero is legal ONLY to keep a high-bit value positive; otherwise it is non-minimal.
                guard len > 1, b[valueStart + 1] & 0x80 != 0 else { return false }
            }
            pos = valueStart + len
        }
        return pos == b.count
    }

    /// Last range of `needle` in `haystack`, or nil. The LAST occurrence so a signature-shaped string inside
    /// the bundle body can never be mistaken for the real trailer.
    private static func lastRange(of needle: Data, in haystack: Data) -> Range<Data.Index>? {
        guard !needle.isEmpty, haystack.count >= needle.count else { return nil }
        var i = haystack.endIndex - needle.count
        while i >= haystack.startIndex {
            var match = true
            for j in 0 ..< needle.count where haystack[i + j] != needle[needle.startIndex + j] {
                match = false
                break
            }
            if match { return i ..< (i + needle.count) }
            i -= 1
        }
        return nil
    }

    // The exact separator bytes: LF + JS line comment + format version + colon (byte-exact).
    private static let separator = Data("\n//# khipu-sig:v1:".utf8)

    // Canonical-DER tags + the smallest structurally possible two-INTEGER SEQUENCE (30 04 02 01 xx 02 01 xx).
    private static let derSequence: UInt8 = 0x30
    private static let derInteger: UInt8 = 0x02
    private static let minDerSize = 8
}

/// A tiny, dependency-free base64 decoder that accepts BOTH the standard (`+/`, the SPKI keys) and the
/// URL-safe (`-_`, the signature trailer) alphabets, padded or not (the trailer is unpadded). Twin of Kotlin
/// `Base64Url`; uses Foundation's `Data(base64Encoded:)` after normalising.
enum Base64Url {
    static func decode(_ s: String) -> Data? {
        var str = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while str.hasSuffix("=") { str.removeLast() } // strip any existing padding…
        switch str.count % 4 { // …then re-pad to a multiple of 4
        case 2: str += "=="
        case 3: str += "="
        case 1: return nil // an invalid base64 length
        default: break
        }
        return Data(base64Encoded: str)
    }
}
