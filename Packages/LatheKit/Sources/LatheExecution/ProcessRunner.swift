import CLatheExecution
import Darwin
import Foundation
import LatheLocalization

/// Executes one explicitly configured command in a private process session.
/// Callbacks run serially on a dedicated worker, outside the control-state lock.
/// Keep callbacks short; persist or enqueue the event before returning.
public final class ProcessRunner: @unchecked Sendable {
    private enum State { case idle, starting, running, finished }
    private let lock = NSLock()
    private var state: State = .idle
    private var cancellationRequested = false
    private var input = Data()
    private var inputClosed = false
    private var terminalMode = false
    private var pendingResize: (columns: Int, rows: Int)?

    public init() {}

    public func run(_ request: CommandRequest,
                    onEvent: @escaping @Sendable (CommandEvent) -> Void) async throws -> CommandResult {
        try request.validate()
        try lock.withLock {
            guard state == .idle else { throw CommandExecutionError.alreadyUsed }
            state = .starting
            terminalMode = request.mode == .pty
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let worker = Thread {
                    lathe_block_sigpipe_for_thread()
                    do { continuation.resume(returning: try self.execute(request, onEvent: onEvent)) }
                    catch {
                        self.lock.withLock { self.state = .finished; self.input.removeAll() }
                        continuation.resume(throwing: error)
                    }
                }
                worker.name = "Lathe.ProcessRunner"
                worker.start()
            }
        } onCancel: {
            self.cancel()
        }
    }

    public func cancel() { lock.withLock { cancellationRequested = true } }

    public func writeInput(_ data: Data) throws {
        try lock.withLock {
            guard state == .running || state == .starting else { throw CommandExecutionError.notRunning }
            guard !inputClosed else { throw CommandExecutionError.inputClosed }
            guard data.count <= 1_048_576 - input.count else { throw CommandExecutionError.inputLimit }
            input.append(data)
        }
    }

    /// Pipes are half-closed after queued input drains. A PTY has no half-close;
    /// EOF sends two canonical EOT characters: flush a partial line, then signal EOF.
    /// Raw-mode programs decide how to handle these bytes.
    public func closeInput() { lock.withLock { inputClosed = true } }

    public func resize(columns: Int, rows: Int) throws {
        guard (1...65_535).contains(columns), (1...65_535).contains(rows) else {
            throw CommandExecutionError.invalidRequest(L10n.errorText("execution.terminalDimensions", table: "ExecutionErrors"))
        }
        try lock.withLock {
            guard state == .running || state == .starting else { throw CommandExecutionError.notRunning }
            guard terminalMode else { throw CommandExecutionError.invalidRequest(L10n.errorText("execution.resizeRequiresPTY", table: "ExecutionErrors")) }
            pendingResize = (columns, rows)
        }
    }

    private func execute(_ request: CommandRequest,
                         onEvent: @Sendable (CommandEvent) -> Void) throws -> CommandResult {
        let started = ProcessInfo.processInfo.systemUptime
        if lock.withLock({ cancellationRequested }) {
            let result = CommandResult(exitCode: nil, terminationSignal: nil, reason: .cancelled,
                                       outputBytes: 0, durationSeconds: 0)
            lock.withLock { state = .finished; input.removeAll() }
            onEvent(.finished(result))
            return result
        }
        let child = try spawn(request)
        lock.withLock { state = .running }
        onEvent(.started(pid: child.pid))
        var outputOpen = true
        var errorOpen = child.error_fd >= 0
        var inputOpen = true
        var terminalEOFQueued = false
        var outputBytes = 0
        var reason = CommandTerminationReason.exited
        var cleanupStarted: Double?
        var killedAt: Double?
        var observedExit = false
        var exitCode: Int32 = -1
        var signalNumber: Int32 = -1
        var workerError: CommandExecutionError?

        func beginCleanup(_ at: Double, because: CommandTerminationReason? = nil) {
            if let because, reason == .exited { reason = because }
            guard cleanupStarted == nil else { return }
            cleanupStarted = at
            // pid is still owned and deliberately unreaped until cleanup completes.
            _ = Darwin.kill(-child.pid, SIGTERM)
            lock.withLock { input.removeAll(); inputClosed = true }
        }
        defer {
            if inputOpen && child.input_fd != child.output_fd { Darwin.close(child.input_fd) }
            if outputOpen { Darwin.close(child.output_fd) }
            if errorOpen { Darwin.close(child.error_fd) }
        }
        while true {
            let now = ProcessInfo.processInfo.systemUptime
            if cleanupStarted == nil {
                if lock.withLock({ cancellationRequested }) { beginCleanup(now, because: .cancelled) }
                else if now - started >= request.timeoutSeconds { beginCleanup(now, because: .timedOut) }
            }
            if !observedExit {
                let observation = lathe_child_exit(child.pid, &exitCode, &signalNumber)
                if observation == 1 { observedExit = true; beginCleanup(now) }
                else if observation < 0 {
                    workerError = .systemCall("waitid", errno)
                    // An unexpected reaper has broken ownership; do not signal a possibly recycled PID.
                    break
                }
            }
            if let cleanupStarted, killedAt == nil, now - cleanupStarted >= request.terminationGraceSeconds {
                _ = Darwin.kill(-child.pid, SIGKILL)
                killedAt = now
            }
            if cleanupStarted == nil {
                let resize = lock.withLock { let value = pendingResize; pendingResize = nil; return value }
                if let resize {
                    let status = lathe_resize_terminal(child.output_fd, UInt16(resize.columns), UInt16(resize.rows))
                    if status != 0 { workerError = .systemCall(L10n.errorText("execution.resizeOperation", table: "ExecutionErrors"), status); beginCleanup(now) }
                }
            }
            if inputOpen {
                var shouldClose = false
                lock.withLock {
                    if inputClosed && input.isEmpty && request.mode == .pty && !terminalEOFQueued && cleanupStarted == nil {
                        input.append(contentsOf: [4, 4]); terminalEOFQueued = true
                    }
                    if !input.isEmpty && cleanupStarted == nil {
                        let written: Int = input.withUnsafeBytes { bytes in
                            Darwin.write(child.input_fd, bytes.baseAddress, bytes.count)
                        }
                        if written > 0 { input.removeFirst(written) }
                        else if written < 0 && errno != EAGAIN && errno != EINTR { input.removeAll(); inputClosed = true; shouldClose = true }
                    }
                    if inputClosed && input.isEmpty &&
                        (request.mode == .pipes || terminalEOFQueued || cleanupStarted != nil) { shouldClose = true }
                }
                if shouldClose {
                    if child.input_fd != child.output_fd { Darwin.close(child.input_fd) }
                    inputOpen = false
                }
            }
            var descriptors: [pollfd] = []
            if outputOpen { descriptors.append(pollfd(fd: child.output_fd, events: Int16(POLLIN | POLLHUP | POLLERR), revents: 0)) }
            if errorOpen { descriptors.append(pollfd(fd: child.error_fd, events: Int16(POLLIN | POLLHUP | POLLERR), revents: 0)) }
            let pollResult = descriptors.withUnsafeMutableBufferPointer { pointer in
                Darwin.poll(pointer.baseAddress, nfds_t(pointer.count), 10)
            }
            if pollResult < 0 && errno != EINTR {
                workerError = .systemCall("poll", errno); beginCleanup(now)
            }
            for descriptor in descriptors where descriptor.revents != 0 {
                // Bound per-descriptor work so an endless writer cannot starve control handling.
                for _ in 0..<8 {
                    var bytes = [UInt8](repeating: 0, count: 16_384)
                    let readCount = Darwin.read(descriptor.fd, &bytes, bytes.count)
                    if readCount > 0 {
                        let remaining = request.outputLimitBytes - outputBytes
                        let accepted = min(remaining, readCount)
                        if accepted > 0 {
                            let stream: CommandOutputStream = request.mode == .pty ? .terminal :
                                (descriptor.fd == child.output_fd ? .stdout : .stderr)
                            outputBytes += accepted
                            onEvent(.output(stream: stream, data: Data(bytes.prefix(accepted))))
                        }
                        if readCount > remaining { beginCleanup(ProcessInfo.processInfo.systemUptime, because: .outputLimit) }
                    } else if readCount == 0 || (readCount < 0 && errno == EIO && request.mode == .pty) {
                        if descriptor.fd == child.output_fd {
                            Darwin.close(child.output_fd); outputOpen = false
                            if request.mode == .pty { inputOpen = false }
                        } else { Darwin.close(child.error_fd); errorOpen = false }
                        break
                    } else if readCount < 0 && errno == EINTR { continue }
                    else if readCount < 0 && errno != EAGAIN {
                        let code = errno; workerError = .systemCall(L10n.errorText("execution.readOutputOperation", table: "ExecutionErrors"), code); beginCleanup(now)
                        break
                    } else { break }
                }
            }
            // Even a descendant that changed its process group/session and retained a
            // pipe cannot keep this runner alive indefinitely. Group cleanup is not a sandbox;
            // such descendants require stronger containment to guarantee termination.
            if let killedAt, observedExit, (!outputOpen && !errorOpen || now - killedAt >= 0.25) { break }
        }
        if observedExit { _ = lathe_reap(child.pid) }
        lock.withLock { state = .finished; input.removeAll() }
        if let workerError { throw workerError }
        let result = CommandResult(exitCode: exitCode >= 0 ? exitCode : nil,
                                   terminationSignal: signalNumber >= 0 ? signalNumber : nil,
                                   reason: reason, outputBytes: outputBytes,
                                   durationSeconds: ProcessInfo.processInfo.systemUptime - started)
        onEvent(.finished(result))
        return result
    }

    private func spawn(_ request: CommandRequest) throws -> lathe_child {
        let argv: [UnsafeMutablePointer<CChar>?] = try cStrings([request.executable] + request.arguments)
        defer { argv.forEach { free($0) } }
        let env: [UnsafeMutablePointer<CChar>?] = try cStrings(request.environment.sorted(by: { $0.key < $1.key }).map { "\($0.key)=\($0.value)" })
        defer { env.forEach { free($0) } }
        var arguments = argv + [nil]
        var environment = env + [nil]
        var child = lathe_child(pid: 0, input_fd: -1, output_fd: -1, error_fd: -1)
        let status = lathe_spawn(request.executable, &arguments, &environment, request.workingDirectory,
                                 request.mode == .pty ? 1 : 0, UInt16(request.terminalColumns), UInt16(request.terminalRows), &child)
        guard status == 0 else { throw CommandExecutionError.systemCall("posix_spawn", status) }
        return child
    }

    private func cStrings(_ values: [String]) throws -> [UnsafeMutablePointer<CChar>?] {
        var pointers: [UnsafeMutablePointer<CChar>?] = []
        for value in values {
            guard let pointer = value.withCString({ Darwin.strdup($0) }) else {
                pointers.forEach { free($0) }
                throw CommandExecutionError.systemCall("strdup", ENOMEM)
            }
            pointers.append(pointer)
        }
        return pointers
    }
}
