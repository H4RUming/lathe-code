import CoreFoundation
import CryptoKit
import Foundation
import LatheDomain
import LatheExecution

public enum ToolError: Error, LocalizedError, Sendable {
    case invalid(String), denied(String), preconditionChanged(String), executionUnknown(String), io(String, Int32)
    public var errorDescription: String? {
        switch self {
        case .invalid(let message), .denied(let message), .preconditionChanged(let message): return message
        case .executionUnknown(let message): return "Execution needs reconciliation: \(message)"
        case .io(let operation, let code): return "\(operation) failed (errno \(code))"
        }
    }
}

public enum PolicyDecision: Equatable, Sendable { case allow, ask, deny(String) }
public enum PolicyEngine {
    public static func decision(_ prepared: PreparedTool, mode: PermissionMode) -> PolicyDecision {
        if prepared.effect == .read { return .allow }
        switch mode {
        case .plan: return .deny("Plan mode permits read-only file tools; writes and unsandboxed commands are blocked.")
        case .dontAsk: return .deny("This operation requires approval, and dontAsk mode cannot request approval.")
        case .acceptEdits: return prepared.effect == .write ? .allow : .ask
        case .manual: return .ask
        }
    }
}

public struct PreparedTool: Sendable {
    public let name: String
    /// Canonical JSON bound to requestHash and displayed by approval clients.
    public let arguments: String
    public let requestHash: String
    public let summary: String
    public let effect: ToolEffect
    public let workspace: URL
    public let beforeContent: Data?
    let rootIdentity: FileIdentity
    let protectedPaths: [URL]
    let operation: Operation
    enum Operation: Sendable {
        case list(String), read(String)
        case write(path: String, content: Data, expectedSHA256: String)
        case command(CommandRequest, relativeDirectory: String, directoryIdentity: FileIdentity)
    }
}

public struct ToolResult: Sendable {
    public let output: String
    public let isError: Bool
    public let rawOutput: Data?
    public let wasCancelled: Bool
    public init(output: String, isError: Bool, rawOutput: Data? = nil, wasCancelled: Bool = false) {
        self.output = output; self.isError = isError; self.rawOutput = rawOutput; self.wasCancelled = wasCancelled
    }
}

