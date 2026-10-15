import CryptoKit
import Darwin
import Foundation
import LatheDomain
import LatheTools
import Testing

private struct ToolFixture {
    let parent: URL
    let workspace: URL
    let state: URL
    init() throws {
        parent = FileManager.default.temporaryDirectory.appendingPathComponent("lathe-tools-\(UUID().uuidString)").resolvingSymlinksInPath()
        workspace = parent.appendingPathComponent("workspace", isDirectory: true)
        state = workspace.appendingPathComponent("engine-state", isDirectory: true)
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
    }
    func cleanup() { try? FileManager.default.removeItem(at: parent) }
    func prepare(_ name: String, _ object: [String: Any]) throws -> PreparedTool {
        let json = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return try ToolBroker.prepare(call: ModelToolCall(id: UUID().uuidString, name: name, arguments: String(decoding: json, as: UTF8.self)), workspace: workspace, protectedPaths: [state])
    }
    func execute(_ prepared: PreparedTool) async throws -> ToolResult {
        try await ToolBroker.execute(prepared, runnerURL: URL(fileURLWithPath: "/unused"), journalRoot: parent.appendingPathComponent(UUID().uuidString))
    }
}

struct ToolTests {
    @Test func createsReadsAndReplacesFilesWithExactSHA() async throws {
        let fixture = try ToolFixture(); defer { fixture.cleanup() }
        let create = try fixture.prepare("write_file", ["path": "hello.txt", "content": "before 🌱\n", "expectedSHA256": "missing"])
        #expect(create.beforeContent == nil)
        #expect(PolicyEngine.decision(create, mode: .manual) == .ask)
        _ = try await fixture.execute(create)
        let read = try await fixture.execute(fixture.prepare("read_file", ["path": "hello.txt"]))
        let object = try #require(try JSONSerialization.jsonObject(with: Data(read.output.utf8)) as? [String: Any])
        let digest = try #require(object["sha256"] as? String)
        #expect(object["content"] as? String == "before 🌱\n")
        let update = try fixture.prepare("write_file", ["path": "hello.txt", "content": "after\n", "expectedSHA256": digest])
        #expect(update.beforeContent == Data("before 🌱\n".utf8))
        _ = try await fixture.execute(update)
        #expect(try String(contentsOf: fixture.workspace.appendingPathComponent("hello.txt"), encoding: .utf8) == "after\n")
        await #expect(throws: (any Error).self) { try await fixture.execute(update) }
    }

    @Test func permissionsNeverGrantShellThroughAcceptEditsOrPlan() throws {
        let fixture = try ToolFixture(); defer { fixture.cleanup() }
        let write = try fixture.prepare("write_file", ["path": "new", "content": "x", "expectedSHA256": "missing"])
        let command = try fixture.prepare("run_command", ["executable": "/bin/echo", "arguments": ["hello"], "workingDirectory": ".", "timeoutSeconds": 5])
        let read = try fixture.prepare("list_directory", ["path": "."])
        #expect(PolicyEngine.decision(write, mode: .acceptEdits) == .allow)
        #expect(PolicyEngine.decision(command, mode: .acceptEdits) == .ask)
        #expect(PolicyEngine.decision(command, mode: .manual) == .ask)
        for mode in [PermissionMode.plan, .dontAsk] {
            if case .deny = PolicyEngine.decision(write, mode: mode) {} else { Issue.record("Unexpected write grant") }
            if case .deny = PolicyEngine.decision(command, mode: mode) {} else { Issue.record("Unexpected shell grant") }
            #expect(PolicyEngine.decision(read, mode: mode) == .allow)
        }
        #expect(command.summary.contains("UNSANDBOXED"))
    }

    @Test func traversalSymlinksGitAndProtectedStateAreBlocked() async throws {
        let fixture = try ToolFixture(); defer { fixture.cleanup() }
        try Data("outside".utf8).write(to: fixture.parent.appendingPathComponent("outside"))
        try FileManager.default.createSymbolicLink(at: fixture.workspace.appendingPathComponent("link"), withDestinationURL: fixture.parent.appendingPathComponent("outside"))
        try FileManager.default.createSymbolicLink(at: fixture.workspace.appendingPathComponent("linked-dir"), withDestinationURL: fixture.parent)
        for path in ["../outside", "/etc/hosts", ".git/config", ".GIT/config", "engine-state/receipt", "link", "linked-dir/outside", "a/../outside", "a//b"] {
            #expect(throws: (any Error).self) { try fixture.prepare("read_file", ["path": path]) }
        }
        let list = try await fixture.execute(fixture.prepare("list_directory", ["path": "."]))
        #expect(!list.output.contains("engine-state"))
        #expect(list.output.contains("symlink (blocked)"))
    }

