import Darwin
import Foundation
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
                guard index + 1 < input.count, values[word] == nil else { throw LatheError.invalidRequest("Missing or duplicate option: \(word)") }
                index += 1; values[word] = input[index]
            } else if switches.contains(word) { flags.insert(word) }
            else if word.hasPrefix("--") { throw LatheError.invalidRequest("Unknown option: \(word)") }
            else { words.append(word) }
            index += 1
        }
    }

    func uuid(_ option: String) throws -> UUID? {
        guard let raw = values[option] else { return nil }
        guard let id = UUID(uuidString: raw) else { throw LatheError.invalidRequest("Invalid UUID for \(option)") }
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
        catch { stderr("lathe: \(error.localizedDescription)"); code = 1 }
        sources.forEach { $0.cancel() }
        exit(code)
    }

    private static func run(_ args: Arguments, interrupted: InterruptFlag) async throws -> Int32 {
        guard let command = args.words.first, !args.flags.contains("--help") else { print(help); return 0 }
        let known: Set<String> = ["status", "sessions", "new", "show", "run", "cancel", "events", "providers", "provider-set", "tools", "tool", "approve", "deny"]
        guard known.contains(command) else { throw LatheError.invalidRequest("Unknown command: \(command)\n\(help)") }
        let root = args.values["--root"]
        if let root, !root.hasPrefix("/") || root.contains("\0") { throw LatheError.invalidRequest("--root must be an absolute path.") }
        let engine = args.values["--developer-engine"].map { URL(fileURLWithPath: $0) }
        if let rawEngine = args.values["--developer-engine"] {
            guard let root, root.hasPrefix("/"), rawEngine.hasPrefix("/"), !rawEngine.contains("\0") else {
                throw LatheError.invalidRequest("--developer-engine requires an absolute executable path and an explicit --root for the isolated test harness.")
            }
        }
        let paths = try EnginePaths(root: root.map { URL(fileURLWithPath: $0, isDirectory: true) })
        let client = EngineClient(paths: paths, executableURL: engine)
        let info: EngineInfo
        do { info = try await client.connect() }
        catch {
            guard engine == nil else { throw error }
            throw LatheError.transport("실행 중인 Lathe 앱에 연결할 수 없습니다. 앱을 먼저 실행하세요. 개발용 CLI는 별도 엔진을 자동 시작하지 않습니다.\n" + error.localizedDescription)
        }
        try checkInterrupt(interrupted)
        let tail = Array(args.words.dropFirst())
        let json = args.flags.contains("--json")
        switch command {
        case "providers":
            let profiles = try await client.providerProfiles()
            if json { try output(profiles) }
            else { for profile in profiles { print("\(profile.id)  \(profile.name)  \(profile.api.rawValue)  \(profile.model)  \(profile.baseURL)") } }
        case "provider-set":
            guard let name = args.values["--name"], let rawAPI = args.values["--api"], let api = ProviderAPI(rawValue: rawAPI),
                  let baseURL = args.values["--base-url"], let model = args.values["--model"] else {
                throw LatheError.invalidRequest("provider-set requires --name, --api openAIResponses|openAIChat, --base-url and --model.")
            }
            let profile = ProviderProfile(id: try args.uuid("--id") ?? UUID(), name: name, api: api, baseURL: baseURL,
                                          model: model, allowInsecureHTTP: args.flags.contains("--allow-http"), reasoningEffort: args.values["--reasoning-effort"])
            try profile.validate()
            let key: String?
            if args.flags.contains("--key-stdin") {
                guard isatty(STDIN_FILENO) == 0 else { throw LatheError.invalidRequest("API keys must arrive through piped stdin or the app's secure field; never command arguments.") }
                key = try readPrompt(interrupted: interrupted).trimmingCharacters(in: .newlines)
            } else { key = nil }
            _ = try await client.saveProviderProfile(profile, apiKey: key, clearCredential: args.flags.contains("--clear-key"))
            if json { try output(profile) } else { print(profile.id) }
        case "tools":
            let items = try await client.invocations(runID: identifier(tail.first, name: "run ID"))
            if json { try output(items) }
            else {
                for item in items { print("\(item.id) [\(item.state.rawValue)] \(item.summary)\nhash=\(item.requestHash)\n\(item.output ?? "")") }
                print("Latest 4 tool calls. Use lathe tool INVOCATION_ID for exact arguments.")
            }
        case "tool":
            let item = try await client.invocation(id: identifier(tail.first, name: "invocation ID"))
            if json { try output(item) }
            else { print("\(item.id) [\(item.state.rawValue)]\n\(item.summary)\n\(item.arguments)\nhash=\(item.requestHash)\n\(item.output ?? "")") }
        case "approve", "deny":
            guard let hash = args.values["--hash"] else { throw LatheError.invalidRequest("Approval requires the exact --hash displayed by lathe tool.") }
            let item = try await client.decideApproval(invocationID: identifier(tail.first, name: "invocation ID"), requestHash: hash, approved: command == "approve")
            if json { try output(item) } else { print("\(item.id) \(item.state.rawValue)") }
        case "status":
            if json { try output(info) }
            else { print("Lathe engine \(info.processID) · protocol \(info.protocolVersion) · \(info.mode)\n\(paths.directory.path)") }
        case "sessions":
            let sessions = try await client.listSessions()
            if json { try output(sessions) }
            else { for session in sessions { print("\(session.id)  \(session.activeRunID == nil ? "idle" : "running")  \(session.title)") } }
        case "new":
            guard let workspace = args.values["--workspace"] ?? tail.first else { throw LatheError.invalidRequest("new requires --workspace /path") }
            let title = args.values["--workspace"] == nil ? tail.dropFirst().joined(separator: " ") : tail.joined(separator: " ")
            try checkInterrupt(interrupted)
            let session = try await client.createSession(title: title.isEmpty ? URL(fileURLWithPath: workspace).lastPathComponent : title, workspacePath: workspace)
            if json { try output(session) } else { print(session.id) }
        case "show":
            let id = try identifier(tail.first, name: "session ID")
            let session = try await client.session(id: id, beforeRunID: args.uuid("--before"))
            if json { try output(session) }
            else {
                print("\(session.title)\n\(session.workspacePath)")
                for run in session.runs { print("\n> \(run.prompt)\n\(run.response)\n[\(run.state.rawValue)] \(run.id)") }
                print("\nShowing \(session.runs.count) of \(session.totalRunCount) runs.")
                if let before = session.nextBeforeRunID { print("Older: lathe show \(id) --before \(before)") }
            }
        case "cancel":
            try checkInterrupt(interrupted)
            let run = try await client.cancel(runID: identifier(tail.first, name: "run ID"))
            if json { try output(run) } else { print("\(run.id) \(run.state.rawValue)") }
        case "run":
            guard args.values["--session"] == nil || args.values["--workspace"] == nil else {
                throw LatheError.invalidRequest("Choose --session or --workspace, not both.")
            }
            let prompt: String
            if !tail.isEmpty { prompt = tail.joined(separator: " ") }
            else {
                guard isatty(STDIN_FILENO) == 0 else { throw LatheError.invalidRequest("run requires a prompt or piped stdin.") }
                prompt = try readPrompt(interrupted: interrupted)
            }
            guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, prompt.utf8.count <= 32_768 else {
                throw LatheError.invalidRequest("A nonempty prompt of at most 32 KiB is required.")
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
                guard let profile = try await client.providerProfiles().first(where: { $0.id == profileID }) else { throw LatheError.notFound("Model connection not found.") }
                guard let mode = PermissionMode(rawValue: args.values["--permission"] ?? "requestApproval") else { throw LatheError.invalidRequest("Permission must be fullAccess, autoApprove, acceptEdits or requestApproval.") }
                guard args.flags.contains("--detach") || mode == .fullAccess else {
                    throw LatheError.invalidRequest("This permission mode may request approval. Use --detach, then approve in the app or with lathe approve. The default is requestApproval; fullAccess must be selected explicitly.")
                }
                guard let maxSteps = Int(args.values["--max-steps"] ?? "12") else { throw LatheError.invalidRequest("Invalid --max-steps.") }
                configuration = RunConfiguration(profile: profile, permissionMode: mode, maxSteps: maxSteps)
            } else { configuration = nil }
            let run: RunSnapshot
            do { run = try await client.submitConfigured(sessionID: sessionID, prompt: prompt, requestID: requestID, configuration: configuration) }
            catch { stderr("Submission identity: session=\(sessionID) request=\(requestID). Reuse both to retry without starting a duplicate run."); throw error }
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
            stderr("session=\(sessionID) run=\(run.id) request=\(requestID) · \(configuration?.profile?.name ?? "mock provider")")
            var cursor: Int64 = 0
            while true {
                if interrupted.isSet {
                    let cancelled = try await client.cancel(runID: run.id)
                    if json { try output(cancelled) } else { print("\n[\(cancelled.state.rawValue)]") }
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
            guard var cursor = Int64(rawCursor), cursor >= 0 else { throw LatheError.invalidRequest("--after must be a non-negative integer") }
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

    private static func identifier(_ raw: String?, name: String) throws -> UUID {
        guard let raw, let id = UUID(uuidString: raw) else { throw LatheError.invalidRequest("A valid \(name) is required.") }
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
        return result.isEmpty ? "새 작업" : result
    }

    private static func readPrompt(interrupted: InterruptFlag) throws -> String {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while true {
            if interrupted.isSet { throw CancellationError() }
            var descriptor = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
            let ready = poll(&descriptor, 1, 100)
            if ready == 0 || (ready < 0 && errno == EINTR) { continue }
            guard ready > 0 else { throw LatheError.invalidRequest("Unable to read stdin.") }
            let count = Darwin.read(STDIN_FILENO, &buffer, buffer.count)
            if count == 0 { break }
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { throw LatheError.invalidRequest("Unable to read stdin.") }
            data.append(contentsOf: buffer.prefix(count))
            guard data.count <= 32_768 else { throw LatheError.invalidRequest("stdin exceeds 32 KiB.") }
        }
        guard let text = String(data: data, encoding: .utf8) else { throw LatheError.invalidRequest("stdin must contain UTF-8 text.") }
        return text
    }

    private static func output<T: Encodable>(_ value: T) throws {
        FileHandle.standardOutput.write(try WireCodec.encode(value))
        FileHandle.standardOutput.write(Data([10]))
    }

    private static func stderr(_ text: String) { FileHandle.standardError.write(Data((text + "\n").utf8)) }

    private static let help = """
    Lathe — optional developer client for the running native app

      lathe status [--json]
      lathe sessions [--json]
      lathe new --workspace /path [title]
      lathe run [--workspace /path | --session UUID] [--detach] [--json] "prompt"
      lathe show SESSION_ID [--before RUN_ID] [--json]
      lathe cancel RUN_ID [--json]
      lathe events [--session UUID] [--after CURSOR] [--follow]
      lathe providers [--json]
      lathe provider-set --name NAME --api openAIResponses|openAIChat --base-url URL --model MODEL
        [--id UUID] [--allow-http] [--key-stdin | --clear-key] [--reasoning-effort VALUE]
      lathe tools RUN_ID [--json]
      lathe tool INVOCATION_ID [--json]
      lathe approve INVOCATION_ID --hash HASH
      lathe deny INVOCATION_ID --hash HASH

    Default: attach to the running Lathe app; never start a background engine.
    Global: --root /absolute/data/path (optional app data root)
    Test harness only: --developer-engine /absolute/path/to/lathe-engine --root /absolute/test/data
    These opt-in developer tools are not installed or included in the app distribution.
    run: --request-id UUID for an idempotent retry; --json emits NDJSON events.
    run: --provider UUID selects a saved connection; omitted selects mock.
         --permission fullAccess|autoApprove|acceptEdits|requestApproval (default requestApproval); --max-steps 1...24.
         All modes except explicit fullAccess require --detach because they may wait for approval.
         Inspect and approve exact requests using the app or tool/approve commands.
    Ctrl-C during run cancels that run. Ctrl-C during events only detaches.
    """
}