public enum ToolBroker {
    static let fileLimit = 262_144
    static let previewLimit = 49_152
    static let commandOutputLimit = 131_072
    public static let definitions: [ToolDefinition] = [
        ToolDefinition(name: "list_directory", description: "List a workspace-relative directory. Symlinks cannot be followed; .git and engine data are protected.", parametersJSON: #"{"type":"object","properties":{"path":{"type":"string","description":"Relative directory; use . for the workspace root"}},"required":["path"],"additionalProperties":false}"#),
        ToolDefinition(name: "read_file", description: "Read a UTF-8 workspace file (up to 256 KiB). Returns sha256 required by write_file. Large content previews are truncated; use small files in this first implementation.", parametersJSON: #"{"type":"object","properties":{"path":{"type":"string"}},"required":["path"],"additionalProperties":false}"#),
        ToolDefinition(name: "write_file", description: "Atomically write UTF-8 content (the complete arguments JSON must fit 32 KiB). expectedSHA256 must match the previous read, or be missing to create a new file. Existing directories must already exist. Requires edit permission.", parametersJSON: #"{"type":"object","properties":{"path":{"type":"string"},"content":{"type":"string"},"expectedSHA256":{"type":"string","description":"64 lowercase hex digits from read_file, or missing for a new file"}},"required":["path","content","expectedSHA256"],"additionalProperties":false}"#),
        ToolDefinition(name: "run_command", description: "Run an explicitly approved UNSANDBOXED local command. executable is an absolute path; arguments are passed literally. workingDirectory is workspace-relative. Only a fixed system PATH and locale are supplied; no API credentials or parent environment. Input is closed; use noninteractive commands. Output is bounded to 128 KiB and timeout to 120 seconds.", parametersJSON: #"{"type":"object","properties":{"executable":{"type":"string"},"arguments":{"type":"array","items":{"type":"string"}},"workingDirectory":{"type":"string"},"timeoutSeconds":{"type":"number","minimum":0.1,"maximum":120}},"required":["executable","arguments","workingDirectory","timeoutSeconds"],"additionalProperties":false}"#),
    ]

    public static func prepare(call: ModelToolCall, workspace: URL, protectedPaths: [URL] = []) throws -> PreparedTool {
        guard call.arguments.utf8.count <= 32_768,
              let bytes = call.arguments.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] else {
            throw ToolError.invalid("Tool arguments must be a bounded JSON object.")
        }
        let root = workspace.resolvingSymlinksInPath().standardizedFileURL
        let protected = protectedPaths.map { $0.resolvingSymlinksInPath().standardizedFileURL }
        let access = try WorkspaceFiles(root: root, protectedPaths: protected)
        let operation: PreparedTool.Operation, effect: ToolEffect, summary: String
        var baseline: Data?
        func string(_ key: String) throws -> String {
            guard let value = object[key] as? String, !value.utf8.contains(0) else { throw ToolError.invalid("\(key) must be a string without NUL.") }
            return value
        }
        func keys(_ expected: Set<String>) throws {
            guard Set(object.keys) == expected else { throw ToolError.invalid("Unexpected or missing arguments for \(call.name).") }
        }
        switch call.name {
        case "list_directory":
            try keys(["path"])
            let path = try access.validate(try string("path"), allowRoot: true)
            try access.checkDirectory(path)
            operation = .list(path); effect = .read; summary = "List directory: \(path)"
        case "read_file":
            try keys(["path"])
            let path = try access.validate(try string("path"))
            _ = try access.read(path)
            operation = .read(path); effect = .read; summary = "Read file: \(path)"
        case "write_file":
            try keys(["path", "content", "expectedSHA256"])
            let path = try access.validate(try string("path")), expected = try string("expectedSHA256")
            let content = Data(try string("content").utf8)
            guard content.count <= fileLimit else { throw ToolError.invalid("File content exceeds 256 KiB.") }
            guard expected == "missing" || (expected.count == 64 && expected.allSatisfy({ "0123456789abcdef".contains($0) })) else {
                throw ToolError.invalid("expectedSHA256 must be a SHA-256 digest from read_file, or missing.")
            }
            baseline = try access.checkPrecondition(path, expected: expected)
            operation = .write(path: path, content: content, expectedSHA256: expected)
            effect = .write; summary = "\(expected == "missing" ? "Create" : "Replace") file: \(path) (\(content.count) bytes; SHA-256 \(expected))"
        case "run_command":
            try keys(["executable", "arguments", "workingDirectory", "timeoutSeconds"])
            let executable = try string("executable")
            guard executable.hasPrefix("/"), let arguments = object["arguments"] as? [String],
                  arguments.count <= 256, arguments.allSatisfy({ !$0.utf8.contains(0) }),
                  let number = object["timeoutSeconds"] as? NSNumber,
                  CFGetTypeID(number) != CFBooleanGetTypeID(),
                  number.doubleValue.isFinite, (0.1...120).contains(number.doubleValue) else {
                throw ToolError.invalid("Command needs an absolute executable, literal string arguments, and a timeout between 0.1 and 120 seconds.")
            }
            let relative = try access.validate(try string("workingDirectory"), allowRoot: true)
            let directoryIdentity = try access.directoryIdentity(relative)
            let cwd = relative == "." ? root : root.appendingPathComponent(relative)
            let request = CommandRequest(executable: executable, arguments: arguments, workingDirectory: cwd.path,
                environment: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "en_US.UTF-8"],
                timeoutSeconds: number.doubleValue, outputLimitBytes: commandOutputLimit)
            try request.validate()
            let encoded = try JSONEncoder().encode(RunnerRequest(protocolVersion: 1, command: request))
            guard encoded.count <= 131_072 else { throw ToolError.invalid("Command request exceeds the runner's 128 KiB limit.") }
            operation = .command(request, relativeDirectory: relative, directoryIdentity: directoryIdentity); effect = .shell
            let argv = try JSONSerialization.data(withJSONObject: [executable] + arguments, options: [.withoutEscapingSlashes])
            summary = "UNSANDBOXED local command; unrestricted filesystem/network effects.\nargv: \(String(decoding: argv, as: UTF8.self))\ncwd: \(cwd.path)\ntimeout: \(request.timeoutSeconds)s; output: \(commandOutputLimit) bytes; input: closed\nenvironment: PATH=/usr/bin:/bin:/usr/sbin:/sbin, LANG=en_US.UTF-8"
        default: throw ToolError.invalid("Unknown tool: \(call.name)")
        }
        let canonical = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        guard canonical.count <= 32_768 else { throw ToolError.invalid("Canonical tool arguments exceed 32 KiB.") }
        let arguments = String(decoding: canonical, as: UTF8.self)
        let fingerprint = [call.name, root.path, access.identity.description, arguments, protected.map(\.path).sorted().joined(separator: "\n")].joined(separator: "\0")
        return PreparedTool(name: call.name, arguments: arguments, requestHash: digest(Data(fingerprint.utf8)),
            summary: String(decoding: Data(summary.utf8).prefix(900), as: UTF8.self) + (summary.utf8.count > 900 ? "… (see exact canonical arguments)" : ""), effect: effect, workspace: root, beforeContent: baseline,
            rootIdentity: access.identity, protectedPaths: protected, operation: operation)
    }

    public static func execute(_ prepared: PreparedTool, runnerURL: URL, journalRoot: URL) async throws -> ToolResult {
        try Task.checkCancellation()
        let access = try WorkspaceFiles(root: prepared.workspace, protectedPaths: prepared.protectedPaths)
        guard access.identity == prepared.rootIdentity else { throw ToolError.preconditionChanged("Workspace identity changed since preparation.") }
        switch prepared.operation {
        case .list(let path):
            return try jsonResult(["path": path, "entries": access.list(path)])
        case .read(let path):
            let bytes = try access.read(path)
            guard let text = String(data: bytes, encoding: .utf8) else { throw ToolError.invalid("read_file supports UTF-8 text only.") }
            var previewBytes = min(bytes.count, 32_768)
            var rendered: Data
            repeat {
                let content = previewBytes == bytes.count ? text : String(decoding: bytes.prefix(previewBytes), as: UTF8.self)
                rendered = try JSONSerialization.data(withJSONObject: ["path": path, "sha256": digest(bytes), "content": content,
                    "truncated": previewBytes < bytes.count], options: [.sortedKeys, .withoutEscapingSlashes])
                if rendered.count <= previewLimit { break }
                previewBytes /= 2
            } while previewBytes > 0
            return ToolResult(output: String(decoding: rendered, as: UTF8.self), isError: false, rawOutput: bytes)
        case .write(let path, let content, let expected):
            try access.write(path, content: content, expected: expected)
            return try jsonResult(["path": path, "sha256": digest(content), "bytes": content.count, "written": true])
        case .command(let command, let relative, let identity):
            guard try access.directoryIdentity(relative) == identity else {
                throw ToolError.preconditionChanged("Working directory identity changed since preparation.")
            }
            return try await RunnerBridge.execute(command, runnerURL: runnerURL, journalRoot: journalRoot)
        }
    }

    static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func jsonResult(_ object: [String: Any]) throws -> ToolResult {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        guard data.count <= 1_048_576 else { throw ToolError.invalid("Tool output exceeds 1 MiB; choose a smaller directory.") }
        return ToolResult(output: preview(data), isError: false, rawOutput: data)
    }
    static func preview(_ data: Data) -> String {
        guard data.count > previewLimit else { return String(decoding: data, as: UTF8.self) }
        return String(decoding: data.prefix(previewLimit - 128), as: UTF8.self) + "\n[Output preview truncated; full bounded output retained in the local tool blob.]"
    }
}
