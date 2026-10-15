import Foundation
import LatheDomain

actor ModelStreamDecoder {
    private let profile: ProviderProfile
    private let allowedTools: Set<String>
    private let onText: @Sendable (String) async throws -> Void
    private var sse = SSEDecoder()
    private var receivedBytes = 0
    private var text = ""
    private var refusal = ""
    private var reasoningFields: [String: String] = [:]
    private var reasoningBytes = 0
    private var toolParts: [Int: ToolParts] = [:]
    private var chatFinish: String?
    private var completed: ModelStep?
    private struct ToolParts { var id = ""; var name = ""; var arguments = "" }

    init(profile: ProviderProfile, allowedTools: Set<String>, onText: @escaping @Sendable (String) async throws -> Void) {
        self.profile = profile; self.allowedTools = allowedTools; self.onText = onText
    }

    func consume(_ data: Data) async throws -> Bool {
        try Task.checkCancellation()
        guard completed == nil else { return false }
        receivedBytes += data.count
        guard receivedBytes <= 8 * 1024 * 1024 else { throw ProviderError.responseLimit }
        for payload in try sse.feed(data) {
            if profile.api == .openAIChat && payload == "[DONE]" {
                completed = try finishChat()
                if text.isEmpty, let final = completed, !final.text.isEmpty { try await appendText(final.text) }
            } else {
                guard let object = try JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any] else {
                    throw ProviderError.invalidStream("JSON object가 필요합니다.")
                }
                if profile.api == .openAIChat { try await consumeChat(object) }
                else { try await consumeResponses(object) }
            }
            if completed != nil { return false }
        }
        return true
    }

    func finish() throws -> ModelStep {
        guard let completed else { throw ProviderError.incompleteStream }
        return completed
    }

    private func appendText(_ delta: String) async throws {
        guard text.utf8.count + delta.utf8.count <= 2 * 1024 * 1024 else { throw ProviderError.responseLimit }
        text += delta
        if !delta.isEmpty { try await onText(delta) }
    }

    private func consumeChat(_ object: [String: Any]) async throws {
        if object["error"] != nil { throw ProviderError.invalidStream("서버가 오류 이벤트를 반환했습니다.") }
        guard let choices = object["choices"] as? [[String: Any]] else { throw ProviderError.invalidStream("choices가 없습니다.") }
        // Usage-only trailing chunks are valid. Multiple candidates are deliberately unsupported.
        guard choices.count <= 1 else { throw ProviderError.unsupportedContent }
        guard let choice = choices.first else { return }
        guard choice["index"] as? Int == 0, let delta = choice["delta"] as? [String: Any], chatFinish == nil else {
            throw ProviderError.invalidStream("선택 index 또는 종료 순서가 유효하지 않습니다.")
        }
        if let value = delta["content"], !(value is NSNull) {
            guard let fragment = value as? String else { throw ProviderError.unsupportedContent }
            try await appendText(fragment)
        }
        if let value = delta["refusal"], !(value is NSNull) {
            guard let fragment = value as? String else { throw ProviderError.unsupportedContent }
            refusal += fragment
            guard refusal.utf8.count <= 65536 else { throw ProviderError.responseLimit }
        }
        // Current vLLM uses reasoning; older compatible servers use
        // reasoning_content. Preserve each field without renaming or merging it.
        for field in ["reasoning", "reasoning_content"] {
            if let value = delta[field], !(value is NSNull) {
                guard let fragment = value as? String else { throw ProviderError.unsupportedContent }
                let bytes = fragment.utf8.count
                guard bytes <= 1024 * 1024 - reasoningBytes else { throw ProviderError.responseLimit }
                reasoningBytes += bytes
                reasoningFields[field, default: ""] += fragment
            }
        }
        if delta["audio"] != nil || delta["function_call"] != nil { throw ProviderError.unsupportedContent }
        if let rawCalls = delta["tool_calls"], !(rawCalls is NSNull) {
            guard let calls = rawCalls as? [[String: Any]] else { throw ProviderError.invalidStream("tool_calls 형식이 유효하지 않습니다.") }
            for call in calls {
                guard let index = call["index"] as? Int, 0..<32 ~= index else { throw ProviderError.responseLimit }
                if let type = call["type"] as? String, type != "function" { throw ProviderError.unsupportedContent }
                var parts = toolParts[index] ?? ToolParts()
                if let id = call["id"] as? String { parts.id += id }
                if let function = call["function"] as? [String: Any] {
                    if let name = function["name"] as? String { parts.name += name }
                    if let arguments = function["arguments"] as? String { parts.arguments += arguments }
                }
                guard parts.id.utf8.count <= 512, parts.name.utf8.count <= 64,
                      parts.arguments.utf8.count <= 256 * 1024 else { throw ProviderError.responseLimit }
                toolParts[index] = parts
            }
        }
        if let reason = choice["finish_reason"] as? String { chatFinish = reason }
    }

    private func finishChat() throws -> ModelStep {
        guard let reason = chatFinish else { throw ProviderError.incompleteStream }
        var calls: [ModelToolCall] = []
        let outcome: ModelStepOutcome
        switch reason {
        case "length": outcome = .truncated
        case "content_filter": outcome = .blocked
        case "stop":
            guard toolParts.isEmpty else { throw ProviderError.invalidStream("stop 응답에 도구 호출이 섞여 있습니다.") }
            outcome = !refusal.isEmpty ? .blocked : (text.isEmpty ? .noUsableOutput : .final)
        case "tool_calls":
            guard !toolParts.isEmpty, refusal.isEmpty else { throw ProviderError.invalidStream("도구 종료 이유와 내용이 일치하지 않습니다.") }
            calls = try checkedCalls(toolParts.sorted(by: { $0.key < $1.key }).map { ModelToolCall(id: $0.value.id, name: $0.value.name, arguments: $0.value.arguments) })
            outcome = .clientTools
        default: throw ProviderError.invalidStream("지원하지 않는 Chat 종료 이유입니다.")
        }
        var raw: [String: Any] = ["role": "assistant", "content": text]
        for (field, value) in reasoningFields { raw[field] = value }
        if !calls.isEmpty { raw["tool_calls"] = calls.map { ["id": $0.id, "type": "function", "function": ["name": $0.name, "arguments": $0.arguments]] as [String: Any] } }
        let state = ModelContinuation(api: profile.api, baseURL: profile.baseURL, model: profile.model,
                                      payload: try JSONSerialization.data(withJSONObject: raw, options: [.sortedKeys]))
        return ModelStep(text: text.isEmpty ? refusal : text, calls: calls, outcome: outcome, continuation: state)
    }

    private func consumeResponses(_ object: [String: Any]) async throws {
        guard let type = object["type"] as? String else { throw ProviderError.invalidStream("Responses event type이 없습니다.") }
        switch type {
        case "response.output_text.delta":
            guard let delta = object["delta"] as? String else { throw ProviderError.invalidStream("text delta가 없습니다.") }
            try await appendText(delta)
        case "error", "response.failed": throw ProviderError.invalidStream("서버가 실패 이벤트를 반환했습니다.")
        case "response.completed", "response.incomplete":
            guard let response = object["response"] as? [String: Any],
                  let output = response["output"] as? [[String: Any]], output.count <= 128,
                  response["status"] as? String == (type == "response.completed" ? "completed" : "incomplete") else {
                throw ProviderError.invalidStream("Responses 종료 상태가 일치하지 않습니다.")
            }
            var finalText = ""
            var calls: [ModelToolCall] = []
            var blocked = false
            for item in output {
                if type == "response.completed", let status = item["status"] as? String, status != "completed" {
                    throw ProviderError.invalidStream("완료 응답에 미완성 output item이 포함되어 있습니다.")
                }
                switch item["type"] as? String {
                case "message":
                    guard item["role"] as? String == "assistant", let content = item["content"] as? [[String: Any]] else {
                        throw ProviderError.invalidStream("assistant message가 유효하지 않습니다.")
                    }
                    for part in content {
                        switch part["type"] as? String {
                        case "output_text":
                            guard let value = part["text"] as? String else { throw ProviderError.invalidStream("최종 text가 없습니다.") }
                            finalText += value
                        case "refusal": blocked = true; refusal += part["refusal"] as? String ?? ""
                        default: throw ProviderError.unsupportedContent
                        }
                    }
                case "function_call":
                    guard let id = item["call_id"] as? String, let name = item["name"] as? String, let arguments = item["arguments"] as? String else {
                        throw ProviderError.invalidStream("최종 function call이 유효하지 않습니다.")
                    }
                    calls.append(ModelToolCall(id: id, name: name, arguments: arguments))
                case "reasoning": break // Preserve the complete encrypted/signed item for the next request.
                default: throw ProviderError.unsupportedContent
                }
            }
            guard finalText.utf8.count <= 2 * 1024 * 1024, refusal.utf8.count <= 65536 else { throw ProviderError.responseLimit }
            if text.isEmpty { try await appendText(finalText) }
            else if text != finalText { throw ProviderError.invalidStream("스트림 text와 최종 text가 일치하지 않습니다.") }
            let outcome: ModelStepOutcome
            if blocked { outcome = .blocked; calls = [] }
            else if type == "response.incomplete" {
                outcome = ((response["incomplete_details"] as? [String: Any])?["reason"] as? String) == "content_filter" ? .blocked : .truncated
                calls = []
            } else if !calls.isEmpty { calls = try checkedCalls(calls); outcome = .clientTools }
            else { outcome = text.isEmpty ? .noUsableOutput : .final }
            let state = ModelContinuation(api: profile.api, baseURL: profile.baseURL, model: profile.model,
                                          payload: try JSONSerialization.data(withJSONObject: output, options: [.sortedKeys]))
            if text.isEmpty, !refusal.isEmpty { try await appendText(refusal) }
            completed = ModelStep(text: text.isEmpty ? refusal : text, calls: calls, outcome: outcome, continuation: state)
        default: break // Metadata, reasoning, and assembly events cannot authorize a tool call.
        }
    }

    private func checkedCalls(_ calls: [ModelToolCall]) throws -> [ModelToolCall] {
        guard calls.count <= 32, Set(calls.map(\.id)).count == calls.count else { throw ProviderError.invalidStream("도구 호출 ID가 중복되거나 한도를 초과했습니다.") }
        for call in calls {
            guard !call.id.isEmpty, call.id.utf8.count <= 512, allowedTools.contains(call.name),
                  call.arguments.utf8.count <= 256 * 1024,
                  (try? JSONSerialization.jsonObject(with: Data(call.arguments.utf8))) is [String: Any] else {
                throw ProviderError.invalidStream("완성되지 않았거나 등록되지 않은 도구 호출입니다.")
            }
        }
        return calls
    }
}
