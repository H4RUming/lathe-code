import CryptoKit
import Darwin
import Foundation
import LatheDomain
@testable import LatheTools
import Testing

private struct SearchFixture: Sendable {
    let parent: URL
    let workspace: URL
    let state: URL

    init() throws {
        parent = FileManager.default.temporaryDirectory.appendingPathComponent("lathe-search-\(UUID().uuidString)").resolvingSymlinksInPath()
        workspace = parent.appendingPathComponent("workspace", isDirectory: true)
        state = workspace.appendingPathComponent("engine-state", isDirectory: true)
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
    }

    func cleanup() { try? FileManager.default.removeItem(at: parent) }
    @discardableResult func write(_ path: String, _ bytes: Data) throws -> URL {
        let url = workspace.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bytes.write(to: url)
        return url
    }
    @discardableResult func write(_ path: String, _ text: String) throws -> URL { try write(path, Data(text.utf8)) }
    func arguments(path: String = ".", glob: String = "*", hidden: Bool = false,
                   offset: Int = 0, limit: Int = 100, query: String? = nil, caseSensitive: Bool = true) -> [String: Any] {
        var value: [String: Any] = ["path": path, "nameGlob": glob, "includeHidden": hidden, "offset": offset, "limit": limit]
        if let query { value["query"] = query; value["caseSensitive"] = caseSensitive }
        return value
    }
    func prepare(_ arguments: [String: Any], name: String? = nil) throws -> PreparedTool {
        let data = try JSONSerialization.data(withJSONObject: arguments, options: [.sortedKeys])
        return try ToolBroker.prepare(call: ModelToolCall(id: UUID().uuidString,
            name: name ?? (arguments["query"] == nil ? "find_files" : "search_content"),
            arguments: String(decoding: data, as: UTF8.self)), workspace: workspace, protectedPaths: [state])
    }
    func execute(_ prepared: PreparedTool) async throws -> ToolResult {
        try await ToolBroker.execute(prepared, runnerURL: URL(fileURLWithPath: "/unused"), journalRoot: parent.appendingPathComponent("unused"))
    }
    func search(_ arguments: [String: Any]) async throws -> [String: Any] {
        let result = try await execute(prepare(arguments))
        #expect(!result.isError)
        #expect(result.output.utf8.count <= 49_152)
        #expect(result.rawOutput == Data(result.output.utf8))
        return try #require(try JSONSerialization.jsonObject(with: Data(result.output.utf8)) as? [String: Any])
    }
    static func matches(_ object: [String: Any]) throws -> [[String: Any]] {
        try #require(object["matches"] as? [[String: Any]])
    }
    static func paths(_ object: [String: Any]) throws -> [String] {
        try matches(object).map { try #require($0["path"] as? String) }
    }
}

struct WorkspaceSearchTests {
    @Test func searchesRequireExplicitRecursiveReadApprovalAndBindAllArguments() throws {
        let fixture = try SearchFixture(); defer { fixture.cleanup() }
        for query: String? in [nil, "needle"] {
            let arguments = fixture.arguments(query: query)
            let prepared = try fixture.prepare(arguments)
            #expect(prepared.effect == .read)
            #expect(PolicyEngine.decision(prepared, mode: .requestApproval) == .ask)
            #expect(PolicyEngine.decision(prepared, mode: .autoApprove) == .ask)
            #expect(PolicyEngine.decision(prepared, mode: .acceptEdits) == .allow)
            #expect(PolicyEngine.decision(prepared, mode: .fullAccess) == .allow)
            #expect(try fixture.prepare(arguments).requestHash == prepared.requestHash)
            #expect(try fixture.prepare(fixture.arguments(hidden: true, query: query)).requestHash != prepared.requestHash)
            #expect(try fixture.prepare(fixture.arguments(offset: 1, query: query)).requestHash != prepared.requestHash)
            #expect(try fixture.prepare(fixture.arguments(limit: 2, query: query)).requestHash != prepared.requestHash)
            #expect(try fixture.prepare(fixture.arguments(glob: "*.swift", query: query)).requestHash != prepared.requestHash)
        }
        let sensitive = try fixture.prepare(fixture.arguments(query: "Needle", caseSensitive: true))
        #expect(try fixture.prepare(fixture.arguments(query: "Needle", caseSensitive: false)).requestHash != sensitive.requestHash)
    }

