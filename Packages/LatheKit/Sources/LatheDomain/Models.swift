import Foundation

public enum RunState: String, Codable, Sendable {
    case running, completed, cancelled, interrupted
}

public struct RunSnapshot: Codable, Identifiable, Sendable, Equatable {
    public let id: UUID
    public let sessionID: UUID
    public let prompt: String
    public var response: String
    public var state: RunState
    public let startedAt: Date
    public var finishedAt: Date?

    public init(id: UUID = UUID(), sessionID: UUID, prompt: String, response: String = "", state: RunState = .running, startedAt: Date = Date(), finishedAt: Date? = nil) {
        self.id = id; self.sessionID = sessionID; self.prompt = prompt
        self.response = response; self.state = state; self.startedAt = startedAt; self.finishedAt = finishedAt
    }
}

public struct SessionSnapshot: Codable, Identifiable, Sendable, Equatable {
    public let id: UUID
    public let title: String
    public let workspacePath: String
    public let createdAt: Date
    public var updatedAt: Date
    public var runs: [RunSnapshot]
    public let totalRunCount: Int
    public let nextBeforeRunID: UUID?
    public let activeRunID: UUID?

    public init(id: UUID = UUID(), title: String, workspacePath: String, createdAt: Date = Date(), updatedAt: Date = Date(), runs: [RunSnapshot] = [], totalRunCount: Int? = nil, nextBeforeRunID: UUID? = nil, activeRunID: UUID? = nil) {
        self.id = id; self.title = title; self.workspacePath = workspacePath
        self.createdAt = createdAt; self.updatedAt = updatedAt; self.runs = runs
        self.totalRunCount = totalRunCount ?? runs.count
        self.nextBeforeRunID = nextBeforeRunID
        self.activeRunID = activeRunID ?? runs.last(where: { $0.state == .running })?.id
    }

    public var activeRun: RunSnapshot? { runs.last(where: { $0.state == .running }) }
}

public struct SessionPage: Codable, Sendable {
    public let sessions: [SessionSnapshot]
    public let nextBefore: UUID?
    public init(sessions: [SessionSnapshot], nextBefore: UUID?) {
        self.sessions = sessions; self.nextBefore = nextBefore
    }
}

public enum EventKind: String, Codable, Sendable {
    case sessionCreated, runStarted, textDelta, runCompleted, runCancelled, runInterrupted
}

public struct EngineEvent: Codable, Identifiable, Sendable, Equatable {
    public var id: Int64 { sequence }
    public let sequence: Int64
    public let sessionID: UUID
    public let runID: UUID?
    public let kind: EventKind
    public let text: String?
    public let timestamp: Date

    public init(sequence: Int64, sessionID: UUID, runID: UUID? = nil, kind: EventKind, text: String? = nil, timestamp: Date = Date()) {
        self.sequence = sequence; self.sessionID = sessionID; self.runID = runID
        self.kind = kind; self.text = text; self.timestamp = timestamp
    }
}

public struct EventPage: Codable, Sendable {
    public let events: [EngineEvent]
    public let nextCursor: Int64
    public init(events: [EngineEvent], nextCursor: Int64) {
        self.events = events; self.nextCursor = nextCursor
    }
}

public struct EngineInfo: Codable, Sendable {
    public let protocolVersion: Int
    public let processID: Int32
    public let engineID: UUID
    public let mode: String
    public init(protocolVersion: Int = 1, processID: Int32, engineID: UUID, mode: String = "mock") {
        self.protocolVersion = protocolVersion; self.processID = processID; self.engineID = engineID; self.mode = mode
    }
}

public enum LatheError: Error, LocalizedError, Sendable {
    case invalidRequest(String), notFound(String), conflict(String), storage(String), transport(String), incompatibleVersion(Int)
    public var errorDescription: String? {
        switch self {
        case .invalidRequest(let s), .notFound(let s), .conflict(let s), .storage(let s), .transport(let s): s
        case .incompatibleVersion(let version): "지원하지 않는 엔진 프로토콜 버전: \(version)"
        }
    }
}
