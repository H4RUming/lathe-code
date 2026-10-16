import Darwin
import Foundation
import LatheDomain
import LatheExecution
@testable import LatheLocalization
@testable import LatheTools
import Testing

struct ExecutionLocalizationTests {
    @Test(arguments: ["en", "ko"])
    func validationErrorsUseDisplayLanguageAndPreserveErrorCodes(language: String) throws {
        try L10n.$localeOverride.withValue(Locale(identifier: language)) {
            #expect(CommandExecutionError.systemCall("fixture", 12345).localizedDescription.contains("errno 12345"))
            #expect(ToolError.io("fixture", 12345).localizedDescription.contains("errno 12345"))
            let request = CommandRequest(executable: "relative", workingDirectory: "/private/tmp")
            do {
                try request.validate()
                Issue.record("Relative executable was accepted")
            } catch let error as CommandExecutionError {
                #expect(error.localizedDescription == (language == "en"
                    ? "executable and workingDirectory must be absolute paths"
                    : "executable과 workingDirectory는 절대 경로여야 합니다."))
            }

            let missing = URL(fileURLWithPath: "/private/tmp/lathe-missing-\(UUID().uuidString)")
            do {
                _ = try ToolBroker.prepare(call: ModelToolCall(id: "fixture", name: "list_directory", arguments: #"{"path":"."}"#), workspace: missing)
                Issue.record("Missing workspace was accepted")
            } catch let error as ToolError {
                guard case .io(let operation, let code) = error else {
                    Issue.record("Expected an I/O failure: \(error)")
                    return
                }
                #expect(code == ENOENT)
                #expect(operation == (language == "en" ? "open workspace" : "작업 공간 열기"))
                #expect(error.localizedDescription.contains("errno \(ENOENT)"))
            }
        }
    }

    @Test func translatedApprovalSummariesKeepCanonicalArgumentsAndHashesStable() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("lathe-l10n-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let command = ModelToolCall(id: "fixture", name: "run_command", arguments:
            #"{"executable":"/usr/bin/printf","arguments":["fixture output"],"workingDirectory":".","timeoutSeconds":0.123456789}"#)
        let en = try L10n.$localeOverride.withValue(Locale(identifier: "en")) {
            try ToolBroker.prepare(call: command, workspace: directory)
        }
        let ko = try L10n.$localeOverride.withValue(Locale(identifier: "ko")) {
            try ToolBroker.prepare(call: command, workspace: directory)
        }
        #expect(en.summary.contains("UNSANDBOXED local command"))
        #expect(ko.summary.contains("샌드박스 없이 로컬 명령"))
        #expect(en.summary.contains("0.123456789s"))
        #expect(ko.summary.contains("0.123456789초"))
        #expect(en.summary != ko.summary)
        #expect(en.requestHash == ko.requestHash)
        #expect(en.arguments == ko.arguments)
        #expect(en.name == ko.name)
    }

    @Test(arguments: ["en", "ko"])
    func translatedPreviewNoticePreservesBoundAndContent(language: String) {
        L10n.$localeOverride.withValue(Locale(identifier: language)) {
            let data = Data(String(repeating: "출력🌱", count: 20_000).utf8)
            let preview = ToolBroker.preview(data)
            #expect(preview.utf8.count <= ToolBroker.previewLimit)
            #expect(preview.hasPrefix("출력🌱출력🌱"))
            #expect(preview.contains(language == "en" ? "Output preview truncated" : "출력 미리보기가 잘렸습니다"))
            let short = Data("원본 output 🌱".utf8)
            #expect(ToolBroker.preview(short) == "원본 output 🌱")
        }
    }
}
