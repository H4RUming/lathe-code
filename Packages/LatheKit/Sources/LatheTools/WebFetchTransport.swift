import Foundation

public struct WebFetchReceipt: Sendable {
    public enum Outcome: String, Sendable { case content, redirect, httpError }

    public let requestedURL: URL
    public let finalURL: URL
    public let statusCode: Int
    public let mimeType: String?
    public let charset: String?
    public let contentType: String?
    public let retrievedAt: Date
    public let body: Data
    public let outcome: Outcome
    /// A validated destination for a separate, newly authorized request.
    public let redirectURL: URL?
}

/// One isolated, unauthenticated GET. A redirect is a receipt, never another request.
public struct WebFetchTransport: Sendable {
    public static let maximumBodyBytes = 5 * 1_024 * 1_024
    private let protocolClasses: [AnyClass]?
    private let timeout: TimeInterval
    private let maximumBodyBytes: Int

    public init() {
        protocolClasses = nil
        timeout = 30
        maximumBodyBytes = Self.maximumBodyBytes
    }

    /// Test-only protocol and budget injection; production always uses the defaults.
    init(protocolClasses: [AnyClass], timeout: TimeInterval = 30, maximumBodyBytes: Int = Self.maximumBodyBytes) {
        self.protocolClasses = protocolClasses
        self.timeout = min(max(timeout, 0.001), 30)
        self.maximumBodyBytes = min(max(maximumBodyBytes, 0), Self.maximumBodyBytes)
    }

    public func fetch(_ request: WebFetchRequest) async throws -> WebFetchReceipt {
        let operation = WebFetchOperation(request: request, protocolClasses: protocolClasses,
                                          timeout: timeout, maximumBodyBytes: maximumBodyBytes)
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            let receipt: WebFetchReceipt = try await withCheckedThrowingContinuation { continuation in
                operation.start(continuation: continuation)
            }
            try Task.checkCancellation()
            return receipt
        } onCancel: {
            operation.cancel()
        }
    }
}

