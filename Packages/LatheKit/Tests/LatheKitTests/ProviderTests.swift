import Foundation
import LatheDomain
@testable import LatheProviders
import Testing

private actor ProviderFixtureTransport: HTTPStreamingTransport {
    var replies: [[Data]]
    var requests: [URLRequest] = []
    init(_ replies: [[Data]]) { self.replies = replies }
    func stream(request: URLRequest, onBytes: @escaping @Sendable (Data) async throws -> Bool) async throws {
        requests.append(request)
        for chunk in replies.removeFirst() { if try await !onBytes(chunk) { break } }
    }
}

private actor ProviderText { var value = ""; func append(_ text: String) { value += text } }
private let readTool = ToolDefinition(name: "read_file", description: "Read one workspace file", parametersJSON: "{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\"}}}")
private func fixtureProfile(_ api: ProviderAPI = .openAIChat) -> ProviderProfile {
    ProviderProfile(name: "Fixture", api: api, baseURL: "https://models.example.invalid/team-a/v1/", model: "fixture-model")
}
private func fixtureSSE(_ objects: [[String: Any]], done: Bool = false) throws -> Data {
    var data = Data()
    for object in objects {
        data.append(Data("data: ".utf8))
        data.append(try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]))
        data.append(Data("\r\n\r\n".utf8))
    }
    if done { data.append(Data("data: [DONE]\r\n\r\n".utf8)) }
    return data
}
private func chatChunk(_ delta: [String: Any], finish: String? = nil) -> [String: Any] {
    ["choices": [["index": 0, "delta": delta, "finish_reason": finish.map { $0 as Any } ?? NSNull()]]]
}
private func responseEnd(output: [[String: Any]], incomplete: Bool = false) -> [String: Any] {
    ["type": incomplete ? "response.incomplete" : "response.completed",
     "response": ["status": incomplete ? "incomplete" : "completed", "output": output]]
}
private func messageItem(_ text: String) -> [String: Any] {
    ["type": "message", "id": "msg_fixture", "status": "completed", "role": "assistant", "content": [["type": "output_text", "text": text, "annotations": []]]]
}

struct ProviderTests {
    @Test func chatUTF8EveryByteBoundaryPreservesTextAndProxyPrefix() async throws {
        let wire = try fixtureSSE([chatChunk(["content": "안녕 👩🏽‍💻"]), chatChunk([:], finish: "stop")], done: true)
        let transport = ProviderFixtureTransport([wire.map { Data([$0]) }])
        let text = ProviderText()
        let result = try await ModelClient(transport: transport).step(profile: fixtureProfile(), credential: "fixture-credential", messages: [.user("hello")], tools: []) { await text.append($0) }
        #expect(result.text == "안녕 👩🏽‍💻")
        #expect(result.outcome == .final)
        #expect(await text.value == result.text)
        let request = try #require(await transport.requests.first)
        #expect(request.url?.absoluteString == "https://models.example.invalid/team-a/v1/chat/completions")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-credential")
        #expect(request.httpMethod == "POST")
    }

