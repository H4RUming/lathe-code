import Foundation
import LatheDomain

/// A presentation of the model's arguments, never a snapshot read from disk.
struct FileEditPreview: Sendable {
    enum ApplicationStatus: Sendable, Equatable {
        case proposal, applying, applied, notConfirmed, unknown
    }

    let path: String
    let expectedSHA256: String
    let removal: FileEditSnippet
    let addition: FileEditSnippet
    let status: ApplicationStatus

    init?(invocation: ToolInvocationSnapshot) {
        // Invalid calls rejected before preparation use a placeholder effect.
        // Only a prepared file write can supply an actionable edit proposal.
        guard invocation.name == "edit_file", invocation.effect == .write,
              invocation.arguments.utf8.count <= 32_768,
              let data = invocation.arguments.data(using: .utf8),
              let arguments = try? JSONDecoder().decode(FileEditArguments.self, from: data) else { return nil }
        path = arguments.path
        expectedSHA256 = arguments.expectedSHA256
        removal = FileEditSnippet(arguments.oldText)
        addition = FileEditSnippet(arguments.newText)
        switch invocation.state {
        case .pendingApproval: status = .proposal
        case .approved, .executing: status = .applying
        // completed is recorded only after the tool reports a successful effect.
        // It says nothing about edits made after that result was recorded.
        case .completed: status = .applied
        case .denied, .failed, .cancelled: status = .notConfirmed
        case .unknown: status = .unknown
        }
    }
}

struct FileEditSnippet: Sendable, Equatable {
    static let byteLimit = 4_096
    static let lineLimit = 60
    let text: String
    let originalByteCount: Int
    let displayedByteCount: Int
    var isTruncated: Bool { displayedByteCount < originalByteCount }
    var isEmpty: Bool { originalByteCount == 0 }

    init(_ original: String, byteLimit: Int = Self.byteLimit, lineLimit: Int = Self.lineLimit) {
        originalByteCount = original.utf8.count
        var prefix = ""
        var bytes = 0
        var lines = 1
        for character in original {
            let piece = String(character)
            let count = piece.utf8.count
            guard bytes + count <= max(0, byteLimit), lines <= max(0, lineLimit) else { break }
            if character.isNewline {
                guard lines < lineLimit else { break }
                lines += 1
            }
            // Extended grapheme boundaries also keep a CRLF pair together.
            prefix.append(character)
            bytes += count
        }
        text = prefix
        displayedByteCount = bytes
    }

    /// Whitespace marks are a display-only transform. `text` always remains an
    /// exact prefix of the supplied UTF-8, including CRLF and combining scalars.
    func rendered(showWhitespace: Bool) -> String {
        guard showWhitespace else { return text }
        return text.map { character -> String in
            switch character {
            case " ": return "·"
            case "\t": return "⇥"
            case "\r\n": return "␍␊\n"
            case "\r": return "␍\n"
            case "\n": return "␊\n"
            default: return String(character)
            }
        }.joined()
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.originalByteCount == rhs.originalByteCount && lhs.displayedByteCount == rhs.displayedByteCount
            && lhs.text.utf8.elementsEqual(rhs.text.utf8)
    }
}
