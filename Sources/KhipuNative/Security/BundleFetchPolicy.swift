import Foundation

/// The PURE transport rules for the SDK's own `/v1/kws.js` fetch: a byte ceiling and an origin pin, because the
/// fetch happens BEFORE any signature check and its body is attacker-influenceable. Behaviorally identical to
/// `BundleFetchPolicy.kt`; see that file for the full rationale.
///
/// **MECHANICAL DIVERGENCE from Kotlin (comment-pinned).** Android reads the response body synchronously off
/// an `InputStream`, so its twin can express the ceiling as one bounded read. `URLSession`'s convenience
/// `dataTask(with:completionHandler:)` hands over a body that is ALREADY fully buffered in memory — checking
/// its size there would report the OOM rather than prevent it. So iOS applies the same two rules through
/// `URLSessionDataDelegate` callbacks instead: `refusal(for:requestHost:)` runs at `didReceive response`
/// (before a single body byte arrives) and `BoundedBody` accumulates `didReceive data` chunks under the
/// ceiling, cancelling the task the moment it is crossed. Same behavior, different plumbing — the parity rule
/// the house enforces is behavioral.
enum BundleFetchPolicy {
    /// The ceiling on a fetched bundle body, in bytes. A signed `kws.js` is tens of KB (about 19 KB on staging and
    /// 24 KB in production), so 2 MiB leaves roughly two orders of magnitude of headroom while still bounding the
    /// allocation. An oversize body is refused outright, never truncated-and-verified (that would hand the verifier
    /// bytes the server never signed).
    static let maxBundleBytes = 2 * 1024 * 1024

    /// Accumulates `URLSessionDataDelegate` body chunks under `maxBundleBytes`.
    ///
    /// The check is on the RUNNING TOTAL, not per chunk: a hostile endpoint streams a huge body as many
    /// ordinary-sized chunks, so a per-chunk ceiling bounds nothing. Once the total crosses, the buffer is
    /// released and every later chunk refused — the caller cancels the task, but chunks already in flight
    /// must not keep growing the allocation this exists to bound.
    struct BoundedBody {
        private(set) var bytes = Data()
        private(set) var overflowed = false

        /// Append a chunk; returns `false` once the ceiling is crossed (the caller cancels and reports
        /// `too_large`).
        mutating func append(_ chunk: Data) -> Bool {
            if overflowed { return false }
            if bytes.count + chunk.count > BundleFetchPolicy.maxBundleBytes {
                overflowed = true
                bytes = Data()
                return false
            }
            bytes.append(chunk)
            return true
        }
    }

    /// Whether a DECLARED body length is already over the ceiling. `URLSession` reports
    /// `NSURLSessionTransferSizeUnknown` (-1) when the server declares no `Content-Length`; that is NOT an
    /// overflow — `BoundedBody` covers it while the bytes arrive.
    static func exceedsCap(_ byteCount: Int64) -> Bool { byteCount > Int64(maxBundleBytes) }

    /// Whether the host that actually served the body is the host the SDK addressed. Host EQUALITY
    /// (case-insensitive — DNS names are), never a suffix match: `js.khipu.com.evil.example` ends with the
    /// trusted name and must not pass. A nil on either side is not same-origin (fail closed).
    static func isSameOrigin(requestHost: String?, responseHost: String?) -> Bool {
        guard let requestHost, let responseHost else { return false }
        return requestHost.caseInsensitiveCompare(responseHost) == .orderedSame
    }

    /// The reason to refuse this response before reading its body, or `nil` to proceed. [requestHost] is the
    /// host the SDK ADDRESSED (the same one that selected the baked key), not whatever answered.
    ///
    /// Order is load-bearing and matches Kotlin's `readResponse`: the origin pin runs FIRST, so bytes from an
    /// unexpected host are refused before the status is consulted — a redirected error body must never be
    /// attributed to a transport failure of the addressed host.
    static func refusal(for response: HTTPURLResponse, requestHost: String) -> String? {
        guard isSameOrigin(requestHost: requestHost, responseHost: response.url?.host) else {
            return BundleVerificationInterceptor.reasonOriginMismatch
        }
        guard (200 ..< 300).contains(response.statusCode) else {
            return BundleVerificationInterceptor.reasonHttpError
        }
        if exceedsCap(response.expectedContentLength) {
            return BundleVerificationInterceptor.reasonTooLarge
        }
        return nil
    }

    /// The terminal outcome the fetch delegate reports once its task completes: the pure twin of the tail of
    /// Kotlin's `readResponse` plus the exception mapping the Kotlin host does in `fetchBundle`. Keeping it here
    /// means the whole `URLSession` result mapping is unit-tested, not only `decide()` downstream of it.
    ///
    /// - Parameters:
    ///   - refusal: a reason already decided while the response was arriving (the origin pin / status /
    ///     declared length at `didReceive response`, or the ceiling at `didReceive data`). It WINS over
    ///     `error`, because refusing means the SDK cancelled the task itself and that cancellation surfaces
    ///     as `NSURLErrorCancelled` — reporting the cancellation would hide the rule that actually fired.
    ///   - error: the transport failure, if any.
    ///   - response: the task's response. Re-checked against the pin/status/ceiling even when no early
    ///     refusal was recorded, so a delegate callback that never ran cannot open a hole.
    ///   - requestHost: the host the SDK addressed.
    ///   - body: the bytes accumulated under the ceiling.
    static func outcome(
        refusal: String?,
        error: Error?,
        response: HTTPURLResponse?,
        requestHost: String,
        body: Data
    ) -> BundleVerificationInterceptor.FetchOutcome {
        if let refusal {
            // Carry the status when the refusal was about the status, so the telemetry keeps its `status` field.
            let status = refusal == BundleVerificationInterceptor.reasonHttpError ? response?.statusCode : nil
            return .unavailable(reason: refusal, status: status)
        }
        if let error = error as NSError? {
            return error.code == NSURLErrorTimedOut
                ? .unavailable(reason: BundleVerificationInterceptor.reasonTimeout)
                // connect/DNS/offline/TLS bucket — the schema's closest connect-failure reason.
                : .unavailable(reason: BundleVerificationInterceptor.reasonDns)
        }
        // No response and no error should be unreachable; treat it as a connect failure rather than trusting
        // an empty body (fail closed).
        guard let response else { return .unavailable(reason: BundleVerificationInterceptor.reasonDns) }
        if let reason = self.refusal(for: response, requestHost: requestHost) {
            let status = reason == BundleVerificationInterceptor.reasonHttpError ? response.statusCode : nil
            return .unavailable(reason: reason, status: status)
        }
        return body.isEmpty ? .unavailable(reason: BundleVerificationInterceptor.reasonEmpty) : .ok(body)
    }
}
