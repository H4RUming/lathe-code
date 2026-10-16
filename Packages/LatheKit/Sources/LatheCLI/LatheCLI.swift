import Darwin
import Foundation
import LatheLocalization
import LatheDomain
import LatheProtocol

private final class InterruptFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var interrupted = false
    func set() { lock.withLock { interrupted = true } }
    var isSet: Bool { lock.withLock { interrupted } }
}

private struct Arguments {
    var words: [String]
    var values: [String: String] = [:]
    var flags: Set<String> = []

    init(_ input: [String]) throws {
        let valued: Set<String> = ["--root", "--developer-engine", "--workspace", "--session", "--request-id", "--after", "--before", "--provider", "--permission", "--max-steps", "--id", "--name", "--api", "--base-url", "--model", "--reasoning-effort", "--hash"]
        let switches: Set<String> = ["--json", "--detach", "--follow", "--help", "--allow-http", "--key-stdin", "--clear-key"]
        words = []
        var index = 0
        while index < input.count {
            let word = input[index]
            if word == "--" { words.append(contentsOf: input.dropFirst(index + 1)); break }
            if valued.contains(word) {
                guard index + 1 < input.count, values[word] == nil else { throw LatheError.invalidRequest(L10n.format("cli.optionValue", table: "CLIMessages", word)) }
                index += 1; values[word] = input[index]
            } else if switches.contains(word) { flags.insert(word) }
            else if word.hasPrefix("--") { throw LatheError.invalidRequest(L10n.format("cli.unknownOption", table: "CLIMessages", word)) }
            else { words.append(word) }
            index += 1
        }
    }

    func uuid(_ option: String) throws -> UUID? {
        guard let raw = values[option] else { return nil }
        guard let id = UUID(uuidString: raw) else { throw LatheError.invalidRequest(L10n.format("cli.invalidUUID", table: "CLIMessages", option)) }
        return id
    }
}

@main
struct LatheCLI {
    static func main() async {
        let interrupted = InterruptFlag()
        signal(SIGINT, SIG_IGN); signal(SIGTERM, SIG_IGN)
        let sources = [SIGINT, SIGTERM].map { number in
            let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
            source.setEventHandler { @Sendable in interrupted.set() }
            source.resume()
            return source
        }
        var code: Int32 = 0
        do { code = try await run(Arguments(Array(CommandLine.arguments.dropFirst())), interrupted: interrupted) }
        catch is CancellationError { code = 130 }
        catch { stderr(L10n.format("cli.error", table: "CLIMessages", error.localizedDescription)); code = 1 }
        sources.forEach { $0.cancel() }
        exit(code)
    }

