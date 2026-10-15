import Darwin
import Foundation
import LatheExecution

struct RunnerRequest: Codable {
    let protocolVersion: Int
    let command: CommandRequest
}

struct RunnerReceipt: Codable {
    let protocolVersion: Int
    let invocationID: UUID
    let status: String
    let result: CommandResult?
    let error: String?
}

enum RunnerFailure: Error, LocalizedError {
    case invalid(String)
    case io(String, Int32)

    var errorDescription: String? {
        switch self {
        case .invalid(let message): message
        case .io(let operation, let code): "\(operation): \(String(cString: strerror(code))) (\(code))"
        }
    }
}

enum RunnerJSON {
    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }
}

/// An invocation owns a fresh private directory. Intent is fsynced before spawn;
/// an absent result receipt means reconciliation is required, never safe replay.
final class ExecutionJournal: @unchecked Sendable {
    let invocationID = UUID()
    private let directoryFD: Int32
    private let eventsFD: Int32
    private let lock = NSLock()
    private var sequence: Int64 = 0

    init(root: URL, command: CommandRequest) throws {
        guard root.path.hasPrefix("/"), !root.path.contains("\0") else {
            throw RunnerFailure.invalid("--journal requires a fresh absolute directory path.")
        }
        guard mkdir(root.path, 0o700) == 0 else { throw RunnerFailure.io("create journal directory", errno) }
        let directory = open(root.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard directory >= 0 else { throw RunnerFailure.io("open journal directory", errno) }
        directoryFD = directory
        let events = openat(directory, "events.ndjson", O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard events >= 0 else { close(directory); throw RunnerFailure.io("create event journal", errno) }
        eventsFD = events
        do {
            // Environment values are deliberately absent from persistent receipts.
            let intent = Intent(invocationID: invocationID, command: command)
            try writeFile("intent.json", data: RunnerJSON.encode(intent))
            guard fsync(directoryFD) == 0 else { throw RunnerFailure.io("sync journal directory", errno) }
            let parent = open(root.deletingLastPathComponent().path, O_RDONLY | O_CLOEXEC)
            guard parent >= 0 else { throw RunnerFailure.io("open journal parent", errno) }
            defer { close(parent) }
            guard fsync(parent) == 0 else { throw RunnerFailure.io("sync journal parent", errno) }
        }
    }

    deinit { close(eventsFD); close(directoryFD) }

    func record(_ event: CommandEvent) throws -> Data {
        try lock.withLock {
            sequence += 1
            var bytes = try RunnerJSON.encode(EventRecord(sequence: sequence, timestamp: Date(), event: event))
            bytes.append(10)
            try Self.writeAll(eventsFD, data: bytes)
            guard fsync(eventsFD) == 0 else { throw RunnerFailure.io("sync event journal", errno) }
            return bytes
        }
    }

    func finish(result: CommandResult?, error: String? = nil) throws -> RunnerReceipt {
        try lock.withLock {
            let receipt = RunnerReceipt(protocolVersion: 1, invocationID: invocationID,
                                        status: error == nil ? "finished" : "failed", result: result, error: error)
            try writeFile("result.json", data: RunnerJSON.encode(receipt))
            guard fsync(directoryFD) == 0 else { throw RunnerFailure.io("sync result directory", errno) }
            return receipt
        }
    }

    private func writeFile(_ name: String, data: Data) throws {
        let temporary = ".\(name).\(UUID().uuidString).tmp"
        let fd = openat(directoryFD, temporary, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw RunnerFailure.io("create \(name)", errno) }
        defer { close(fd); unlinkat(directoryFD, temporary, 0) }
        try Self.writeAll(fd, data: data)
        guard fsync(fd) == 0 else { throw RunnerFailure.io("sync \(name)", errno) }
        // Publish the complete file atomically without replacing an earlier receipt.
        guard linkat(directoryFD, temporary, directoryFD, name, 0) == 0 else {
            throw RunnerFailure.io("publish \(name)", errno)
        }
    }

    private static func writeAll(_ fd: Int32, data: Data) throws {
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw RunnerFailure.io("write journal", errno) }
                offset += count
            }
        }
    }

    private struct EventRecord: Encodable {
        let protocolVersion = 1
        let sequence: Int64
        let timestamp: Date
        let event: CommandEvent
    }

    private struct Intent: Encodable {
        let protocolVersion = 1
        let invocationID: UUID
        let timestamp = Date()
        let executable: String
        let arguments: [String]
        let workingDirectory: String
        let environmentKeys: [String]
        let mode: CommandMode
        let timeoutSeconds: Double
        let terminationGraceSeconds: Double
        let outputLimitBytes: Int
        let terminalColumns: Int
        let terminalRows: Int

        init(invocationID: UUID, command: CommandRequest) {
            self.invocationID = invocationID
            executable = command.executable
            arguments = command.arguments
            workingDirectory = command.workingDirectory
            environmentKeys = command.environment.keys.sorted()
            mode = command.mode
            timeoutSeconds = command.timeoutSeconds
            terminationGraceSeconds = command.terminationGraceSeconds
            outputLimitBytes = command.outputLimitBytes
            terminalColumns = command.terminalColumns
            terminalRows = command.terminalRows
        }
    }
}
