import Foundation
import BridgeGenerated

/// Handles the `getCapabilities_v1` bridge operation, which tells the payment page which native capabilities the SDK
/// registered and whether each one is available on this device. `KhipuPayment` registers its own instance.
///
/// The reply is `{capabilities: [{id, available}, …]}`, built from the list that `registry` returns on each call.
/// It has no side effects and is available on every OS version.
final class GetCapabilitiesCapability: BridgeCapability {
    let id = ContractConstants.opGetCapabilitiesV1
    var availableOnOS: Bool { true }

    private let registry: () -> [Capability]

    init(registry: @escaping () -> [Capability]) {
        self.registry = registry
    }

    func handle(payload: [String: Any]) throws -> [String: Any] {
        let caps = registry().map { ["id": $0.id, "available": $0.available] as [String: Any] }
        return ["capabilities": caps]
    }
}
