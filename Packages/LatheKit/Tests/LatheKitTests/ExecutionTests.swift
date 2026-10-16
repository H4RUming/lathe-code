import Darwin
import Foundation
import LatheExecution
import Testing

private final class CommandCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [CommandEvent] = []
    func record(_ event: CommandEvent) { lock.withLock { stored.append(event) } }
    var events: [CommandEvent] { lock.withLock { stored } }
    func data(_ stream: CommandOutputStream) -> Data {
        lock.withLock {
            stored.reduce(into: Data()) { result, event in
                if case .output(let kind, let bytes) = event, kind == stream { result.append(bytes) }
            }
        }
    }
    func text(_ stream: CommandOutputStream) -> String { String(decoding: data(stream), as: UTF8.self) }
}

private struct CommandFixture {
    let directory: URL
    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("lathe-execution-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    func cleanUp() { try? FileManager.default.removeItem(at: directory) }
}

struct ExecutionTests {
    @Test func exactArgumentsExplicitEnvironmentAndChildOnlyWorkingDirectory() async throws {
        let fixture = try CommandFixture(); defer { fixture.cleanUp() }
        let current = FileManager.default.currentDirectoryPath
        let resolved = try #require(fixture.directory.path.withCString { Darwin.realpath($0, nil) })
        let physicalPath = String(cString: resolved)
        free(resolved)
        let payload = "spaces 'quotes' \"double\" $(touch should-never-exist)\nnext"
        let capture = CommandCapture()
        let request = CommandRequest(executable: "/bin/sh",
            arguments: ["-c", "printf '%s\\n' \"$1\" \"$PWD\" \"$LATHE_EXPLICIT\" \"${HOME-unset}\"", "lathe-test", payload],
            workingDirectory: fixture.directory.path, environment: ["LATHE_EXPLICIT": "only this value"],
            terminationGraceSeconds: 0.02)
        let result = try await ProcessRunner().run(request, onEvent: capture.record)
        #expect(result.exitCode == 0)
        #expect(result.reason == .exited)
        #expect(capture.text(.stdout) == "\(payload)\n\(physicalPath)\nonly this value\nunset\n")
        #expect(FileManager.default.currentDirectoryPath == current)
        #expect(!FileManager.default.fileExists(atPath: fixture.directory.appendingPathComponent("should-never-exist").path))
        let environment = CommandCapture()
        _ = try await ProcessRunner().run(CommandRequest(executable: "/usr/bin/env", workingDirectory: fixture.directory.path,
            environment: ["EXACT": "value"], terminationGraceSeconds: 0.02), onEvent: environment.record)
        #expect(environment.text(.stdout) == "EXACT=value\n")
    }

    @Test func drainsBothPipesAndDeliversOneFinalEventAfterOutput() async throws {
        let capture = CommandCapture()
        let script = "i=0; while [ $i -lt 3000 ]; do printf 'stdout-%04d\\n' $i; printf 'stderr-%04d\\n' $i >&2; i=$((i+1)); done"
        let result = try await ProcessRunner().run(CommandRequest(executable: "/bin/sh", arguments: ["-c", script],
            workingDirectory: "/tmp", terminationGraceSeconds: 0.02), onEvent: capture.record)
        #expect(result.exitCode == 0)
        #expect(capture.text(.stdout).split(separator: "\n").count == 3000)
        #expect(capture.text(.stderr).split(separator: "\n").count == 3000)
        #expect(result.outputBytes == 72_000)
        #expect(capture.events.filter { if case .finished = $0 { true } else { false } }.count == 1)
        if case .finished = capture.events.last {} else { Issue.record("Missing final event") }
        if case .started = capture.events.first {} else { Issue.record("Missing initial started event") }
    }

    @Test func outputLimitIsExactAndStopsAnEndlessWriter() async throws {
        let capture = CommandCapture()
        let result = try await ProcessRunner().run(CommandRequest(executable: "/usr/bin/yes", workingDirectory: "/tmp",
            timeoutSeconds: 3, terminationGraceSeconds: 0.02, outputLimitBytes: 1025), onEvent: capture.record)
        #expect(result.reason == .outputLimit)
        #expect(result.outputBytes == 1025)
        #expect(capture.data(.stdout).count == 1025)
        #expect(result.durationSeconds < 2)
    }

