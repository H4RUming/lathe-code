import Darwin
import Foundation
import LatheExecution

@main
struct LatheRunnerMain {
    static func main() async {
        // stdout is an event channel owned by a supervisor, never a terminal renderer.
        signal(SIGPIPE, SIG_IGN)
        var journal: ExecutionJournal?
        var code: Int32 = 1
        do {
            let paths = try parseArguments()
            let file = try FileHandle(forReadingFrom: paths.request)
            defer { try? file.close() }
            let data = try file.read(upToCount: 131_073) ?? Data()
            guard data.count <= 131_072 else { throw RunnerFailure.invalid("Runner request exceeds 128 KiB.") }
            let request = try JSONDecoder().decode(RunnerRequest.self, from: data)
            guard request.protocolVersion == 1 else { throw RunnerFailure.invalid("Unsupported runner protocol version.") }
            let created = try ExecutionJournal(root: paths.journal, command: request.command)
            journal = created
            let runner = ProcessRunner()
            let controls = RunnerControl(runner: runner, journal: created)
            let flags = fcntl(STDOUT_FILENO, F_GETFL)
            guard flags >= 0, fcntl(STDOUT_FILENO, F_SETFL, flags | O_NONBLOCK) == 0 else {
                throw RunnerFailure.io("configure event channel", errno)
            }
            signal(SIGINT, SIG_IGN)
            signal(SIGTERM, SIG_IGN)
            let signals = [SIGINT, SIGTERM].map { number in
                let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
                source.setEventHandler { @Sendable in runner.cancel() }
                source.resume()
                return source
            }
            defer { signals.forEach { $0.cancel() }; controls.stop() }
            let result = try await runner.run(request.command) { event in controls.handle(event) }
            controls.stop()
            _ = try created.finish(result: result, error: controls.error)
            if let error = controls.error {
                stderr(error)
                code = 1
            } else {
                switch result.reason {
                case .cancelled: code = 130
                case .timedOut: code = 124
                case .outputLimit: code = 125
                case .exited:
                    code = result.exitCode ?? min(255, 128 + (result.terminationSignal ?? 1))
                }
            }
        } catch {
            if let journal { _ = try? journal.finish(result: nil, error: error.localizedDescription) }
            stderr(error.localizedDescription)
        }
        exit(code)
    }

    private static func parseArguments() throws -> (request: URL, journal: URL) {
        let args = Array(CommandLine.arguments.dropFirst())
        if args == ["--help"] {
            print("""
            lathe-runner — internal M0 execution helper (no policy/sandbox)
            Usage: lathe-runner --request /absolute/request.json --journal /absolute/fresh-directory
            stdin: NDJSON controls input(base64 data), eof, resize(columns/rows), cancel.
            Keep stdin open while supervising; owner EOF cancels the process group.
            stdout: versioned journal events. intent/result files are retained in --journal.
            This is a developer harness; model tools are not connected to it yet.
            """)
            exit(0)
        }
        guard args.count == 4, args[0] == "--request", args[2] == "--journal",
              args[1].hasPrefix("/"), args[3].hasPrefix("/"),
              !args[1].contains("\0"), !args[3].contains("\0") else {
            throw RunnerFailure.invalid("Usage: lathe-runner --request /absolute/request.json --journal /absolute/fresh-directory")
        }
        return (URL(fileURLWithPath: args[1]), URL(fileURLWithPath: args[3], isDirectory: true))
    }

    private static func stderr(_ text: String) {
        FileHandle.standardError.write(Data(("lathe-runner: " + text + "\n").utf8))
    }
}
