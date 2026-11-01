import Foundation
import Security

/// The JavaScript the host evaluates in the payment page, built in one place so its text is unit-tested and the same
/// scripts run in a real WKWebView in BridgeScriptsWebViewTests. Mirrors `BridgeScripts.kt`.
///
/// Each page load (epoch) has a document token. The readiness probe writes it into the document whose
/// `window.khipuBridge` it found, and a delivery runs only in a document that holds its epoch's token. Native cannot
/// tell which document a script will run in: `callAsyncJavaScript` reaches the page asynchronously, and a navigation
/// can commit in between. So the check runs in the same JavaScript execution as the delivery (ADR-240).
///
/// Every script is strict. In sloppy mode a page getter that the script triggers (on the token or on
/// `window.khipuBridge`) can read the script's own text through `Function.caller`, and with it the token; a strict
/// caller is hidden from it.
enum BridgeScripts {
    static let tokenProperty = "__khipuDocumentToken"
    static let staleDocument = "stale_document"

    /// 128 random bits as lowercase hex.
    static func newDocumentToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        // A CSPRNG failure is catastrophic and astronomically rare; fail loudly rather than mark documents with a
        // predictable token (DebugId does the same).
        precondition(status == errSecSuccess, "SecRandomCopyBytes failed: \(status)")
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// `true` once `window.khipuBridge` exists, and only then marks this document with `token`.
    static func probe(token: String) -> String {
        precondition(isToken(token), "not a document token")
        return "(function(){'use strict';if(typeof window.khipuBridge==='undefined')return false;"
            + "window.\(tokenProperty)='\(token)';return true;})()"
    }

    /// The `callAsyncJavaScript` body for `target`. Its arguments are `t` (the token), plus `r` (the envelope JSON)
    /// or `id` (`_resume`'s operationId), always structured, never concatenated. In a document that does not hold
    /// `t` it returns `"stale_document"` and delivers nothing.
    static func delivery(_ target: JsTarget) -> String {
        let guardLine = "'use strict'; if (window.\(tokenProperty) !== t) { return \"\(staleDocument)\"; } "
        switch target {
        case .respond: return guardLine + "window.khipuBridge._respond(JSON.parse(r)); return \"ok\";"
        case .request: return guardLine + "window.khipuBridge._request(JSON.parse(r)); return \"ok\";"
        case .resume: return guardLine + "window.khipuBridge._resume(id); return \"ok\";"
        case .ping: return guardLine + "return window.khipuBridge._ping() === true;"
        }
    }

    static func isToken(_ s: String) -> Bool {
        s.count == 32 && s.allSatisfy { ("0"..."9").contains($0) || ("a"..."f").contains($0) }
    }
}
