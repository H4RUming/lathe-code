import Foundation
import LatheLocalization

/// A validated destination. Creating a request performs no network or DNS work.
public struct WebFetchRequest: Equatable, Sendable {
    public static let maximumURLBytes = 8_192
    public let approvedURL: URL

    public init(url value: String) throws {
        guard !value.isEmpty, value.utf8.count <= Self.maximumURLBytes,
              !Self.containsForbiddenCharacters(value, includingWhitespace: true),
              let decoded = value.removingPercentEncoding,
              !Self.containsForbiddenCharacters(decoded, includingWhitespace: false),
              var components = URLComponents(string: value),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              value.lowercased().hasPrefix(scheme + "://"),
              components.user == nil, components.password == nil,
              components.fragment == nil,
              let host = components.host, !host.isEmpty,
              !Self.containsForbiddenCharacters(host, includingWhitespace: true),
              !host.contains(where: { "/?#@%".contains($0) }) else {
            throw WebFetchError.invalidURL
        }
        if let port = components.port, !(1...65_535).contains(port) {
            throw WebFetchError.invalidURL
        }
        // Foundation accepts an empty explicit port. Reject it instead of silently
        // turning a malformed authority into a different approved destination.
        let authority = value.dropFirst(scheme.count + 3).prefix { $0 != "/" && $0 != "?" && $0 != "#" }
        let explicitPort: Substring?
        if authority.first == "[", let bracket = authority.firstIndex(of: "]") {
            let suffix = authority[authority.index(after: bracket)...]
            guard suffix.isEmpty || suffix.first == ":" else { throw WebFetchError.invalidURL }
            explicitPort = suffix.isEmpty ? nil : suffix.dropFirst()
        } else if let colon = authority.lastIndex(of: ":") {
            explicitPort = authority[authority.index(after: colon)...]
        } else {
            explicitPort = nil
        }
        if let explicitPort {
            guard !explicitPort.isEmpty, explicitPort.utf8.allSatisfy({ (48...57).contains($0) }),
                  let port = Int(explicitPort), (1...65_535).contains(port) else {
                throw WebFetchError.invalidURL
            }
        }
        // Match URLSession's HTTP identity normalization before approval. Keep the
        // path and query otherwise exact; redirects still require a new request.
        components.scheme = scheme
        components.host = host.lowercased()
        if components.percentEncodedPath.isEmpty { components.percentEncodedPath = "/" }
        guard let destination = components.url, destination.baseURL == nil,
              destination.absoluteString.utf8.count <= Self.maximumURLBytes else {
            throw WebFetchError.invalidURL
        }
        approvedURL = destination
    }

    private static func containsForbiddenCharacters(_ value: String, includingWhitespace: Bool) -> Bool {
        value.unicodeScalars.contains {
            CharacterSet.controlCharacters.contains($0) ||
            (includingWhitespace && CharacterSet.whitespacesAndNewlines.contains($0)) || $0 == "\\"
        }
    }
}

public enum WebFetchError: Error, LocalizedError, Sendable {
    case invalidURL
    case responseLimit
    case invalidResponse
    case changedURL
    case authenticationRequired
    case timedOut
    case transport(String)

    public var errorDescription: String? {
        switch self {
        case .invalidURL: L10n.errorText("fetch.invalidURL", table: "ToolMessages")
        case .responseLimit: L10n.errorText("fetch.responseLimit", table: "ToolMessages")
        case .invalidResponse: L10n.errorText("fetch.invalidResponse", table: "ToolMessages")
        case .changedURL: L10n.errorText("fetch.changedURL", table: "ToolMessages")
        case .authenticationRequired: L10n.errorText("fetch.authenticationRequired", table: "ToolMessages")
        case .timedOut: L10n.errorText("fetch.timedOut", table: "ToolMessages")
        case .transport(let detail): L10n.errorFormat("fetch.transport", table: "ToolMessages", detail)
        }
    }
}