    @Test func stdinRoundTripsArbitraryBytesAndEOF() async throws {
        let runner = ProcessRunner(), capture = CommandCapture()
        let input = Data([0, 1, 2, 10, 255, 254, 0, 128])
        let result = try await runner.run(CommandRequest(executable: "/bin/cat", workingDirectory: "/tmp",
            terminationGraceSeconds: 0.02)) { event in
                capture.record(event)
                if case .started = event { try? runner.writeInput(input); runner.closeInput() }
            }
        #expect(result.exitCode == 0)
        #expect(capture.data(.stdout) == input)
    }

    @Test func timeoutKillsGrandchildrenThatIgnoreTermAndHoldPipes() async throws {
        let fixture = try CommandFixture(); defer { fixture.cleanUp() }
        let marker = fixture.directory.appendingPathComponent("survived")
        let capture = CommandCapture()
        let script = "trap '' TERM; (trap '' TERM; /bin/sleep 0.6; /usr/bin/touch survived) & wait"
        let result = try await ProcessRunner().run(CommandRequest(executable: "/bin/sh", arguments: ["-c", script],
            workingDirectory: fixture.directory.path, timeoutSeconds: 0.1, terminationGraceSeconds: 0.03), onEvent: capture.record)
        #expect(result.reason == .timedOut)
        // The deadline includes process startup. A loaded host may time out before
        // the shell installs its trap; either termination signal is then correct.
        #expect(result.terminationSignal == SIGTERM || result.terminationSignal == SIGKILL)
        #expect(result.durationSeconds < 2)
        try await Task.sleep(for: .milliseconds(650))
        #expect(!FileManager.default.fileExists(atPath: marker.path))
    }

    @Test func cancellationEscalatesAfterShellAndDescendantIgnoreTerm() async throws {
        let fixture = try CommandFixture(); defer { fixture.cleanUp() }
        let runner = ProcessRunner(), capture = CommandCapture()
        // Readiness comes from the descendant after both TERM traps are installed.
        // Cancellation must therefore escalate, regardless of process startup time.
        let script = "trap '' TERM; (trap '' TERM; printf READY; /bin/sleep 0.6; /usr/bin/touch survived) & wait"
        let result = try await runner.run(CommandRequest(executable: "/bin/sh", arguments: ["-c", script],
            workingDirectory: fixture.directory.path, timeoutSeconds: 5, terminationGraceSeconds: 0.03)) { event in
                capture.record(event)
                if case .output = event, capture.text(.stdout).contains("READY") { runner.cancel() }
            }
        #expect(capture.text(.stdout).contains("READY"))
        #expect(result.reason == .cancelled)
        #expect(result.terminationSignal == SIGKILL)
        #expect(result.durationSeconds < 2)
        try await Task.sleep(for: .milliseconds(650))
        #expect(!FileManager.default.fileExists(atPath: fixture.directory.appendingPathComponent("survived").path))
    }

    @Test func leaderExitStillCleansUpGrandchildrenHoldingOutputPipes() async throws {
        let fixture = try CommandFixture(); defer { fixture.cleanUp() }
        let capture = CommandCapture()
        let script = "(trap '' TERM; /bin/sleep 0.6; /usr/bin/touch survived) & exit 7"
        let result = try await ProcessRunner().run(CommandRequest(executable: "/bin/sh", arguments: ["-c", script],
            workingDirectory: fixture.directory.path, timeoutSeconds: 3, terminationGraceSeconds: 0.03), onEvent: capture.record)
        #expect(result.reason == .exited)
        #expect(result.exitCode == 7)
        #expect(result.durationSeconds < 1)
        try await Task.sleep(for: .milliseconds(650))
        #expect(!FileManager.default.fileExists(atPath: fixture.directory.appendingPathComponent("survived").path))
    }

