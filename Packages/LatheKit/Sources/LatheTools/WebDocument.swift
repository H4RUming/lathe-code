import Foundation
import LatheLocalization
import SwiftSoup

struct WebDocumentLink: Sendable {
    let text: String
    let url: URL
}

/// Text derived from one response. The caller retains the original response
/// bytes separately; this type never follows links or executes document code.
struct WebDocument: Sendable {
    static let maximumBytes = 5 * 1_024 * 1_024

    let title: String?
    let text: String
    let mediaType: String
    let sourceURL: URL
    let links: [WebDocumentLink]
    let linksTruncated: Bool

    static func extract(data: Data, contentType: String, sourceURL: URL) throws -> WebDocument {
        try Task.checkCancellation()
        guard data.count <= maximumBytes else { throw failure("fetch.documentLimit") }
        let type = try ContentType(contentType)
        let supported: Set<String> = ["text/plain", "text/markdown", "text/x-markdown", "application/json", "text/html"]
        guard supported.contains(type.mediaType) else { throw failure("fetch.unsupportedMediaType") }
        var bytes = data
        if bytes.starts(with: [0xef, 0xbb, 0xbf]) { bytes.removeFirst(3) }
        guard !bytes.contains(where: isBinaryControl), let source = String(data: bytes, encoding: .utf8) else {
            throw failure("fetch.invalidText")
        }
        if type.asciiOnly, bytes.contains(where: { $0 >= 0x80 }) { throw failure("fetch.invalidText") }
        guard !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw failure("fetch.emptyDocument")
        }
        guard type.mediaType == "text/html" else {
            return WebDocument(title: nil, text: source, mediaType: type.mediaType, sourceURL: sourceURL,
                               links: [], linksTruncated: false)
        }
        // The parser cannot yield during a parse. Bound both input and markup
        // work before calling it, then bound the iterative extraction as well.
        guard bytes.lazy.filter({ $0 == 0x3c }).prefix(50_001).count <= 50_000 else {
            throw failure("fetch.documentLimit")
        }
        let document: Document
        do { document = try SwiftSoup.parseHTML(source, sourceURL.absoluteString) }
        catch { throw failure("fetch.invalidHTML") }
        try Task.checkCancellation()
        let extracted = try extractHTML(document, sourceURL: sourceURL)
        guard !extracted.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw failure("fetch.emptyDocument")
        }
        return WebDocument(title: extracted.title, text: extracted.text, mediaType: type.mediaType, sourceURL: sourceURL,
                           links: extracted.links, linksTruncated: extracted.linksTruncated)
    }

    private static func failure(_ key: String) -> ToolError {
        .invalid(L10n.errorText(key, table: "ToolMessages"))
    }

    private static func isBinaryControl(_ byte: UInt8) -> Bool {
        byte < 0x20 && byte != 0x09 && byte != 0x0a && byte != 0x0c && byte != 0x0d || byte == 0x7f
    }

    private struct ContentType {
        let mediaType: String
        let asciiOnly: Bool

        init(_ value: String) throws {
            guard value.utf8.count <= 4_096 else { throw failure("fetch.unsupportedMediaType") }
            let parts = value.split(separator: ";", omittingEmptySubsequences: false)
            mediaType = parts[0].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            var charsets = Set<String>()
            for part in parts.dropFirst() {
                let assignment = part.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                guard assignment[0].trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "charset" else { continue }
                guard assignment.count == 2 else { throw failure("fetch.unsupportedCharset") }
                var charset = assignment[1].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if charset.hasPrefix("\""), charset.hasSuffix("\""), charset.count >= 2 {
                    charset.removeFirst(); charset.removeLast()
                }
                if charset == "utf8" { charset = "utf-8" }
                guard charset == "utf-8" || charset == "us-ascii" else { throw failure("fetch.unsupportedCharset") }
                charsets.insert(charset)
            }
            guard charsets.count <= 1 else { throw failure("fetch.unsupportedCharset") }
            asciiOnly = charsets.contains("us-ascii")
        }
    }

    private struct Frame {
        let node: Node
        let depth: Int
        var exitBlock = false
        var inHead = false
        var inTitle = false
        var preserveWhitespace = false
        var linkIndex: Int?
    }

    private static func extractHTML(_ document: Document, sourceURL: URL) throws
        -> (title: String?, text: String, links: [WebDocumentLink], linksTruncated: Bool) {
        let omitted: Set<String> = ["script", "style", "template", "noscript", "svg", "iframe", "object"]
        var body = TextBuffer(limit: maximumBytes)
        var title = TextBuffer(limit: 4_096)
        var titleSeen = false
        var stack = [Frame(node: document, depth: 0)]
        var visited = 0
        var linkURLs: [URL] = []
        var linkLabels: [TextBuffer] = []
        var linksTruncated = false
        while let frame = stack.popLast() {
            try Task.checkCancellation()
            if frame.exitBlock { try body.lineBreak(); continue }
            visited += 1
            guard visited <= 100_000, frame.depth <= 128 else { throw failure("fetch.documentLimit") }
            if let textNode = frame.node as? TextNode {
                let value = textNode.getWholeText()
                guard !value.utf8.contains(where: isBinaryControl) else { throw failure("fetch.invalidText") }
                if frame.inTitle { try title.append(value, preservingWhitespace: false) }
                else if !frame.inHead {
                    try body.append(value, preservingWhitespace: frame.preserveWhitespace)
                    if let index = frame.linkIndex { try linkLabels[index].append(value, preservingWhitespace: false) }
                }
                continue
            }
            guard let element = frame.node as? Element else { continue }
            let name = element.tagNameNormal()
            if omitted.contains(name) { continue }
            // A password form is an access barrier, not evidence that the
            // requested document was read. No credentials or forms are used.
            if name == "input", try element.attr("type").lowercased() == "password" {
                throw failure("fetch.authenticationRequired")
            }
            if name == "form", try hasLoginAction(element) { throw failure("fetch.authenticationRequired") }
            if name == "meta" { try validateMetaCharset(element) }
            var child = Frame(node: element, depth: frame.depth + 1)
            child.inHead = frame.inHead || name == "head"
            child.inTitle = frame.inTitle
            if name == "title", child.inHead {
                if titleSeen { continue }
                titleSeen = true
                child.inTitle = true
            }
            child.preserveWhitespace = frame.preserveWhitespace || name == "pre" || name == "textarea"
            child.linkIndex = frame.linkIndex
            if name == "a", !child.inHead {
                let href = try element.attr("href")
                if let url = documentLink(href, sourceURL: sourceURL) {
                    if linkURLs.count < 30 {
                        child.linkIndex = linkURLs.count
                        linkURLs.append(url)
                        linkLabels.append(TextBuffer(limit: 256, truncateAtLimit: true))
                    } else { linksTruncated = true }
                } else if href.utf8.count > 2_048 { linksTruncated = true }
            }
            let block = !child.inHead && (element.isBlock() || name == "br" || name == "hr" || name == "td" || name == "th")
            if block {
                try body.lineBreak()
                stack.append(Frame(node: element, depth: frame.depth, exitBlock: true))
            }
            let count = element.childNodeSize()
            guard count <= 100_000 - visited, stack.count <= 200_000 - count else { throw failure("fetch.documentLimit") }
            for index in (0..<count).reversed() {
                stack.append(Frame(node: element.childNode(index), depth: child.depth, inHead: child.inHead,
                                   inTitle: child.inTitle, preserveWhitespace: child.preserveWhitespace, linkIndex: child.linkIndex))
            }
        }
        let titleText = title.result()
        let links = zip(linkURLs, linkLabels).map { WebDocumentLink(text: $0.1.result(), url: $0.0) }
        linksTruncated = linksTruncated || linkLabels.contains(where: \.isTruncated)
        return (titleText.isEmpty ? nil : titleText, body.result(), links, linksTruncated)
    }

    private static func documentLink(_ href: String, sourceURL: URL) -> URL? {
        guard !href.isEmpty, href.utf8.count <= 2_048,
              let resolved = URL(string: href, relativeTo: sourceURL)?.absoluteURL,
              resolved.scheme?.lowercased() == "https" || resolved.scheme?.lowercased() == "http",
              resolved.user == nil, resolved.password == nil, resolved.host != nil,
              resolved.absoluteString.utf8.count <= 2_048 else { return nil }
        return resolved
    }

    private static func hasLoginAction(_ element: Element) throws -> Bool {
        let action = try element.attr("action")
        guard let components = URLComponents(string: action) else { return false }
        let segments = components.path.lowercased().split(separator: "/")
        let knownLoginPaths: Set<String> = ["login", "signin", "sign-in", "sign_in", "log-in", "log_in"]
        return segments.contains(where: { knownLoginPaths.contains(String($0)) })
    }

    private static func validateMetaCharset(_ element: Element) throws {
        let charset = try element.attr("charset")
        if !charset.isEmpty { _ = try ContentType("text/html; charset=" + charset) }
        if try element.attr("http-equiv").lowercased() == "content-type" {
            _ = try ContentType(element.attr("content"))
        }
    }

    /// Normalizes HTML spacing without concatenating neighbouring block text.
    /// Text inside pre/textarea retains indentation and line endings.
    private struct TextBuffer {
        let limit: Int
        var truncateAtLimit = false
        var isTruncated = false
        var bytes: [UInt8] = []
        var pendingSpace = false
        var generatedTrailingBreak = false

        mutating func append(_ value: String, preservingWhitespace: Bool) throws {
            if preservingWhitespace {
                if pendingSpace, !bytes.isEmpty, bytes.last != 0x0a { try appendBytes([0x20]) }
                pendingSpace = false
                try appendBytes(value.utf8)
                return
            }
            var scalarsVisited = 0
            for scalar in value.unicodeScalars {
                scalarsVisited += 1
                if scalarsVisited % 1_024 == 0 { try Task.checkCancellation() }
                if scalar.properties.isWhitespace { pendingSpace = true; continue }
                if pendingSpace, !bytes.isEmpty, bytes.last != 0x0a { try appendBytes([0x20]) }
                pendingSpace = false
                try appendBytes(String(scalar).utf8)
            }
        }

        mutating func lineBreak() throws {
            pendingSpace = false
            if !bytes.isEmpty, bytes.last != 0x0a {
                try appendBytes([0x0a])
                generatedTrailingBreak = true
            }
        }

        mutating func appendBytes<C: Collection>(_ value: C) throws where C.Element == UInt8 {
            if isTruncated { return }
            guard value.count <= limit - bytes.count else {
                if truncateAtLimit { isTruncated = true; return }
                throw failure("fetch.documentLimit")
            }
            if !value.isEmpty { bytes.append(contentsOf: value); generatedTrailingBreak = false }
        }

        func result() -> String {
            let retained = generatedTrailingBreak ? bytes.dropLast() : bytes[...]
            return String(decoding: retained, as: UTF8.self)
        }
    }
}
