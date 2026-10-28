import Foundation

/// The wait of one async `start` call: the payment's outcome, handed to a caller that may stop waiting first.
///
/// Both async `start` surfaces start the payment through the callback form and only then wait here, so the payment
/// never depends on its caller. Cancelling the waiting Task ends the WAIT, not the payment: `value()` throws
/// `CancellationError` at once, the payment runs on to its own terminal (recorded, and persisted as an orphan when
/// the cause leaves the payer in limbo, by the coordinator as for any payment), and the outcome that arrives later
/// is dropped for that caller. Ending a payment is `close()`'s job.
///
/// This is the contract Kotlin gets from `suspendCancellableCoroutine`, kept identical on purpose so a merchant's
/// cancellation code means the same on both platforms — including its prompt-cancellation rule: a caller cancelled
/// before it resumes never receives the outcome, even one that had already reached it.
///
/// Completion and cancellation arrive on arbitrary threads and may race, so every transition is made under `lock`
/// and the continuation is resumed exactly once, by whichever event moves the state to `.finished`.
final class CancellableOutcome: @unchecked Sendable {
    private enum State {
        /// Neither delivered nor awaited yet.
        case pending
        /// Delivered before the caller started waiting: the delivery hop can beat the caller's own.
        case delivered(KhipuPaymentOutcome)
        /// The caller is suspended on this continuation.
        case awaiting(CheckedContinuation<KhipuPaymentOutcome, Error>)
        /// The caller's Task was cancelled before it started waiting, so its wait throws at once.
        case cancelled
        /// The caller was resumed; whatever arrives later is dropped.
        case finished
    }

    private let lock = NSLock()
    private var state = State.pending

    /// The payment's one terminal delivery, from the callback form of `start`.
    func deliver(_ outcome: KhipuPaymentOutcome) {
        lock.lock()
        switch state {
        case .pending:
            state = .delivered(outcome)
            lock.unlock()
        case .awaiting(let continuation):
            state = .finished
            lock.unlock()
            continuation.resume(returning: outcome)
        case .delivered, .cancelled, .finished:
            // The caller already stopped waiting: only its copy of the outcome is dropped.
            lock.unlock()
        }
    }

    /// The outcome, or `CancellationError` as soon as the calling Task is cancelled. Awaited once per instance.
    func value() async throws -> KhipuPaymentOutcome {
        let outcome = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { wait($0) }
        } onCancel: {
            cancel()
        }
        // The prompt-cancellation rule: an outcome that resumed a Task cancelled before it got to run here is
        // dropped too, so "cancelled before start returned" always means "no outcome", as in Kotlin.
        try Task.checkCancellation()
        return outcome
    }

    private func wait(_ continuation: CheckedContinuation<KhipuPaymentOutcome, Error>) {
        lock.lock()
        switch state {
        case .pending:
            state = .awaiting(continuation)
            lock.unlock()
        case .delivered(let outcome):
            state = .finished
            lock.unlock()
            continuation.resume(returning: outcome)
        case .cancelled:
            state = .finished
            lock.unlock()
            continuation.resume(throwing: CancellationError())
        case .awaiting, .finished:
            // Unreachable (each instance is awaited once). Fail the extra wait instead of leaking it or trapping.
            lock.unlock()
            continuation.resume(throwing: CancellationError())
        }
    }

    private func cancel() {
        lock.lock()
        switch state {
        case .pending:
            state = .cancelled
            lock.unlock()
        case .awaiting(let continuation):
            state = .finished
            lock.unlock()
            continuation.resume(throwing: CancellationError())
        case .delivered, .cancelled, .finished:
            // `.delivered`: the wait hands the outcome over and `value()`'s cancellation check then drops it.
            lock.unlock()
        }
    }
}