    @Test func terminalCanonicalEOFCompletesCat() async throws {
        let runner = ProcessRunner(), capture = CommandCapture()
        let result = try await runner.run(CommandRequest(executable: "/bin/cat", workingDirectory: "/tmp",
            mode: .pty, timeoutSeconds: 2, terminationGraceSeconds: 0.02)) { event in
                capture.record(event)
                if case .started = event {
                    try? runner.writeInput(Data("line before EOF".utf8))
                    runner.closeInput()
                }
            }
        #expect(result.reason == .exited)
        #expect(result.exitCode == 0)
        #expect(capture.text(.terminal).contains("line before EOF"))
    }

    @Test func cancellationFromCallbackAndBeforeStartAreSafe() async throws {
        let runner = ProcessRunner(), capture = CommandCapture()
        let result = try await runner.run(CommandRequest(executable: "/bin/sh",
            arguments: ["-c", "printf ready; /bin/sleep 10"], workingDirectory: "/tmp", terminationGraceSeconds: 0.02)) { event in
                capture.record(event)
                if case .output = event { runner.cancel() }
            }
        #expect(result.reason == .cancelled)
        #expect(result.durationSeconds < 2)
        let preCancelled = ProcessRunner(), early = CommandCapture()
        preCancelled.cancel()
        let earlyResult = try await preCancelled.run(CommandRequest(executable: "/bin/echo", arguments: ["must not execute"],
            workingDirectory: "/tmp"), onEvent: early.record)
        #expect(earlyResult.reason == .cancelled)
        #expect(earlyResult.exitCode == nil)
        #expect(early.events.count == 1)
        #expect(throws: CommandExecutionError.self) { try preCancelled.writeInput(Data([1])) }
    }

    @Test func taskCancellationReachesOwnedProcessGroup() async throws {
        let runner = ProcessRunner(), capture = CommandCapture()
        let task = Task {
            try await runner.run(CommandRequest(executable: "/bin/sleep", arguments: ["10"], workingDirectory: "/tmp",
                terminationGraceSeconds: 0.02), onEvent: capture.record)
        }
        try await Task.sleep(for: .milliseconds(30))
        task.cancel()
        let result = try await task.value
        #expect(result.reason == .cancelled)
        #expect(result.durationSeconds < 2)
    }

    @Test func ptyOwnsControllingTerminalAcceptsInputAndResizes() async throws {
        let runner = ProcessRunner(), capture = CommandCapture()
        let script = "test -t 0 && test -t 1 && test -t 2 || exit 21; : </dev/tty || exit 22; printf READY; read line; /bin/stty size; printf 'GOT:%s\\n' \"$line\""
        let result = try await runner.run(CommandRequest(executable: "/bin/sh", arguments: ["-c", script],
            workingDirectory: "/tmp", environment: ["TERM": "xterm-256color"], mode: .pty,
            timeoutSeconds: 3, terminationGraceSeconds: 0.02)) { event in
                capture.record(event)
                if case .started = event {
                    try? runner.resize(columns: 103, rows: 37)
                    try? runner.writeInput(Data("hello terminal\n".utf8))
                }
            }
        #expect(result.exitCode == 0)
        #expect(result.reason == .exited)
        #expect(capture.text(.terminal).contains("37 103"))
        #expect(capture.text(.terminal).contains("GOT:hello terminal"))
        #expect(capture.data(.stdout).isEmpty)
        #expect(capture.data(.stderr).isEmpty)
    }

    @Test func validationRejectsNULAndSpawnFailureLeavesRunnerTerminal() async throws {
        #expect(throws: CommandExecutionError.self) {
            try CommandRequest(executable: "/bin/echo", arguments: ["bad\0argument"], workingDirectory: "/tmp").validate()
        }
        #expect(throws: CommandExecutionError.self) {
            try CommandRequest(executable: "/bin/echo", workingDirectory: "/tmp", environment: ["BAD=NAME": "x"]).validate()
        }
        let runner = ProcessRunner()
        await #expect(throws: CommandExecutionError.self) {
            try await runner.run(CommandRequest(executable: "/this/path/does/not/exist", workingDirectory: "/tmp")) { _ in }
        }
        await #expect(throws: CommandExecutionError.self) {
            try await runner.run(CommandRequest(executable: "/bin/echo", workingDirectory: "/tmp")) { _ in }
        }
    }
}