    private static func run(_ args: Arguments, interrupted: InterruptFlag) async throws -> Int32 {
        guard let command = args.words.first, !args.flags.contains("--help") else { print(help); return 0 }
        let known: Set<String> = ["status", "sessions", "new", "show", "run", "cancel", "events", "providers", "provider-set", "tools", "tool", "approve", "deny"]
        guard known.contains(command) else { throw LatheError.invalidRequest(L10n.format("cli.unknownCommand", table: "CLIMessages", command, help)) }
        let root = args.values["--root"]
        if let root, !root.hasPrefix("/") || root.contains("\0") { throw LatheError.invalidRequest(L10n.text("cli.rootAbsolute", table: "CLIMessages")) }
        let engine = args.values["--developer-engine"].map { URL(fileURLWithPath: $0) }
        if let rawEngine = args.values["--developer-engine"] {
            guard let root, root.hasPrefix("/"), rawEngine.hasPrefix("/"), !rawEngine.contains("\0") else {
                throw LatheError.invalidRequest(L10n.text("cli.developerEngineArguments", table: "CLIMessages"))
            }
        }
        let paths = try EnginePaths(root: root.map { URL(fileURLWithPath: $0, isDirectory: true) })
        let client = EngineClient(paths: paths, executableURL: engine)
        let info: EngineInfo
        do { info = try await client.connect() }
        catch {
            guard engine == nil else { throw error }
            throw LatheError.transport(L10n.format("cli.appUnavailable", table: "CLIMessages", error.localizedDescription))
        }
        try checkInterrupt(interrupted)
        let tail = Array(args.words.dropFirst())
        let json = args.flags.contains("--json")
        switch command {
        case "providers":
            let profiles = try await client.providerProfiles()
            if json { try output(profiles) }
            else { for profile in profiles { print(L10n.format("cli.providerRow", table: "CLIMessages", profile.id.uuidString, profile.name, profile.api.rawValue, profile.model, profile.baseURL)) } }
        case "provider-set":
            guard let name = args.values["--name"], let rawAPI = args.values["--api"], let api = ProviderAPI(rawValue: rawAPI),
                  let baseURL = args.values["--base-url"], let model = args.values["--model"] else {
                throw LatheError.invalidRequest(L10n.text("cli.providerArguments", table: "CLIMessages"))
            }
            let profile = ProviderProfile(id: try args.uuid("--id") ?? UUID(), name: name, api: api, baseURL: baseURL,
                                          model: model, allowInsecureHTTP: args.flags.contains("--allow-http"), reasoningEffort: args.values["--reasoning-effort"])
            try profile.validate()
            let key: String?
            if args.flags.contains("--key-stdin") {
                guard isatty(STDIN_FILENO) == 0 else { throw LatheError.invalidRequest(L10n.text("cli.keyInput", table: "CLIMessages")) }
                key = try readPrompt(interrupted: interrupted).trimmingCharacters(in: .newlines)
            } else { key = nil }
            _ = try await client.saveProviderProfile(profile, apiKey: key, clearCredential: args.flags.contains("--clear-key"))
            if json { try output(profile) } else { print(profile.id) }
        case "tools":
            let items = try await client.invocations(runID: identifier(tail.first, name: L10n.text("cli.identifier.run", table: "CLIMessages")))
            if json { try output(items) }
            else {
                for item in items { print(L10n.format("cli.toolRow", table: "CLIMessages", item.id.uuidString, toolState(item.state), item.summary, item.requestHash, item.output ?? "")) }
                print(L10n.text("cli.recentTools", table: "CLIMessages"))
            }
        case "tool":
            let item = try await client.invocation(id: identifier(tail.first, name: L10n.text("cli.identifier.invocation", table: "CLIMessages")))
            if json { try output(item) }
            else { print(L10n.format("cli.toolDetail", table: "CLIMessages", item.id.uuidString, toolState(item.state), item.summary, item.arguments, item.requestHash, item.output ?? "")) }
        case "approve", "deny":
            guard let hash = args.values["--hash"] else { throw LatheError.invalidRequest(L10n.text("cli.approvalHashRequired", table: "CLIMessages")) }
            let item = try await client.decideApproval(invocationID: identifier(tail.first, name: L10n.text("cli.identifier.invocation", table: "CLIMessages")), requestHash: hash, approved: command == "approve")
            if json { try output(item) } else { print(L10n.format("cli.itemState", table: "CLIMessages", item.id.uuidString, toolState(item.state))) }
        case "status":
            if json { try output(info) }
            else { print(L10n.format("cli.engineStatus", table: "CLIMessages", String(info.processID), String(info.protocolVersion), engineMode(info.mode), paths.directory.path)) }
        case "sessions":
            let sessions = try await client.listSessions()
            if json { try output(sessions) }
            else {
                for session in sessions {
                    let state = session.activeRunID == nil ? L10n.text("cli.session.idle", table: "CLIMessages") : L10n.text("cli.session.running", table: "CLIMessages")
                    print(L10n.format("cli.sessionRow", table: "CLIMessages", session.id.uuidString, state, session.title))
                }
            }
        case "new":
            guard let workspace = args.values["--workspace"] ?? tail.first else { throw LatheError.invalidRequest(L10n.text("cli.newWorkspaceRequired", table: "CLIMessages")) }
            let title = args.values["--workspace"] == nil ? tail.dropFirst().joined(separator: " ") : tail.joined(separator: " ")
            try checkInterrupt(interrupted)
            let session = try await client.createSession(title: title.isEmpty ? URL(fileURLWithPath: workspace).lastPathComponent : title, workspacePath: workspace)
            if json { try output(session) } else { print(session.id) }
        case "show":
            let id = try identifier(tail.first, name: L10n.text("cli.identifier.session", table: "CLIMessages"))
            let session = try await client.session(id: id, beforeRunID: args.uuid("--before"))
            if json { try output(session) }
            else {
                print(L10n.format("cli.sessionDetail", table: "CLIMessages", session.title, session.workspacePath))
                for run in session.runs { print(L10n.format("cli.runDetail", table: "CLIMessages", run.prompt, run.response, runState(run.state), run.id.uuidString)) }
                print(L10n.format("cli.runCount", table: "CLIMessages", Int64(session.runs.count), Int64(session.totalRunCount)))
                if let before = session.nextBeforeRunID { print(L10n.format("cli.olderRuns", table: "CLIMessages", id.uuidString, before.uuidString)) }
            }
        case "cancel":
            try checkInterrupt(interrupted)
            let run = try await client.cancel(runID: identifier(tail.first, name: L10n.text("cli.identifier.run", table: "CLIMessages")))
            if json { try output(run) } else { print(L10n.format("cli.itemState", table: "CLIMessages", run.id.uuidString, runState(run.state))) }
        case "run":
            guard args.values["--session"] == nil || args.values["--workspace"] == nil else {
                throw LatheError.invalidRequest(L10n.text("cli.conflictingWorkspace", table: "CLIMessages"))
            }
            let prompt: String
            if !tail.isEmpty { prompt = tail.joined(separator: " ") }
            else {
                guard isatty(STDIN_FILENO) == 0 else { throw LatheError.invalidRequest(L10n.text("cli.promptRequired", table: "CLIMessages")) }
                prompt = try readPrompt(interrupted: interrupted)
            }
            guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, prompt.utf8.count <= 32_768 else {
                throw LatheError.invalidRequest(L10n.text("cli.promptBound", table: "CLIMessages"))
            }
            try checkInterrupt(interrupted)
            let sessionID: UUID
            if let existing = try args.uuid("--session") { sessionID = existing }
            else {
                let workspace = args.values["--workspace"] ?? FileManager.default.currentDirectoryPath
                sessionID = try await client.createSession(title: automaticTitle(prompt), workspacePath: workspace).id
            }
            try checkInterrupt(interrupted)
            let requestID = try args.uuid("--request-id") ?? UUID()
            let configuration: RunConfiguration?
            if let profileID = try args.uuid("--provider") {
                guard let profile = try await client.providerProfiles().first(where: { $0.id == profileID }) else { throw LatheError.notFound(L10n.text("cli.providerMissing", table: "CLIMessages")) }
                guard let mode = PermissionMode(rawValue: args.values["--permission"] ?? "requestApproval") else { throw LatheError.invalidRequest(L10n.text("cli.permissionInvalid", table: "CLIMessages")) }
                guard args.flags.contains("--detach") || mode == .fullAccess else {
                    throw LatheError.invalidRequest(L10n.text("cli.detachRequired", table: "CLIMessages"))
                }
                guard let maxSteps = Int(args.values["--max-steps"] ?? "12") else { throw LatheError.invalidRequest(L10n.text("cli.maxStepsInvalid", table: "CLIMessages")) }
                configuration = RunConfiguration(profile: profile, permissionMode: mode, maxSteps: maxSteps)
            } else { configuration = nil }
            let run: RunSnapshot
            do { run = try await client.submitConfigured(sessionID: sessionID, prompt: prompt, requestID: requestID, configuration: configuration) }
            catch { stderr(L10n.format("cli.submissionIdentity", table: "CLIMessages", sessionID.uuidString, requestID.uuidString)); throw error }
            if interrupted.isSet {
                let stopped = try await client.cancel(runID: run.id)
                if json || args.flags.contains("--detach") { try output(stopped) }
                return 130
            }
            if args.flags.contains("--detach") { try output(run); return 0 }
            if run.state != .running {
                if json { try output(run) } else { print(run.response) }
                return run.state == .completed ? 0 : (run.state == .failed ? 1 : 130)
            }
            stderr(L10n.format("cli.runIdentity", table: "CLIMessages", sessionID.uuidString, run.id.uuidString, requestID.uuidString, configuration?.profile?.name ?? L10n.text("cli.mockProvider", table: "CLIMessages")))
            var cursor: Int64 = 0
            while true {
                if interrupted.isSet {
                    let cancelled = try await client.cancel(runID: run.id)
                    if json { try output(cancelled) } else { print(L10n.format("cli.stoppedState", table: "CLIMessages", runState(cancelled.state))) }
                    return cancelled.state == .completed ? 0 : 130
                }
                let page = try await client.events(after: cursor, sessionID: sessionID, runID: run.id)
                cursor = page.nextCursor
                for event in page.events where event.runID == run.id {
                    if json { try output(event) }
                    else if event.kind == .textDelta, let text = event.text { FileHandle.standardOutput.write(Data(text.utf8)) }
                    if [.runCompleted, .runCancelled, .runInterrupted, .runFailed].contains(event.kind) {
                        if !json { print("") }
                        return event.kind == .runCompleted ? 0 : (event.kind == .runFailed ? 1 : 130)
                    }
                }
                try await Task.sleep(for: .milliseconds(150))
            }
        case "events":
            let rawCursor = args.values["--after"] ?? "0"
            guard var cursor = Int64(rawCursor), cursor >= 0 else { throw LatheError.invalidRequest(L10n.text("cli.afterInvalid", table: "CLIMessages")) }
            let sessionID = try args.uuid("--session")
            repeat {
                let page = try await client.events(after: cursor, sessionID: sessionID)
                cursor = page.nextCursor
                for event in page.events { try output(event) }
                if !args.flags.contains("--follow") || interrupted.isSet { break }
                try await Task.sleep(for: .milliseconds(150))
            } while true
        default: break
        }
        return interrupted.isSet ? 130 : 0
    }

