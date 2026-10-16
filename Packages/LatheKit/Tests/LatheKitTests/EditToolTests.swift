import CryptoKit
import Darwin
import Foundation
import LatheDomain
import LatheProviders
import LatheRuntime
import LatheTools
import Testing

private struct EditFixture: Sendable {
    let root: URL
    let workspace: URL
    let state: URL
    var database: URL { state.appendingPathComponent("lathe.sqlite") }
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("lathe-edit-\(UUID().uuidString)").resolvingSymlinksInPath()
        workspace = root.appendingPathComponent("workspace", isDirectory: true)
        state = root.appendingPathComponent("state", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    }
    func cleanup() { try? FileManager.default.removeItem(at: root) }
    @discardableResult func write(_ path: String, _ data: Data) throws -> URL {
        let file = workspace.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: file)
        return file
    }
    static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    func arguments(path: String = "file.txt", old: String = "before", new: String = "after", hash: String) -> [String: Any] {
        ["path": path, "oldText": old, "newText": new, "expectedSHA256": hash]
    }
    func prepare(_ object: [String: Any]) throws -> PreparedTool {
        let bytes = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        return try ToolBroker.prepare(call: .init(id: UUID().uuidString, name: "edit_file", arguments: String(decoding: bytes, as: UTF8.self)),
                                      workspace: workspace, protectedPaths: [state])
    }
    func execute(_ prepared: PreparedTool) async throws -> ToolResult {
        try await ToolBroker.execute(prepared, runnerURL: URL(fileURLWithPath: "/unused"), journalRoot: state.appendingPathComponent("unused"))
    }
}