    @Test func rechecksContentAndParentLinksImmediatelyBeforeWrite() async throws {
        let fixture = try ToolFixture(); defer { fixture.cleanup() }
        let directory = fixture.workspace.appendingPathComponent("dir")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let file = directory.appendingPathComponent("file")
        try Data("before".utf8).write(to: file)
        let hash = SHA256.hash(data: Data("before".utf8)).map { String(format: "%02x", $0) }.joined()
        let prepared = try fixture.prepare("write_file", ["path": "dir/file", "content": "agent", "expectedSHA256": hash])
        try Data("human".utf8).write(to: file)
        await #expect(throws: (any Error).self) { try await fixture.execute(prepared) }
        #expect(try String(contentsOf: file, encoding: .utf8) == "human")
        try FileManager.default.removeItem(at: directory)
        try FileManager.default.createSymbolicLink(at: directory, withDestinationURL: fixture.parent)
        await #expect(throws: (any Error).self) { try await fixture.execute(prepared) }
        #expect(!FileManager.default.fileExists(atPath: fixture.parent.appendingPathComponent("file").path))
    }

    @Test func hardlinksAndSpecialFilesCannotExposeOtherRootsOrBlockReads() throws {
        let fixture = try ToolFixture(); defer { fixture.cleanup() }
        let original = fixture.parent.appendingPathComponent("outside"), hardlink = fixture.workspace.appendingPathComponent("hardlink")
        try Data("private".utf8).write(to: original)
        #expect(link(original.path, hardlink.path) == 0)
        #expect(throws: (any Error).self) { try fixture.prepare("read_file", ["path": "hardlink"]) }
        #expect(mkfifo(fixture.workspace.appendingPathComponent("fifo").path, 0o600) == 0)
        #expect(throws: (any Error).self) { try fixture.prepare("read_file", ["path": "fifo"]) }
    }

    @Test func creationPreconditionAndWorkspaceIdentitySurviveApprovalDelay() async throws {
        let fixture = try ToolFixture(); defer { fixture.cleanup() }
        let prepared = try fixture.prepare("write_file", ["path": "new", "content": "agent", "expectedSHA256": "missing"])
        try Data("human".utf8).write(to: fixture.workspace.appendingPathComponent("new"))
        await #expect(throws: (any Error).self) { try await fixture.execute(prepared) }
        try FileManager.default.moveItem(at: fixture.workspace, to: fixture.parent.appendingPathComponent("old"))
        try FileManager.default.createDirectory(at: fixture.workspace, withIntermediateDirectories: false)
        await #expect(throws: (any Error).self) { try await fixture.execute(prepared) }
        #expect(!FileManager.default.fileExists(atPath: fixture.workspace.appendingPathComponent("new").path))
    }

