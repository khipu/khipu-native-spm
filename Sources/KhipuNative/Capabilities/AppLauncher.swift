import Foundation
import UIKit
import BridgeGenerated

/// Handles the `openApp_v1` bridge operation, which opens the payer's bank or wallet app so they can authorize the
/// payment. `KhipuPayment` registers its own instance.
///
/// The request payload names the app by its URL scheme in `ios.scheme` (a trailing `://` is tolerated). The reply
/// is `{launched: true}` when the app can be opened and its opening has been scheduled, and `{launched: false,
/// reason: "app_not_installed"}` when it cannot be opened or the payload names no usable scheme. Neither is an
/// error: both are successful replies, and `handle(payload:)` does not throw for either. The reply covers only the
/// launch: the authorization result never comes back through it, and the payment continues when the payer returns.
///
/// Whether the app can be opened is decided synchronously, with `canOpenURL`, on the calling queue. The app is then
/// opened on the main queue after `handle(payload:)` returns, without waiting for the result of opening it. Each
/// successful launch is reported to `onLaunched`.
///
/// The capability is available on every supported iOS version.
final class AppLauncher: BridgeCapability {
    let id = ContractConstants.opOpenAppV1
    // Launch works at the iOS 15 floor — no OS gating (canOpenURL/open are long-standing UIKit APIs).
    var availableOnOS: Bool { true }

    private let canOpenURL: (URL) -> Bool
    private let openURL: (URL) -> Void
    // The launch-marker seam — fired when this capability LAUNCHES an external app for the active payment, so the
    // bank-app return detector can correlate the next foreground resume with this launch.
    // House DI: a no-op default; the production closure (wired ONLY when the build flag is ON, KhipuPayment.init)
    // records the launch on the detector. Kept as a `() -> Void` (NOT a typed detector ref) so the flag-OFF build
    // (#if compiled out) leaves no dangling reference. A non-throwing closure type — no never-crash guard needed
    // (Swift's type system guarantees it cannot throw into handle(), unlike Kotlin's JVM closure → its runCatching).
    private let onLaunched: () -> Void

    /// Creates the capability. `canOpenURL` decides whether the app is installed and `openURL` opens it; both default
    /// to `UIApplication.shared` and can be replaced so `handle(payload:)` can be driven without a device.
    /// `onLaunched` runs after each successful launch decision.
    init(
        canOpenURL: @escaping (URL) -> Bool = { UIApplication.shared.canOpenURL($0) },
        openURL: @escaping (URL) -> Void = { UIApplication.shared.open($0, options: [:], completionHandler: nil) },
        onLaunched: @escaping () -> Void = {}
    ) {
        self.canOpenURL = canOpenURL
        self.openURL = openURL
        self.onLaunched = onLaunched
    }

    func handle(payload: [String: Any]) throws -> [String: Any] {
        // Read ONLY this platform's sub-object (the single kws.js bundle carries both android+ios; native reads its
        // own). LENIENT shape handling: a launch-target SHAPE problem (ios sub-object absent/wrong-type, scheme
        // absent/non-string/empty/unbuildable) is NOT a transport error — it is reported as the not-installed
        // result {launched:false}, identically to the Kotlin twin. canOpenURL likewise decides
        // installed/not-installed synchronously (it also answers false for a scheme the host app does not list in
        // LSApplicationQueriesSchemes); folding all of these into ONE guard means handle() never throws for a
        // launch-target shape problem. The per-op dispatch queue is NOT main (BridgeDispatcher), so the actual
        // open() side-effect hops to main — mirroring the Kotlin twin's main-thread-posted startActivity.
        guard let iosTarget = payload["ios"] as? [String: Any],
              let scheme = iosTarget["scheme"] as? String,
              let url = Self.launchURL(fromScheme: scheme),
              canOpenURL(url) else {
            return ["launched": false, "reason": Self.reasonAppNotInstalled]
        }
        // Record the launch marker — an external app WAS launched (never on the not-installed branch above, which
        // returned {launched:false}). Mirrors the Kotlin twin's `if (launched) onLaunched()`.
        onLaunched()
        let openURL = self.openURL
        DispatchQueue.main.async { openURL(url) }
        return ["launched": true]
    }

    /// Build the launch URL from a scheme. Normally a BARE scheme (e.g. "bancochilemipass2"); defensively tolerate
    /// a trailing "://" if khenshin ever sends a full "scheme://". Build "<scheme>://" either way.
    private static func launchURL(fromScheme raw: String) -> URL? {
        let bare = raw.hasSuffix("://") ? String(raw.dropLast(3)) : raw
        guard !bare.isEmpty else { return nil }
        return URL(string: "\(bare)://")
    }

    private static let reasonAppNotInstalled = "app_not_installed"
}
