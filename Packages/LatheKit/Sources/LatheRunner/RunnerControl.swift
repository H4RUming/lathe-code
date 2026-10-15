import Darwin
import Foundation
import LatheExecution

/// stdin is the owner's control channel. EOF means owner loss, not target EOF.
/// The separate `eof` command closes the target's input without cancelling it.
final class RunnerControl: @unchecked Sendable {
    private let runner: ProcessRunner
    private let journal: ExecutionJournal
    private let lock = NSLock()
    private var started = false
    private var finished = false
    private var failure: String?
    // Accessed only by ProcessRunner's serialized event callback.
    private var eventChannelFailed = false

    init(runner: ProcessRunner, journal: ExecutionJournal) {
        self.runner = runner
        self.journal = journal
    }

    var error: String? { lock.withLock { failure } }
    private var isFinished: Bool { lock.withLock { finished } }

    func handle(_ event: CommandEvent) {
        if case .finished = event { stop() }
        if !eventChannelFailed {
            do {
                let bytes = try journal.record(event)
                try emit(bytes)
            } catch { eventChannelFailed = true; fail(error.localizedDescription) }
        }
        switch event {
        case .started:
            let shouldStart = lock.withLock {
                guard !started else { return false }
                started = true
                return true
            }
            if shouldStart { DispatchQueue.global(qos: .utility).async { self.readControls() } }
        case .finished: stop()
        default: break
        }
    }

    func stop() { lock.withLock { finished = true } }

    private func fail(_ message: String) {
        lock.withLock { if failure == nil { failure = message } }
        runner.cancel()
    }

    private func readControls() {
        var pending = Data()
        var buffer = [UInt8](repeating: 0, count: 8_192)
        do {
            while !isFinished {
                var descriptor = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
                let ready = poll(&descriptor, 1, 100)
                if ready == 0 || (ready < 0 && errno == EINTR) { continue }
                guard ready > 0 else { throw RunnerFailure.io("poll owner", errno) }
                let count = Darwin.read(STDIN_FILENO, &buffer, buffer.count)
                if count == 0 { runner.cancel(); return }
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw RunnerFailure.io("read owner", errno) }
                pending.append(contentsOf: buffer.prefix(count))
                while let newline = pending.firstIndex(of: 10) {
                    let line = pending.prefix(upTo: newline)
                    guard line.count <= 65_536 else { throw RunnerFailure.invalid("Control frame exceeds 64 KiB.") }
                    let command = try JSONDecoder().decode(Control.self, from: line)
                    if isFinished { return }
                    do { try apply(command) }
                    catch CommandExecutionError.notRunning { return }
                    pending.removeSubrange(...newline)
                }
                guard pending.count <= 65_536 else { throw RunnerFailure.invalid("Control frame exceeds 64 KiB.") }
            }
        } catch {
            if !isFinished { fail("Control channel failed: \(error.localizedDescription)") }
        }
    }

    private func apply(_ control: Control) throws {
        switch control.action {
        case "cancel": runner.cancel()
        case "eof": runner.closeInput()
        case "input":
            guard let encoded = control.data, let bytes = Data(base64Encoded: encoded) else {
                throw RunnerFailure.invalid("input requires base64 data.")
            }
            try runner.writeInput(bytes)
        case "resize":
            guard let columns = control.columns, let rows = control.rows else {
                throw RunnerFailure.invalid("resize requires columns and rows.")
            }
            try runner.resize(columns: columns, rows: rows)
        default: throw RunnerFailure.invalid("Unknown runner control action.")
        }
    }

    private func emit(_ data: Data) throws {
        let deadline = ContinuousClock.now + .seconds(1)
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                guard ContinuousClock.now < deadline else { throw RunnerFailure.invalid("Owner is not consuming runner events.") }
                var descriptor = pollfd(fd: STDOUT_FILENO, events: Int16(POLLOUT), revents: 0)
                let ready = poll(&descriptor, 1, 50)
                if ready == 0 || (ready < 0 && errno == EINTR) { continue }
                guard ready > 0 else { throw RunnerFailure.io("poll events", errno) }
                let count = Darwin.write(STDOUT_FILENO, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0 && [EINTR, EAGAIN, EWOULDBLOCK].contains(errno) { continue }
                guard count > 0 else { throw RunnerFailure.io("write events", errno) }
                offset += count
            }
        }
    }

    private struct Control: Decodable {
        let action: String
        let data: String?
        let columns: Int?
        let rows: Int?
    }
}
