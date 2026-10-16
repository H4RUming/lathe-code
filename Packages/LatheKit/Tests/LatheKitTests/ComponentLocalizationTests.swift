import Darwin
import Foundation
import LatheDomain
@testable import LatheEngineHost
@testable import LatheLocalization
import LatheProtocol
@testable import LatheProviders
import LatheRuntime
import Testing

struct ComponentLocalizationTests {
    @Test(arguments: ["ko", "en"])
    func domainValidationAndVersionErrorsUseTheSelectedLanguage(language: String) throws {
        try L10n.$localeOverride.withValue(Locale(identifier: language)) {
            let profile = ProviderProfile(name: "fixture", api: .openAIChat, baseURL: "http://example.invalid/v1", model: "fixture")
            do {
                try profile.validate()
                Issue.record("Unapproved HTTP connection was accepted")
            } catch let error as LatheError {
                #expect(error.localizedDescription == (language == "ko"
                    ? "HTTPS가 필요합니다. HTTP 서버는 해당 연결에서 명시적으로 허용하세요."
                    : "HTTPS is required. Explicitly allow HTTP for this connection to use an HTTP server."))
            }
            #expect(LatheError.incompatibleVersion(9001).localizedDescription == (language == "ko"
                ? "지원하지 않는 엔진 프로토콜 버전: 9001" : "Unsupported engine protocol version: 9001"))
        }
    }

    @Test(arguments: ["ko", "en"])
    func providerErrorsLocalizeBothLayersAndPreserveRawDiagnosticValues(language: String) throws {
        try L10n.$localeOverride.withValue(Locale(identifier: language)) {
            let profile = ProviderProfile(name: "fixture", api: .openAIChat, baseURL: "https://example.invalid/v1", model: "fixture")
            do {
                _ = try ModelClient.request(profile: profile, credential: nil, messages: [], tools: [])
                Issue.record("Empty request unexpectedly accepted")
            } catch let error as ProviderError {
                #expect(error.localizedDescription == (language == "ko"
                    ? "모델 요청 오류: 메시지 또는 도구 수가 유효하지 않습니다."
                    : "Model request error: The number of messages or tools is invalid."))
            }
            var decoder = SSEDecoder()
            do {
                _ = try decoder.feed(Data([0xff, 10]))
                Issue.record("Invalid UTF-8 unexpectedly accepted")
            } catch let error as ProviderError {
                #expect(error.localizedDescription == (language == "ko"
                    ? "모델 스트림 오류: 유효하지 않은 UTF-8입니다."
                    : "Model stream error: The stream contains invalid UTF-8."))
            }
            let detail = "raw server detail: 100% %@ /fixture/모델"
            #expect(ProviderError.invalidStream(detail).localizedDescription == (language == "ko" ? "모델 스트림 오류: " : "Model stream error: ") + detail)
            #expect(ProviderError.httpStatus(429).localizedDescription == (language == "ko"
                ? "모델 서버가 HTTP 429를 반환했습니다." : "The model server returned HTTP 429."))
            #expect(CredentialStoreError(status: -25293).localizedDescription == (language == "ko"
                ? "모델 자격 증명 저장소 오류 (-25293)." : "Model credential store error (-25293)."))
        }
    }

    @Test(arguments: ["ko", "en"])
    func socketMessagesPreservePathAndErrnoWithoutChangingOperationIdentifiers(language: String) {
        L10n.$localeOverride.withValue(Locale(identifier: language)) {
            let path = "/fixture/100% %@/socket"
            #expect(SocketTransportError.invalidPath(path).localizedDescription == (language == "ko"
                ? "Unix socket 경로가 올바르지 않거나 너무 깁니다: " : "The Unix socket path is invalid or too long: ") + path)
            let osDescription = String(cString: strerror(EACCES))
            #expect(SocketTransportError.systemCall("open lock", EACCES).localizedDescription == "open lock: \(osDescription) (\(EACCES))")
            #expect(SocketTransportError.frameTooLarge(1_048_577).localizedDescription == (language == "ko"
                ? "IPC 프레임이 1 MiB 한도를 초과합니다: 1,048,577" : "The IPC frame exceeds the 1 MiB limit: 1,048,577"))
        }
    }

    @Test(arguments: ["ko", "en"])
    func hostRPCFailuresKeepCodesAndIdentifiersWhileLocalizingMessages(language: String) async throws {
        try await L10n.$localeOverride.withValue(Locale(identifier: language)) {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("lathe-l10n-host-\(UUID())")
            defer { try? FileManager.default.removeItem(at: root) }
            let runtime = try EngineRuntime(databaseURL: root.appendingPathComponent("state.sqlite"), credentials: MemoryCredentialStore())
            let service = EngineService(runtime: runtime, info: EngineInfo(processID: getpid(), engineID: UUID()))
            let method = "unknown_%@_100%"
            let request = RPCRequest(id: "fixture-id", method: method)
            let response = try WireCodec.decode(RPCResponse.self, from: await service.handle(WireCodec.encode(request)))
            #expect(response.id == request.id && response.error?.code == -32601)
            #expect(response.error?.message == (language == "ko" ? "알 수 없는 엔진 메서드: " : "Unknown engine method: ") + method)
            let missing = RPCRequest(method: "session")
            let missingResponse = try WireCodec.decode(RPCResponse.self, from: await service.handle(WireCodec.encode(missing)))
            #expect(missingResponse.error?.code == -32602)
            #expect(missingResponse.error?.message == (language == "ko" ? "필수 매개변수가 없습니다: sessionID" : "Missing parameter: sessionID"))
            await service.closeAdmission()
            let stopped = try WireCodec.decode(RPCResponse.self, from: await service.handle(WireCodec.encode(request)))
            #expect(stopped.error?.code == -32009)
            #expect(stopped.error?.message == (language == "ko" ? "앱 엔진이 종료 중입니다." : "The engine host is stopping."))
            await runtime.shutdown()
        }
    }
}
