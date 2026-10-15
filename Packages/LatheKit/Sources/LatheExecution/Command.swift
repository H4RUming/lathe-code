import Foundation

public enum CommandMode: String, Codable, Sendable { case pipes, pty }
public enum CommandOutputStream: String, Codable, Sendable { case stdout, stderr, terminal }
public enum CommandTerminationReason: String, Codable, Sendable { case exited, cancelled, timedOut, outputLimit }

public struct CommandRequest: Codable, Sendable {
    public let executable: String
    public let arguments: [String]
    public let workingDirectory: String
    public let environment: [String: String]
    public let mode: CommandMode
    public let timeoutSeconds: Double
    public let terminationGraceSeconds: Double
    public let outputLimitBytes: Int
    public let terminalColumns: Int
    public let terminalRows: Int

    public init(executable: String, arguments: [String] = [], workingDirectory: String,
                environment: [String: String] = [:], mode: CommandMode = .pipes,
                timeoutSeconds: Double = 30, terminationGraceSeconds: Double = 0.5,
                outputLimitBytes: Int = 1_048_576, terminalColumns: Int = 80, terminalRows: Int = 24) {
        self.executable = executable; self.arguments = arguments; self.workingDirectory = workingDirectory
        self.environment = environment; self.mode = mode; self.timeoutSeconds = timeoutSeconds
        self.terminationGraceSeconds = terminationGraceSeconds; self.outputLimitBytes = outputLimitBytes
        self.terminalColumns = terminalColumns; self.terminalRows = terminalRows
    }

    public func validate() throws {
        guard executable.hasPrefix("/"), workingDirectory.hasPrefix("/") else {
            throw CommandExecutionError.invalidRequest("executable and workingDirectory must be absolute paths")
        }
        let values = [executable, workingDirectory] + arguments + Array(environment.keys) + Array(environment.values)
        guard !values.contains(where: { $0.utf8.contains(0) }) else {
            throw CommandExecutionError.invalidRequest("paths, arguments and environment must not contain NUL")
        }
        guard !environment.keys.contains(where: { $0.isEmpty || $0.contains("=") }) else {
            throw CommandExecutionError.invalidRequest("environment keys must be nonempty and contain no equals sign")
        }
        guard timeoutSeconds.isFinite, timeoutSeconds > 0, timeoutSeconds <= 86_400,
              terminationGraceSeconds.isFinite, (0...10).contains(terminationGraceSeconds),
              (1...67_108_864).contains(outputLimitBytes),
              (1...65_535).contains(terminalColumns), (1...65_535).contains(terminalRows) else {
            throw CommandExecutionError.invalidRequest("invalid timeout, grace period, output bound or terminal dimensions")
        }
    }
}

public struct CommandResult: Codable, Sendable, Equatable {
    public let exitCode: Int32?
    public let terminationSignal: Int32?
    public let reason: CommandTerminationReason
    /// Bytes delivered to the event consumer, never exceeding the request limit.
    public let outputBytes: Int
    public let durationSeconds: Double
    public init(exitCode: Int32?, terminationSignal: Int32?, reason: CommandTerminationReason,
                outputBytes: Int, durationSeconds: Double) {
        self.exitCode = exitCode; self.terminationSignal = terminationSignal; self.reason = reason
        self.outputBytes = outputBytes; self.durationSeconds = durationSeconds
    }
}

public enum CommandEvent: Codable, Sendable {
    case started(pid: Int32)
    case output(stream: CommandOutputStream, data: Data)
    case finished(CommandResult)
}

public enum CommandExecutionError: Error, LocalizedError, Sendable {
    case invalidRequest(String), alreadyUsed, notRunning, inputClosed, inputLimit
    case systemCall(String, Int32)
    public var errorDescription: String? {
        switch self {
        case .invalidRequest(let message): return message
        case .alreadyUsed: return "A ProcessRunner can execute only one command"
        case .notRunning: return "The command is not running"
        case .inputClosed: return "Command input is closed"
        case .inputLimit: return "Pending command input exceeds 1 MiB"
        case .systemCall(let operation, let code): return "\(operation) failed (errno \(code))"
        }
    }
}