    @Test func argumentsAreStrictBoundedAndHashCanonical() throws {
        let fixture = try ToolFixture(); defer { fixture.cleanup() }
        for object: [String: Any] in [
            ["path": "x", "content": "x", "expectedSHA256": "missing", "extra": true],
            ["path": "x", "content": String(repeating: "x", count: 33_000), "expectedSHA256": "missing"],
            ["path": "x", "content": "x", "expectedSHA256": "anything"],
        ] { #expect(throws: (any Error).self) { try fixture.prepare("write_file", object) } }
        #expect(throws: (any Error).self) {
            try fixture.prepare("run_command", ["executable": "/bin/echo", "arguments": [], "workingDirectory": ".", "timeoutSeconds": true])
        }
        let first = try ToolBroker.prepare(call: ModelToolCall(id: "a", name: "write_file", arguments: #"{"path":"x","content":"hi","expectedSHA256":"missing"}"#), workspace: fixture.workspace)
        let second = try ToolBroker.prepare(call: ModelToolCall(id: "b", name: "write_file", arguments: #"{"expectedSHA256":"missing", "content":"hi", "path":"x"}"#), workspace: fixture.workspace)
        #expect(first.requestHash == second.requestHash)
    }

    @Test func commandWorkingDirectoryIsRevalidatedAfterApprovalDelay() async throws {
        let fixture = try ToolFixture(); defer { fixture.cleanup() }
        let cwd = fixture.workspace.appendingPathComponent("cwd")
        try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: false)
        let command = try fixture.prepare("run_command", ["executable": "/bin/echo", "arguments": ["test"], "workingDirectory": "cwd", "timeoutSeconds": 1])
        try FileManager.default.moveItem(at: cwd, to: fixture.workspace.appendingPathComponent("old-cwd"))
        try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: false)
        do { _ = try await fixture.execute(command); Issue.record("Changed cwd was accepted") }
        catch ToolError.preconditionChanged {} catch { Issue.record("Unexpected error: \(error)") }
    }

    @Test func readOutputPreviewIsBoundedAndCompleteBlobPreserved() async throws {
        let fixture = try ToolFixture(); defer { fixture.cleanup() }
        let contents = String(repeating: "안녕", count: 20_000)
        try Data(contents.utf8).write(to: fixture.workspace.appendingPathComponent("large"))
        let result = try await fixture.execute(fixture.prepare("read_file", ["path": "large"]))
        #expect(result.output.utf8.count <= 49_152)
        #expect(result.output.contains("truncated"))
        let raw = try #require(result.rawOutput)
        #expect(raw.count > 100_000)
        #expect(String(data: raw, encoding: .utf8) == contents)
        let object = try #require(try JSONSerialization.jsonObject(with: Data(result.output.utf8)) as? [String: Any])
        #expect((object["sha256"] as? String)?.count == 64)
        #expect(object["truncated"] as? Bool == true)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["LATHE_TEST_RUNNER"] != nil, "Set LATHE_TEST_RUNNER to exercise the native helper."))
    func nativeRunnerClosesInputPreservesRawBytesAndDoesNotInheritEnvironment() async throws {
        let path = try #require(ProcessInfo.processInfo.environment["LATHE_TEST_RUNNER"])
        let fixture = try ToolFixture(); defer { fixture.cleanup() }
        func execute(_ executable: String, _ args: [String], timeout: Double = 5) async throws -> ToolResult {
            let prepared = try fixture.prepare("run_command", ["executable": executable, "arguments": args, "workingDirectory": ".", "timeoutSeconds": timeout])
            return try await ToolBroker.execute(prepared, runnerURL: URL(fileURLWithPath: path), journalRoot: fixture.parent.appendingPathComponent(UUID().uuidString))
        }
        let environment = try await execute("/usr/bin/env", [])
        #expect(!environment.isError)
        #expect(String(decoding: try #require(environment.rawOutput), as: UTF8.self).split(separator: "\n").sorted() == ["LANG=en_US.UTF-8", "PATH=/usr/bin:/bin:/usr/sbin:/sbin"])
        let cat = try await execute("/bin/cat", [])
        #expect(!cat.isError)
        #expect(cat.rawOutput == Data())
        let bytes = try await execute("/bin/sh", ["-c", "printf '\\377\\000a'"])
        #expect(bytes.rawOutput == Data([255, 0, 97]))
        let timeout = try await execute("/bin/sleep", ["10"], timeout: 0.1)
        #expect(timeout.isError)
        #expect(timeout.output.contains("timedOut"))
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["LATHE_TEST_RUNNER"] != nil, "Set LATHE_TEST_RUNNER to exercise helper cancellation."))
    func runnerCancellationIsReceiptedAndJournalIsNeverReused() async throws {
        let path = try #require(ProcessInfo.processInfo.environment["LATHE_TEST_RUNNER"])
        let fixture = try ToolFixture(); defer { fixture.cleanup() }
        let command = try fixture.prepare("run_command", ["executable": "/bin/sh", "arguments": ["-c", "(trap '' TERM; /bin/sleep 0.8; /usr/bin/touch survived) & printf ready > ready; wait"], "workingDirectory": ".", "timeoutSeconds": 10])
        let journal = fixture.parent.appendingPathComponent("cancel-journal")
        let task = Task { try await ToolBroker.execute(command, runnerURL: URL(fileURLWithPath: path), journalRoot: journal) }
        let deadline = ContinuousClock.now + .seconds(5)
        while !FileManager.default.fileExists(atPath: fixture.workspace.appendingPathComponent("ready").path) {
            if ContinuousClock.now >= deadline { task.cancel(); _ = try? await task.value; Issue.record("Target failed to start"); return }
            try await Task.sleep(for: .milliseconds(10))
        }
        task.cancel()
        let result = try await task.value
        #expect(result.wasCancelled)
        #expect(result.isError)
        #expect(!FileManager.default.fileExists(atPath: fixture.workspace.appendingPathComponent("survived").path))
        #expect(FileManager.default.fileExists(atPath: journal.appendingPathComponent("execution/result.json").path))
        await #expect(throws: (any Error).self) {
            try await ToolBroker.execute(command, runnerURL: URL(fileURLWithPath: path), journalRoot: journal)
        }
    }

    @Test func successfulHelperExitWithoutReceiptIsUnknown() async throws {
        let fixture = try ToolFixture(); defer { fixture.cleanup() }
        let command = try fixture.prepare("run_command", ["executable": "/bin/echo", "arguments": ["never executed"], "workingDirectory": ".", "timeoutSeconds": 1])
        do {
            _ = try await ToolBroker.execute(command, runnerURL: URL(fileURLWithPath: "/usr/bin/true"), journalRoot: fixture.parent.appendingPathComponent("missing-receipt"))
            Issue.record("Missing receipt was treated as success")
        } catch ToolError.executionUnknown {} catch { Issue.record("Expected unknown execution, got \(error)") }
    }
}