    @Test func searchArgumentsRejectCoercionsTraversalAndUnboundedInputs() throws {
        let fixture = try SearchFixture(); defer { fixture.cleanup() }
        for query: String? in [nil, "needle"] {
            let base = fixture.arguments(query: query)
            for (key, value): (String, Any) in [
                ("includeHidden", 1), ("includeHidden", "false"), ("offset", true), ("offset", -1),
                ("offset", 0.5), ("offset", 1_001), ("limit", false), ("limit", 0), ("limit", 101),
                ("nameGlob", ""), ("nameGlob", "src/*.swift"), ("nameGlob", "a\0b"),
                ("nameGlob", String(repeating: "x", count: 129)), ("path", "../outside"),
                ("path", "/tmp"), ("path", "a/../b"), ("path", ".git"), ("extra", true),
            ] {
                var invalid = base; invalid[key] = value
                #expect(throws: (any Error).self) { try fixture.prepare(invalid) }
            }
            for key in base.keys {
                var missing = base; missing.removeValue(forKey: key)
                #expect(throws: (any Error).self) { try fixture.prepare(missing, name: query == nil ? "find_files" : "search_content") }
            }
        }
        for (key, value): (String, Any) in [
            ("query", ""), ("query", "a\nb"), ("query", "a\rb"), ("query", "a\0b"),
            ("query", String(repeating: "가", count: 86)), ("caseSensitive", 1), ("caseSensitive", "true"),
        ] {
            var invalid = fixture.arguments(query: "needle"); invalid[key] = value
            #expect(throws: (any Error).self) { try fixture.prepare(invalid) }
        }
    }

    @Test func preparingRecursiveSearchDoesNotOpenUnreadableBodiesOrTraverseChildren() throws {
        let fixture = try SearchFixture(); defer { fixture.cleanup() }
        let body = try fixture.write("private.txt", "sensitive fixture body")
        let nested = try fixture.write("closed/nested.txt", "sensitive nested fixture")
        let directory = nested.deletingLastPathComponent()
        #expect(chmod(body.path, 0o000) == 0)
        #expect(chmod(directory.path, 0o000) == 0)
        defer { _ = chmod(body.path, 0o600); _ = chmod(directory.path, 0o700) }
        for query: String? in [nil, "sensitive"] {
            let prepared = try fixture.prepare(fixture.arguments(query: query))
            #expect(PolicyEngine.decision(prepared, mode: .requestApproval) == .ask)
            #expect(!prepared.summary.contains("sensitive fixture body"))
            #expect(try ToolBroker.captureBeforeContent(prepared) == nil)
        }
    }

    @Test func approvalCannotBeReusedAfterSearchRootOrWorkspaceReplacement() async throws {
        let fixture = try SearchFixture(); defer { fixture.cleanup() }
        try fixture.write("sub/original.txt", "needle")
        let nested = try fixture.prepare(fixture.arguments(path: "sub", query: "needle"))
        try FileManager.default.moveItem(at: fixture.workspace.appendingPathComponent("sub"), to: fixture.workspace.appendingPathComponent("old-sub"))
        try fixture.write("sub/replacement.txt", "needle replacement")
        await #expect(throws: (any Error).self) { try await fixture.execute(nested) }
        let root = try fixture.prepare(fixture.arguments(query: "needle"))
        try FileManager.default.moveItem(at: fixture.workspace, to: fixture.parent.appendingPathComponent("old-workspace"))
        try FileManager.default.createDirectory(at: fixture.workspace, withIntermediateDirectories: false)
        await #expect(throws: (any Error).self) { try await fixture.execute(root) }
    }

    @Test func searchRootSymlinkSwapIsRejectedAndTraversalNeverFollowsLinksOrSpecialFiles() async throws {
        let fixture = try SearchFixture(); defer { fixture.cleanup() }
        let outside = fixture.parent.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
        let secret = outside.appendingPathComponent("secret.txt")
        try Data("needle outside secret".utf8).write(to: secret)
        try fixture.write("inside.txt", "needle inside")
        try fixture.write("sub/original.txt", "original")
        let prepared = try fixture.prepare(fixture.arguments(path: "sub", query: "needle"))
        try FileManager.default.removeItem(at: fixture.workspace.appendingPathComponent("sub"))
        try FileManager.default.createSymbolicLink(at: fixture.workspace.appendingPathComponent("sub"), withDestinationURL: outside)
        await #expect(throws: (any Error).self) { try await fixture.execute(prepared) }
        try FileManager.default.createSymbolicLink(at: fixture.workspace.appendingPathComponent("link.txt"), withDestinationURL: secret)
        #expect(link(secret.path, fixture.workspace.appendingPathComponent("hardlink.txt").path) == 0)
        #expect(mkfifo(fixture.workspace.appendingPathComponent("fifo.txt").path, 0o600) == 0)
        for query: String? in [nil, "needle"] {
            let result = try await fixture.search(fixture.arguments(query: query))
            #expect(try SearchFixture.paths(result) == ["inside.txt"])
            #expect(!String(describing: result).contains("outside secret"))
        }
    }

