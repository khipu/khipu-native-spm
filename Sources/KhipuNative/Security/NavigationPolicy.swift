import Foundation

/// Pure main-frame navigation classifier (AC-SEC-012b: the main frame may only stay on the trusted khipu origin),
/// the SDK's enforcement slice of the 3-layer CSP responsibility split (`security/CSP-RACI.md`, Layer 2). Given a
/// MAIN-FRAME navigation's destination (scheme + host) and the SDK's currently-trusted origin (derived from
/// `PaymentOrigin`), it classifies the navigation into one of three decisions. Like
/// `BundleVerificationInterceptor.decide` and `KhipuWebViewHost.isGenuineLoadFailure`, it is a PURE, stdlib-only
/// brain that unit tests bite on without a real WKWebView; the real `WKNavigationDelegate.decidePolicyFor` / Android
/// `shouldOverrideUrlLoading` wiring is not unit-tested. Behaviorally identical to `NavigationPolicy.kt`.
///
/// The trusted origin is derived from the LOADED `PaymentOrigin`, so the SAME code allows staging (`.staging` →
/// `js.khipu-st.com`) and production (`.production` → `js.khipu.com`) with zero edits — only which origin is loaded
/// changes. The recognized khipu host set is read from `KhipuSigningKeys` (the hosts
/// the SDK bakes a signing key for); host strings are NEVER hardcoded here.
///
/// NONE of the three decisions is a payment terminal: a `.blockUnexpected`/`.externalSeam` only CANCELS the WebView
/// navigation (the wiring returns `.cancel` / Android `true`); it never fires the `onLoadFailed` seam, so a bank-app
/// universal link or a superseded load is never turned into a false load-failure terminal (that benign-cancel
/// concern lives in the load-failure seam, `isGenuineLoadFailure`, NOT here).
enum NavigationPolicy {
    /// The classification of a main-frame navigation. Mirrors Kotlin's `NavigationPolicy.Decision`.
    enum Decision: Equatable {
        /// Same origin as the loaded page (the `file://` harness self-nav, or the same trusted khipu https host).
        case allow

        /// A main-frame nav to a DIFFERENT `http(s)` origin (banking-grade: kws.js is a same-origin SPA, so an
        /// unexpected main-frame departure is suspicious). Cancel the WebView nav + telemetry; NOT a terminal.
        case blockUnexpected

        /// A non-`http(s)` scheme (`bankapp://`, `intent://`, …): a deep link out of the WebView, e.g. from
        /// `window.open`. NOT launched here: cancel the nav. The SDK opens another app only through the `openApp_v1`
        /// bridge op (`AppLauncher`), never by following a web-supplied link.
        case externalSeam
    }

    // The khipu hosts the SDK bakes a signing key for (`KhipuSigningKeys`) — the ONLY https hosts a main-frame
    // navigation may stay on. Reused (not hardcoded) so staging and production work with zero edits.
    private static let recognizedKhipuHosts: Set<String> = [KhipuSigningKeys.stagingHost, KhipuSigningKeys.prodHost]

    /// Classify a MAIN-FRAME navigation to `destinationScheme`://`destinationHost` given the loaded `origin`.
    /// Scheme + host are compared case-insensitively; an empty/blank host is normalized to nil (so a `file://`
    /// destination's nil host matches the harness's nil host).
    static func decide(destinationScheme: String?, destinationHost: String?, origin: PaymentOrigin) -> Decision {
        let scheme = destinationScheme?.lowercased()
        let host = normHost(destinationHost)
        let (trustedScheme, trustedHost) = trustedOrigin(origin)
        // 1. Same origin as the loaded page → allow. Covers the sandbox `file://` harness navigating within itself
        //    (scheme `file`, host nil==nil) AND an https main-frame nav that stays on the loaded khipu host. For an
        //    https trusted origin the host must additionally be a recognized khipu host (defense in depth — the
        //    trusted host is always file-less OR a baked khipu host, so a non-khipu https trusted origin can't arise).
        if let scheme = scheme, scheme == trustedScheme, host == trustedHost {
            let httpsToUnrecognized = scheme == "https" && !(host.map { recognizedKhipuHosts.contains($0) } ?? false)
            return httpsToUnrecognized ? .blockUnexpected : .allow
        }
        // 2. A main-frame nav to a DIFFERENT http(s) origin → blockUnexpected. A bank-app universal link (https to
        //    a different host) lands here too: this only CANCELS the WebView nav (lets the OS handle the universal
        //    link) — it is NEVER a payment terminal.
        if scheme == "http" || scheme == "https" { return .blockUnexpected }
        // 3. A non-http(s) scheme: a deep link out of the WebView. NOT launched here (app launches go through
        //    `openApp_v1`).
        return .externalSeam
    }

    /// Derive the trusted (scheme, host) from the loaded `PaymentOrigin`: production and staging are their baked
    /// khipu host over https; the harness parses its app-bundle URL (`file://`, host nil — or
    /// `about:blank`, which `start()` fails fast before any navigation). Twin of Kotlin's `trustedOrigin`.
    private static func trustedOrigin(_ origin: PaymentOrigin) -> (String?, String?) {
        switch origin {
        case .production: return ("https", KhipuSigningKeys.prodHost)
        case .staging: return ("https", KhipuSigningKeys.stagingHost)
        case .harness(let url): return (url.scheme?.lowercased(), normHost(url.host))
        }
    }

    private static func normHost(_ host: String?) -> String? {
        guard let host = host?.lowercased(), !host.isEmpty else { return nil }
        return host
    }
}
