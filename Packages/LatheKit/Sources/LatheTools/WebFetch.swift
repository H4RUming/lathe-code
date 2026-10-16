import Foundation
import LatheLocalization

/// Formats a retrieval receipt independently from the raw source bytes. Nothing
/// in an extracted document can change the policy used for its next tool call.
enum WebFetch {
    static func execute(_ request: WebFetchRequest,
                        transport: WebFetchTransport = WebFetchTransport()) async throws -> ToolResult {
        let receipt: WebFetchReceipt
        do {
            receipt = try await transport.fetch(request)
        } catch {
            try Task.checkCancellation()
            if error is CancellationError { throw error }
            return try render([
                "status": "fetchFailed", "sourceURL": request.approvedURL.absoluteString,
                "untrusted": true,
                "message": L10n.errorFormat("fetch.failed", table: "ToolMessages", bounded(error.localizedDescription, bytes: 2_048)),
            ], isError: true)
        }
        try Task.checkCancellation()
        var fields: [String: Any] = [
            "sourceURL": receipt.requestedURL.absoluteString,
            "finalURL": receipt.finalURL.absoluteString,
            "httpStatus": receipt.statusCode,
            "retrievedAt": ISO8601DateFormatter().string(from: receipt.retrievedAt),
            "redirectChain": [String](), "untrusted": true,
        ]
        if let type = receipt.mimeType { fields["mediaType"] = bounded(type, bytes: 512) }
        if let charset = receipt.charset { fields["charset"] = bounded(charset, bytes: 128) }
        if (300...399).contains(receipt.statusCode) {
            fields["status"] = "redirect"
            fields["message"] = L10n.errorText("fetch.redirectNotFollowed", table: "ToolMessages")
            if let target = receipt.redirectURL { fields["redirectURL"] = target.absoluteString }
            return try render(fields, isError: true)
        }
        guard (200...299).contains(receipt.statusCode) else {
            fields["status"] = "httpError"
            fields["message"] = L10n.errorFormat("fetch.httpStatus", table: "ToolMessages", Int64(receipt.statusCode))
            return try render(fields, isError: true)
        }
        fields["sha256"] = ToolBroker.digest(receipt.body)
        fields["rawBytes"] = receipt.body.count
        let document: WebDocument
        do {
            document = try WebDocument.extract(data: receipt.body, contentType: receipt.contentType ?? "",
                                               sourceURL: receipt.finalURL)
        } catch {
            try Task.checkCancellation()
            if error is CancellationError { throw error }
            fields["status"] = "unsupportedContent"
            fields["message"] = bounded(error.localizedDescription, bytes: 2_048)
            return try render(fields, isError: true, raw: receipt.body)
        }
        try Task.checkCancellation()
        fields["status"] = "content"
        fields["extraction"] = document.mediaType == "text/html" ? "htmlText" : "plainText"
        if let title = document.title { fields["title"] = bounded(title, bytes: 1_024) }
        var links: [[String: String]] = []
        for link in document.links {
            let candidate = links + [["text": link.text, "url": link.url.absoluteString]]
            guard try JSONSerialization.data(withJSONObject: candidate, options: [.withoutEscapingSlashes]).count <= 12_288 else { break }
            links = candidate
        }
        fields["links"] = links
        fields["linksTruncated"] = document.linksTruncated || links.count < document.links.count
        fields["linkedPagesFetched"] = false
        fields["contentBytes"] = document.text.utf8.count
        var limit = 16_384
        while true {
            let content = bounded(document.text, bytes: limit)
            fields["content"] = content
            fields["returnedContentBytes"] = content.utf8.count
            fields["truncated"] = content.utf8.count < document.text.utf8.count
            let encoded = try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys, .withoutEscapingSlashes])
            if encoded.count <= ToolBroker.previewLimit {
                return ToolResult(output: String(decoding: encoded, as: UTF8.self), isError: false, rawOutput: receipt.body)
            }
            guard limit > 0 else { throw ToolError.invalid(L10n.errorText("tool.outputLimit", table: "ToolMessages")) }
            limit /= 2
        }
    }

    private static func render(_ fields: [String: Any], isError: Bool, raw: Data? = nil) throws -> ToolResult {
        let encoded = try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys, .withoutEscapingSlashes])
        guard encoded.count <= ToolBroker.previewLimit else {
            throw ToolError.invalid(L10n.errorText("tool.outputLimit", table: "ToolMessages"))
        }
        return ToolResult(output: String(decoding: encoded, as: UTF8.self), isError: isError, rawOutput: raw ?? encoded)
    }

    private static func bounded(_ text: String, bytes: Int) -> String {
        guard text.utf8.count > bytes else { return text }
        var end = text.unicodeScalars.startIndex
        var count = 0
        while end < text.unicodeScalars.endIndex {
            let next = text.unicodeScalars[end].utf8.count
            guard next <= bytes - count else { break }
            count += next
            text.unicodeScalars.formIndex(after: &end)
        }
        return String(text[..<end])
    }
}
