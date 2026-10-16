import Darwin
import Foundation
import LatheLocalization
import LatheExecution

struct RunnerRequest: Codable { let protocolVersion: Int; let command: CommandRequest }

private struct RunnerReceipt: Decodable {
    let protocolVersion: Int
    let invocationID: UUID
    let status: String
    let result: CommandResult?
    let error: String?
}
private struct RunnerEvent: Decodable {
    let protocolVersion: Int
    let sequence: Int64
    let event: CommandEvent
}

private final class RunnerCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var standard = Data(), diagnostic = Data()
    func append(_ event: CommandEvent) {
        lock.withLock {
            if case .output(let stream, let bytes) = event {
                if stream == .stdout { standard.append(bytes) } else { diagnostic.append(bytes) }
            }
        }
    }
    var output: Data { lock.withLock { standard } }
}

/// The engine owns a native helper; the helper owns the actual target's process group.
/// TERM gives the helper time to cancel, drain and durably record its target before KILL.
/// Unknown effects are never retried here.
enum RunnerBridge {
    static func execute(_ command: CommandRequest, runnerURL: URL, journalRoot: URL) async throws -> ToolResult {
        try Task.checkCancellation()
        guard runnerURL.isFileURL, runnerURL.path.hasPrefix("/"), journalRoot.isFileURL else {
            throw ToolError.invalid(L10n.text("runner.absolutePaths", table: "ToolMessages"))
        }
        guard mkdir(journalRoot.path, 0o700) == 0 else { let code = errno; throw ToolError.io(L10n.text("runner.operation.createDirectory", table: "ToolMessages"), code) }
        let directory = open(journalRoot.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directory >= 0 else { let code = errno; throw ToolError.io(L10n.text("runner.operation.openDirectory", table: "ToolMessages"), code) }
        defer { close(directory) }
        let requestURL = journalRoot.appendingPathComponent("request.json")
        let executionURL = journalRoot.appendingPathComponent("execution", isDirectory: true)
        let request = try JSONEncoder().encode(RunnerRequest(protocolVersion: 1, command: command))
        let fd = openat(directory, "request.json", O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { let code = errno; throw ToolError.io(L10n.text("runner.operation.createRequest", table: "ToolMessages"), code) }
        do {
            defer { close(fd) }
            try request.withUnsafeBytes { buffer in
                var offset = 0
                while offset < buffer.count {
                    let count = Darwin.write(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                    if count < 0 && errno == EINTR { continue }
                    guard count > 0 else { let code = errno; throw ToolError.io(L10n.text("runner.operation.writeRequest", table: "ToolMessages"), code) }
                    offset += count
                }
            }
            guard fsync(fd) == 0, fsync(directory) == 0 else { let code = errno; throw ToolError.io(L10n.text("runner.operation.syncRequest", table: "ToolMessages"), code) }
        }
        let supervisor = ProcessRunner(), capture = RunnerCapture()
        let requestToHelper = CommandRequest(executable: runnerURL.path,
            arguments: ["--request", requestURL.path, "--journal", executionURL.path],
            workingDirectory: journalRoot.path, environment: ["LATHE_DISPLAY_LANGUAGE": L10n.preferredLanguage], timeoutSeconds: command.timeoutSeconds + 8,
            terminationGraceSeconds: 3, outputLimitBytes: 4_194_304)
        let helperResult: CommandResult
        do {
            helperResult = try await supervisor.run(requestToHelper) { event in
                capture.append(event)
                if case .started = event {
                    // This closes target input while retaining the supervisor control pipe.
                    try? supervisor.writeInput(Data("{\"action\":\"eof\"}\n".utf8))
                }
            }
        } catch {
            throw ToolError.executionUnknown(L10n.format("runner.supervisionFailed", table: "ToolMessages", error.localizedDescription))
        }
        let receipt: RunnerReceipt
        do {
            let data = try boundedRead(executionURL.appendingPathComponent("result.json"), limit: 65_536)
            receipt = try JSONDecoder().decode(RunnerReceipt.self, from: data)
        } catch {
            throw ToolError.executionUnknown(L10n.format("runner.receiptUnavailable", table: "ToolMessages", helperResult.reason.localizedDescription))
        }
        guard receipt.protocolVersion == 1, receipt.status == "finished", receipt.error == nil,
              let target = receipt.result else {
            throw ToolError.executionUnknown(receipt.error ?? L10n.text("runner.receiptInvalid", table: "ToolMessages"))
        }
        var sequence: Int64 = 0, finished: CommandResult?, stdout = Data(), stderr = Data(), raw = Data()
        do {
            let bytes = capture.output
            guard bytes.last == 10 else { throw ToolError.invalid(L10n.text("runner.incompleteStream", table: "ToolMessages")) }
            for line in bytes.split(separator: 10, omittingEmptySubsequences: true) {
                let record = try JSONDecoder().decode(RunnerEvent.self, from: Data(line))
                sequence += 1
                guard record.protocolVersion == 1, record.sequence == sequence, finished == nil else {
                    throw ToolError.invalid(L10n.text("runner.eventMismatch", table: "ToolMessages"))
                }
                switch record.event {
                case .started: break
                case .output(let stream, let data):
                    guard data.count <= command.outputLimitBytes - raw.count else { throw ToolError.invalid(L10n.text("runner.outputLimit", table: "ToolMessages")) }
                    raw.append(data)
                    if stream == .stderr { stderr.append(data) } else { stdout.append(data) }
                case .finished(let result): finished = result
                }
            }
            guard finished == target, raw.count == target.outputBytes else {
                throw ToolError.invalid(L10n.text("runner.resultMismatch", table: "ToolMessages"))
            }
        } catch { throw ToolError.executionUnknown(error.localizedDescription) }
        let object: [String: Any] = [
            "reason": target.reason.rawValue,
            "exitCode": target.exitCode.map { $0 as Any } ?? NSNull(),
            "terminationSignal": target.terminationSignal.map { $0 as Any } ?? NSNull(),
            "stdout": String(decoding: stdout, as: UTF8.self),
            "stderr": String(decoding: stderr, as: UTF8.self),
            "outputBytes": target.outputBytes,
            "durationSeconds": target.durationSeconds,
        ]
        let rendered = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        return ToolResult(output: ToolBroker.preview(rendered),
            isError: target.reason != .exited || target.exitCode != 0, rawOutput: raw, wasCancelled: target.reason == .cancelled)
    }

    private static func boundedRead(_ url: URL, limit: Int) throws -> Data {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { let code = errno; throw ToolError.io(L10n.text("runner.operation.openReceipt", table: "ToolMessages"), code) }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size <= limit else {
            throw ToolError.invalid(L10n.text("runner.receiptFileInvalid", table: "ToolMessages"))
        }
        var result = Data(), buffer = [UInt8](repeating: 0, count: 8192)
        while result.count <= limit {
            let count = Darwin.read(fd, &buffer, min(buffer.count, limit + 1 - result.count))
            if count < 0 && errno == EINTR { continue }
            guard count >= 0 else { let code = errno; throw ToolError.io(L10n.text("runner.operation.readReceipt", table: "ToolMessages"), code) }
            if count == 0 { return result }
            result.append(contentsOf: buffer.prefix(count))
        }
        throw ToolError.invalid(L10n.text("runner.receiptLimit", table: "ToolMessages"))
    }
}