private actor EditCallTransport: HTTPStreamingTransport {
    let arguments: String
    private(set) var requests: [URLRequest] = []
    init(arguments: String) { self.arguments = arguments }
    func stream(request: URLRequest, onBytes: @escaping @Sendable (Data) async throws -> Bool) async throws {
        requests.append(request)
        let frame: Data
        if requests.count == 1 {
            let object: [String: Any] = ["choices": [["index": 0, "delta": ["tool_calls": [["index": 0,
                "id": "edit-fixture", "type": "function", "function": ["name": "edit_file", "arguments": arguments]]]],
                "finish_reason": "tool_calls"]]]
            frame = try JSONSerialization.data(withJSONObject: object)
        } else {
            frame = Data(#"{"choices":[{"index":0,"delta":{"content":"fixture complete"},"finish_reason":"stop"}]}"#.utf8)
        }
        _ = try await onBytes(Data("data: ".utf8) + frame + Data("\n\ndata: [DONE]\n\n".utf8))
    }
}

struct EditToolTests {
    @Test func exactReplacementPreservesUnrelatedUTF8NewlinesPermissionsAndReturnsNewDigest() async throws {
        let fixture = try EditFixture(); defer { fixture.cleanup() }
        let before = Data("head\r\nbefore 가🌱\r\ntail\n".utf8), after = Data("head\r\nafter 🧪\r\ntail\n".utf8)
        let file = try fixture.write("file.txt", before)
        #expect(chmod(file.path, 0o640) == 0)
        let prepared = try fixture.prepare(fixture.arguments(old: "before 가🌱", new: "after 🧪", hash: EditFixture.digest(before)))
        #expect(try ToolBroker.captureBeforeContent(prepared) == before)
        let result = try await fixture.execute(prepared)
        #expect(!result.isError && !result.wasCancelled)
        #expect(try Data(contentsOf: file) == after)
        let object = try #require(try JSONSerialization.jsonObject(with: Data(result.output.utf8)) as? [String: Any])
        #expect(object["path"] as? String == "file.txt")
        #expect(object["sha256"] as? String == EditFixture.digest(after))
        #expect(object["beforeSHA256"] as? String == EditFixture.digest(before))
        #expect(object["written"] as? Bool == true && object["replacements"] as? Int == 1)
        #expect(object["bytes"] as? Int == after.count)
        var info = stat(); #expect(stat(file.path, &info) == 0)
        #expect(info.st_mode & 0o777 == 0o640)
        await #expect(throws: (any Error).self) { try await fixture.execute(prepared) }
        #expect(try Data(contentsOf: file) == after)
    }

    @Test func editArgumentsAreStrictAndApprovalHashBindsEveryChange() throws {
        let fixture = try EditFixture(); defer { fixture.cleanup() }
        let before = Data("before".utf8)
        try fixture.write("file.txt", before)
        let base = fixture.arguments(hash: EditFixture.digest(before))
        let original = try fixture.prepare(base)
        #expect(try fixture.prepare(base).requestHash == original.requestHash)
        for (key, value): (String, Any) in [
            ("oldText", ""), ("oldText", 7), ("newText", false), ("oldText", "a\0b"), ("newText", "a\0b"),
            ("expectedSHA256", "missing"), ("expectedSHA256", String(repeating: "A", count: 64)),
            ("expectedSHA256", String(repeating: "a", count: 63)), ("extra", "x"),
            ("path", "/etc/hosts"), ("path", "../outside"), ("path", ".git/config"),
            ("newText", String(repeating: "x", count: 32_768)),
        ] {
            var object = base; object[key] = value
            #expect(throws: (any Error).self) { try fixture.prepare(object) }
        }
        for key in base.keys {
            var object = base; object.removeValue(forKey: key)
            #expect(throws: (any Error).self) { try fixture.prepare(object) }
        }
        #expect(throws: (any Error).self) { try fixture.prepare(fixture.arguments(new: "before", hash: EditFixture.digest(before))) }
        #expect(throws: (any Error).self) { try fixture.prepare(fixture.arguments(path: "missing.txt", hash: EditFixture.digest(before))) }
        for (key, value) in [("oldText", "different"), ("newText", "different"), ("expectedSHA256", String(repeating: "0", count: 64))] {
            var object = base; object[key] = value
            #expect(try fixture.prepare(object).requestHash != original.requestHash)
        }
    }

    @Test func editUsesWritePermissionPolicyIncludingSensitiveAndExecutablePaths() throws {
        let fixture = try EditFixture(); defer { fixture.cleanup() }
        let before = Data("before".utf8), hash = EditFixture.digest(before)
        for path in ["src/main.swift", ".env", "Package.swift", "src/APIKey.swift", "src/executable.py"] {
            let file = try fixture.write(path, before)
            if path == "src/executable.py" { #expect(chmod(file.path, 0o700) == 0) }
            let prepared = try fixture.prepare(fixture.arguments(path: path, hash: hash))
            #expect(prepared.effect == .write)
            #expect(PolicyEngine.decision(prepared, mode: .fullAccess) == .allow)
            #expect(PolicyEngine.decision(prepared, mode: .acceptEdits) == .allow)
            #expect(PolicyEngine.decision(prepared, mode: .requestApproval) == .ask)
            #expect(PolicyEngine.decision(prepared, mode: .autoApprove) == (path == "src/main.swift" ? .allow : .ask))
        }
    }

    @Test func preparationDoesNotReadBodyOrCheckSHABeforeApproval() throws {
        let fixture = try EditFixture(); defer { fixture.cleanup() }
        let body = Data("unreadable private fixture".utf8)
        let file = try fixture.write("file.txt", body)
        #expect(chmod(file.path, 0o000) == 0)
        defer { _ = chmod(file.path, 0o600) }
        let prepared = try fixture.prepare(fixture.arguments(hash: String(repeating: "0", count: 64)))
        #expect(PolicyEngine.decision(prepared, mode: .requestApproval) == .ask)
        #expect(!prepared.summary.contains("unreadable private fixture"))
        #expect(throws: (any Error).self) { try ToolBroker.captureBeforeContent(prepared) }
        #expect(chmod(file.path, 0o600) == 0)
        #expect(throws: (any Error).self) { try ToolBroker.captureBeforeContent(prepared) }
        #expect(try Data(contentsOf: file) == body)
    }

    @Test func exactBytesDistinguishCanonicalUnicodeAndAllowNormalizationChanges() async throws {
        let fixture = try EditFixture(); defer { fixture.cleanup() }
        let before = Data("prefix e\u{301} suffix\r\n".utf8)
        let file = try fixture.write("file.txt", before), hash = EditFixture.digest(before)
        let wrongBytes = try fixture.prepare(fixture.arguments(old: "é", new: "x", hash: hash))
        #expect(throws: (any Error).self) { try ToolBroker.captureBeforeContent(wrongBytes) }
        await #expect(throws: (any Error).self) { try await fixture.execute(wrongBytes) }
        #expect(try Data(contentsOf: file) == before)
        // Swift String equality considers these equivalent; edit_file must not.
        let normalize = try fixture.prepare(fixture.arguments(old: "e\u{301}", new: "é", hash: hash))
        _ = try await fixture.execute(normalize)
        #expect(try Data(contentsOf: file) == Data("prefix é suffix\r\n".utf8))
    }

    @Test func missingOrRepeatedMatchesIncludingOverlapsNeverMutateTheFile() async throws {
        let fixture = try EditFixture(); defer { fixture.cleanup() }
        for (text, old) in [("aaa", "aa"), ("abababa", "aba"), ("before before", "before"), ("unrelated", "before")] {
            let before = Data(text.utf8), file = try fixture.write("file.txt", Data(text.utf8))
            let prepared = try fixture.prepare(fixture.arguments(old: old, new: "after", hash: EditFixture.digest(before)))
            #expect(throws: (any Error).self) { try ToolBroker.captureBeforeContent(prepared) }
            await #expect(throws: (any Error).self) { try await fixture.execute(prepared) }
            #expect(try Data(contentsOf: file) == before)
        }
    }

    @Test func deletionIsAllowedButBinaryInvalidUTF8AndOversizedFilesAreRejected() async throws {
        let fixture = try EditFixture(); defer { fixture.cleanup() }
        let original = Data("head\r\nbefore\r\ntail".utf8)
        let file = try fixture.write("file.txt", original)
        let deletion = try fixture.prepare(fixture.arguments(old: "before\r\n", new: "", hash: EditFixture.digest(original)))
        _ = try await fixture.execute(deletion)
        #expect(try Data(contentsOf: file) == Data("head\r\ntail".utf8))
        for bytes in [Data("before\0after".utf8), Data("before".utf8) + Data([0xff]), Data("before".utf8) + Data(repeating: 120, count: 262_144)] {
            try bytes.write(to: file)
            let prepared = try fixture.prepare(fixture.arguments(hash: EditFixture.digest(bytes)))
            #expect(throws: (any Error).self) { try ToolBroker.captureBeforeContent(prepared) }
            await #expect(throws: (any Error).self) { try await fixture.execute(prepared) }
            #expect(try Data(contentsOf: file) == bytes)
        }
    }

    @Test func replacementResultHonorsByteLimitEvenWithSmallArguments() async throws {
        let fixture = try EditFixture(); defer { fixture.cleanup() }
        for size in [262_143, 262_144] {
            let before = Data("X".utf8) + Data(repeating: 120, count: size - 1)
            let file = try fixture.write("file.txt", before)
            let prepared = try fixture.prepare(fixture.arguments(old: "X", new: "YZ", hash: EditFixture.digest(before)))
            if size == 262_143 {
                _ = try await fixture.execute(prepared)
                let after = try Data(contentsOf: file)
                #expect(after.count == 262_144 && after.prefix(2) == Data("YZ".utf8))
            } else {
                #expect(throws: (any Error).self) { try ToolBroker.captureBeforeContent(prepared) }
                await #expect(throws: (any Error).self) { try await fixture.execute(prepared) }
                #expect(try Data(contentsOf: file) == before)
            }
        }
    }

    @Test func changedSHARootAndLinksAreRejectedAcrossApprovalAndBaselineBoundaries() async throws {
        let fixture = try EditFixture(); defer { fixture.cleanup() }
        let before = Data("before".utf8), human = Data("human edit".utf8)
        let file = try fixture.write("sub/file.txt", before)
        let prepared = try fixture.prepare(fixture.arguments(path: "sub/file.txt", hash: EditFixture.digest(before)))
        #expect(try ToolBroker.captureBeforeContent(prepared) == before)
        try human.write(to: file)
        await #expect(throws: (any Error).self) { try await fixture.execute(prepared) }
        #expect(try Data(contentsOf: file) == human)
        try before.write(to: file)
        let outside = fixture.root.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
        let externalFile = outside.appendingPathComponent("file.txt")
        try before.write(to: externalFile)
        try FileManager.default.removeItem(at: file.deletingLastPathComponent())
        try FileManager.default.createSymbolicLink(at: file.deletingLastPathComponent(), withDestinationURL: outside)
        await #expect(throws: (any Error).self) { try await fixture.execute(prepared) }
        #expect(try Data(contentsOf: externalFile) == before)
        #expect(throws: (any Error).self) { try fixture.prepare(fixture.arguments(path: "sub/file.txt", hash: EditFixture.digest(before))) }
        #expect(link(externalFile.path, fixture.workspace.appendingPathComponent("hardlink.txt").path) == 0)
        #expect(throws: (any Error).self) { try fixture.prepare(fixture.arguments(path: "hardlink.txt", hash: EditFixture.digest(before))) }
        let rootFile = try fixture.write("file.txt", before)
        let rootEdit = try fixture.prepare(fixture.arguments(hash: EditFixture.digest(before)))
        try FileManager.default.moveItem(at: fixture.workspace, to: fixture.root.appendingPathComponent("old-workspace"))
        try FileManager.default.createDirectory(at: fixture.workspace, withIntermediateDirectories: false)
        try before.write(to: rootFile)
        await #expect(throws: (any Error).self) { try await fixture.execute(rootEdit) }
        #expect(try Data(contentsOf: rootFile) == before)
    }

    @Test func cancelledEditCannotCaptureBaselineOrMutate() async throws {
        let fixture = try EditFixture(); defer { fixture.cleanup() }
        let before = Data("before".utf8), file = try fixture.write("file.txt", Data("before".utf8))
        let prepared = try fixture.prepare(fixture.arguments(hash: EditFixture.digest(before)))
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            #expect(throws: CancellationError.self) { try ToolBroker.captureBeforeContent(prepared) }
            return try await fixture.execute(prepared)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(try Data(contentsOf: file) == before)
    }

    @Test(arguments: [true, false])
    func runtimeEditStoresBaselineOnlyAfterExactApprovalAndDenialLeavesNoBody(approved: Bool) async throws {
        let fixture = try EditFixture(); defer { fixture.cleanup() }
        let before = Data("head before tail".utf8), file = try fixture.write("file.txt", Data("head before tail".utf8))
        let hash = EditFixture.digest(before)
        let json = try JSONSerialization.data(withJSONObject: fixture.arguments(hash: hash))
        let transport = EditCallTransport(arguments: String(decoding: json, as: UTF8.self))
        let runtime = try EngineRuntime(databaseURL: fixture.database, credentials: MemoryCredentialStore(), modelClient: ModelClient(transport: transport))
        let profile = ProviderProfile(name: "fixture", api: .openAIChat, baseURL: "https://fixture.invalid/v1", model: "fixture")
        _ = try await runtime.saveProviderProfile(profile, apiKey: nil, clearCredential: false)
        let session = try await runtime.createSession(title: "edit fixture", workspacePath: fixture.workspace.path)
        let run = try await runtime.submit(sessionID: session.id, prompt: "edit fixture", requestID: UUID(), configuration: .init(profile: profile, permissionMode: .requestApproval))
        let deadline = ContinuousClock.now + .seconds(5)
        var pending: ToolInvocationSnapshot?
        while pending == nil, ContinuousClock.now < deadline {
            pending = try await runtime.invocations(runID: run.id).first(where: { $0.state == .pendingApproval })
            if pending == nil { try await Task.sleep(for: .milliseconds(5)) }
        }
        let item = try #require(pending)
        #expect(item.name == "edit_file" && item.effect == .write)
        #expect(item.beforeBlobID == nil && item.blobID == nil && item.output == nil)
        let baseline = fixture.state.appendingPathComponent("blobs/" + hash)
        #expect(!FileManager.default.fileExists(atPath: baseline.path))
        #expect(try Data(contentsOf: file) == before)
        await #expect(throws: LatheError.self) {
            try await runtime.decideApproval(invocationID: item.id, requestHash: String(repeating: "0", count: 64), approved: true)
        }
        _ = try await runtime.decideApproval(invocationID: item.id, requestHash: item.requestHash, approved: approved)
        var completed = false
        while ContinuousClock.now < deadline {
            let snapshot = try await runtime.session(id: session.id)
            if snapshot.runs.first(where: { $0.id == run.id })?.state == .completed { completed = true; break }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(completed)
        let result = try await runtime.invocation(id: item.id)
        #expect(result.state == (approved ? .completed : .denied))
        #expect(await transport.requests.count == 2)
        if approved {
            #expect(result.beforeBlobID == hash && result.blobID != nil)
            #expect(try Data(contentsOf: baseline) == before)
            #expect(try Data(contentsOf: file) == Data("head after tail".utf8))
        } else {
            #expect(result.beforeBlobID == nil && result.blobID == nil)
            #expect(!FileManager.default.fileExists(atPath: baseline.path))
            #expect(try Data(contentsOf: file) == before)
            for request in await transport.requests {
                #expect(!String(decoding: request.httpBody ?? Data(), as: UTF8.self).contains("head before tail"))
            }
        }
        await runtime.shutdown()
    }
}
