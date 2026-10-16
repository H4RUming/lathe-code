import Foundation
import LatheDomain
import LatheLocalization

/// Pure byte editing, separate from authorization and filesystem effects.
enum FileEdit {
    static func validateArguments(_ arguments: FileEditArguments) throws {
        let old = Data(arguments.oldText.utf8), new = Data(arguments.newText.utf8)
        guard !old.isEmpty, !old.contains(0), !new.contains(0) else {
            throw ToolError.invalid(L10n.errorText("edit.textArguments", table: "ToolMessages"))
        }
        // String equality folds canonical Unicode equivalents, but replacing a
        // decomposed sequence with its composed form is a real byte change.
        guard old != new else {
            throw ToolError.invalid(L10n.errorText("edit.unchanged", table: "ToolMessages"))
        }
        let digest = arguments.expectedSHA256.utf8
        guard digest.count == 64, digest.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw ToolError.invalid(L10n.errorText("edit.expectedDigest", table: "ToolMessages"))
        }
    }

    static func replacing(in content: Data, arguments: FileEditArguments) throws -> Data {
        try Task.checkCancellation()
        try validateArguments(arguments)
        guard content.count <= ToolBroker.fileLimit else {
            throw ToolError.invalid(L10n.errorText("workspace.fileLimit", table: "ToolMessages"))
        }
        guard !content.contains(0), String(data: content, encoding: .utf8) != nil else {
            throw ToolError.invalid(L10n.errorText("edit.utf8Text", table: "ToolMessages"))
        }
        let old = Data(arguments.oldText.utf8), new = Data(arguments.newText.utf8)
        guard let match = content.range(of: old) else {
            throw ToolError.preconditionChanged(L10n.errorText("edit.noMatch", table: "ToolMessages"))
        }
        // Start one byte after the first match, not after its end: "aa" occurs
        // twice in "aaa" and must never be treated as an unambiguous edit.
        let remainder = content.index(after: match.lowerBound)..<content.endIndex
        guard content.range(of: old, in: remainder) == nil else {
            throw ToolError.preconditionChanged(L10n.errorText("edit.multipleMatches", table: "ToolMessages"))
        }
        guard new.count <= ToolBroker.fileLimit - (content.count - old.count) else {
            throw ToolError.invalid(L10n.errorText("edit.resultLimit", table: "ToolMessages"))
        }
        try Task.checkCancellation()
        var result = content
        result.replaceSubrange(match, with: new)
        return result
    }
}