    private static func runState(_ state: RunState) -> String {
        switch state {
        case .running: L10n.text("run.state.running")
        case .completed: L10n.text("run.state.completed")
        case .cancelled: L10n.text("run.state.cancelled")
        case .interrupted: L10n.text("run.state.interrupted")
        case .failed: L10n.text("run.state.failed")
        }
    }

    private static func toolState(_ state: ToolInvocationState) -> String {
        switch state {
        case .pendingApproval: L10n.text("tool.state.pendingApproval")
        case .approved: L10n.text("tool.state.approved")
        case .executing: L10n.text("tool.state.executing")
        case .completed: L10n.text("tool.state.completed")
        case .denied: L10n.text("tool.state.denied")
        case .failed: L10n.text("tool.state.failed")
        case .cancelled: L10n.text("tool.state.cancelled")
        case .unknown: L10n.text("tool.state.unknown")
        }
    }

    private static func engineMode(_ mode: String) -> String {
        switch mode {
        case "coding-preview": L10n.text("cli.engineMode.codingPreview", table: "CLIMessages")
        case "mock": L10n.text("cli.engineMode.mock", table: "CLIMessages")
        default: mode
        }
    }

    private static func identifier(_ raw: String?, name: String) throws -> UUID {
        guard let raw, let id = UUID(uuidString: raw) else { throw LatheError.invalidRequest(L10n.format("cli.identifierRequired", table: "CLIMessages", name)) }
        return id
    }