    @Test func hiddenGeneratedGitAndProtectedFilesRespectExplicitExclusions() async throws {
        let fixture = try SearchFixture(); defer { fixture.cleanup() }
        let fixed = [".git", ".GIT", ".build", "node_modules", "vendor", ".venv", "venv", "build", "dist", "target", "engine-state"]
        for directory in fixed { try fixture.write("\(directory)/secret.txt", "needle excluded") }
        try fixture.write("visible.txt", "needle visible")
        try fixture.write(".hidden.txt", "needle hidden")
        try fixture.write(".private/nested.txt", "needle hidden directory")
        for query: String? in [nil, "needle"] {
            let normal = try await fixture.search(fixture.arguments(query: query))
            #expect(try SearchFixture.paths(normal) == ["visible.txt"])
            let hidden = try await fixture.search(fixture.arguments(hidden: true, query: query))
            #expect(Set(try SearchFixture.paths(hidden)) == ["visible.txt", ".hidden.txt", ".private/nested.txt"])
            let exclusions = try #require(hidden["exclusions"] as? [String: Any])
            #expect(exclusions["gitignoreApplied"] as? Bool == false)
            #expect(exclusions["hidden"] as? Bool == false)
        }
    }

    @Test func contentSearchIsLiteralUTF8LineBasedAndReportsWholeFileSHA() async throws {
        let fixture = try SearchFixture(); defer { fixture.cleanup() }
        let contents = "first\r\nNeedle 가🌱\r\nneedle twice needle\nlast"
        try fixture.write("text.txt", contents)
        try fixture.write("binary.txt", Data([110, 101, 101, 100, 108, 101, 0, 120]))
        try fixture.write("invalid.txt", Data([110, 101, 101, 100, 108, 101, 255]))
        try fixture.write("large.txt", "needle" + String(repeating: "x", count: 262_144))
        try fixture.write("literal.txt", "a.b\naXb\na*b\n")
        let insensitive = try await fixture.search(fixture.arguments(query: "needle", caseSensitive: false))
        let matches = try SearchFixture.matches(insensitive)
        #expect(matches.count == 2)
        #expect(try SearchFixture.paths(insensitive) == ["text.txt", "text.txt"])
        #expect(matches.compactMap { $0["line"] as? Int } == [2, 3])
        #expect(matches.compactMap { $0["text"] as? String } == ["Needle 가🌱", "needle twice needle"])
        let digest = SHA256.hash(data: Data(contents.utf8)).map { String(format: "%02x", $0) }.joined()
        #expect(matches.allSatisfy { $0["sha256"] as? String == digest })
        #expect(matches.allSatisfy { $0["snippetTruncated"] as? Bool == false })
        let sensitive = try await fixture.search(fixture.arguments(query: "needle"))
        #expect(try SearchFixture.matches(sensitive).compactMap { $0["line"] as? Int } == [3])
        let literal = try await fixture.search(fixture.arguments(query: "a.b"))
        #expect(try SearchFixture.matches(literal).compactMap { $0["text"] as? String } == ["a.b"])
    }

    @Test func filenameGlobUsesOnlyStarQuestionAndLiteralBasenames() async throws {
        let fixture = try SearchFixture(); defer { fixture.cleanup() }
        for path in ["a.swift", "ab.swift", "b.swift", "[ab].swift", "*literal.swift", "nested/a.swift", "nested/c.txt"] {
            try fixture.write(path, "fixture")
        }
        let question = try await fixture.search(fixture.arguments(glob: "?.swift"))
        #expect(try SearchFixture.paths(question) == ["a.swift", "b.swift", "nested/a.swift"])
        let bracket = try await fixture.search(fixture.arguments(glob: "[ab].swift"))
        #expect(try SearchFixture.paths(bracket) == ["[ab].swift"])
        let nested = try await fixture.search(fixture.arguments(path: "nested", glob: "*.swift"))
        #expect(try SearchFixture.paths(nested) == ["nested/a.swift"])
        let star = try await fixture.search(fixture.arguments(glob: "*"))
        #expect(try SearchFixture.paths(star).contains("*literal.swift"))
    }

