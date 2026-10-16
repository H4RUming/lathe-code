import Foundation
import LatheLocalization

public protocol HTTPStreamingTransport: Sendable {
    /// Returning false stops the transport after an adapter-verified terminal event.
    func stream(request: URLRequest, onBytes: @escaping @Sendable (Data) async throws -> Bool) async throws
}

/// Each request owns its ephemeral session. Cookies, cached responses, shared credentials,
/// redirects and cross-request connection authentication are deliberately not used.
public struct URLSessionStreamingTransport: HTTPStreamingTransport {
    public init() {}

    public func stream(request: URLRequest, onBytes: @escaping @Sendable (Data) async throws -> Bool) async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 120
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.httpShouldSetCookies = false
        let session = URLSession(configuration: configuration, delegate: NoRedirectDelegate(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        try await withTaskCancellationHandler {
            let (bytes, response) = try await session.bytes(for: request)
            try Self.validate(response: response, requestedURL: request.url)
            var buffer = Data()
            for try await byte in bytes {
                try Task.checkCancellation()
                buffer.append(byte)
                if byte == 10 || byte == 13 || buffer.count >= 16384 {
                    let shouldContinue = try await onBytes(buffer)
                    buffer.removeAll(keepingCapacity: true)
                    if !shouldContinue { return }
                }
            }
            if !buffer.isEmpty { _ = try await onBytes(buffer) }
        } onCancel: {
            session.invalidateAndCancel()
        }
    }

    static func validate(response: URLResponse, requestedURL: URL?) throws {
        guard let http = response as? HTTPURLResponse else { throw ProviderError.invalidStream(L10n.text("provider.http.notHTTP", table: "ProviderErrors")) }
        guard http.url == requestedURL else { throw ProviderError.invalidStream(L10n.text("provider.http.redirectNotAllowed", table: "ProviderErrors")) }
        guard 200..<300 ~= http.statusCode else { throw ProviderError.httpStatus(http.statusCode) }
        guard http.mimeType?.lowercased() == "text/event-stream" else {
            throw ProviderError.invalidStream(L10n.text("provider.http.requiresEventStream", table: "ProviderErrors"))
        }
    }
}

final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
