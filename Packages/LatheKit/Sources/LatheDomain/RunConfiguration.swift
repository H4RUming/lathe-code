import Foundation
import LatheLocalization

/// Frozen per run. A nil profile selects the deterministic mock; credentials
/// are deliberately excluded from run snapshots and the idempotency payload.
public struct RunConfiguration: Codable, Sendable, Equatable {
    public let profile: ProviderProfile?
    public let permissionMode: PermissionMode
    public let maxSteps: Int
    public let approvalTimeoutSeconds: Double

    public init(profile: ProviderProfile? = nil, permissionMode: PermissionMode = .requestApproval,
                maxSteps: Int = 12, approvalTimeoutSeconds: Double = 300) {
        self.profile = profile; self.permissionMode = permissionMode
        self.maxSteps = maxSteps; self.approvalTimeoutSeconds = approvalTimeoutSeconds
    }

    public func validate() throws {
        guard (1...24).contains(maxSteps), approvalTimeoutSeconds.isFinite,
              (1...600).contains(approvalTimeoutSeconds) else {
            throw LatheError.invalidRequest(L10n.errorText("domain.run.invalidLimits", table: "DomainErrors"))
        }
        try profile?.validate()
    }
}
