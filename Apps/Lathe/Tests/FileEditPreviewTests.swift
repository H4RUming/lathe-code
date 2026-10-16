import Foundation
import LatheDomain
import Testing
@testable import LatheAppSupport

struct FileEditPreviewTests {
    @Test func proposalUsesOnlySuppliedArgumentsAndSupportsDeletion() throws {
        let arguments = FileEditArguments(path: "/nonexistent/lathe-preview-fixture/source.swift",
                                          oldText: "  original\r\n", newText: "", expectedSHA256: String(repeating: "a", count: 64))
        let preview = try #require(FileEditPreview(invocation: invocation(arguments)))
        #expect(preview.path == arguments.path)
        #expect(preview.expectedSHA256 == arguments.expectedSHA256)
        #expect(preview.removal.text.utf8.elementsEqual(arguments.oldText.utf8))
        #expect(preview.addition.isEmpty)
        #expect(!preview.addition.isTruncated)
        #expect(preview.status == .proposal)
    }

    @Test(arguments: [ToolInvocationState.pendingApproval, .approved, .executing, .completed,
                      .denied, .failed, .cancelled, .unknown])
    func onlySuccessfulToolCompletionClaimsApplication(state: ToolInvocationState) throws {
        let preview = try #require(FileEditPreview(invocation: invocation(state: state)))
        let expected: FileEditPreview.ApplicationStatus
        switch state {
        case .pendingApproval: expected = .proposal
        case .approved, .executing: expected = .applying
        case .completed: expected = .applied
        case .denied, .failed, .cancelled: expected = .notConfirmed
        case .unknown: expected = .unknown
        }
        #expect(preview.status == expected)
        #expect((preview.status == .applied) == (state == .completed))
    }

    @Test func rejectedOrMalformedCallsDoNotBecomeActionableProposals() throws {
        var request = try invocation()
        request.effect = .shell
        #expect(FileEditPreview(invocation: request) == nil)
        request.effect = .write
        request.name = "write_file"
        #expect(FileEditPreview(invocation: request) == nil)
        request.name = "edit_file"
        request.arguments = "{}"
        #expect(FileEditPreview(invocation: request) == nil)
        request.arguments = "not JSON"
        #expect(FileEditPreview(invocation: request) == nil)
        request = try invocation(FileEditArguments(path: "source.txt", oldText: "old",
                                                   newText: String(repeating: "a", count: 32_768), expectedSHA256: String(repeating: "a", count: 64)))
        #expect(FileEditPreview(invocation: request) == nil)
    }

    @Test func whitespaceRenderingNeverChangesTheSourceBytes() {
        let original = " \tfirst\r\nsecond\rthird\n"
        let snippet = FileEditSnippet(original)
        #expect(snippet.text.utf8.elementsEqual(original.utf8))
        #expect(snippet.rendered(showWhitespace: false).utf8.elementsEqual(original.utf8))
        #expect(snippet.rendered(showWhitespace: true) == "·⇥first␍␊\nsecond␍\nthird␊\n")
        #expect(snippet.displayedByteCount == original.utf8.count)
        #expect(!snippet.isTruncated)
    }

    @Test func truncationKeepsGraphemesAndCRLFPairsIntact() {
        let original = "a\r\n👩🏽‍💻e\u{301}tail"
        let crlfCut = FileEditSnippet(original, byteLimit: 2)
        #expect(crlfCut.text == "a")
        #expect(crlfCut.isTruncated)
        let emojiCut = FileEditSnippet(original, byteLimit: 4)
        #expect(emojiCut.text.utf8.elementsEqual("a\r\n".utf8))
        let prefix = "a\r\n👩🏽‍💻"
        let combiningCut = FileEditSnippet(original, byteLimit: prefix.utf8.count + 1)
        #expect(combiningCut.text.utf8.elementsEqual(prefix.utf8))
        #expect(combiningCut.displayedByteCount == prefix.utf8.count)
        #expect(combiningCut.isTruncated)
        #expect(FileEditSnippet("one\r\ntwo\nthree", lineLimit: 2).text.utf8.elementsEqual("one\r\ntwo".utf8))
        #expect(FileEditSnippet("text", byteLimit: 0).displayedByteCount == 0)
        #expect(FileEditSnippet("text", lineLimit: 0).displayedByteCount == 0)
    }

    @Test func defaultLimitsBoundLargeAndManyLineProposals() {
        let long = FileEditSnippet(String(repeating: "x", count: 16_000))
        #expect(long.displayedByteCount == 4_096)
        #expect(long.isTruncated)
        let lines = FileEditSnippet(String(repeating: "x\r\n", count: 100))
        #expect(lines.text.filter(\.isNewline).count == 59)
        #expect(lines.isTruncated)
    }

    @Test func canonicalEquivalenceDoesNotEraseByteDistinctProposal() throws {
        let nfc = "é"
        let nfd = "e\u{301}"
        #expect(nfc == nfd)
        let preview = try #require(FileEditPreview(invocation: invocation(
            FileEditArguments(path: "unicode.txt", oldText: nfc, newText: nfd, expectedSHA256: String(repeating: "b", count: 64)))))
        #expect(preview.removal.text.utf8.elementsEqual(nfc.utf8))
        #expect(preview.addition.text.utf8.elementsEqual(nfd.utf8))
        #expect(preview.removal.originalByteCount == 2)
        #expect(preview.addition.originalByteCount == 3)
        #expect(preview.removal != preview.addition)
    }

    private func invocation(_ arguments: FileEditArguments = FileEditArguments(path: "source.txt", oldText: "old", newText: "new", expectedSHA256: String(repeating: "a", count: 64)),
                            state: ToolInvocationState = .pendingApproval) throws -> ToolInvocationSnapshot {
        ToolInvocationSnapshot(runID: UUID(), callID: "preview-fixture", name: "edit_file",
                               arguments: String(decoding: try JSONEncoder().encode(arguments), as: UTF8.self),
                               requestHash: String(repeating: "b", count: 64), summary: "Fixture proposal", effect: .write, state: state)
    }
}
