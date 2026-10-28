import Foundation

/// The ECDSA P-256 signing public keys baked into the SDK per environment (ADR-003). Each value is the environment's
/// signing key as **SPKI DER, base64**: the exact representation `openssl pkey -pubout -outform DER | base64` emits
/// and that iOS `P256.Signing.PublicKey(derRepresentation:)` and Android `X509EncodedKeySpec` consume directly (one
/// representation, both targets). Behaviorally identical to `KhipuSigningKeys.kt`. The `signingkeys:check` gate
/// requires the eight baked values to be identical across Kotlin and Swift, valid P-256 SPKI, and distinct across
/// slots.
///
/// Trust is single-level (NO `keys.json` / `signing_key_id`): `BundleSignatureVerifier` verifies a bundle's embedded
/// `//# khipu-sig:v1:` signature DIRECTLY against the baked key for the loaded origin's environment. The key is
/// selected by the request host, so the staging key only ever validates staging bytes and the prod key only prod
/// bytes. There is no certificate pinning: transport trust is TLS + DNS CAA (ADR-004, `security/TRANSPORT-TRUST.md`)
/// and integrity is the embedded signature; `OriginGate` only asks whether the page's bundle verified during that
/// load (ADR-221).
///
/// **Rotation.** Each environment bakes a `CURRENT` and an OPTIONAL pre-published `NEXT`, gated by a
/// per-environment `ACTIVATE_NEXT` flag. When `activateNext == true` and `NEXT` is present, `keysForHost` returns
/// `[CURRENT, NEXT]` so the bundle verifies against either key across the platform pod's signing-key switch;
/// otherwise it returns `[CURRENT]`. The verifier's multi-key shape is unchanged: the rotation is expressed entirely
/// by WHICH keys land in the list (see `selectKeys`). A baked key changes only with an SDK release, so `NEXT` is
/// pre-published ahead of the switch to cover merchants who update late. The promote sequence (generate, pre-publish
/// `NEXT`, switch the pod and flip `ACTIVATE_NEXT`, promote `NEXT` → `CURRENT`) is in
/// `docs/SECURITY-INCIDENT-RUNBOOK.md`.
enum KhipuSigningKeys {
    /// Staging signing public key (SPKI DER, base64) for `js.khipu-st.com`: staging signs
    /// `https://js.khipu-st.com/v1/kws.js` with its private half.
    static let stagingCurrent =
        "MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEI/yMQm3wg0I3rRqpttjmucU6Uz0t+WD79jpToWZWNAySWD4zskhQp8SZfBh5C3x+QM2hg3BROSbE3M15aIM2Lw=="

    /// Production signing public key (SPKI DER, base64) for `js.khipu.com`: production signs
    /// `https://js.khipu.com/v1/kws.js` with its private half.
    static let prodCurrent =
        "MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAElWnaCLQ/XDh2N9houumxHdbyBLseD4rdLURo4g1gw/UArQF0RhP7smxZ9Lhnx5xRyGuckgJEZhateavOf1jfZQ=="

    /// Staging signing public key, NEXT slot (SPKI DER, base64): a disposable, pre-published rotation key for
    /// `js.khipu-st.com` (`security/scripts/gen-kws-signing-keypair.sh staging`). Its PRIVATE half is
    /// khipu-platform's to wire into the staging pod when a rotation is exercised (out of this repo).
    static let stagingNext =
        "MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEdDd1IFSNQcsOh5sUxuO45r+MPAQ9jwDCdYvr2jl2sD0hwNLxkkh4LQy6ws50Fm39+cT2AcqUzIS2xibBZv9LUQ=="

    /// Production signing public key, NEXT slot (SPKI DER, base64). Baked from the first release on, so the
    /// production rotation window already exists. Its PRIVATE half is staged in the prod k8s Secret and does NOT
    /// sign yet: `prodActivateNext` stays `false` until the platform pod switches to it (step 3 of the promote
    /// sequence, `docs/SECURITY-INCIDENT-RUNBOOK.md`); until then production signs with `prodCurrent`.
    static let prodNext =
        "MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEMzeNr7DIOCKdNcyiegVwvmCx0MiML2hck27uSTLdA/N++vGUaEfsfa3b6Tx+DLRCQ1QS+gw4F4O4FZJWqnYyYw=="

    /// Per-environment rotation toggle. `false` = accept CURRENT only; `true` (with a non-empty NEXT) =
    /// accept CURRENT **or** NEXT (AC-SEC-005: with the toggle off, a NEXT-signed bundle does not verify). `false`
    /// on both until the platform pod actually switches to a NEXT, so each environment accepts its CURRENT only.
    /// Per-environment so a staging rotation never forces production to accept a NEXT it has not staged.
    static let stagingActivateNext = false
    static let prodActivateNext = false

    /// The host that serves each environment's `/v1/kws.js`. The intercept selects the baked key by the request
    /// host (staging key ↔ staging origin).
    static let stagingHost = "js.khipu-st.com"
    static let prodHost = "js.khipu.com"

    /// Compose the SPKI key list (base64) for a `current` key, an OPTIONAL `next` key, and an `activateNext`
    /// toggle (AC-SEC-005): `[current, next]` iff `activateNext && next` is present, else `[current]`. An
    /// absent NEXT (nil OR empty) is NEVER injected into the list: composing it cleanly out keeps the
    /// verifier's per-key attempts meaningful and fails closed for an environment with no NEXT staged. Pure +
    /// by-value so unit tests drive both states with generated test keys against the REAL composition.
    /// Twin of Kotlin `selectKeys`; kept SEPARATE from `keysForHost` so the `KhipuSigningKeys.keysForHost`
    /// reference in `BundleVerificationInterceptor` stays a single 1-arg function.
    static func selectKeys(current: String, next: String?, activateNext: Bool) -> [String] {
        if activateNext, let next = next, !next.isEmpty { return [current, next] }
        return [current]
    }

    /// The SPKI keys (base64) to verify a bundle served by `host` against — CURRENT, plus NEXT when this
    /// host's `ACTIVATE_NEXT` is on and a NEXT is staged (`selectKeys`). An unknown host yields an EMPTY
    /// list, so the verifier can only return `.invalid`/`.noMarker` → fail-closed: a bundle from an origin
    /// the SDK bakes no key for is never trusted.
    static func keysForHost(_ host: String) -> [String] {
        switch host {
        case stagingHost: return selectKeys(current: stagingCurrent, next: stagingNext, activateNext: stagingActivateNext)
        case prodHost: return selectKeys(current: prodCurrent, next: prodNext, activateNext: prodActivateNext)
        default: return []
        }
    }
}
