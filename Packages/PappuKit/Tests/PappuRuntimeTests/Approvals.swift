import PappuCore
@testable import PappuExtensions

extension ExecutionApproval {
    /// What the store would mint for an extension the user approved with every gate on. The runtime's
    /// tests are about running, not approving; `ExecutionApprovalTests` is about approving.
    static func approving(_ action: CatalogAction, gates: Set<GatedCapability>? = nil) -> ExecutionApproval {
        ExecutionApproval(identity: action.owner.flatMap(LocalIdentity.init), digest: nil, gates: gates ?? action.gates)
    }

    /// An approval for some other install than `action`'s.
    static func approvingSomethingElse(than action: CatalogAction) -> ExecutionApproval {
        ExecutionApproval(identity: LocalIdentity(), digest: nil, gates: Set(GatedCapability.allCases))
    }
}
