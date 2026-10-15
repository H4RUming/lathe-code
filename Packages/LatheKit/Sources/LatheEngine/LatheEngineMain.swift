import Darwin
import Foundation
import LatheDomain
import LatheProtocol
import LatheRuntime

@main
struct LatheEngineMain {
    static func main() async {
        do {
            var root: URL?
            let args = Array(CommandLine.arguments.dropFirst())
            if !args.isEmpty {
                guard args.count == 2, args[0] == "--root", args[1].hasPrefix("/") else {
                    throw LatheError.invalidRequest("Usage: lathe-engine [--root /absolute/data/directory]")
                }
                root = URL(fileURLWithPath: args[1], isDirectory: true)
            }
            let paths = try EnginePaths(root: root)
            let lease = try EngineLease(paths: paths)
            let runtime = try EngineRuntime(databaseURL: paths.database)
            let service = EngineService(runtime: runtime, info: EngineInfo(processID: getpid(), engineID: UUID()))
            let server = try UnixSocketServer(path: paths.socketPath) { await service.handle($0) }
            signal(SIGINT, SIG_IGN)
            signal(SIGTERM, SIG_IGN)
            let signals = [SIGINT, SIGTERM].map { number in
                let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
                source.setEventHandler { @Sendable in server.stop() }
                source.resume()
                return source
            }
            defer {
                signals.forEach { $0.cancel() }
                withExtendedLifetime(lease) {}
            }
            try await server.run()
        } catch {
            FileHandle.standardError.write(Data("lathe-engine: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }
}