    @Test func paginationIsStableSortedDepthFirstAndDoesNotLoseOrRepeatMatches() async throws {
        let fixture = try SearchFixture(); defer { fixture.cleanup() }
        let expected = ["a/a.txt", "a/z.txt", "b.txt", "c/x.txt", "z.txt"]
        for path in expected.reversed() { try fixture.write(path, "needle") }
        for query: String? in [nil, "needle"] {
            var collected: [String] = [], offset = 0
            for _ in 0..<4 {
                let page = try await fixture.search(fixture.arguments(offset: offset, limit: 2, query: query))
                let paths = try SearchFixture.paths(page)
                collected += paths
                guard let next = page["nextOffset"] as? Int else { break }
                #expect(next == offset + paths.count)
                #expect(next > offset)
                #expect(page["truncated"] as? Bool == true)
                offset = next
            }
            #expect(collected == expected)
            let repeatPage = try await fixture.search(fixture.arguments(offset: 2, limit: 2, query: query))
            #expect(try SearchFixture.paths(repeatPage) == Array(expected[2..<4]))
            let pastEnd = try await fixture.search(fixture.arguments(offset: 99, limit: 2, query: query))
            #expect(try SearchFixture.paths(pastEnd).isEmpty)
            #expect(pastEnd["nextOffset"] is NSNull)
            #expect(pastEnd["truncated"] as? Bool == false)
        }
    }

    @Test func outputBudgetPreservesValidJSONPaginationAndUTF8SnippetsAroundMatch() async throws {
        let fixture = try SearchFixture(); defer { fixture.cleanup() }
        let prefix = String(repeating: "가🌱", count: 100), suffix = String(repeating: "🧪나", count: 100)
        let contents = (1...100).map { "\(prefix)needle-\($0)\(suffix)" }.joined(separator: "\n")
        #expect(contents.utf8.count < 262_144)
        try fixture.write("long.txt", contents)
        var lines: [Int] = [], offset = 0
        for _ in 0..<4 {
            let page = try await fixture.search(fixture.arguments(offset: offset, query: "needle"))
            let matches = try SearchFixture.matches(page)
            #expect(!matches.isEmpty)
            for match in matches {
                let text = try #require(match["text"] as? String)
                #expect(text.utf8.count <= 512)
                #expect(text.contains("needle"))
                #expect(!text.contains("\u{FFFD}"))
                #expect(match["snippetTruncated"] as? Bool == true)
            }
            lines += matches.compactMap { $0["line"] as? Int }
            guard let next = page["nextOffset"] as? Int else { break }
            #expect(next == offset + matches.count)
            #expect(next > offset)
            #expect(page["truncated"] as? Bool == true)
            offset = next
        }
        #expect(lines == Array(1...100))
    }

    @Test func cancelledSearchDoesNotEnumerateOrReturnPartialSuccess() async throws {
        let fixture = try SearchFixture(); defer { fixture.cleanup() }
        try fixture.write("test.txt", "needle")
        let prepared = try fixture.prepare(fixture.arguments(query: "needle"))
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await fixture.execute(prepared)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test func traversalBudgetsReportIncompleteResultsWithoutAnUnresumableOffset() async throws {
        let fixture = try SearchFixture(); defer { fixture.cleanup() }
        for path in ["a.txt", "b.txt", "nested/c.txt"] { try fixture.write(path, "needle") }
        for (limits, reason) in [
            (WorkspaceSearch.Limits(entries: 2), "entryLimit"),
            (WorkspaceSearch.Limits(files: 1), "fileLimit"),
            (WorkspaceSearch.Limits(readBytes: 1), "byteLimit"),
            (WorkspaceSearch.Limits(depth: 0), "depthLimit"),
            (WorkspaceSearch.Limits(seconds: 0), "timeLimit"),
        ] {
            try await WorkspaceSearch.$limitsOverride.withValue(limits) {
                let result = try await fixture.search(fixture.arguments(query: "needle"))
                #expect(result["truncated"] as? Bool == true)
                #expect(result["stopReason"] as? String == reason)
                #expect(result["nextOffset"] is NSNull)
                let stats = try #require(result["stats"] as? [String: Int])
                #expect(try #require(stats["entriesVisited"]) <= limits.entries)
                #expect(try #require(stats["filesRead"]) <= limits.files)
                #expect(try #require(stats["bytesRead"]) <= limits.readBytes)
            }
        }
        try await WorkspaceSearch.$limitsOverride.withValue(.init(fileBytes: 4)) {
            let result = try await fixture.search(fixture.arguments(query: "needle"))
            #expect(try SearchFixture.matches(result).isEmpty)
            #expect(result["truncated"] as? Bool == false)
            #expect((result["skipped"] as? [String: Int])?["tooLarge"] == 3)
        }
    }
}
