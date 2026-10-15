import Darwin
import Foundation
import LatheDomain
import LatheProtocol
import LatheEngineHost

@main
struct LatheEngineMain {
    static func main() async {
        do {
            let args = Array(CommandLine.arguments.dropFirst())
            guard args.count == 2, args[0] == "--root", args[1].hasPrefix("/") else {
                throw LatheError.invalidRequest("Developer harness usage: lathe-engine --root /absolute/test/data/directory")
            }
            let root = URL(fileURLWithPath: args[1], isDirectory: true)
            let paths = try EnginePaths(root: root)
            let executable = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
            let host = EngineHost(paths: paths, runnerURL: executable.deletingLastPathComponent().appendingPathComponent("lathe-runner"))
            signal(SIGINT, SIG_IGN)
            signal(SIGTERM, SIG_IGN)
            let signals = [SIGINT, SIGTERM].map { number in
                let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
                source.setEventHandler { @Sendable in Task { await host.stop() } }
                source.resume()
                return source
            }
            defer {
                signals.forEach { $0.cancel() }
            }
            try await host.start()
            try await host.waitUntilStopped()
        } catch {
            FileHandle.standardError.write(Data("lathe-engine: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }
}
