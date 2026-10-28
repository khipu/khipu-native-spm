import UIKit
import WebKit

/// The SDK-owned payment sheet content. A plain `UIViewController` — NO SwiftUI (zero new runtime dependencies).
/// A thin shell by design: every decision lives in the VC/WebView-free coordinator, where it is unit-testable;
/// this class only hosts the SDK-retained WKWebView full-bleed with safe-area-respecting constraints.
internal final class KhipuPaymentViewController: UIViewController {
    private let webView: WKWebView
    private let isDark: Bool
    /// Fired from `viewDidDisappear` when this view controller is being dismissed — the presenter discriminates
    /// a coordinator-driven close (binding already cleared) from a SYSTEM/external dismissal (the merchant
    /// dismissed the anchor in code, or the OS tore the UI down) and routes the PAYMENT_ABORTED system-teardown
    /// latch for the latter (the iOS counterpart of Android's `onDestroy` external-finish guard). The full-screen
    /// `isModalInPresentation` controller has NO user swipe-dismiss, so this is purely the system/programmatic
    /// teardown signal.
    var onDismissed: (() -> Void)?

    init(webView: WKWebView, isDark: Bool) {
        self.webView = webView
        self.isDark = isDark
        super.init(nibName: nil, bundle: nil)
        // This full-screen VC drives the status-bar style (preferredStatusBarStyle below).
        modalPresentationCapturesStatusBarAppearance = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("KhipuPaymentViewController is code-only (internal)") }

    /// Native chrome theming: dark status-bar icons on the LIGHT (white) theme, light on DARK.
    override var preferredStatusBarStyle: UIStatusBarStyle { isDark ? .lightContent : .darkContent }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isBeingDismissed || presentingViewController == nil {
            onDismissed?()
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        // Native chrome theming: the view background shows in the safe-area regions (status/notch above, home
        // indicator below), so it IS the system-bar color. Match the RESOLVED theme — NOT .systemBackground, which
        // follows the OS rather than the SDK's (possibly forced) theme.
        view.backgroundColor = isDark ? UIColor(white: 0.07, alpha: 1) : .white
        // Attach the RETAINED host WebView (created by KhipuPayment) — the page keeps loading while the sheet
        // opens; no native splash/spinner chrome. Detach on disappear is unnecessary: the WebView moves to the next
        // presentation's view on the following start().
        attachWebView(into: view)
    }

    /// Attach the SDK-retained WebView full-bleed into `parent`, pinned to `parent`'s safe area.
    private func attachWebView(into parent: UIView) {
        webView.removeFromSuperview()
        webView.translatesAutoresizingMaskIntoConstraints = false
        parent.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: parent.safeAreaLayoutGuide.topAnchor),
            webView.bottomAnchor.constraint(equalTo: parent.safeAreaLayoutGuide.bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: parent.safeAreaLayoutGuide.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: parent.safeAreaLayoutGuide.trailingAnchor),
        ])
    }
}

/// The real iOS `PaymentPresenting`: presents the payment FULL-SCREEN (`modalPresentationStyle = .fullScreen`,
/// `isModalInPresentation = true` — NO swipe-to-dismiss; the ONLY user-facing exit is khipu-web's X) from the
/// `start(from:)` anchor. With no swipe-down user cancel there is no `UIAdaptivePresentationControllerDelegate`
/// swipe hook; the SOLE teardown route is `sheetDidDisappear` → `onSystemTeardown` (a SYSTEM/programmatic
/// dismissal — the merchant dismissing the anchor in code, or an OS teardown — the iOS counterpart of Android's
/// `onDestroy` external-finish guard), which resolves the latch with PAYMENT_ABORTED AFTER teardown completes.
internal final class SheetPaymentPresenter: NSObject, PaymentPresenting {
    private let webView: WKWebView
    /// Wired by KhipuPayment after the coordinator exists (the presenter is constructed first). SYSTEM teardown
    /// only (the `sheetDidDisappear` external-dismissal guard): there is no user swipe-cancel.
    var onSystemTeardown: ((String) -> Void)?
    /// Wired by KhipuPayment: the sheet could not be presented (nil resolved host / host already presenting) —
    /// the coordinator fails the operation closed instead of running a headless payment.
    var onPresentFailed: ((String) -> Void)?
    /// Wired by KhipuPayment to the coordinator's presentConfirmed — the POSITIVE "the UI actually appeared"
    /// signal (the `present(_:animated:completion:)` completion ran). Android's twin is the payment Activity's
    /// onCreate binding.
    var onPresented: ((String) -> Void)?
    /// The presentation anchor for the NEXT present() — set by `start(from:)`, RELEASED by KhipuPayment on the
    /// terminal delivery (a strong anchor held past the payment would pin the merchant's view controller). nil
    /// resolves the key window's top-most presented controller (best-effort).
    var anchor: UIViewController?

