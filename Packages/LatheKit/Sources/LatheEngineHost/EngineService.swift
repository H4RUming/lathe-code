import Foundation
import LatheDomain
import LatheProtocol
import LatheRuntime

actor EngineService {
    let runtime: EngineRuntime
    let info: EngineInfo
    private var accepting = true
    private var activeRequests = 0
    private var drainWaiters: [CheckedContinuation<Void, Never>] = []

    init(runtime: EngineRuntime, info: EngineInfo) {
        self.runtime = runtime; self.info = info
    }

    /// Admission closes before runtime shutdown; requests that were already
    /// admitted are drained before the host releases its data-directory lease.
    func closeAdmission() { accepting = false }

    func drain() async {
        guard activeRequests > 0 else { return }
        await withCheckedContinuation { drainWaiters.append($0) }
    }

    func handle(_ data: Data) async -> Data {
        guard accepting else {
            let id = (try? WireCodec.decode(RPCRequest.self, from: data))?.id
            return encode(.init(id: id, error: .init(code: -32009, message: "Engine host is stopping.")))
        }
        activeRequests += 1
        defer {
            activeRequests -= 1
            if activeRequests == 0 {
                let waiters = drainWaiters
                drainWaiters.removeAll()
                waiters.forEach { $0.resume() }
            }
        }
        let request: RPCRequest
        do { request = try WireCodec.decode(RPCRequest.self, from: data) }
        catch {
            let validJSON = (try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed)) != nil
            return encode(.init(id: nil, error: .init(
                code: validJSON ? -32600 : -32700,
                message: validJSON ? "Invalid JSON-RPC request." : "Invalid JSON."
            )))
        }
        do {
            guard request.jsonrpc == "2.0", !request.id.isEmpty, request.id.utf8.count <= 128 else {
                throw RPCFailure(code: -32600, message: "Invalid JSON-RPC envelope.")
            }
            guard request.params.protocolVersion == EngineProtocol.version else {
                throw LatheError.incompatibleVersion(request.params.protocolVersion)
            }
            let p = request.params
            let result: RPCResult
            switch request.method {
            case "handshake": result = .init(info: info)
            case "sessions": result = .init(sessions: try await runtime.listSessions(before: p.before, limit: p.limit ?? 50))
            case "session": result = .init(session: try await runtime.session(id: require(p.sessionID, "sessionID"), beforeRunID: p.before, limit: p.limit ?? 4))
            case "createSession":
                result = .init(session: try await runtime.createSession(title: require(p.title, "title"), workspacePath: require(p.workspacePath, "workspacePath")))
            case "submit":
                result = .init(run: try await runtime.submit(sessionID: require(p.sessionID, "sessionID"), prompt: require(p.prompt, "prompt"), requestID: require(p.requestID, "requestID"), configuration: p.configuration))
            case "providerProfiles": result = .init(profiles: try await runtime.providerProfiles())
            case "saveProviderProfile":
                result = .init(profiles: try await runtime.saveProviderProfile(require(p.profile, "profile"), apiKey: p.apiKey, clearCredential: p.clearCredential ?? false))
            case "invocations": result = .init(invocations: try await runtime.invocations(runID: require(p.runID, "runID")))
            case "invocation": result = .init(invocation: try await runtime.invocation(id: require(p.invocationID, "invocationID")))
            case "decideApproval":
                result = .init(invocation: try await runtime.decideApproval(invocationID: require(p.invocationID, "invocationID"), requestHash: require(p.requestHash, "requestHash"), approved: require(p.approved, "approved")))
            case "cancel": result = .init(run: try await runtime.cancel(runID: require(p.runID, "runID")))
            case "events": result = .init(page: try await runtime.events(after: p.cursor ?? 0, sessionID: p.sessionID, runID: p.runID, limit: p.limit ?? 256))
            default: throw RPCFailure(code: -32601, message: "Unknown engine method: \(request.method.prefix(64))")
            }
            return encode(.init(id: request.id, result: result))
        } catch {
            let failure: RPCFailure
            switch error {
            case let e as RPCFailure: failure = e
            case LatheError.invalidRequest(let message): failure = .init(code: -32602, message: message)
            case LatheError.notFound(let message): failure = .init(code: -32004, message: message)
            case LatheError.conflict(let message): failure = .init(code: -32009, message: message)
            case LatheError.incompatibleVersion(let version): failure = .init(code: -32001, message: "Protocol version \(version) is not supported; expected \(EngineProtocol.version).")
            default: failure = .init(code: -32603, message: "Engine operation failed: \(error.localizedDescription)")
            }
            return encode(.init(id: request.id, error: failure))
        }
    }

    private func require<T>(_ value: T?, _ name: String) throws -> T {
        guard let value else { throw LatheError.invalidRequest("Missing parameter: \(name)") }
        return value
    }

    private func encode(_ response: RPCResponse) -> Data {
        // The fallback is valid JSON even when an unexpected encoding error occurs.
        (try? WireCodec.encode(response)) ?? Data(#"{"jsonrpc":"2.0","id":null,"error":{"code":-32603,"message":"Encoding failed"}}"#.utf8)
    }
}
