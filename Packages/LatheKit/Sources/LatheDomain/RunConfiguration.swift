import Foundation

/// Frozen per run. A nil profile selects the deterministic mock; credentials
/// are deliberately excluded from run snapshots and the idempotency payload.
public struct RunConfiguration: Codable, Sendable, Equatable {
    public let profile: ProviderProfile?
    public let permissionMode: PermissionMode
    public let maxSteps: Int
    public let approvalTimeoutSeconds: Double

    public init(profile: ProviderProfile? = nil, permissionMode: PermissionMode = .manual,
                maxSteps: Int = 12, approvalTimeoutSeconds: Double = 300) {
        self.profile = profile; self.permissionMode = permissionMode
        self.maxSteps = maxSteps; self.approvalTimeoutSeconds = approvalTimeoutSeconds
    }

    public func validate() throws {
        guard (1...24).contains(maxSteps), approvalTimeoutSeconds.isFinite,
              (1...600).contains(approvalTimeoutSeconds) else {
            throw LatheError.invalidRequest("실행 단계는 1~24, 승인 대기는 1~600초여야 합니다.")
        }
        try profile?.validate()
    }
}
