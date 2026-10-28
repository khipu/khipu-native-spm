import Foundation

/// The `URLSession` glue that applies `BundleFetchPolicy` while the `/v1/kws.js` response arrives. Deliberately
/// thin: every decision it takes comes from the pure, unit-tested policy; what lives here is only the callback
/// plumbing that cannot be exercised without a socket (not unit-tested: the SDK takes no HTTP-client dependency
/// and no mocking framework).
///
/// It exists because the SDK's fetch happens BEFORE any signature check, so its body is
/// attacker-influenceable. `URLSession`'s convenience `dataTask(with:completionHandler:)` hands over a body
/// that is already fully buffered: by then an oversize response has ALREADY been allocated. A data delegate
/// is the only place iOS can refuse one while it is still arriving:
///
///  - `willPerformHTTPRedirection` → never follow. The 3xx is delivered as the response instead, so it surfaces
///    as `http_error` and nothing is read from the redirect target.
///  - `didReceive response` → the origin pin, the status and the declared length, BEFORE any body byte.
///  - `didReceive data` → the running-total ceiling, cancelling the task the moment it is crossed.
///
/// The session's delegate queue is serial (`delegateQueue: nil`), so the mutable state below is confined to
/// one queue and needs no lock; `reported` makes the completion one-shot regardless.
final class BundleFetchDelegate: NSObject, URLSessionDataDelegate {
    private let requestHost: String
    private let completion: (BundleVerificationInterceptor.FetchOutcome) -> Void
    private var body = BundleFetchPolicy.BoundedBody()
    private var refusal: String?
    private var reported = false

    init(requestHost: String, completion: @escaping (BundleVerificationInterceptor.FetchOutcome) -> Void) {
        self.requestHost = requestHost
        self.completion = completion
    }

    /// Refuse every redirect. `URLSession` follows them by default, which would let a compromised
    /// endpoint bounce the fetch to another host whose bytes are then checked against the ORIGINAL host's
    /// baked key. Passing `nil` delivers the 3xx as the task's response rather than following it.
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }

    /// The pin + status + declared-length gate, applied before a single body byte is accepted.
    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let http = response as? HTTPURLResponse else {
            // A bundle is always served over HTTP(S); anything else is a transport we cannot reason about.
            refusal = BundleVerificationInterceptor.reasonDns
            completionHandler(.cancel)
            return
        }
        if let reason = BundleFetchPolicy.refusal(for: http, requestHost: requestHost) {
            refusal = reason
            completionHandler(.cancel)
            return
        }
        completionHandler(.allow)
    }

    /// The running-total ceiling. Cancelling here is what turns "detect an oversize body" into "never allocate
    /// one".
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        if !body.append(data) {
            refusal = BundleVerificationInterceptor.reasonTooLarge
            dataTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard !reported else { return }
        reported = true
        completion(
            BundleFetchPolicy.outcome(
                refusal: refusal,
                error: error,
                response: task.response as? HTTPURLResponse,
                requestHost: requestHost,
                body: body.bytes
            )
        )
    }
}