/// Delegate callbacks and cancellation may arrive on different queues. All mutable
/// state is protected by the lock; a terminal result resumes the continuation once.
private final class WebFetchOperation: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let request: WebFetchRequest
    private let protocolClasses: [AnyClass]?
    private let timeout: TimeInterval
    private let maximumBodyBytes: Int
    private let lock = NSLock()
    private var continuation: CheckedContinuation<WebFetchReceipt, any Error>?
    private var terminalResult: Result<WebFetchReceipt, any Error>?
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var timer: DispatchSourceTimer?
    private var response: HTTPURLResponse?
    private var body = Data()

    init(request: WebFetchRequest, protocolClasses: [AnyClass]?, timeout: TimeInterval, maximumBodyBytes: Int) {
        self.request = request
        self.protocolClasses = protocolClasses
        self.timeout = timeout
        self.maximumBodyBytes = maximumBodyBytes
    }

    func start(continuation: CheckedContinuation<WebFetchReceipt, any Error>) {
        lock.lock()
        if let terminalResult {
            lock.unlock()
            continuation.resume(with: terminalResult)
            return
        }
        self.continuation = continuation
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.urlCredentialStorage = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        configuration.waitsForConnectivity = false
        configuration.httpAdditionalHeaders = [:]
        if let protocolClasses { configuration.protocolClasses = protocolClasses }
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        var urlRequest = URLRequest(url: request.approvedURL, cachePolicy: .reloadIgnoringLocalCacheData,
                                    timeoutInterval: timeout)
        urlRequest.httpMethod = "GET"
        urlRequest.httpShouldHandleCookies = false
        let task = session.dataTask(with: urlRequest)
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + timeout)
        timer.setEventHandler { [weak self] in self?.finish(.failure(WebFetchError.timedOut)) }
        self.session = session
        self.task = task
        self.timer = timer
        timer.resume()
        task.resume()
        lock.unlock()
    }

    func cancel() { finish(.failure(CancellationError())) }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        guard let response = response as? HTTPURLResponse else {
            completionHandler(.cancel)
            finish(.failure(WebFetchError.invalidResponse))
            return
        }
        do {
            let receipt = try makeReceipt(response: response, body: Data())
            guard receipt.outcome == .content else {
                completionHandler(.cancel)
                finish(.success(receipt))
                return
            }
            guard response.expectedContentLength <= Int64(maximumBodyBytes) else {
                completionHandler(.cancel)
                finish(.failure(WebFetchError.responseLimit))
                return
            }
            lock.lock()
            let active = terminalResult == nil
            if active { self.response = response }
            lock.unlock()
            completionHandler(active ? .allow : .cancel)
        } catch {
            completionHandler(.cancel)
            finish(.failure(error))
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        guard terminalResult == nil else { lock.unlock(); return }
        guard data.count <= maximumBodyBytes - body.count else {
            lock.unlock()
            finish(.failure(WebFetchError.responseLimit))
            return
        }
        body.append(data)
        lock.unlock()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        if let error {
            if (error as? URLError)?.code == .timedOut {
                finish(.failure(WebFetchError.timedOut))
            } else {
                finish(.failure(WebFetchError.transport(error.localizedDescription)))
            }
            return
        }
        lock.lock()
        let response = self.response
        let body = self.body
        let active = terminalResult == nil
        lock.unlock()
        guard active else { return }
        guard let response else { finish(.failure(WebFetchError.invalidResponse)); return }
        do { finish(.success(try makeReceipt(response: response, body: body))) }
        catch { finish(.failure(error)) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
        do { finish(.success(try makeReceipt(response: response, body: Data()))) }
        catch { finish(.failure(error)) }
    }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        handle(challenge: challenge, completionHandler: completionHandler)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        handle(challenge: challenge, completionHandler: completionHandler)
    }

    private func handle(challenge: URLAuthenticationChallenge,
                        completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        completionHandler(.cancelAuthenticationChallenge, nil)
        if let response = challenge.failureResponse as? HTTPURLResponse, !(200..<300).contains(response.statusCode) {
            do { finish(.success(try makeReceipt(response: response, body: Data()))) }
            catch { finish(.failure(error)) }
        } else {
            finish(.failure(WebFetchError.authenticationRequired))
        }
    }

    private func makeReceipt(response: HTTPURLResponse, body: Data) throws -> WebFetchReceipt {
        guard let finalURL = response.url else { throw WebFetchError.invalidResponse }
        guard finalURL.absoluteString == request.approvedURL.absoluteString else { throw WebFetchError.changedURL }
        let status = response.statusCode
        let outcome: WebFetchReceipt.Outcome = (200..<300).contains(status) ? .content :
            ((300..<400).contains(status) ? .redirect : .httpError)
        var redirectURL: URL?
        if outcome == .redirect, let location = response.value(forHTTPHeaderField: "Location"),
           location.utf8.count <= WebFetchRequest.maximumURLBytes,
           let destination = URL(string: location, relativeTo: finalURL)?.absoluteURL,
           var components = URLComponents(url: destination, resolvingAgainstBaseURL: true) {
            // URL fragments are local navigation only. Never expose credentials or
            // an unsupported scheme as the destination of a suggested follow-up.
            components.fragment = nil
            if let value = components.url?.absoluteString {
                redirectURL = try? WebFetchRequest(url: value).approvedURL
            }
        }
        return WebFetchReceipt(requestedURL: request.approvedURL, finalURL: finalURL, statusCode: status,
                               mimeType: response.mimeType, charset: response.textEncodingName,
                               contentType: response.value(forHTTPHeaderField: "Content-Type"),
                               retrievedAt: Date(), body: outcome == .content ? body : Data(),
                               outcome: outcome, redirectURL: redirectURL)
    }

    private func finish(_ result: Result<WebFetchReceipt, any Error>) {
        lock.lock()
        guard terminalResult == nil else { lock.unlock(); return }
        terminalResult = result
        let continuation = self.continuation
        let session = self.session
        let task = self.task
        let timer = self.timer
        self.continuation = nil
        self.session = nil
        self.task = nil
        self.timer = nil
        body.removeAll(keepingCapacity: false)
        lock.unlock()
        timer?.cancel()
        task?.cancel()
        session?.invalidateAndCancel()
        continuation?.resume(with: result)
    }
}
