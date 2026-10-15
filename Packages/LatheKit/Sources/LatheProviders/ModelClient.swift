import Foundation
import LatheDomain

public struct ModelClient: Sendable {
    private let transport: any HTTPStreamingTransport
    public init(transport: any HTTPStreamingTransport = URLSessionStreamingTransport()) { self.transport = transport }

    public func step(profile: ProviderProfile, credential: String?, messages: [ModelMessage], tools: [ToolDefinition],
                     onText: @escaping @Sendable (String) async throws -> Void) async throws -> ModelStep {
        try Task.checkCancellation()
        let request = try Self.request(profile: profile, credential: credential, messages: messages, tools: tools)
        let decoder = ModelStreamDecoder(profile: profile, allowedTools: Set(tools.map(\.name)), onText: onText)
        try await transport.stream(request: request) { data in try await decoder.consume(data) }
        try Task.checkCancellation()
        return try await decoder.finish()
    }

    static func request(profile: ProviderProfile, credential: String?, messages: [ModelMessage], tools: [ToolDefinition]) throws -> URLRequest {
        try profile.validate()
        guard messages.count <= 1024, !messages.isEmpty, tools.count <= 64, Set(tools.map(\.name)).count == tools.count else {
            throw ProviderError.invalidRequest("메시지 또는 도구 수가 유효하지 않습니다.")
        }
        var components = URLComponents(string: profile.baseURL)!
        let base = components.percentEncodedPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let route = profile.api == .openAIResponses ? "responses" : "chat/completions"
        // base URL is the API root, including /v1 and any proxy prefix supplied by the user.
        components.percentEncodedPath = "/" + (base.isEmpty ? "" : base + "/") + route
        guard let url = components.url else { throw ProviderError.invalidRequest("endpoint URL을 만들 수 없습니다.") }
        var body: [String: Any] = ["model": profile.model, "stream": true]
        let functions: [[String: Any]] = try tools.map { tool in
            guard !tool.name.isEmpty, tool.name.utf8.count <= 64,
                  tool.name.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }),
                  tool.description.utf8.count <= 8192, tool.parametersJSON.utf8.count <= 65536,
                  let schema = try JSONSerialization.jsonObject(with: Data(tool.parametersJSON.utf8)) as? [String: Any],
                  schema["type"] as? String == "object" else {
                throw ProviderError.invalidRequest("도구 정의가 유효하지 않습니다.")
            }
            return ["name": tool.name, "description": tool.description, "parameters": schema, "strict": false]
        }
        if profile.api == .openAIResponses {
            body["store"] = false
            body["include"] = ["reasoning.encrypted_content"]
            body["input"] = try responsesInput(messages, profile: profile)
            if !functions.isEmpty { body["tools"] = functions.map { $0.merging(["type": "function"]) { _, value in value } } }
            if let effort = profile.reasoningEffort { body["reasoning"] = ["effort": effort] }
        } else {
            body["messages"] = try chatInput(messages, profile: profile)
            if !functions.isEmpty { body["tools"] = functions.map { ["type": "function", "function": $0] } }
            if let effort = profile.reasoningEffort { body["reasoning_effort"] = effort }
        }
        let data = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        guard data.count <= 4 * 1024 * 1024 else { throw ProviderError.invalidRequest("요청 context가 4 MiB 한도를 초과했습니다.") }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        if let credential {
            guard !credential.isEmpty, credential.utf8.count <= 16384,
                  !credential.contains(where: { $0.isNewline || $0.asciiValue == 0 }) else {
                throw ProviderError.invalidRequest("API key 형식이 유효하지 않습니다.")
            }
            request.setValue("Bearer " + credential, forHTTPHeaderField: "Authorization")
        }
        request.httpBody = data
        return request
    }

    private static func check(_ state: ModelContinuation, profile: ProviderProfile) throws {
        guard state.api == profile.api, state.baseURL == profile.baseURL, state.model == profile.model else {
            throw ProviderError.invalidRequest("다른 연결이나 모델의 continuation을 재사용할 수 없습니다.")
        }
    }

    private static func responsesInput(_ messages: [ModelMessage], profile: ProviderProfile) throws -> [[String: Any]] {
        var result: [[String: Any]] = []
        for message in messages {
            switch message {
            case .system(let text): result.append(["role": "system", "content": text])
            case .user(let text): result.append(["role": "user", "content": text])
            case .toolResult(let callID, let content):
                result.append(["type": "function_call_output", "call_id": callID, "output": content])
            case .assistant(let step):
                if let state = step.continuation {
                    try check(state, profile: profile)
                    guard state.payload.count <= 8 * 1024 * 1024,
                          let items = try JSONSerialization.jsonObject(with: state.payload) as? [[String: Any]] else {
                        throw ProviderError.invalidRequest("Responses continuation 형식이 유효하지 않습니다.")
                    }
                    result.append(contentsOf: items)
                } else {
                    guard step.calls.isEmpty else { throw ProviderError.invalidRequest("도구 호출의 원본 Responses 출력이 없습니다.") }
                    result.append(["role": "assistant", "content": step.text])
                }
            }
        }
        return result
    }

    private static func chatInput(_ messages: [ModelMessage], profile: ProviderProfile) throws -> [[String: Any]] {
        try messages.map { message in
            switch message {
            case .system(let text): return ["role": "system", "content": text]
            case .user(let text): return ["role": "user", "content": text]
            case .toolResult(let callID, let content): return ["role": "tool", "tool_call_id": callID, "content": content]
            case .assistant(let step):
                if let state = step.continuation {
                    try check(state, profile: profile)
                    guard state.payload.count <= 8 * 1024 * 1024,
                          let item = try JSONSerialization.jsonObject(with: state.payload) as? [String: Any],
                          item["role"] as? String == "assistant" else {
                        throw ProviderError.invalidRequest("Chat continuation 형식이 유효하지 않습니다.")
                    }
                    return item
                }
                var item: [String: Any] = ["role": "assistant", "content": step.text]
                if !step.calls.isEmpty {
                    item["tool_calls"] = step.calls.map {
                        ["id": $0.id, "type": "function", "function": ["name": $0.name, "arguments": $0.arguments]] as [String: Any]
                    }
                }
                return item
            }
        }
    }
}
