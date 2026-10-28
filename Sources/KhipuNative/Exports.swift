// Re-export the GENERATED bridge contract THROUGH `KhipuNative` so a single `import KhipuNative` exposes the
// result/error types a merchant app must name — `KhipuPaymentResult`, `KhipuPaymentError`, `KhipuPublicErrorCode`,
// `KhipuErrorFault`, `faultOf(_:)`, … — with NO `import BridgeGenerated`. This restores parity with Android, where
// the SDK module already re-exports the contract via `api(project(":bridge-generated"))`
// (android/khipuNative/build.gradle.kts), so the quickstart sees the generated types transitively. Without this, the
// iOS sample compiles only while it string-interpolates the result; the moment it `switch`es on `KhipuPaymentResult`
// or reads `KhipuPaymentError.code` / `faultOf(...)` the types are invisible ("cannot find type 'KhipuPaymentResult'
// in scope"), and a merchant integrating from the sample and the generated types alone cannot name them.
//
// Trade-off: `@_exported` re-exports ALL of `BridgeGenerated` (incl. the wire/envelope types — `Capability`,
// `StartPaymentRequest`, `MessageType`, …), exactly the blast radius Android's `api()` already has — so it is the
// parity-true choice. A surgical alternative (public `typealias`/`func` re-decls for only the ~5 surface symbols)
// would narrow the iOS surface but diverge from Android; not taken.
@_exported import BridgeGenerated
