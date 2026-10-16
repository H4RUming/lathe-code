import Foundation
import LatheLocalization

public enum PermissionMode: String, Codable, CaseIterable, Sendable {
    case fullAccess, autoApprove, acceptEdits, requestApproval

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        // Old read-only modes must never become automatic write/command grants.
        // Interrupted runs are not resumed; viewing an old snapshot remains safe.
        switch value {
        case "manual", "plan", "dontAsk": self = .requestApproval
        default:
            guard let mode = Self(rawValue: value) else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: L10n.errorFormat("domain.permission.unknown", table: "DomainErrors", value))
            }
            self = mode
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}
public enum ToolEffect: String, Codable, Sendable { case read, write, shell }
public enum ToolInvocationState: String, Codable, Sendable {
    case pendingApproval, approved, executing, completed, denied, failed, cancelled, unknown
}

public struct ToolInvocationSnapshot: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var runID: UUID
    public var callID: String
    public var name: String
    public var arguments: String
    public var requestHash: String
    public var summary: String
    public var effect: ToolEffect
    public var state: ToolInvocationState
    public var output: String?
    public var blobID: String?
    public var beforeBlobID: String?
    public var createdAt: Date

    public init(id: UUID = UUID(), runID: UUID, callID: String, name: String, arguments: String,
                requestHash: String, summary: String, effect: ToolEffect, state: ToolInvocationState,
                output: String? = nil, blobID: String? = nil, beforeBlobID: String? = nil, createdAt: Date = Date()) {
        self.id = id; self.runID = runID; self.callID = callID; self.name = name
        self.arguments = arguments; self.requestHash = requestHash; self.summary = summary
        self.effect = effect; self.state = state; self.output = output; self.blobID = blobID
        self.beforeBlobID = beforeBlobID; self.createdAt = createdAt
    }
}
