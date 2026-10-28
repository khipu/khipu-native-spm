import Foundation

/// The SCOPE decision behind the selective per-domain cookie clear at terminal/close. Pure by design so it is
/// unit-testable without a WebView, and because the scope is the load-bearing part: `WKWebsiteDataStore.default()`
/// is APP-GLOBAL, so a blanket clear would wipe the MERCHANT app's own cookies.
///
/// Unlike Android — where `CookieManager` has no per-domain delete and cookies must be overwritten as expired —
/// `WKHTTPCookieStore` deletes individual cookies, so iOS FILTERS the store with [belongs].
///
/// Twin of `PaymentCookieScope.kt`.
enum PaymentCookieScope {

    /// The host whose cookies belong to this payment, or `nil` when there is nothing to scope to (a `file://`
    /// harness origin in dev/CI has no cookie domain — and no host must mean clear NOTHING, never everything).
    static func host(of url: URL) -> String? {
        guard let host = url.host, !host.isEmpty else { return nil }
        return host
    }

    /// Whether a cookie's `domain` belongs to the payment served from `paymentHost`.
    ///
    /// True for the host itself and for a PARENT-domain cookie (`.khipu.com` for `js.khipu.com`) — a session
    /// cookie issued at the parent reaches the payment page, so skipping it would be a silent half-clear. False
    /// for siblings (`api.khipu.com`), for unrelated hosts, for suffix look-alikes (`notkhipu.com`,
    /// `js.khipu.com.evil.test`) and — deliberately — for a bare public suffix: matching `com` would authorise
    /// deleting every `.com` cookie in the merchant's app, the app-global foot-gun in miniature.
    static func belongs(cookieDomain: String, paymentHost: String) -> Bool {
        let domain = cookieDomain.lowercased().drop(while: { $0 == "." })
        let host = paymentHost.lowercased()
        guard !domain.isEmpty, !host.isEmpty else { return false }
        // A cookie domain with no dot cannot be a registrable domain here (it is a public suffix or a bare label).
        guard domain.contains(".") else { return false }
        if host == domain { return true }
        return host.hasSuffix("." + domain)
    }
}