    private var presentedController: KhipuPaymentViewController?
    private var currentOpId: String?

    init(webView: WKWebView) {
        self.webView = webView
    }

    func present(nativeOpId: String, isDark: Bool) {
        // Best-effort present-failure detection: a nil resolved host or a host that is already presenting makes
        // UIKit refuse silently (no error channel) — fail closed via onPresentFailed instead of recording state
        // as-if-presented and running headless until the payment timeout. The remaining undetectable refusals are
        // caught by the coordinator's present-confirmation deadline — the present-completion below is the positive
        // signal that cancels it.
        guard let hostVC = anchor ?? Self.topMostViewController(), hostVC.presentedViewController == nil else {
            onPresentFailed?(nativeOpId)
            return
        }
        let controller = KhipuPaymentViewController(webView: webView, isDark: isDark)
        // FULL-SCREEN, NON-dismissible: cancellation belongs to the web page. `.fullScreen` removes the sheet
        // chrome (no detents/grabber); `isModalInPresentation = true` blocks the swipe-to-dismiss gesture entirely
        // — there is NO native user-facing escape, so no `presentationControllerDidDismiss` swipe hook and no
        // delegate. `close()`/system teardown still dismiss programmatically (routed via `sheetDidDisappear` →
        // `onSystemTeardown`). The ONLY user-facing exit is khipu-web's X (→ a web `error` verdict with
        // `failure_reason == .USER_CANCELED`).
        controller.modalPresentationStyle = .fullScreen
        controller.isModalInPresentation = true
        currentOpId = nativeOpId
        presentedController = controller
        controller.onDismissed = { [weak self, weak controller] in
            guard let self, let controller else { return }
            self.sheetDidDisappear(controller)
        }
        // The completion IS the positive present-confirmation — a UIKit refusal the pre-checks above missed never
        // runs it, so the coordinator's deadline fails that case closed instead of a headless hang until the
        // payment timeout. The pre-check refusal path keeps onPresentFailed (immediate — no deadline).
        hostVC.present(controller, animated: true) { [weak self] in
            self?.onPresented?(nativeOpId)
        }
    }

    /// Any disappearance of a controller the coordinator did NOT close is a SYSTEM/external dismissal (the
    /// merchant dismissed the anchor/stack in code, or the OS tore the UI down) — there is no user swipe in the
    /// full-screen `isModalInPresentation` model. Route the PAYMENT_ABORTED system-teardown latch — the
    /// coordinator absorbs it if already terminal (the iOS counterpart of Android's `isFinishing &&
    /// !closedByCoordinator` external-finish guard — the callback is never left hanging).
    private func sheetDidDisappear(_ controller: KhipuPaymentViewController) {
        guard presentedController === controller, let opId = currentOpId else { return }
        presentedController = nil
        currentOpId = nil
        onSystemTeardown?(opId)
    }

    func close(nativeOpId: String, onClosed: @escaping () -> Void) {
        guard let controller = presentedController, currentOpId == nativeOpId else {
            // Already dismissed (a system/external dismissal) or never presented — idempotent: the terminal
            // delivery must never be lost.
            onClosed()
            return
        }
        presentedController = nil
        currentOpId = nil
        if controller.presentingViewController != nil {
            // Teardown-then-deliver: onClosed runs in the dismiss COMPLETION — the sheet is fully gone before the
            // callback fires.
            controller.dismiss(animated: true) { onClosed() }
        } else {
            onClosed()
        }
    }

    /// Best-effort top-most resolution for a nil anchor (documented: merchants SHOULD pass `from:`).
    private static func topMostViewController() -> UIViewController? {
        let window = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow }
        var top = window?.rootViewController
        while let presented = top?.presentedViewController { top = presented }
        return top
    }
}
