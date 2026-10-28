import Foundation

/// A native operation the payment page can invoke through the bridge. Not an extension point: `KhipuPayment`
/// registers the SDK's own capabilities on a dispatcher it keeps private.
///
/// `id` is the operation's `op` name. `availableOnOS` says whether the capability works on the current OS version;
/// an unavailable one is still reported to the page, as unavailable, but cannot be invoked.
protocol BridgeCapability {
    var id: String { get }
    var availableOnOS: Bool { get }
    /// Handles one request payload (a decoded JSON object) and returns a JSON-serializable response payload.
    /// Called off the main queue, one call at a time per capability. A thrown error is answered to the page as an
    /// `INTERNAL_ERROR`.
    func handle(payload: [String: Any]) throws -> [String: Any]
}