    @Test func responsesToolRoundPreservesEncryptedReasoningAndRawOutput() async throws {
        let output: [[String: Any]] = [
            ["type": "reasoning", "id": "reason_fixture", "summary": [], "encrypted_content": "fixture-opaque-state"],
            ["type": "function_call", "id": "fc_fixture", "call_id": "call_1", "name": "read_file", "arguments": "{\"path\":\"README.md\"}", "status": "completed"]
        ]
        let first = try fixtureSSE([
            ["type": "response.function_call_arguments.delta", "item_id": "fc_fixture", "delta": "{\"path\":"],
            responseEnd(output: output)
        ])
        let second = try fixtureSSE([["type": "response.output_text.delta", "delta": "Done"], responseEnd(output: [messageItem("Done")])])
        let transport = ProviderFixtureTransport([[first], [second]])
        let client = ModelClient(transport: transport)
        let profile = fixtureProfile(.openAIResponses)
        let result = try await client.step(profile: profile, credential: nil, messages: [.user("read")], tools: [readTool]) { _ in }
        #expect(result.outcome == .clientTools)
        #expect(result.calls == [ModelToolCall(id: "call_1", name: "read_file", arguments: "{\"path\":\"README.md\"}")])
        let next = try await client.step(profile: profile, credential: nil, messages: [.user("read"), .assistant(result), .toolResult(callID: "call_1", content: "fixture file")], tools: [readTool]) { _ in }
        #expect(next.outcome == .final)
        let requests = await transport.requests
        let bodyData = try #require(requests.last?.httpBody)
        let body = try #require(try JSONSerialization.jsonObject(with: bodyData) as? [String: Any])
        #expect(body["store"] as? Bool == false)
        #expect(body["previous_response_id"] == nil)
        let input = try #require(body["input"] as? [[String: Any]])
        #expect(input[1]["encrypted_content"] as? String == "fixture-opaque-state")
        #expect(input[2]["id"] as? String == "fc_fixture")
        #expect(input[3]["type"] as? String == "function_call_output")
        #expect(input[3]["call_id"] as? String == "call_1")
    }

    @Test func chatIndexedParallelCallsAndReasoningRoundTrip() async throws {
        let wire = try fixtureSSE([
            chatChunk(["reasoning_content": "fixture reasoning"]),
            chatChunk(["tool_calls": [["index": 1, "id": "call_b", "type": "function", "function": ["name": "read_file", "arguments": "{\"path\":"]], ["index": 0, "id": "call_a", "function": ["name": "read_file", "arguments": "{\"path\":\"a\"}"]]]]),
            chatChunk(["tool_calls": [["index": 1, "function": ["arguments": "\"b\"}"]]]], finish: "tool_calls")
        ], done: true)
        let client = ModelClient(transport: ProviderFixtureTransport([[wire]]))
        let step = try await client.step(profile: fixtureProfile(), credential: nil, messages: [.user("read")], tools: [readTool]) { _ in }
        #expect(step.calls.map(\.id) == ["call_a", "call_b"])
        #expect(step.calls.map(\.arguments) == ["{\"path\":\"a\"}", "{\"path\":\"b\"}"])
        #expect(step.text.isEmpty)
        let request = try ModelClient.request(profile: fixtureProfile(), credential: nil, messages: [.assistant(step), .toolResult(callID: "call_a", content: "ok"), .toolResult(callID: "call_b", content: "ok")], tools: [readTool])
        let bodyData = try #require(request.httpBody)
        let body = try #require(try JSONSerialization.jsonObject(with: bodyData) as? [String: Any])
        let messages = try #require(body["messages"] as? [[String: Any]])
        #expect(messages[0]["reasoning_content"] as? String == "fixture reasoning")
        #expect(messages[1]["tool_call_id"] as? String == "call_a")
    }

