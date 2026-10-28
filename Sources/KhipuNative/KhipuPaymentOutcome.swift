import BridgeGenerated

/// The outcome of a payment started with `KhipuPayment.start`: either the payment page reached a verdict, or the
/// flow ended without one.
///
/// - `.completed`: the payment page reached a verdict, carried as a `KhipuPaymentResult` (`ok`, `error`,
///   `warning` or `continue`). A failed payment is still `.completed`: a payer cancellation, for example, is
///   `.completed(.error(...))` with `failureReason == .USER_CANCELED`. Payer cancellations are reported only this
///   way, never as `.interrupted`.
/// - `.interrupted`: no verdict was obtained — for example after `KhipuPayment.close()`, a dismissal the SDK did
///   not initiate, the payment timeout, a second `start` while a payment is active, a page that could not be
///   loaded or verified, an error reported by the page instead of a verdict, or a response the SDK could not
///   process. Carries a typed `KhipuPaymentError` (such as `PAYMENT_ABORTED` or `PAYMENT_TIMEOUT`).
///
/// `.interrupted` does not by itself mean the payment failed: after a close, a dismissal or a timeout the payer
/// may still have completed it. Confirm the payment's status with your backend; see
/// `KhipuPayment.onOrphanedPaymentDetected(_:)`.
public enum KhipuPaymentOutcome: Equatable {
    /// The payment page reached a verdict, including a failed payment (an `.error` result).
    case completed(KhipuPaymentResult)
    /// The flow ended without a verdict; the error says why. Never a payer cancellation.
    case interrupted(KhipuPaymentError)
}
