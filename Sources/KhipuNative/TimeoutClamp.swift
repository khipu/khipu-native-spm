import Foundation
import BridgeGenerated

/// `Int(someDouble)` TRAPS in Swift (it does not saturate) when the value exceeds `Int`'s range or is
/// NaN/±Inf, so an unclamped `.milliseconds(Int(timeoutMs))` is one injected value away from killing the process.
///
/// **The floor is 0, not the op's `minMs`**: these `Double` seams are the TEST-INJECTION point, and
/// `KhipuPaymentInternalTests` drives expiry with `paymentTimeoutMs: 80` / `600`, far below the 60s `minMs` — a
/// contract floor here would silently turn those into 60-second waits. `minMs` is REQUEST validation: the façade
/// already applies it in `invoke()` (see the codegen test that raises a sub-min `timeoutMs` to the schema min). What
/// this seam owes is only that the timer is representable and bounded above.
///
/// Non-finite inputs resolve by INTENT rather than uniformly: NaN carries none, so it falls back to the contract
/// default; ±Inf carries a direction, so it saturates to the matching bound. Pure and `internal` so
/// `TimeoutClampTests` can drive it directly (a trap cannot be asserted — it would take the test process with it),
/// and so it stays off the public ABI surface the swift-api-digester baselines pin.
internal func khipuClampTimeoutMs(_ value: Double, max hi: Int64, fallback: Int64) -> Int {
    guard value.isFinite else {
        if value.isNaN { return Int(fallback) }
        return value > 0 ? Int(hi) : 0
    }
    let clamped = Swift.min(Swift.max(value, 0), Double(hi))
    return Int(clamped.rounded())
}

/// Budget-carrying overload: saturates at the op's schema-declared `maxMs`, falling back to its `defaultMs` when
/// the input carries no usable intent (NaN).
internal func khipuClampTimeoutMs(_ value: Double, budget: ContractConstants.OpTimeout) -> Int {
    khipuClampTimeoutMs(value, max: budget.maxMs, fallback: budget.defaultMs)
}