    private static func checkInterrupt(_ interrupted: InterruptFlag) throws {
        if interrupted.isSet { throw CancellationError() }
    }

    private static func automaticTitle(_ prompt: String) -> String {
        var result = ""
        for character in prompt.trimmingCharacters(in: .whitespacesAndNewlines).prefix(48) {
            let piece = String(character)
            guard result.utf8.count + piece.utf8.count <= 512 else { break }
            result.append(character)
        }
        return result.isEmpty ? L10n.text("cli.newTask", table: "CLIMessages") : result
    }

    private static func readPrompt(interrupted: InterruptFlag) throws -> String {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while true {
            if interrupted.isSet { throw CancellationError() }
            var descriptor = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
            let ready = poll(&descriptor, 1, 100)
            if ready == 0 || (ready < 0 && errno == EINTR) { continue }
            guard ready > 0 else { throw LatheError.invalidRequest(L10n.text("cli.stdinReadFailed", table: "CLIMessages")) }
            let count = Darwin.read(STDIN_FILENO, &buffer, buffer.count)
            if count == 0 { break }
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { throw LatheError.invalidRequest(L10n.text("cli.stdinReadFailed", table: "CLIMessages")) }
            data.append(contentsOf: buffer.prefix(count))
            guard data.count <= 32_768 else { throw LatheError.invalidRequest(L10n.text("cli.stdinLimit", table: "CLIMessages")) }
        }
        guard let text = String(data: data, encoding: .utf8) else { throw LatheError.invalidRequest(L10n.text("cli.stdinUTF8", table: "CLIMessages")) }
        return text
    }

    private static func output<T: Encodable>(_ value: T) throws {
        FileHandle.standardOutput.write(try WireCodec.encode(value))
        FileHandle.standardOutput.write(Data([10]))
    }

    private static func stderr(_ text: String) { FileHandle.standardError.write(Data((text + "\n").utf8)) }

    private static var help: String { L10n.text("cli.help", table: "CLIMessages") }
}