    @Test func EOFNeverAuthorizesPartialOrApparentlyFinishedCalls() async throws {
        for finish in [nil, "tool_calls"] as [String?] {
            let wire = try fixtureSSE([chatChunk(["tool_calls": [["index": 0, "id": "c", "function": ["name": "read_file", "arguments": "{}"]]]], finish: finish)])
            let client = ModelClient(transport: ProviderFixtureTransport([[wire]]))
            await #expect(throws: ProviderError.incompleteStream) {
                try await client.step(profile: fixtureProfile(), credential: nil, messages: [.user("read")], tools: [readTool]) { _ in }
            }
        }
        let response = try fixtureSSE([["type": "response.function_call_arguments.done", "arguments": "{}", "name": "read_file"]])
        await #expect(throws: ProviderError.incompleteStream) {
            try await ModelClient(transport: ProviderFixtureTransport([[response]])).step(profile: fixtureProfile(.openAIResponses), credential: nil, messages: [.user("read")], tools: [readTool]) { _ in }
        }
    }

    @Test func truncatedCallsAreDiscardedAndRefusalIsDistinctFromEmpty() async throws {
        let cases: [(String, [String: Any], ModelStepOutcome)] = [
            ("length", ["tool_calls": [["index": 0, "id": "c", "function": ["name": "read_file", "arguments": "{invalid"]]]], .truncated),
            ("content_filter", [:], .blocked), ("stop", ["refusal": "Cannot comply"], .blocked), ("stop", [:], .noUsableOutput)
        ]
        for (reason, delta, expected) in cases {
            let wire = try fixtureSSE([chatChunk(delta, finish: reason)], done: true)
            let step = try await ModelClient(transport: ProviderFixtureTransport([[wire]])).step(profile: fixtureProfile(), credential: nil, messages: [.user("test")], tools: [readTool]) { _ in }
            #expect(step.outcome == expected)
            #expect(step.calls.isEmpty)
        }
        let wire = try fixtureSSE([responseEnd(output: [["type": "function_call", "call_id": "c", "name": "read_file", "arguments": "{invalid"]], incomplete: true)])
        let step = try await ModelClient(transport: ProviderFixtureTransport([[wire]])).step(profile: fixtureProfile(.openAIResponses), credential: nil, messages: [.user("test")], tools: [readTool]) { _ in }
        #expect(step.outcome == .truncated)
        #expect(step.calls.isEmpty)
    }

    @Test func malformedUnknownDuplicateAndInconsistentCallsFailClosed() async throws {
        let invalidCalls: [[String: Any]] = [
            ["index": 0, "id": "c", "function": ["name": "read_file", "arguments": "{invalid"]],
            ["index": 0, "id": "c", "function": ["name": "unknown", "arguments": "{}"]],
            ["index": 0, "function": ["name": "read_file", "arguments": "{}"]]
        ]
        for call in invalidCalls {
            let wire = try fixtureSSE([chatChunk(["tool_calls": [call]], finish: "tool_calls")], done: true)
            await #expect(throws: ProviderError.self) {
                try await ModelClient(transport: ProviderFixtureTransport([[wire]])).step(profile: fixtureProfile(), credential: nil, messages: [.user("test")], tools: [readTool]) { _ in }
            }
        }
        for reason in ["stop", "tool_calls"] {
            let wire = try fixtureSSE([chatChunk(["tool_calls": [
                ["index": 0, "id": "same", "function": ["name": "read_file", "arguments": "{}"]],
                ["index": 1, "id": "same", "function": ["name": "read_file", "arguments": "{}"]]
            ]], finish: reason)], done: true)
            await #expect(throws: ProviderError.self) {
                try await ModelClient(transport: ProviderFixtureTransport([[wire]])).step(profile: fixtureProfile(), credential: nil, messages: [.user("test")], tools: [readTool]) { _ in }
            }
        }
    }

    @Test func responsesRejectsHostedToolsAndInconsistentText() async throws {
        for wire in [
            try fixtureSSE([responseEnd(output: [["type": "web_search_call", "status": "completed"]])]),
            try fixtureSSE([["type": "response.output_text.delta", "delta": "wrong"], responseEnd(output: [messageItem("final")])]),
            try fixtureSSE([responseEnd(output: [["type": "function_call", "status": "in_progress", "call_id": "c", "name": "read_file", "arguments": "{}"]])])
        ] {
            await #expect(throws: ProviderError.self) {
                try await ModelClient(transport: ProviderFixtureTransport([[wire]])).step(profile: fixtureProfile(.openAIResponses), credential: nil, messages: [.user("test")], tools: [readTool]) { _ in }
            }
        }
    }

    @Test func profileValidationAndContinuationAffinityPreventWrongDestination() throws {
        for url in ["http://localhost:8000/v1", "https://user:secret@example.invalid/v1", "https://example.invalid/v1?key=secret", "https://example.invalid/v1#key", "file:///tmp/model", "https://example.invalid/a/../v1"] {
            var profile = fixtureProfile(); profile.baseURL = url
            #expect(throws: LatheError.self) { try profile.validate() }
        }
        var local = fixtureProfile(); local.baseURL = "http://127.0.0.1:8080/team/v1"; local.allowInsecureHTTP = true
        try local.validate()
        let request = try ModelClient.request(profile: local, credential: nil, messages: [.user("test")], tools: [])
        #expect(request.url?.path == "/team/v1/chat/completions")
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        let foreign = ModelContinuation(api: .openAIResponses, baseURL: "https://other.invalid/v1", model: "fixture-model", payload: Data("[]".utf8))
        #expect(throws: ProviderError.self) {
            try ModelClient.request(profile: fixtureProfile(.openAIResponses), credential: nil, messages: [.assistant(ModelStep(text: "", outcome: .clientTools, continuation: foreign))], tools: [])
        }
    }

    @Test func SSEHandlesCRCommentsMultilineAndRejectsMalformedOrOversizedUTF8() throws {
        var decoder = SSEDecoder()
        #expect(try decoder.feed(Data(": comment\rdata: one\rdata: two\r\r".utf8)) == ["one\ntwo"])
        #expect(try decoder.feed(Data("data: three\n\n".utf8)) == ["three"])
        #expect(throws: ProviderError.self) { try decoder.feed(Data([0xff, 10])) }
        var bounded = SSEDecoder()
        #expect(throws: ProviderError.responseLimit) { try bounded.feed(Data(repeating: 97, count: SSEDecoder.frameLimit + 1)) }
    }

    @Test func transportRejectsRedirectStatusOriginChangeAndNonSSE() throws {
        let url = URL(string: "https://models.example.invalid/v1/responses")!
        for (responseURL, status, mime) in [(url, 302, "text/event-stream"), (URL(string: "https://other.invalid/")!, 200, "text/event-stream"), (url, 200, "application/json"), (url, 401, "application/json")] {
            let response = HTTPURLResponse(url: responseURL, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": mime])!
            #expect(throws: ProviderError.self) { try URLSessionStreamingTransport.validate(response: response, requestedURL: url) }
        }
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let task = session.dataTask(with: url)
        let delegated = RedirectResult()
        NoRedirectDelegate().urlSession(session, task: task, willPerformHTTPRedirection: HTTPURLResponse(url: url, statusCode: 307, httpVersion: nil, headerFields: [:])!, newRequest: URLRequest(url: URL(string: "https://other.invalid/")!)) { delegated.store($0) }
        #expect(delegated.wasCalled)
        #expect(delegated.request == nil)
    }

    @Test func cancellationReachesInFlightTransport() async throws {
        let transport = HangingProviderTransport()
        let task = Task { try await ModelClient(transport: transport).step(profile: fixtureProfile(), credential: nil, messages: [.user("test")], tools: []) { _ in } }
        let deadline = ContinuousClock.now + .seconds(2)
        while await !transport.started {
            guard ContinuousClock.now < deadline else { throw ProviderError.invalidStream("fixture did not start") }
            try await Task.sleep(for: .milliseconds(1))
        }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await transport.cancelled)
    }

    @Test func memoryCredentialsStaySeparateFromProfileEncoding() throws {
        let profile = fixtureProfile()
        let store = MemoryCredentialStore()
        try store.set(id: profile.id, value: "fixture-secret-do-not-persist")
        #expect(try store.get(id: profile.id) == "fixture-secret-do-not-persist")
        #expect(!String(decoding: try JSONEncoder().encode(profile), as: UTF8.self).contains("fixture-secret"))
        try store.delete(id: profile.id)
        #expect(try store.get(id: profile.id) == nil)
    }
}

private final class RedirectResult: @unchecked Sendable {
    private let lock = NSLock()
    private var value: URLRequest?
    private var called = false
    func store(_ request: URLRequest?) { lock.withLock { value = request; called = true } }
    var request: URLRequest? { lock.withLock { value } }
    var wasCalled: Bool { lock.withLock { called } }
}
private actor HangingProviderTransport: HTTPStreamingTransport {
    var started = false
    var cancelled = false
    func stream(request: URLRequest, onBytes: @escaping @Sendable (Data) async throws -> Bool) async throws {
        started = true
        do { try await Task.sleep(for: .seconds(60)) }
        catch { cancelled = Task.isCancelled; throw error }
    }
}
